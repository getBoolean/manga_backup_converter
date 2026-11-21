package dev.getboolean.sourceruntime.webview

import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Process
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Visible source challenges (KTD19): an Activity declared in the
 * `:source_runtime` process, so it shares the service process's WebView
 * profile (cookies a solved challenge sets are the ones the source's WebViews
 * and later page loads see). It loads only http(s) URLs and refuses
 * navigation to any other scheme (KTD20).
 */
class ChallengeActivity : Activity() {
    private var webView: WebView? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL)
        if (url == null || !ChallengeLauncher.isWebUrl(url)) {
            finish()
            return
        }
        val view = WebView(this)
        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = true
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                !ChallengeLauncher.isWebUrl(request.url.toString())
        }
        setContentView(view)
        webView = view
        view.loadUrl(url)
        current = this
        ChallengeLauncher.shown?.countDown()
    }

    override fun onDestroy() {
        webView?.destroy()
        webView = null
        if (current === this) current = null
        ChallengeLauncher.closed?.countDown()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_URL = "url"

        @Volatile
        var current: ChallengeActivity? = null
            private set
    }
}

/** Opens [ChallengeActivity] from the service process when, and only when, the app is visible. */
internal object ChallengeLauncher {
    @Volatile var shown: CountDownLatch? = null
    @Volatile var closed: CountDownLatch? = null

    fun isWebUrl(url: String): Boolean {
        val scheme = runCatching { Uri.parse(url).scheme?.lowercase() }.getOrNull()
        return scheme == "http" || scheme == "https"
    }

    /** True when the app's main process hosts a visible Activity. */
    fun appVisible(context: Context): Boolean {
        val am = context.getSystemService(ActivityManager::class.java) ?: return false
        val main = context.packageName
        return am.runningAppProcesses.orEmpty().any {
            it.processName == main && it.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
        }
    }

    /**
     * Shows [url] in the challenge Activity and waits (bounded) until it is on
     * screen. Returns `interaction-required` while the app is not visible.
     */
    fun show(context: Context, url: String, timeoutMs: Long): JSONObject {
        if (!isWebUrl(url)) return JSONObject().put("result", "capability-unavailable").put("reason", "only http(s) URLs")
        if (!appVisible(context)) return JSONObject().put("result", "interaction-required")
        val latch = CountDownLatch(1)
        shown = latch
        closed = CountDownLatch(1)
        context.startActivity(
            Intent(context, ChallengeActivity::class.java)
                .putExtra(ChallengeActivity.EXTRA_URL, url)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        val ok = latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        return JSONObject().put("result", if (ok) "shown" else "timeout").put("activityPid", Process.myPid())
    }

    fun close(timeoutMs: Long): JSONObject {
        val activity = ChallengeActivity.current ?: return JSONObject().put("result", "none")
        activity.runOnUiThread { activity.finish() }
        val ok = closed?.await(timeoutMs, TimeUnit.MILLISECONDS) ?: true
        return JSONObject().put("result", if (ok) "closed" else "timeout")
    }
}
