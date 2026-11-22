package dev.getboolean.sourceruntime.tachi

import android.os.Parcel
import android.os.SharedMemory
import android.system.OsConstants
import java.io.Closeable
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong

/**
 * Carries one protocol frame across Binder (KTD18).
 *
 * Binder carries bounded control messages only: a frame of at most
 * [INLINE_LIMIT] bytes travels inline. A larger one (a long chapter list)
 * travels as a read-only [SharedMemory] descriptor with its length and
 * SHA-256, which the receiver validates before use. The sender closes its
 * descriptor right after the transaction; the receiver closes its copy on
 * every path, so nothing is left behind (shared memory is never a file on
 * disk, so there is nothing to unlink). The 16 MiB logical frame limit of
 * protocol v1 still applies on top.
 */
internal object FrameTransport {
    /** Inline frame bound in bytes, well under the process-wide 1 MiB Binder buffer shared by pending calls. */
    const val INLINE_LIMIT = 32 * 1024

    /** Protocol v1 frame limit (16 MiB) plus framing slack. */
    const val MAX_FRAME_BYTES = 16 * 1024 * 1024 + 1024

    private const val INLINE = 0
    private const val DESCRIPTOR = 1

    val descriptorFramesSent = AtomicLong()
    val descriptorFramesReceived = AtomicLong()
    val descriptorBytesReceived = AtomicLong()
    val descriptorsClosed = AtomicLong()

    /** Writes [frame] to [parcel]; the returned handle must be closed after the transaction. */
    fun write(parcel: Parcel, frame: ByteArray): Closeable {
        require(frame.size <= MAX_FRAME_BYTES) { "frame of ${frame.size} bytes exceeds $MAX_FRAME_BYTES" }
        if (frame.size <= INLINE_LIMIT) {
            parcel.writeInt(INLINE)
            parcel.writeByteArray(frame)
            return Closeable {}
        }
        val memory = SharedMemory.create("source-runtime-frame", frame.size)
        try {
            val buffer = memory.mapReadWrite()
            try {
                buffer.put(frame)
            } finally {
                SharedMemory.unmap(buffer)
            }
            check(memory.setProtect(OsConstants.PROT_READ)) { "could not make the frame descriptor read-only" }
            parcel.writeInt(DESCRIPTOR)
            parcel.writeInt(frame.size)
            parcel.writeString(sha256(frame))
            memory.writeToParcel(parcel, 0)
            descriptorFramesSent.incrementAndGet()
        } catch (t: Throwable) {
            memory.close()
            throw t
        }
        return Closeable {
            memory.close()
            descriptorsClosed.incrementAndGet()
        }
    }

    /** A frame read off a Parcel; [open] validates and returns its bytes and always releases the descriptor. */
    sealed interface Received {
        fun open(): ByteArray
    }

    private class Inline(val bytes: ByteArray) : Received {
        override fun open() = bytes
    }

    private class Shared(val memory: SharedMemory, val length: Int, val digest: String) : Received {
        override fun open(): ByteArray {
            try {
                if (memory.size != length) throw FrameException("descriptor holds ${memory.size} bytes, expected $length")
                val buffer = memory.mapReadOnly()
                val bytes = try {
                    ByteArray(length).also { buffer.get(it) }
                } finally {
                    SharedMemory.unmap(buffer)
                }
                val actual = sha256(bytes)
                if (actual != digest) throw FrameException("descriptor digest $actual does not match $digest")
                descriptorFramesReceived.incrementAndGet()
                descriptorBytesReceived.addAndGet(length.toLong())
                return bytes
            } finally {
                memory.close()
                descriptorsClosed.incrementAndGet()
            }
        }
    }

    /** Reads the frame [write] wrote. Cheap: safe on a Binder thread; call [Received.open] elsewhere. */
    fun read(parcel: Parcel): Received = when (val mode = parcel.readInt()) {
        INLINE -> Inline(parcel.createByteArray() ?: ByteArray(0))
        DESCRIPTOR -> {
            val length = parcel.readInt()
            val digest = parcel.readString() ?: ""
            val memory = SharedMemory.CREATOR.createFromParcel(parcel)
            if (length < 0 || length > MAX_FRAME_BYTES) {
                memory.close()
                throw FrameException("descriptor frame length $length out of range")
            }
            Shared(memory, length, digest)
        }
        else -> throw FrameException("unknown frame mode $mode")
    }

    fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    class FrameException(message: String) : RuntimeException(message)
}
