package dev.getboolean.sourceruntime.browser

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.annotation.Keep
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Probes when `WebViewCompat.setProfile` still succeeds on a WebView (U12,
 * KTD19): right after construction, after a settings change, after
 * `addJavascriptInterface`, after a load and after an evaluation. Run in the
 * app process (Paperback sessions assign the profile right after
 * construction) and in `:source_runtime` (extensions construct and configure
 * their own WebView), so the receipt shows whether the service could assign
 * a profile to an extension-created WebView at all. Also records whether a
 * profile can be deleted right after its WebView is destroyed.
 */
@Keep
object ProfileProbe {
    private val stages = listOf("afterConstruction", "afterSettings", "afterAddJavascriptInterface", "afterLoad", "afterEvaluate")

    /** Runs on the main looper; blocks the calling (non-main) thread, bounded. */
    fun runBlocking(context: Context): String {
        check(Looper.myLooper() != Looper.getMainLooper()) { "runBlocking must not run on the main thread" }
        val done = CountDownLatch(1)
        val out = AtomicReference<JSONObject>()
        Handler(Looper.getMainLooper()).post { run(context) { out.set(it); done.countDown() } }
        if (!done.await(60, TimeUnit.SECONDS)) return JSONObject().put("error", "probe timed out").toString()
        return out.get().toString()
    }

    /** Main looper only; [done] receives the matrix once every stage ran. */
    fun run(context: Context, done: (JSONObject) -> Unit) {
        val result = JSONObject()
            .put("process", android.os.Process.myPid())
            .put("multiProfile", WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE))
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            done(result.put("stages", JSONObject()))
            return
        }
        val matrix = JSONObject()
        fun next(i: Int) {
            if (i == stages.size) {
                done(result.put("stages", matrix))
                return
            }
            stage(context, stages[i]) { outcome ->
                matrix.put(stages[i], outcome)
                next(i + 1)
            }
        }
        next(0)
    }

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    private fun stage(context: Context, stage: String, done: (JSONObject) -> Unit) {
        val store = ProfileStore.getInstance()
        val name = "srt-probe-${System.nanoTime()}"
        store.getOrCreateProfile(name)
        val view = WebView(context.applicationContext)
        val main = Handler(Looper.getMainLooper())

        fun attempt() {
            val outcome = JSONObject()
            val set = runCatching { WebViewCompat.setProfile(view, name) }
            outcome.put("setProfile", if (set.isSuccess) "ok" else "${set.exceptionOrNull()?.javaClass?.simpleName}: ${set.exceptionOrNull()?.message}")
            if (set.isSuccess) {
                outcome.put("profileInUse", runCatching { WebViewCompat.getProfile(view).name }.getOrNull())
            }
            view.destroy()
            fun delete(n: Int) {
                val deleted = runCatching { store.deleteProfile(name) }
                if (deleted.isFailure && n < 40) {
                    main.postDelayed({ delete(n + 1) }, 50)
                    return
                }
                outcome.put("deleteAfterDestroy", if (deleted.isSuccess) "ok after ${n + 1} attempts" else "${deleted.exceptionOrNull()}")
                done(outcome)
            }
            delete(0)
        }

        if (stage == "afterConstruction") return attempt()
        view.settings.javaScriptEnabled = true
        if (stage == "afterSettings") return attempt()
        view.addJavascriptInterface(Bridge(), "probe")
        if (stage == "afterAddJavascriptInterface") return attempt()
        view.webViewClient = object : android.webkit.WebViewClient() {
            override fun onPageFinished(webView: WebView, url: String?) {
                if (stage == "afterLoad") {
                    attempt()
                } else {
                    webView.evaluateJavascript("1 + 1") { attempt() }
                }
            }
        }
        view.loadDataWithBaseURL("https://probe.invalid/", "<html><body>probe</body></html>", "text/html", "utf-8", null)
    }

    private class Bridge {
        @JavascriptInterface
        fun postMessage(@Suppress("UNUSED_PARAMETER") message: String) = Unit
    }
}
