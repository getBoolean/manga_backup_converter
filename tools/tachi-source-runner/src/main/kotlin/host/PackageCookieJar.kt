package mangabackup.tachi.host

import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * One package's cookies, in memory only (session-only per KTD9). Shared by the
 * package's OkHttp clients and its android.webkit.CookieManager view, as on
 * Android where both read the WebView cookie store.
 *
 * On Android the extension's WebViews are real ones with their own cookie
 * store. [browserCookies] (set by the Android runtime for packages whose code
 * uses WebView) reads that store, and every request first copies the cookies
 * it holds for the URL into this jar, so a cookie a WebView acquired (a solved
 * challenge's clearance) reaches the package's HTTP calls, as Mihon's
 * CookieManager-backed jar does. The copy stays in this package's jar only.
 */
class PackageCookieJar : CookieJar {
    private val cookies = ArrayList<Cookie>()

    /** Cookies a browser holds for a URL; `null` (desktop, iOS) reads none. */
    @Volatile
    var browserCookies: ((HttpUrl) -> List<Cookie>)? = null

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        for (cookie in cookies) {
            this.cookies.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
            if (cookie.expiresAt > System.currentTimeMillis()) this.cookies += cookie
        }
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        // Read outside the lock: the Android reader hops to the main looper.
        val fromBrowser = browserCookies?.let { read -> runCatching { read(url) }.getOrDefault(emptyList()) }.orEmpty()
        synchronized(this) {
            if (fromBrowser.isNotEmpty()) saveFromResponse(url, fromBrowser)
            val now = System.currentTimeMillis()
            cookies.removeAll { it.expiresAt <= now }
            return cookies.filter { it.matches(url) }
        }
    }

    @Synchronized
    fun all(): List<Cookie> = cookies.toList()

    @Synchronized
    fun clear() {
        cookies.clear()
    }
}

