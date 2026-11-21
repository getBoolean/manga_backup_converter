package fixture.webview

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class Factory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(WebViewSource())
}

/**
 * The `runWebViewBlocking` shape: post to the main looper, build a WebView
 * there, block the calling thread on a latch until the page answers through a
 * JavascriptInterface. The query picks the base URL (`file` → a file: URL the
 * shim must refuse). The result title reports the Chromium-glue probe.
 *
 * Protocol 1.2 queries: `ipc` (channel named `ipc`), `docstart`
 * (addDocumentStartJavaScript, then ScriptHandler.remove), `observe` / `replace`
 * / `redirect` / `throws` (loadUrl with a shouldInterceptRequest that records what it sees
 * and, for `replace` / `redirect`, answers the main frame), `evalerr` (a throwing
 * evaluateJavascript instead of a channel message). `evalthrow` (U9 iOS) also
 * evaluates a throwing script, from its own WebViewClient, with the `bridge` channel installed.
 */
class WebViewSource : HttpSource() {
    override val name = "WebView"
    override val lang = "en"
    override val baseUrl = "https://webview.test"
    override val supportsLatest = false

    override suspend fun getPopularManga(page: Int) = MangasPage(emptyList(), false)
    override suspend fun getLatestUpdates(page: Int) = MangasPage(emptyList(), false)

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        val probe = try {
            WebView.getWebViewClassLoader().loadClass("org.chromium.support_lib_glue.SupportLibReflectionUtil")
            "glue"
        } catch (_: ClassNotFoundException) {
            "no-glue"
        }
        val latch = CountDownLatch(1)
        var result: String? = null
        var error: String? = null
        var webView: WebView? = null
        val seen = java.util.concurrent.CopyOnWriteArrayList<String>()
        var removeOutcome = ""
        val main = Handler(Looper.getMainLooper())
        main.post {
            check(Looper.myLooper() == Looper.getMainLooper())
            val view = WebView(Injekt.get<Application>())
            webView = view
            view.settings.javaScriptEnabled = true
            view.settings.userAgentString = "FixtureAgent/1"
            val bridge = object {
                @JavascriptInterface
                fun postMessage(message: String) {
                    result = message
                    latch.countDown()
                }
            }
            // `badname`: a channel name that is not a JavaScript identifier, which the shim must refuse.
            if (query == "badname") view.addJavascriptInterface(bridge, "bad-name")
            when (query) {
                "ipc" -> view.addJavascriptInterface(bridge, "ipc")
                "evalerr" -> Unit
                else -> view.addJavascriptInterface(bridge, "bridge")
            }
            view.webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): android.webkit.WebResourceResponse? {
                    seen += "${request.method} ${request.url} main=${request.isForMainFrame} ua=${request.requestHeaders["sec-ch-ua"]}"
                    return when {
                        query == "intercept" -> android.webkit.WebResourceResponse("text/html", "utf-8", java.io.ByteArrayInputStream(ByteArray(0)))
                        query == "replace" && request.isForMainFrame ->
                            android.webkit.WebResourceResponse("text/html", "utf-8", 200, "Replaced", mapOf("X-Fixture" to "1"), "replaced".byteInputStream())
                        query == "throws" -> throw NotImplementedError("fixture handler fails")
                        query == "redirect" && request.isForMainFrame ->
                            android.webkit.WebResourceResponse("text/html", "utf-8", 302, "Found", mapOf("Location" to "https://elsewhere.test/"), null)
                        else -> null
                    }
                }

                override fun onPageFinished(view: WebView, url: String) {
                    if (query == "evalerr") view.evaluateJavascript("throw new Error('boom')") { value ->
                        result = "eval=$value"
                        latch.countDown()
                    }
                }

                override fun onReceivedError(view: WebView, request: WebResourceRequest, error2: WebResourceError) {
                    error = error2.description.toString()
                    latch.countDown()
                }
            }
            val base = if (query == "file") "file:///etc/passwd" else "https://webview.test/"
            if (query == "docstart") {
                val handler = androidx.webkit.WebViewCompat.addDocumentStartJavaScript(view, "window.__fixture = 1", setOf("https://webview.test"))
                removeOutcome = try {
                    handler.remove()
                    "|remove=ok"
                } catch (e: UnsupportedOperationException) {
                    "|remove=${e.javaClass.simpleName}"
                }
            }
            if (query == "evalthrow") {
                // A script that throws: Android's evaluateJavascript reports JSON `null` (U9 iOS path through the
                // browser port's androidCompatible semantics).
                view.webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String) {
                        view.evaluateJavascript("throw new Error(\"boom\")") { value ->
                            result = "eval=$value"
                            latch.countDown()
                        }
                    }
                }
                view.loadDataWithBaseURL(base, "<html><body>eval</body></html>", "text/html", "UTF-8", null)
            } else if (query in setOf("intercept", "load", "observe", "replace", "redirect", "throws")) {
                view.loadUrl("https://webview.test/page")
            } else {
                view.loadDataWithBaseURL(base, "<html><script>bridge.postMessage('solved')</script></html>", "text/html", "UTF-8", null)
            }
        }
        if (!latch.await(30, TimeUnit.SECONDS)) throw IOException("WebView timed out")
        main.post { webView?.destroy() }
        error?.let { throw IOException("WebView failed: $it") }
        val suffix = if (query in setOf("observe", "replace")) "|seen=${seen.joinToString(";")}" else removeOutcome
        return MangasPage(listOf(SManga.create().apply { url = "/w"; title = "$probe:$result$suffix" }), false)
    }

    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
        SMangaUpdate(manga, emptyList())

    override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()
    override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
    override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
}

