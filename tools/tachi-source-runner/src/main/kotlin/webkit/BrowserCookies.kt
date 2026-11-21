package mangabackup.tachi.webkit

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import mangabackup.tachi.host.PackageCookieJar
import mangabackup.tachi.protocol.optStr
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Copies cookies between a package's jar and a browser session (`host.browser.setCookie` /
 * `host.browser.getCookies`), so the package's OkHttp clients and its browser sessions see one store,
 * as on Android. [call] sends one reverse request and returns its reply.
 */
internal class BrowserCookies(private val jar: PackageCookieJar, private val call: (String, JsonObject) -> JsonObject) {
    /** Pushes the jar's cookies for [url] into [session]. */
    fun push(session: String, url: String) {
        val httpUrl = url.toHttpUrlOrNull() ?: return
        for (cookie in jar.loadForRequest(httpUrl)) {
            call("host.browser.setCookie", buildJsonObject {
                put("session", session)
                put("url", url)
                put("cookie", toJson(cookie))
            })
        }
    }

    /** Reads [session]'s cookies for [url] without storing them. */
    fun read(session: String, url: String): List<Cookie> {
        val httpUrl = url.toHttpUrlOrNull() ?: return emptyList()
        val reply = call("host.browser.getCookies", buildJsonObject {
            put("session", session)
            put("url", url)
        })
        return (reply["cookies"] as? JsonArray ?: return emptyList()).mapNotNull { element ->
            val o = element.jsonObject
            val builder = Cookie.Builder().name(o.optStr("name") ?: return@mapNotNull null).value(o.optStr("value").orEmpty())
            val domain = o.optStr("domain")?.removePrefix(".") ?: httpUrl.host
            builder.domain(domain).path(o.optStr("path") ?: "/")
            o.optStr("expires")?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() }.getOrNull() }?.let(builder::expiresAt)
            if ((o["secure"] as? JsonPrimitive)?.content == "true") builder.secure()
            if ((o["httpOnly"] as? JsonPrimitive)?.content == "true") builder.httpOnly()
            runCatching { builder.build() }.getOrNull()
        }
    }

    /** Pulls [session]'s cookies for [url] into the jar. */
    fun pull(session: String, url: String) {
        val httpUrl = url.toHttpUrlOrNull() ?: return
        jar.saveFromResponse(httpUrl, read(session, url))
    }

    private fun toJson(c: Cookie) = buildJsonObject {
        put("name", c.name)
        put("value", c.value)
        put("domain", c.domain)
        put("path", c.path)
        if (c.persistent) put("expires", java.time.Instant.ofEpochMilli(c.expiresAt).toString())
        put("secure", c.secure)
        put("httpOnly", c.httpOnly)
    }
}
