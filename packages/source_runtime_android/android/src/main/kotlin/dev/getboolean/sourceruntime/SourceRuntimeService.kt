package dev.getboolean.sourceruntime

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import android.os.RemoteException
import android.util.Log
import android.webkit.WebView
import dev.getboolean.sourceruntime.tachi.FrameTransport
import dev.getboolean.sourceruntime.tachi.RuntimeCodes
import dev.getboolean.sourceruntime.tachi.ServiceDiagnostics
import dev.getboolean.sourceruntime.tachi.WorkerHost
import mangabackup.tachi.android.ServiceWebViews
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The private `:source_runtime` service process (KTD17).
 *
 * It owns every Tachi package class loader and source call: the shared
 * protocol worker runs here ([WorkerHost], driven by `TachiWorkerConnection`
 * in the app process). Gate and diagnostics calls arrive as one-way
 * [RuntimeProtocol.DISPATCH] transactions and run on service-owned threads;
 * each reply goes back one-way on the caller's reply binder. A call that never
 * returns (a CPU loop) is ended only by killing this process, which the client
 * does with the PID reported by [RuntimeProtocol.HELLO].
 *
 * On every start, before anything touches WebView, the service deletes the
 * WebView data an earlier (possibly killed) instance left behind (KTD19/KTD20)
 * and any artifacts it had staged, then applies its data directory suffix.
 */
class SourceRuntimeService : Service() {
    private lateinit var executor: ExecutorService
    private lateinit var webViews: WebViewHolder
    private lateinit var worker: WorkerHost

    override fun onCreate() {
        super.onCreate()
        // Must run before anything in this process touches WebView or
        // CookieManager (KTD19). minSdk is 28, so the suffix call always exists.
        startupWipe = ServiceWebViews.wipeDataDirectories(applicationContext)
        WebView.setDataDirectorySuffix(WEBVIEW_DATA_SUFFIX)
        dataDirectorySuffixApplied = true
        worker = WorkerHost(applicationContext)
        worker.runtime.staging.clear()
        executor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "source-runtime-call").apply { isDaemon = true }
        }
        webViews = WebViewHolder(applicationContext)
        Log.i(TAG, "created pid=${Process.myPid()} sdk=${Build.VERSION.SDK_INT} suffix=$dataDirectorySuffixApplied")
    }

    override fun onBind(intent: Intent): IBinder = binder

    override fun onUnbind(intent: Intent): Boolean {
        // No client is left. A worker must not outlive its supervisor: the next
        // supervisor would find this process busy. End it, as a killed worker would.
        if (worker.isOpen) {
            Log.i(TAG, "last client unbound with a worker running; ending the process")
            Process.killProcess(Process.myPid())
        }
        return false
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }

    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            when (code) {
                RuntimeProtocol.HELLO -> {
                    data.enforceInterface(RuntimeProtocol.DESCRIPTOR)
                    reply?.writeNoException()
                    reply?.writeInt(Process.myPid())
                    reply?.writeInt(Build.VERSION.SDK_INT)
                    return true
                }
                RuntimeCodes.WORKER_OPEN -> {
                    data.enforceInterface(RuntimeProtocol.DESCRIPTOR)
                    val args = data.readString() ?: "[]"
                    val replyTo = data.readStrongBinder() ?: return true
                    // Off the Binder thread: starting may take seconds.
                    executor.execute { worker.openAndReport(args, replyTo) }
                    return true
                }
                RuntimeCodes.WORKER_FRAME_IN -> {
                    data.enforceInterface(RuntimeProtocol.DESCRIPTOR)
                    val received = try {
                        FrameTransport.read(data)
                    } catch (e: Exception) {
                        Log.w(TAG, "dropped a malformed frame transfer: ${e.message}")
                        return true
                    }
                    // One-way transactions to this binder arrive in order; keep the
                    // order by opening and queueing here (both are bounded and quick).
                    try {
                        worker.onFrame(received.open())
                    } catch (e: Exception) {
                        Log.e(TAG, "frame from the app failed validation; ending the worker", e)
                        Process.killProcess(Process.myPid())
                    }
                    return true
                }
                RuntimeProtocol.DISPATCH -> {
                    data.enforceInterface(RuntimeProtocol.DESCRIPTOR)
                    val callId = data.readLong()
                    val op = data.readString() ?: ""
                    val args = data.readString() ?: "{}"
                    val replyTo = data.readStrongBinder() ?: return true
                    executor.execute { run(callId, op, args, replyTo) }
                    return true
                }
            }
            return super.onTransact(code, data, reply, flags)
        }
    }

    private fun run(callId: Long, op: String, argsJson: String, replyTo: IBinder) {
        val (ok, payload) = try {
            val args = JSONObject(argsJson)
            true to handle(op, args).toString()
        } catch (e: Throwable) {
            false to JSONObject()
                .put("error", e.javaClass.name)
                .put("message", e.message ?: "")
                .toString()
        }
        sendReply(replyTo, callId, ok, payload)
    }

    private fun handle(op: String, args: JSONObject): JSONObject = when (op) {
        "ping" -> JSONObject()
            .put("pid", Process.myPid())
            .put("processName", currentProcessName())
            .put("sdkInt", Build.VERSION.SDK_INT)
        "cpuLoop" -> GateFixtures.cpuLoop()
        "loadExtension" -> ExtensionLoader(applicationContext).load(
            path = args.getString("path"),
            expectedSha256 = args.getString("sha256"),
        )
        "webViewProbe" -> webViews.probe(dataDirectorySuffixApplied)
        "webViewRelease" -> webViews.release()
        "gc" -> JSONObject().also { RuntimeDiagnostics.collectJavaGarbage() }
        "diagnostics" -> ServiceDiagnostics.collect(applicationContext, worker, startupWipe, args)
        "showChallenge" -> dev.getboolean.sourceruntime.webview.ChallengeLauncher.show(
            applicationContext,
            args.getString("url"),
            args.optLong("timeoutMs", 15_000),
        )
        "closeChallenge" -> dev.getboolean.sourceruntime.webview.ChallengeLauncher.close(args.optLong("timeoutMs", 15_000))
        else -> throw IllegalArgumentException("unknown op: $op")
    }

    private fun sendReply(replyTo: IBinder, callId: Long, ok: Boolean, payload: String) {
        val bounded = if (payload.length > RuntimeProtocol.MAX_MESSAGE_CHARS) {
            JSONObject().put("error", "response-too-large").put("length", payload.length).toString()
        } else {
            payload
        }
        val data = Parcel.obtain()
        try {
            data.writeInterfaceToken(RuntimeProtocol.REPLY_DESCRIPTOR)
            data.writeLong(callId)
            data.writeInt(if (ok && bounded === payload) 1 else 0)
            data.writeString(bounded)
            replyTo.transact(RuntimeProtocol.REPLY, data, null, IBinder.FLAG_ONEWAY)
        } catch (e: RemoteException) {
            Log.w(TAG, "reply $callId dropped: client gone", e)
        } finally {
            data.recycle()
        }
    }

    companion object {
        private const val TAG = "SourceRuntimeService"
        const val WEBVIEW_DATA_SUFFIX = "source_runtime"

        @Volatile
        var dataDirectorySuffixApplied = false
            private set

        /** WebView data directories removed at this process's start. */
        @Volatile
        var startupWipe: List<String> = emptyList()
            private set

        fun currentProcessName(): String =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                android.app.Application.getProcessName()
            } else {
                runCatching {
                    java.io.File("/proc/self/cmdline").readText().trimEnd('\u0000')
                }.getOrDefault("")
            }
    }
}
