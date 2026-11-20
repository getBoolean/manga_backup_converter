package mangabackup.tachi.webkit

import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.ValueCallback
import android.webkit.WebView
import mangabackup.tachi.host.PackageScope
import mangabackup.tachi.shim.HostBackends
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Installs the KTD20 android.webkit translation backends. */
object WebkitHost {
    fun install(bridge: BrowserBridge) {
        HostBackends.install({ view: WebView -> WebViewTranslation(view, bridge) }, PackageCookieManager)
    }

    val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }
}

/** android.webkit.CookieManager over the calling package's cookie jar (shared with its OkHttp clients). */
object PackageCookieManager : CookieManager() {
    private fun jar() = PackageScope.require("CookieManager").cookieJar

    override fun setAcceptCookie(accept: Boolean) = Unit

    override fun acceptCookie(): Boolean = true

    override fun setAcceptThirdPartyCookies(webview: WebView?, accept: Boolean) = Unit

    override fun acceptThirdPartyCookies(webview: WebView?): Boolean = true

    override fun setCookie(url: String, value: String) {
        val httpUrl = url.toHttpUrlOrNull() ?: return
        val cookie = Cookie.parse(httpUrl, value) ?: return
        jar().saveFromResponse(httpUrl, listOf(cookie))
    }

    override fun setCookie(url: String, value: String, callback: ValueCallback<Boolean>?) {
        setCookie(url, value)
        callback?.let { cb -> WebkitHost.mainHandler.post { cb.onReceiveValue(true) } }
    }

    override fun getCookie(url: String): String? {
        val httpUrl = url.toHttpUrlOrNull() ?: return null
        val cookies = jar().loadForRequest(httpUrl)
        return if (cookies.isEmpty()) null else cookies.joinToString("; ") { "${it.name}=${it.value}" }
    }

    override fun removeSessionCookies(callback: ValueCallback<Boolean>?) {
        val jar = jar()
        jar.all().filter { !it.persistent }.forEach { c ->
            jar.saveFromResponse(
                okhttp3.HttpUrl.Builder().scheme("https").host(c.domain).build(),
                listOf(Cookie.Builder().name(c.name).value("").domain(c.domain).path(c.path).expiresAt(0).build()),
            )
        }
        callback?.let { cb -> WebkitHost.mainHandler.post { cb.onReceiveValue(true) } }
    }

    override fun removeAllCookies(callback: ValueCallback<Boolean>?) {
        jar().clear()
        callback?.let { cb -> WebkitHost.mainHandler.post { cb.onReceiveValue(true) } }
    }

    override fun hasCookies(): Boolean = jar().all().isNotEmpty()

    override fun flush() = Unit
}

