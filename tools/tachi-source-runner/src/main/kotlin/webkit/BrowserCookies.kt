package mangabackup.tachi.webkit

import kotlinx.serialization.json.JsonObject
import mangabackup.tachi.host.PackageCookieJar
import mangabackup.tachi.protocol.BrowserCookieJson
import mangabackup.tachi.protocol.HostBrowserCookies
import mangabackup.tachi.protocol.HostBrowserGetCookies
import mangabackup.tachi.protocol.HostBrowserRequest
import mangabackup.tachi.protocol.HostBrowserSetCookie
import mangabackup.tachi.protocol.Wire
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Copies cookies between a package's jar and a browser session (`host.browser.setCookie` /
 * `host.browser.getCookies`), so the package's OkHttp clients and its browser sessions see one store,
 * as on Android. [call] sends one reverse request and returns its reply.
 */
internal class BrowserCookies(private val jar: PackageCookieJar, private val call: (HostBrowserRequest) -> JsonObject) {
    /** Pushes the jar's cookies for [url] into [session]. */
    fun push(session: String, url: String) {
        val httpUrl = url.toHttpUrlOrNull() ?: return
        for (cookie in jar.loadForRequest(httpUrl)) call(HostBrowserSetCookie(session, url, toJson(cookie)))
    }

    /** Reads [session]'s cookies for [url] without storing them. */
    fun read(session: String, url: String): List<Cookie> {
        val httpUrl = url.toHttpUrlOrNull() ?: return emptyList()
        val reply = Wire.decode<HostBrowserCookies>(call(HostBrowserGetCookies(session, url)), "host.browser.getCookies reply")
        return reply.cookies.mapNotNull { c ->
            val builder = Cookie.Builder().name(c.name ?: return@mapNotNull null).value(c.value.orEmpty())
            builder.domain(c.domain?.removePrefix(".") ?: httpUrl.host).path(c.path ?: "/")
            c.expires?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() }.getOrNull() }?.let(builder::expiresAt)
            if (c.secure) builder.secure()
            if (c.httpOnly) builder.httpOnly()
            runCatching { builder.build() }.getOrNull()
        }
    }

    /** Pulls [session]'s cookies for [url] into the jar. */
    fun pull(session: String, url: String) {
        val httpUrl = url.toHttpUrlOrNull() ?: return
        jar.saveFromResponse(httpUrl, read(session, url))
    }

    private fun toJson(c: Cookie) = BrowserCookieJson(
        name = c.name,
        value = c.value,
        domain = c.domain,
        path = c.path,
        expires = if (c.persistent) java.time.Instant.ofEpochMilli(c.expiresAt).toString() else null,
        secure = c.secure,
        httpOnly = c.httpOnly,
    )
}
