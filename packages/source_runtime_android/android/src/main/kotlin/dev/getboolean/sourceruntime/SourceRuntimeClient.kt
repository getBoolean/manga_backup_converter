package dev.getboolean.sourceruntime

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import android.os.RemoteException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * App-process facade over the `:source_runtime` bound service (KTD18).
 *
 * Dart calls [bind], [dispatch], [kill] and [unbind] synchronously through
 * JNIgen; each returns at once. Results arrive on [listener], always from
 * this client's single executor thread: Binder threads only hand work to that
 * executor and return, so no Binder thread waits on Dart.
 *
 * Each bind opens a new generation. Replies and death notifications carry it,
 * so the Dart side can fence stale results. On binder death the dead
 * connection is unbound before anything else, which stops the framework from
 * restarting the service behind the caller's back; the caller rebinds
 * explicitly.
 */
class SourceRuntimeClient(context: Context, private val listener: SourceRuntimeListener) {
    private val appContext: Context = context.applicationContext
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "source-runtime-client").apply { isDaemon = true }
    }
    private val nextCallId = AtomicLong(1)
    private val lock = Any()

    private var generation = 0L
    private var connection: GenerationConnection? = null

    /** PID the current generation's service reported at bind time, or 0. */
    val boundPid: Int
        get() = synchronized(lock) { connection?.pid ?: 0 }

    /** Generation of the current connection, or 0 when unbound. */
    val currentGeneration: Long
        get() = synchronized(lock) { connection?.generation ?: 0L }

    /**
     * Starts binding a new generation and returns its number. Completion is
     * reported through [SourceRuntimeListener.onBound] or
     * [SourceRuntimeListener.onBindFailed]. Any previous connection is
     * unbound first.
     */
    fun bind(): Long {
        val conn: GenerationConnection
        synchronized(lock) {
            connection?.let { releaseLocked(it) }
            generation += 1
            conn = GenerationConnection(generation)
            connection = conn
        }
        val intent = Intent(appContext, SourceRuntimeService::class.java)
        val ok = try {
            appContext.bindService(intent, conn, Context.BIND_AUTO_CREATE)
        } catch (e: SecurityException) {
            false
        }
        if (!ok) {
            synchronized(lock) { if (connection === conn) releaseLocked(conn) }
            post { listener.onBindFailed(conn.generation, "bindService returned false") }
        }
        return conn.generation
    }

    /**
     * Dispatches [op] with [argsJson] one-way and returns its call id. The
     * reply arrives through [SourceRuntimeListener.onReply]. A call made while
     * unbound, or on a dead binder, is answered with `ok = false`.
     */
    fun dispatch(op: String, argsJson: String): Long {
        val callId = nextCallId.getAndIncrement()
        val conn = synchronized(lock) { connection }
        val remote = conn?.remote
        if (conn == null || remote == null) {
            post { listener.onReply(callId, conn?.generation ?: 0L, false, "not-bound") }
            return callId
        }
        if (op.length > RuntimeProtocol.MAX_MESSAGE_CHARS || argsJson.length > RuntimeProtocol.MAX_MESSAGE_CHARS) {
            post { listener.onReply(callId, conn.generation, false, "message-too-large") }
            return callId
        }
        val data = Parcel.obtain()
        try {
            data.writeInterfaceToken(RuntimeProtocol.DESCRIPTOR)
            data.writeLong(callId)
            data.writeString(op)
            data.writeString(argsJson)
            data.writeStrongBinder(conn.replyBinder)
            remote.transact(RuntimeProtocol.DISPATCH, data, null, IBinder.FLAG_ONEWAY)
        } catch (e: RemoteException) {
            post { listener.onReply(callId, conn.generation, false, "dead-object: ${e.message}") }
        } finally {
            data.recycle()
        }
        return callId
    }

    /**
     * Terminates the current generation's service process by the PID it
     * reported at bind time. Only this app's own `:source_runtime` process can
     * be targeted; the Flutter app process is never killed. Death is then
     * observed through the binder death notification.
     */
    fun kill(): Boolean {
        val pid = synchronized(lock) { connection?.pid ?: 0 }
        if (pid <= 0 || pid == Process.myPid()) return false
        Process.killProcess(pid)
        return true
    }

    /** Unbinds the current generation without killing its process. */
    fun unbind() {
        synchronized(lock) { connection?.let { releaseLocked(it) } }
    }

    /** Unbinds and stops the executor. The client cannot be reused. */
    fun dispose() {
        unbind()
        executor.shutdown()
    }

    private fun releaseLocked(conn: GenerationConnection) {
        if (connection === conn) connection = null
        conn.release()
    }

    private fun post(block: () -> Unit) {
        try {
            executor.execute(block)
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            // Disposed: callbacks after dispose are dropped by design.
        }
    }

    private inner class GenerationConnection(val generation: Long) : ServiceConnection, IBinder.DeathRecipient {
        @Volatile var remote: IBinder? = null
        @Volatile var pid: Int = 0
        @Volatile private var released = false
        private val deathReported = java.util.concurrent.atomic.AtomicBoolean(false)
        private var bound = true

        val replyBinder: Binder = object : Binder() {
            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                if (code != RuntimeProtocol.REPLY) return super.onTransact(code, data, reply, flags)
                data.enforceInterface(RuntimeProtocol.REPLY_DESCRIPTOR)
                val callId = data.readLong()
                val ok = data.readInt() != 0
                val payload = data.readString() ?: ""
                // Binder thread: hand off and return immediately.
                post { listener.onReply(callId, generation, ok, payload) }
                return true
            }
        }

        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            if (released || remote != null) return
            // HELLO is a short synchronous transaction to our own service; run
            // it on the executor so the main thread never waits on Binder.
            post {
                if (released) return@post
                val data = Parcel.obtain()
                val reply = Parcel.obtain()
                try {
                    service.linkToDeath(this, 0)
                    data.writeInterfaceToken(RuntimeProtocol.DESCRIPTOR)
                    service.transact(RuntimeProtocol.HELLO, data, reply, 0)
                    reply.readException()
                    val servicePid = reply.readInt()
                    val sdkInt = reply.readInt()
                    pid = servicePid
                    remote = service
                    listener.onBound(generation, servicePid, sdkInt)
                } catch (e: RemoteException) {
                    listener.onBindFailed(generation, "hello failed: ${e.message}")
                } finally {
                    data.recycle()
                    reply.recycle()
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            // Death is reported through binderDied; nothing to do here. The
            // framework would restart the service while still bound, so
            // binderDied unbinds first.
        }

        override fun onBindingDied(name: ComponentName) {
            binderDied()
        }

        override fun binderDied() {
            if (!deathReported.compareAndSet(false, true)) return
            val deadPid = pid
            synchronized(lock) { releaseLocked(this) }
            post { listener.onDeath(generation, deadPid) }
        }

        fun release() {
            if (released) return
            released = true
            remote?.let { runCatching { it.unlinkToDeath(this, 0) } }
            if (bound) {
                bound = false
                runCatching { appContext.unbindService(this) }
            }
        }
    }
}
