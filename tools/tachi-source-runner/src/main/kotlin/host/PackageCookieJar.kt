package mangabackup.tachi.host

import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * One package's cookies, in memory only (session-only per KTD9). Shared by the
 * package's OkHttp clients and its android.webkit.CookieManager view, as on
 * Android where both read the WebView cookie store.
 */
class PackageCookieJar : CookieJar {
    private val cookies = ArrayList<Cookie>()

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        for (cookie in cookies) {
            this.cookies.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
            if (cookie.expiresAt > System.currentTimeMillis()) this.cookies += cookie
        }
    }

    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        cookies.removeAll { it.expiresAt <= now }
        return cookies.filter { it.matches(url) }
    }

    @Synchronized
    fun all(): List<Cookie> = cookies.toList()

    @Synchronized
    fun clear() {
        cookies.clear()
    }
}

