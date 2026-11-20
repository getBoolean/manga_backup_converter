package mangabackup.tachi.protocol

import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.LinkedBlockingQueue

/**
 * An in-memory byte pipe safe for many writer threads. java.io.Piped* streams
 * fail with "Write end dead" once the last writing thread exits, which breaks
 * a worker that answers from pool and browser threads.
 */
class QueuePipe {
    private val chunks = LinkedBlockingQueue<ByteArray>()
    private val eof = ByteArray(0)

    val output: OutputStream = object : OutputStream() {
        @Volatile
        private var closed = false

        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        override fun write(b: ByteArray, off: Int, len: Int) {
            if (closed) throw java.io.IOException("pipe closed")
            if (len > 0) chunks.put(b.copyOfRange(off, off + len))
        }

        override fun close() {
            if (!closed) {
                closed = true
                chunks.put(eof)
            }
        }
    }

    val input: InputStream = object : InputStream() {
        private var current: ByteArray? = null
        private var pos = 0
        private var ended = false

        private fun fill(): Boolean {
            if (ended) return false
            while (current == null || pos >= current!!.size) {
                val next = chunks.take()
                if (next === eof) {
                    ended = true
                    return false
                }
                current = next
                pos = 0
            }
            return true
        }

        override fun read(): Int = if (fill()) current!![pos++].toInt() and 0xff else -1

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            if (!fill()) return -1
            val n = minOf(len, current!!.size - pos)
            System.arraycopy(current!!, pos, b, off, n)
            pos += n
            return n
        }
    }
}
