package fixture.android

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/*
 * Synthetic Tachi extensions for the U11 Android tests. Each package is built
 * into its own signed APK of original DEX by android/fixtures/build_fixtures.sh
 * (fixtures/source_captures/tachi-android/). None makes a network request.
 */

/** Shared no-network source shape; [search] supplies the hits. */
abstract class FixtureSource(final override val name: String) : HttpSource() {
    override val lang = "en"
    override val baseUrl = "https://fixture.test"
    override val supportsLatest = false

    override suspend fun getPopularManga(page: Int) = MangasPage(emptyList(), false)
    override suspend fun getLatestUpdates(page: Int) = MangasPage(emptyList(), false)

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage =
        MangasPage(listOf(SManga.create().apply { url = "/q/$query"; title = search(query) }), false)

    abstract fun search(query: String): String

    open fun chapters(manga: SManga): List<SChapter> = listOf(
        SChapter.create().apply { url = "${manga.url}/1"; name = "Chapter 1"; chapter_number = 1f },
    )

    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
        SMangaUpdate(SManga.create().apply { url = manga.url; title = manga.title; initialized = true }, chapters(manga))

    override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()
    override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
    override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
}

// --- busy: a call-free CPU loop that ignores interruption (AE10) ---------------------------------

class BusyFactory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(Busy())
}

class Busy : FixtureSource("Android Busy") {
    @Volatile
    var counter = 0L

    override fun search(query: String): String {
        if (query == "busy") while (true) counter++
        return "ok:$query"
    }
}

// --- prefs: reads a seeded password and writes a derived token (KTD9) ----------------------------

class PrefsFactory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(Prefs())
}

class Prefs : FixtureSource("Android Prefs") {
    override fun search(query: String): String {
        val app = Injekt.get<Application>()
        val prefs = app.getSharedPreferences("source_$id", 0)
        val password = prefs.getString("password", null).orEmpty()
        // Extensions keep tokens beside settings; both must stay in memory.
        prefs.edit().putString("token", "$password-token").commit()
        android.preference.PreferenceManager.getDefaultSharedPreferences(app).edit().putString("echo", password).commit()
        return "password=${if (password.isEmpty()) "unset" else "set"};token=${prefs.getString("token", null) != null}"
    }
}

// --- big: a chapter list far beyond the Binder transaction limit ---------------------------------

class BigFactory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(Big())
}

class Big : FixtureSource("Android Big") {
    override fun search(query: String) = "big:$query"

    /** `/q/<n>` → n chapters with 120-character titles. */
    override fun chapters(manga: SManga): List<SChapter> {
        val n = manga.url.substringAfterLast('/').toIntOrNull() ?: 1
        val pad = "x".repeat(100)
        return List(n) { i ->
            SChapter.create().apply {
                url = "${manga.url}/$i"
                name = "Chapter $i $pad"
                chapter_number = i.toFloat()
            }
        }
    }
}

// --- dup / dup2: two packages whose sources share one ID ------------------------------------------

class DupFactory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(Dup())
}

/** Same name, language and version in both packages, so both generate the same source ID. */
class Dup : FixtureSource("Android Dup") {
    override fun search(query: String) = "dup:$query"
}

// --- cookies: a real service-process WebView plus the process CookieManager -----------------------

class CookiesFactory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(Cookies("Android Cookies A"), Cookies("Android Cookies B"))
}

/**
 * Search `set:<value>` builds a WebView on the main looper (the
 * `runWebViewBlocking` shape), loads a page with an https base URL, reads a
 * JavaScript result, and sets `k=<value>` for https://cookies.test through
 * CookieManager. Search `get` reports the cookie names CookieManager holds for
 * that URL. Search `net` loads https://proxy-check.invalid/ in a WebView and
 * reports how the load ended (`net=<error description>`), so tests can prove
 * the process's WebView traffic goes where the host sends it.
 * Titles: `webview=<js>;pid=<pid>;cookies=<names>`.
 */
class Cookies(name: String) : FixtureSource(name) {
    override fun search(query: String): String {
        if (query == "net") return "net=${netLoad()}"
        val js = if (query.startsWith("set:")) webView() else "-"
        val manager = CookieManager.getInstance()
        if (query.startsWith("set:")) {
            manager.setCookie(URL, "k=${query.removePrefix("set:")}")
            manager.flush()
        }
        val names = manager.getCookie(URL)?.split(';')?.joinToString(",") { it.substringBefore('=').trim() }.orEmpty()
        return "webview=$js;pid=${android.os.Process.myPid()};cookies=$names"
    }

    private fun webView(): String {
        val result = AtomicReference("timeout")
        val done = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            val view = WebView(Injekt.get<Application>())
            view.settings.javaScriptEnabled = true
            view.webViewClient = object : WebViewClient() {
                override fun onPageFinished(webView: WebView, url: String?) {
                    webView.evaluateJavascript("document.title + ':' + (6 * 7)") { value ->
                        result.set(value.trim('"'))
                        webView.destroy()
                        done.countDown()
                    }
                }
            }
            view.loadDataWithBaseURL(URL, "<html><head><title>fixture</title></head><body></body></html>", "text/html", "utf-8", null)
        }
        done.await(30, TimeUnit.SECONDS)
        return result.get()
    }

    private fun netLoad(): String {
        val result = AtomicReference("timeout")
        val done = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            val view = WebView(Injekt.get<Application>())
            view.webViewClient = object : WebViewClient() {
                override fun onReceivedError(webView: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) {
                        result.set(error.description.toString())
                        webView.destroy()
                        done.countDown()
                    }
                }

                override fun onPageFinished(webView: WebView, url: String?) {
                    if (done.count > 0L && result.get() == "timeout") {
                        result.set("loaded")
                        done.countDown()
                    }
                }
            }
            view.loadUrl("https://proxy-check.invalid/")
        }
        done.await(30, TimeUnit.SECONDS)
        return result.get()
    }

    private companion object {
        const val URL = "https://cookies.test/"
    }
}
