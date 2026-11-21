package mangabackup.tachi.webkit

import android.webkit.WebResourceResponse
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import mangabackup.tachi.host.CapabilityUnavailableException
import java.util.Base64

/** Browser features a 1.2 session reports on `host.browser.open` (`BrowserFeature` in Dart). */
object BrowserFeature {
    const val PAGE_START_SCRIPTS = "pageStartScripts"
    const val OBSERVE_NAVIGATIONS = "observeNavigations"
    const val OBSERVE_SUBRESOURCES = "observeSubresources"
    const val REPLACE_REQUESTS = "replaceRequests"

    /**
     * The `available` features of an open reply. Absent capabilities (a 1.1 supervisor, or a peer
     * that reports none) mean no feature is available: nothing is assumed.
     */
    fun available(openReply: JsonObject): Set<String> {
        val caps = openReply["capabilities"] as? JsonObject ?: return emptySet()
        val list = caps["available"] as? JsonArray ?: return emptySet()
        return list.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }.toSet()
    }

    /** The reason the supervisor gave for an unavailable feature, if any. */
    fun reason(openReply: JsonObject, feature: String): String? =
        ((openReply["capabilities"] as? JsonObject)?.get("unavailable") as? JsonObject)?.get(feature)
            ?.let { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
}

/** A `host.browser.request` event (1.2). `requestId` is present only for a held (replace-tier) request. */
data class BrowserRequestEvent(
    val session: String,
    val requestId: String?,
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val mainFrame: Boolean,
    val redirect: Boolean,
) {
    companion object {
        /** Lenient decoding: a malformed event yields null and is dropped. */
        fun parse(p: JsonObject): BrowserRequestEvent? {
            fun str(key: String) = (p[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
            fun bool(key: String) = (p[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content == "true"
            val headers = (p["headers"] as? JsonObject)?.mapNotNull { (k, v) ->
                (v as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { k to it }
            }?.toMap() ?: emptyMap()
            return BrowserRequestEvent(
                session = str("session") ?: return null,
                requestId = str("requestId"),
                method = (str("method") ?: return null).uppercase(),
                url = str("url") ?: return null,
                headers = headers,
                mainFrame = bool("mainFrame"),
                redirect = bool("redirect"),
            )
        }
    }
}

/** Encodes an extension's `WebResourceResponse` as a protocol `BrowserReplacement`. */
object BrowserReplacement {
    const val OPERATION_REDIRECT = "android.webkit.shouldInterceptRequest.redirect"

    fun encode(response: WebResourceResponse): JsonObject {
        val status = response.statusCode
        if (status !in 100..599 || status in 300..399) {
            // A replacement can never substitute a redirect (protocol 1.2), and Android rejects 3xx here too.
            throw CapabilityUnavailableException("shouldInterceptRequest returned status $status; a replacement cannot be a redirect or outside 100-599", OPERATION_REDIRECT)
        }
        val headers = LinkedHashMap<String, String>()
        response.responseHeaders?.forEach { (k, v) -> if (k != null && v != null) headers[k] = v }
        if (headers.keys.none { it.equals("Content-Type", ignoreCase = true) } && !response.mimeType.isNullOrBlank()) {
            headers["Content-Type"] = response.mimeType + (response.encoding?.takeIf { it.isNotBlank() }?.let { "; charset=$it" } ?: "")
        }
        val body = response.data?.use { it.readBytes() }
        return buildJsonObject {
            put("status", status)
            response.reasonPhrase?.takeIf { it.isNotBlank() && '\n' !in it && '\r' !in it }?.let { put("reason", it) }
            put("headers", JsonObject(headers.mapValues { JsonPrimitive(it.value) }))
            if (body != null) put("bodyBase64", Base64.getEncoder().encodeToString(body))
        }
    }
}

/**
 * Emulates `addDocumentStartJavaScript`'s `allowedOriginRules` over a page-start script that runs in
 * every frame: the script is wrapped in a `location` check.
 *
 * Rule grammar (androidx.webkit `addWebMessageListener`): `*` matches every origin;
 * `http(s)://host[:port]` matches that host, or with a `*.` prefix only its subdomains ("matches
 * https://calendar.example.com ... but not https://example.com"), on the scheme's default port when
 * none is given; a custom scheme rule `scheme://` is valid but never matches, because the browser
 * port only loads http(s) documents. A malformed rule throws [IllegalArgumentException], as on Android. With a `*` rule the script is passed
 * unchanged; otherwise it runs inside an `if` block, so its top-level `let`/`const`/`class`
 * declarations are scoped to that block (its `var` and function declarations stay global).
 */
object OriginRules {
    private val RULE = Regex("^(https?)://(\\*\\.)?([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:]+])(?::(\\d{1,5}))?/?$")
    private val CUSTOM_SCHEME = Regex("^[A-Za-z][A-Za-z0-9+.-]*://$")

    data class Rule(val scheme: String, val host: String, val subdomains: Boolean, val port: String)

    /** Scheme marker of a custom-scheme rule, which no http(s) document matches. */
    const val NEVER = ""

    /** Null for `*`; a rule whose scheme is [NEVER] for a custom-scheme rule. */
    fun parse(rule: String): Rule? {
        if (rule == "*") return null
        if (CUSTOM_SCHEME.matches(rule) && !rule.startsWith("http://") && !rule.startsWith("https://")) return Rule(NEVER, "", false, "")
        val m = RULE.matchEntire(rule) ?: throw IllegalArgumentException("allowedOriginRules: malformed rule '$rule'")
        val scheme = m.groupValues[1]
        val port = m.groupValues[4].ifEmpty { if (scheme == "https") "443" else "80" }
        return Rule(scheme, m.groupValues[3].lowercase(), m.groupValues[2].isNotEmpty(), port)
    }

    fun wrap(script: String, rules: Set<String>): String {
        require(rules.isNotEmpty()) { "allowedOriginRules must not be empty" }
        val parsed = rules.map(::parse)
        if (parsed.any { it == null }) return script
        val json = JsonArray(parsed.filterNotNull().filter { it.scheme != NEVER }.sortedBy { "${it.scheme}://${it.host}:${it.port}" }.map { r ->
            JsonArray(listOf(JsonPrimitive(r.scheme), JsonPrimitive(r.host), JsonPrimitive(r.subdomains), JsonPrimitive(r.port)))
        })
        return "if ((function (r) {" +
            "var p = location.protocol.slice(0, -1), h = location.hostname.toLowerCase(), " +
            "t = location.port || (p === 'https' ? '443' : p === 'http' ? '80' : '');" +
            "for (var i = 0; i < r.length; i++) {" +
            "var x = r[i]; if (x[0] !== p || x[3] !== t) continue;" +
            "if (x[2] ? h.slice(-x[1].length - 1) === '.' + x[1] : h === x[1]) return true;" +
            "} return false; })($json)) {\n$script\n}"
    }
}
