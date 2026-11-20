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
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The private `:source_runtime` service process (KTD17).
 *
 * It owns every Tachi package class loader and source call. Calls arrive as
 * one-way [RuntimeProtocol.DISPATCH] transactions and run on service-owned
 * threads; each reply goes back one-way on the caller's reply binder. A call
 * that never returns (a CPU loop) is ended only by killing this process,
 * which the client does with the PID reported by [RuntimeProtocol.HELLO].
 */
class SourceRuntimeService : Service() {
    private lateinit var executor: ExecutorService
    private lateinit var webViews: WebViewHolder

    override fun onCreate() {
        super.onCreate()
        // Must run before anything in this process touches WebView or
        // CookieManager (KTD19). Below API 28 the call does not exist; see
        // docs/validation/source-runners/android/ for the U17 decision.
        dataDirectorySuffixApplied = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WebView.setDataDirectorySuffix(WEBVIEW_DATA_SUFFIX)
            true
        } else {
            false
        }
        executor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "source-runtime-call").apply { isDaemon = true }
        }
        webViews = WebViewHolder(applicationContext)
        Log.i(TAG, "created pid=${Process.myPid()} sdk=${Build.VERSION.SDK_INT} suffix=$dataDirectorySuffixApplied")
    }

    override fun onBind(intent: Intent): IBinder = binder

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
