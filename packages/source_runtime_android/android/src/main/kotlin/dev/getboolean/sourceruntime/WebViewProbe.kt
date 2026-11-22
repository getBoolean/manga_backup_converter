package dev.getboolean.sourceruntime

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.Keep
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Creates a WebView on this process's main looper, loads local content and
 * reads a JavaScript result back, then keeps the WebView alive until
 * [release]. Used in both processes to prove that the app-process and
 * service-process WebViews coexist (KTD19).
 *
 * Callers wait on a native latch from a non-main thread they own; the main
 * thread and Dart never wait.
 */
internal class WebViewHolder(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val live = mutableListOf<WebView>()

    fun probe(dataDirectorySuffixApplied: Boolean): JSONObject {
        check(Looper.myLooper() != Looper.getMainLooper()) { "probe must not run on the main thread" }
        val done = CountDownLatch(1)
        val result = AtomicReference<String?>()
        val failure = AtomicReference<Throwable?>()
        main.post {
            try {
                createAndLoad(result, done)
            } catch (e: Throwable) {
                failure.set(e)
                done.countDown()
            }
        }
        if (!done.await(PROBE_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            throw IllegalStateException("WebView probe timed out after ${PROBE_TIMEOUT_SECONDS}s")
        }
        failure.get()?.let { throw it }
        return JSONObject()
            .put("pid", android.os.Process.myPid())
            .put("processName", SourceRuntimeService.currentProcessName())
            .put("sdkInt", Build.VERSION.SDK_INT)
            .put("jsResult", result.get())
            .put("liveWebViews", synchronized(live) { live.size })
            .put("dataDirectorySuffixApplied", dataDirectorySuffixApplied)
            .put("webViewPackage", webViewPackage())
            .put("webViewDataDirs", webViewDataDirs())
    }

    fun release(): JSONObject {
        val done = CountDownLatch(1)
        var released = 0
        main.post {
            synchronized(live) {
                released = live.size
                live.forEach { it.destroy() }
                live.clear()
            }
            done.countDown()
        }
        done.await(PROBE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        return JSONObject().put("released", released)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createAndLoad(result: AtomicReference<String?>, done: CountDownLatch) {
        val view = WebView(context)
        synchronized(live) { live.add(view) }
        view.settings.javaScriptEnabled = true
        view.webViewClient = object : WebViewClient() {
            override fun onPageFinished(webView: WebView, url: String?) {
                webView.evaluateJavascript(PROBE_SCRIPT) { value ->
                    result.set(value)
                    done.countDown()
                }
            }
        }
        view.loadDataWithBaseURL(null, PROBE_HTML, "text/html", "utf-8", null)
    }

    private fun webViewPackage(): JSONObject? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val pkg = WebView.getCurrentWebViewPackage() ?: return null
        return JSONObject().put("packageName", pkg.packageName).put("versionName", pkg.versionName)
    }

    private fun webViewDataDirs(): JSONArray {
        val names = context.dataDir.list()?.filter { it.startsWith("app_webview") }?.sorted().orEmpty()
        return JSONArray(names)
    }

    companion object {
        const val PROBE_TIMEOUT_SECONDS = 30L
        const val PROBE_HTML = "<html><body><p id=\"g\">gate</p></body></html>"
        const val PROBE_SCRIPT = "document.getElementById('g').textContent + ':' + (6 * 7)"
    }
}

/** Result callback for [AppWebViewProbe]; implemented in Dart as a listener. */
@Keep
interface ProbeListener {
    fun onResult(ok: Boolean, payload: String)
}

/**
 * App-process WebView probe driven from Dart through JNIgen. The work runs on
 * a probe-owned thread; Dart gets the result through [ProbeListener].
 */
@Keep
class AppWebViewProbe(context: Context) {
    private val holder = WebViewHolder(context.applicationContext)

    fun probe(listener: ProbeListener) {
        runOffMain(listener) { holder.probe(dataDirectorySuffixApplied = false) }
    }

    /** Destroys every WebView this probe created. */
    fun destroyAll(listener: ProbeListener) {
        runOffMain(listener) { holder.release() }
    }

    private fun runOffMain(listener: ProbeListener, block: () -> JSONObject) {
        Thread({
            val (ok, payload) = try {
                true to block().toString()
            } catch (e: Throwable) {
                false to JSONObject().put("error", e.javaClass.name).put("message", e.message ?: "").toString()
            }
            listener.onResult(ok, payload)
        }, "source-runtime-app-webview").apply { isDaemon = true }.start()
    }
}
