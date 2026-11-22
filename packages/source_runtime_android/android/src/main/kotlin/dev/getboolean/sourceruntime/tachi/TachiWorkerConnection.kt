package dev.getboolean.sourceruntime.tachi

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import android.os.RemoteException
import androidx.annotation.Keep
import dev.getboolean.sourceruntime.SourceRuntimeService
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Callbacks from [TachiWorkerConnection] to the Dart backend. Dart implements
 * it through JNIgen with every method registered as an asynchronous listener,
 * so the Java caller only posts to the isolate and returns (KTD18, KTD23).
 * All calls come from the connection's single executor thread, in order.
 */
@Keep
interface TachiWorkerListener {
    /** The worker started in the service process [pid] (the PID [TachiWorkerConnection.kill] targets). */
    fun onStarted(pid: Int, sdkInt: Int)

    /** Binding or starting the worker failed; [onExit] follows. */
    fun onStartFailed(message: String)

    /** One protocol frame from the worker (without its newline). */
    fun onFrame(frame: String)

    /** One diagnostics line from the worker process (stderr). */
    fun onLog(line: String)

    /**
     * The worker's process is gone (binder death notification, or a failed
     * start). [code] is the exit code the worker reported, or 137 when the
     * process was killed. Called exactly once.
     */
    fun onExit(code: Int)
}

/**
 * App-process facade over one Tachi worker in the `:source_runtime` service
 * (KTD18): the Android counterpart of a desktop worker process, so the Dart
 * `WorkerSupervisor` drives it unchanged.
 *
 * Every method returns at once. [start] binds the service (explicitly, never
 * exported), asks it for its PID, and opens the worker; frames go out
 * one-way and come back one-way on a reply binder. Binder threads only hand
 * work to this connection's executor and return, so no Binder thread waits on
 * Dart. Large frames travel as read-only descriptors ([FrameTransport]).
 *
 * A connection is one worker lifetime. On binder death it unbinds first, so
 * the framework never restarts the service behind the supervisor; the
 * supervisor starts a new connection for the next generation.
 */
