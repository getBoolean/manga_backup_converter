package dev.getboolean.sourceruntime.tachi

import android.content.Context
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import android.os.RemoteException
import android.util.Log
import mangabackup.tachi.android.AndroidPackageRuntime
import mangabackup.tachi.android.AndroidWorkerRuntime
import mangabackup.tachi.protocol.QueuePipe
import org.json.JSONArray
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.io.PrintStream

/**
 * The shared protocol worker inside the `:source_runtime` process (KTD17).
 *
 * The desktop worker reads frames from stdin and writes them to stdout; here
 * Binder is its stdio. Frames from the app arrive one-way and are queued into
 * the worker's input; every frame the worker writes goes back one-way on the
 * app's reply binder ([FrameTransport]: inline, or a read-only descriptor for
 * large replies). The worker's diagnostics (stderr) follow as log lines.
 *
 * One worker per process lifetime: when it exits (`shutdown`, or its input
 * closes) the process exits, so the app always observes the end as a binder
 * death and no class loader or WebView state outlives a worker. A worker that
 * never returns is ended by the app killing this process.
 */
internal class WorkerHost(private val context: Context) {
    private val lock = Any()
    private var session: Session? = null

    val runtime: AndroidPackageRuntime by lazy { AndroidPackageRuntime(context) }

    /** Whether a worker was opened in this process. */
    val isOpen: Boolean get() = synchronized(lock) { session != null }

    /** Starts the worker with [argsJson] (a JSON string array); returns an error message or null. */
    fun open(argsJson: String, replyTo: IBinder): String? = synchronized(lock) {
        session?.let { return "a worker is already running in this process (pid ${Process.myPid()})" }
        val args = try {
            JSONArray(argsJson).let { a -> List(a.length()) { a.getString(it) } }
        } catch (e: Exception) {
            return "bad worker arguments: $e"
        }
        val pipe = QueuePipe()
        val out = FrameOutput(replyTo)
        val started = try {
            AndroidWorkerRuntime.start(context, runtime, args, pipe.input, out)
        } catch (e: Exception) {
            return "worker did not start: ${e.message ?: e.javaClass.name}"
        }
        val s = Session(pipe, out, replyTo)
        session = s
        installErr(replyTo)
        // Interactive runs only: a Cloudflare challenge opens the visible
        // challenge Activity (unattended runs keep interaction-required).
        eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor.challengeSolver =
            started.challengeTimeoutMs?.let { bound ->
                eu.kanade.tachiyomi.network.interceptor.CloudflareChallengeSolver { challenge ->
                    val finished = dev.getboolean.sourceruntime.webview.ChallengeLauncher.solve(context, challenge.url, challenge.userAgent, bound)
                    if (finished) eu.kanade.tachiyomi.network.interceptor.CloudflareSolution() else null
                }
            }
        Thread({
            val code = try {
                started.worker.run()
            } catch (t: Throwable) {
                Log.e(TAG, "worker crashed", t)
                70
            }
            eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor.challengeSolver = null
            s.exit(code)
        }, "tachi-worker").apply { isDaemon = true }.start()
        null
    }

    /** Starts the worker and reports the outcome one-way on [replyTo] ([RuntimeCodes.WORKER_STARTED]). */
    fun openAndReport(argsJson: String, replyTo: IBinder) {
        val error = try {
            open(argsJson, replyTo)
        } catch (t: Throwable) {
            "worker did not start: $t"
        }
        send(replyTo, RuntimeCodes.WORKER_STARTED) { it.writeString(error) }
    }

    /** One frame from the app, already validated and opened. */
    fun onFrame(bytes: ByteArray) {
        val s = synchronized(lock) { session } ?: return
        s.pipe.output.write(bytes)
        if (bytes.isEmpty() || bytes.last() != '\n'.code.toByte()) s.pipe.output.write('\n'.code)
    }

    /** Redirects this process's stderr (worker diagnostics, replay misses) to the log and to the app. */
    private fun installErr(replyTo: IBinder) {
        System.setErr(PrintStream(LineOutput { line ->
            Log.w(TAG, line)
            send(replyTo, RuntimeCodes.WORKER_LOG) { it.writeString(line.take(4096)) }
        }, true, "UTF-8"))
    }

    private inner class Session(val pipe: QueuePipe, val out: FrameOutput, val replyTo: IBinder) {
        fun exit(code: Int) {
            send(replyTo, RuntimeCodes.WORKER_EXIT) { it.writeInt(code) }
            Log.i(TAG, "worker exited with $code; ending the process")
            // One-way transactions are queued in order; give the exit a moment to leave, then end the process.
            Thread.sleep(EXIT_FLUSH_MS)
            Process.killProcess(Process.myPid())
        }
    }

    /** Splits the worker's output into frames and sends each one. */
    private inner class FrameOutput(private val replyTo: IBinder) : OutputStream() {
        private val buffer = ByteArrayOutputStream()

        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        @Synchronized
        override fun write(b: ByteArray, off: Int, len: Int) {
            var start = off
            val end = off + len
            for (i in off until end) {
                if (b[i] == '\n'.code.toByte()) {
                    buffer.write(b, start, i - start)
                    val frame = buffer.toByteArray()
                    buffer.reset()
                    sendFrame(frame)
                    start = i + 1
                }
            }
            if (start < end) buffer.write(b, start, end - start)
        }

        private fun sendFrame(frame: ByteArray) {
            send(replyTo, RuntimeCodes.WORKER_FRAME) { data -> FrameTransport.write(data, frame) }
        }
    }

    private class LineOutput(private val onLine: (String) -> Unit) : OutputStream() {
        private val buffer = ByteArrayOutputStream()

        override fun write(b: Int) {
            if (b == '\n'.code) flushLine() else buffer.write(b)
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            for (i in off until off + len) write(b[i].toInt())
        }

        private fun flushLine() {
            onLine(buffer.toString("UTF-8"))
            buffer.reset()
        }
    }

    private fun send(replyTo: IBinder, code: Int, write: (Parcel) -> Any?) {
        val data = Parcel.obtain()
        var handle: java.io.Closeable? = null
        try {
            data.writeInterfaceToken(RuntimeCodes.REPLY_DESCRIPTOR)
            handle = write(data) as? java.io.Closeable
            replyTo.transact(code, data, null, IBinder.FLAG_ONEWAY)
        } catch (e: RemoteException) {
            Log.w(TAG, "app reply binder gone; dropping transaction $code")
        } finally {
            handle?.close()
            data.recycle()
        }
    }

    companion object {
        private const val TAG = "TachiWorkerHost"
        private const val EXIT_FLUSH_MS = 200L
    }
}