@Keep
class TachiWorkerConnection(context: Context, private val listener: TachiWorkerListener) {
    private val appContext: Context = context.applicationContext
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "tachi-worker-client").apply { isDaemon = true }
    }
    private val exited = AtomicBoolean(false)
    private val started = AtomicBoolean(false)

    @Volatile private var remote: IBinder? = null
    @Volatile private var bound = false
    @Volatile private var exitCode = KILLED

    /** PID of the service process hosting this worker, or 0 before [TachiWorkerListener.onStarted]. */
    @Volatile
    var pid: Int = 0
        private set

    /** Descriptor (large-frame) transfers received so far in this process, for receipts. */
    val descriptorFramesReceived: Long get() = FrameTransport.descriptorFramesReceived.get()

    /** Descriptors closed so far in this process, for receipts. */
    val descriptorsClosed: Long get() = FrameTransport.descriptorsClosed.get()

    /**
     * Binder, death and service-connection callbacks reach this connection
     * through clearable relays. system_server and the dead service can keep
     * the framework objects (InnerConnection, JavaBBinder) alive until their
     * own GC; the relays are cleared at exit so they no longer pin this
     * connection or the Dart listener proxy behind it (KTD23 reference bounds).
     */
    private class Relay(@Volatile var target: TachiWorkerConnection?) : Binder(), ServiceConnection, IBinder.DeathRecipient {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean =
            target?.onReply(code, data) ?: super.onTransact(code, data, reply, flags)

        override fun binderDied() {
            target?.onGone()
        }

        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            target?.let { t -> t.post { t.open(service) } }
        }

        override fun onServiceDisconnected(name: ComponentName) = Unit

        override fun onBindingDied(name: ComponentName) {
            target?.onGone()
        }

        override fun onNullBinding(name: ComponentName) {
            target?.let { t -> t.post { t.fail("service returned no binder") } }
        }
    }

    private val relay = Relay(this)

    private fun onReply(code: Int, data: Parcel): Boolean {
            when (code) {
                RuntimeCodes.WORKER_FRAME -> {
                    data.enforceInterface(RuntimeCodes.REPLY_DESCRIPTOR)
                    val received = try {
                        FrameTransport.read(data)
                    } catch (e: Exception) {
                        post { listener.onLog("[client] dropped a malformed frame transfer: ${e.message}") }
                        return true
                    }
                    // Binder thread: hand off; the executor validates and decodes in arrival order.
                    post {
                        val bytes = try {
                            received.open()
                        } catch (e: Exception) {
                            // A frame that fails validation must not be skipped silently: the supervisor
                            // would wait for a reply that never comes. Ending the worker restarts it.
                            listener.onLog("[client] frame failed validation: ${e.message}; ending the worker")
                            kill()
                            return@post
                        }
                        listener.onFrame(String(bytes, Charsets.UTF_8))
                    }
                    return true
                }
                RuntimeCodes.WORKER_LOG -> {
                    data.enforceInterface(RuntimeCodes.REPLY_DESCRIPTOR)
                    val line = data.readString() ?: ""
                    post { listener.onLog(line) }
                    return true
                }
                RuntimeCodes.WORKER_STARTED -> {
                    data.enforceInterface(RuntimeCodes.REPLY_DESCRIPTOR)
                    val error = data.readString()
                    post { started(error) }
                    return true
                }
                RuntimeCodes.WORKER_EXIT -> {
                    data.enforceInterface(RuntimeCodes.REPLY_DESCRIPTOR)
                    exitCode = data.readInt()
                    return true
                }
            }
            return false
    }

    /**
     * Binds the service and starts the worker with [argsJson] (a JSON array of
     * worker arguments). Returns false if this connection was already started.
     */
    fun start(argsJson: String): Boolean {
        if (!started.compareAndSet(false, true)) return false
        this.argsJson = argsJson
        val ok = try {
            appContext.bindService(Intent(appContext, SourceRuntimeService::class.java), relay, Context.BIND_AUTO_CREATE)
        } catch (e: SecurityException) {
            false
        }
        bound = ok
        if (!ok) post { fail("bindService returned false") }
        return true
    }

    @Volatile private var argsJson: String = "[]"

    /** Sends one frame one-way. Returns false when the worker is not running. */
    fun send(frame: String): Boolean {
        val target = remote ?: return false
        if (exited.get()) return false
        val data = Parcel.obtain()
        var handle: java.io.Closeable? = null
        return try {
            data.writeInterfaceToken(RuntimeCodes.DESCRIPTOR)
            handle = FrameTransport.write(data, frame.toByteArray(Charsets.UTF_8))
            target.transact(RuntimeCodes.WORKER_FRAME_IN, data, null, IBinder.FLAG_ONEWAY)
            true
        } catch (e: RemoteException) {
            false
        } catch (e: IllegalArgumentException) {
            post { listener.onLog("[client] refused to send: ${e.message}") }
            false
        } finally {
            handle?.close()
            data.recycle()
        }
    }

    /**
     * Kills the worker's service process by the PID it reported at start. Only
     * this app's own `:source_runtime` process can be targeted, never the app
     * process. The end is then observed as a binder death ([TachiWorkerListener.onExit]).
     */
    fun kill(): Boolean {
        val target = pid
        if (target <= 0 || target == Process.myPid()) return false
        Process.killProcess(target)
        return true
    }

    /** Unbinds without killing; the service ends its worker when no client is bound. */
    fun close() {
        unbind()
        executor.shutdown()
    }

    private fun open(service: IBinder) {
        if (exited.get()) return
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            linked = service
            service.linkToDeath(relay, 0)
            data.writeInterfaceToken(RuntimeCodes.DESCRIPTOR)
            service.transact(dev.getboolean.sourceruntime.RuntimeProtocol.HELLO, data, reply, 0)
            reply.readException()
            val servicePid = reply.readInt()
            val sdkInt = reply.readInt()
            data.setDataPosition(0)
            data.setDataSize(0)
            reply.setDataPosition(0)
            reply.setDataSize(0)
            pid = servicePid
            this.sdkInt = sdkInt
            pendingRemote = service
            data.writeInterfaceToken(RuntimeCodes.DESCRIPTOR)
            data.writeString(argsJson)
            data.writeStrongBinder(relay)
            service.transact(RuntimeCodes.WORKER_OPEN, data, null, IBinder.FLAG_ONEWAY)
        } catch (e: RemoteException) {
            fail("worker start failed: ${e.message}")
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    @Volatile private var linked: IBinder? = null
    @Volatile private var pendingRemote: IBinder? = null
    @Volatile private var sdkInt: Int = 0

    private fun started(error: String?) {
        if (exited.get()) return
        if (error != null) {
            fail(error)
            return
        }
        remote = pendingRemote
        listener.onStarted(pid, sdkInt)
    }

    private fun fail(message: String) {
        listener.onStartFailed(message)
        // A worker that did not start leaves nothing to fence; report its end now.
        unbind()
        reportExit(START_FAILED)
    }

    private fun onGone() {
        unbind()
        post { reportExit(exitCode) }
    }

    private fun reportExit(code: Int) {
        if (exited.compareAndSet(false, true)) {
            remote = null
            listener.onExit(code)
            relay.target = null
        }
    }

    @Synchronized
    private fun unbind() {
        linked?.let { runCatching { it.unlinkToDeath(relay, 0) } }
        linked = null
        if (bound) {
            bound = false
            runCatching { appContext.unbindService(relay) }
        }
    }

    private fun post(block: () -> Unit) {
        try {
            executor.execute(block)
        } catch (_: RejectedExecutionException) {
            // Closed: callbacks after close are dropped by design.
        }
    }

    companion object {
        /** Exit code reported when the process was killed (no exit code arrived). */
        const val KILLED = 137

        /** Exit code reported when the worker never started. */
        const val START_FAILED = 70
    }
}
