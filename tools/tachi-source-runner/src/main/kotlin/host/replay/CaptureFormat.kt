package mangabackup.tachi.host.replay

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import mangabackup.tachi.extensions.Digests
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.File
import java.time.Instant

/**
 * Kotlin reading and writing of the committed capture format
 * (packages/source_runtime/lib/src/capture/capture_format.dart, format 1):
 * `capture.json` plus `bodies/<sha256>.bin`, matched on method, canonical URL
 * (query sorted, fragment dropped) and request-body SHA-256. Request headers
 * are never stored; responses keep only content-type, location, retry-after and
 * cf-mitigated (Cloudflare's header-based challenge signal).
 *
 * `Set-Cookie` is recorded only for the names in the manifest's
 * `setCookieAllowList` (protocol 1.3 capture rule), sanitised to name, value,
 * `Path` and `Domain`; a `redact` entry's value is written as `redacted`, so a
 * replay shows that a site issued a token (Mangahub's `mhub_access`) without
 * committing it. Replay serves each such cookie as its own `Set-Cookie` header.
 */
object CaptureFormat {
    const val FORMAT = 1
    const val MANIFEST = "capture.json"
    const val BODIES = "bodies"
    const val VOLATILE_VALUE = "*"

    /** The only body path a manifest may name. */
    val BODY_FILE = Regex("bodies/[0-9a-f]{64}[.]bin")
    val RECORDED_RESPONSE_HEADERS = setOf("content-type", "location", "retry-after", "cf-mitigated")

    /** How an allow-listed `Set-Cookie` value is written (Dart `CapturedCookieValue`). */
    enum class CookieMode(val wire: String) {
        /** Recorded as the site sent it; only for values that are not credentials. */
        KEEP("keep"),

        /** Recorded as [CapturedCookie.REDACTED]; the cookie's presence and name still replay. */
        REDACT("redact");

        companion object {
            fun fromWire(wire: String?): CookieMode = entries.firstOrNull { it.wire == wire }
                ?: throw IllegalArgumentException("Unknown cookie capture mode $wire (expected keep or redact)")
        }
    }

    /** A sanitised allow-listed `Set-Cookie` (Dart `CapturedCookie`): no expiry or other attributes. */
    data class CapturedCookie(val name: String, val value: String, val path: String? = null, val domain: String? = null, val redacted: Boolean = false) {
        /** The `Set-Cookie` header value replay serves. */
        fun toHeader(): String = listOfNotNull("$name=$value", path?.let { "Path=$it" }, domain?.let { "Domain=$it" }).joinToString("; ")

        fun toJson(): JsonObject = buildJsonObject {
            put("name", name)
            put("value", value)
            path?.let { put("path", it) }
            domain?.let { put("domain", it) }
            if (redacted) put("redacted", true)
        }

        companion object {
            const val REDACTED = "redacted"

            fun fromJson(o: JsonObject) = CapturedCookie(
                name = o["name"]!!.jsonPrimitive.content,
                value = o["value"]!!.jsonPrimitive.content,
                path = (o["path"] as? JsonPrimitive)?.contentOrNull,
                domain = (o["domain"] as? JsonPrimitive)?.contentOrNull,
                redacted = (o["redacted"] as? JsonPrimitive)?.content == "true",
            )
        }
    }

    private val COOKIE_SEPARATOR = Regex(",(?=\\s*[^;,=\\s]+=)")

    /**
     * Splits one `Set-Cookie` header value into cookies, as Dart's `parseSetCookieHeader`: a comma
     * separates cookies only when a `name=` follows it (an `Expires` date has a comma too); attributes
     * other than `Path` and `Domain` are dropped, and a part without `name=` is ignored.
     */
    fun parseSetCookieHeader(header: String): List<CapturedCookie> = header.split(COOKIE_SEPARATOR).mapNotNull { text ->
        val parts = text.split(';')
        val eq = parts.first().indexOf('=')
        if (eq <= 0) return@mapNotNull null
        val name = parts.first().substring(0, eq).trim()
        if (name.isEmpty()) return@mapNotNull null
        var path: String? = null
        var domain: String? = null
        for (attribute in parts.drop(1)) {
            val i = attribute.indexOf('=')
            if (i < 0) continue
            val key = attribute.substring(0, i).trim().lowercase()
            val value = attribute.substring(i + 1).trim()
            if (key == "path") path = value
            if (key == "domain") domain = value
        }
        CapturedCookie(name, parts.first().substring(eq + 1).trim(), path, domain)
    }

    /** The allow-listed cookies of live `Set-Cookie` header values, sanitised and redacted for a capture. */
    fun recordedCookies(setCookieHeaders: List<String>, allowList: Map<String, CookieMode>): List<CapturedCookie> {
        if (allowList.isEmpty()) return emptyList()
        return setCookieHeaders.flatMap(::parseSetCookieHeader).mapNotNull { c ->
            when (allowList[c.name]) {
                null -> null
                CookieMode.KEEP -> c
                CookieMode.REDACT -> c.copy(value = CapturedCookie.REDACTED, redacted = true)
            }
        }
    }

    /** Dart `Uri.encodeQueryComponent`: unreserved A-Z a-z 0-9 - _ . ! ~ * ' ( ), space as '+', the rest %XX. */
    fun encodeQueryComponent(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            val ch = c.toChar()
            when {
                ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch in "-_.!~*'()" -> sb.append(ch)
                ch == ' ' -> sb.append('+')
                else -> sb.append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 15])
            }
        }
        return sb.toString()
    }

    /** Canonical URL string used for matching; same rules as Dart's `CaptureKey.canonicalUrl`. */
    fun canonicalUrl(url: HttpUrl, volatile: Set<String> = emptySet()): String {
        val base = StringBuilder().append(url.scheme).append("://").append(url.host)
        val defaultPort = HttpUrl.defaultPort(url.scheme)
        if (url.port != defaultPort) base.append(':').append(url.port)
        base.append(url.encodedPath)
        if (url.encodedQuery == null) return base.toString()
        val params = (0 until url.querySize).map { i ->
            val name = url.queryParameterName(i)
            name to (if (name in volatile) VOLATILE_VALUE else url.queryParameterValue(i).orEmpty())
        }.sortedWith(compareBy({ it.first }, { it.second }))
        base.append('?').append(params.joinToString("&") { "${encodeQueryComponent(it.first)}=${encodeQueryComponent(it.second)}" })
        return base.toString()
    }

    data class Key(val method: String, val url: String, val bodySha256: String?) {
        override fun toString(): String = "$method $url${if (bodySha256 == null) "" else " body=$bodySha256"}"
    }

    fun key(method: String, url: HttpUrl, body: ByteArray?, volatile: Set<String>): Key =
        Key(method.uppercase(), canonicalUrl(url, volatile), body?.takeIf { it.isNotEmpty() }?.let { Digests.sha256(it) })

    data class Exchange(
        val key: Key,
        val status: Int,
        val headers: Map<String, String>,
        val bodyFile: String,
        val sourceUrl: String,
        val sha256: String,
        val size: Int,
        val licence: String,
        /** Allow-listed cookies the response set, in the order the site sent them. */
        val setCookies: List<CapturedCookie> = emptyList(),
    )

    data class Manifest(
        val ecosystem: String,
        val source: String,
        val recordedAt: Instant,
        val notes: String,
        val volatileQueryParameters: Set<String>,
        val exchanges: List<Exchange>,
        val recordedBy: String = "tools/tachi-source-runner capture",
        /** Cookie names whose `Set-Cookie` the capture keeps, and how (empty: none). */
        val setCookieAllowList: Map<String, CookieMode> = emptyMap(),
    ) {
        fun encode(): String {
            val o = buildJsonObject {
                put("format", FORMAT)
                put("ecosystem", ecosystem)
                put("source", source)
                put("recordedAt", recordedAt.toString())
                put("recordedBy", recordedBy)
                put("notes", notes)
                put("volatileQueryParameters", buildJsonArray { volatileQueryParameters.sorted().forEach { add(JsonPrimitive(it)) } })
                if (setCookieAllowList.isNotEmpty()) {
                    put("setCookieAllowList", JsonObject(setCookieAllowList.toSortedMap().mapValues { JsonPrimitive(it.value.wire) }))
                }
                put("exchanges", buildJsonArray {
                    for (e in exchanges) {
                        add(buildJsonObject {
                            put("request", buildJsonObject {
                                put("method", e.key.method)
                                put("url", e.key.url)
                                put("bodySha256", e.key.bodySha256?.let { JsonPrimitive(it) } ?: JsonNull)
                            })
                            put("response", buildJsonObject {
                                put("status", e.status)
                                put("headers", JsonObject(e.headers.toSortedMap().mapValues { JsonPrimitive(it.value) }))
                                put("body", e.bodyFile)
                                if (e.setCookies.isNotEmpty()) put("setCookies", JsonArray(e.setCookies.map { it.toJson() }))
                            })
                            put("artifact", buildJsonObject {
                                put("sourceUrl", e.sourceUrl)
                                put("sha256", e.sha256)
                                put("size", e.size)
                                put("licence", e.licence)
                            })
                        })
                    }
                })
            }
            return PRETTY.encodeToString(JsonObject.serializer(), o) + "\n"
        }
    }

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    private val PRETTY = Json {
        prettyPrint = true
        prettyPrintIndent = "  "
    }

    /** A loaded capture directory with every body verified against its digest and size. */
    class CaptureSet(val dir: File, val manifest: Manifest, private val bodies: Map<Key, Pair<Exchange, ByteArray>>) {
        fun lookup(key: Key): Pair<Exchange, ByteArray>? = bodies[key]

        val keys: Set<Key> get() = bodies.keys
    }

    fun load(dir: File): CaptureSet {
        val root = Json.parseToJsonElement(File(dir, MANIFEST).readText()).jsonObject
        require(root["format"]?.jsonPrimitive?.int == FORMAT) { "Unsupported capture format in $dir" }
        val volatile = root["volatileQueryParameters"]?.jsonArray?.map { it.jsonPrimitive.content }?.toSet().orEmpty()
        val exchanges = root["exchanges"]!!.jsonArray.map { e ->
            val o = e.jsonObject
            val req = o["request"]!!.jsonObject
            val res = o["response"]!!.jsonObject
            val art = o["artifact"]!!.jsonObject
            Exchange(
                key = Key(
                    req["method"]!!.jsonPrimitive.content.uppercase(),
                    canonicalUrl(req["url"]!!.jsonPrimitive.content.toHttpUrl(), volatile),
                    (req["bodySha256"] as? JsonPrimitive)?.contentOrNull,
                ),
                status = res["status"]!!.jsonPrimitive.int,
                headers = res["headers"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content },
                bodyFile = res["body"]!!.jsonPrimitive.content,
                sourceUrl = art["sourceUrl"]!!.jsonPrimitive.content,
                sha256 = art["sha256"]!!.jsonPrimitive.content,
                size = art["size"]!!.jsonPrimitive.long.toInt(),
                licence = art["licence"]!!.jsonPrimitive.content,
                setCookies = (res["setCookies"] as? JsonArray)?.map { CapturedCookie.fromJson(it.jsonObject) }.orEmpty(),
            )
        }
        val manifest = Manifest(
            ecosystem = root["ecosystem"]!!.jsonPrimitive.content,
            source = root["source"]!!.jsonPrimitive.content,
            recordedAt = Instant.parse(root["recordedAt"]!!.jsonPrimitive.content),
            notes = (root["notes"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
            volatileQueryParameters = volatile,
            exchanges = exchanges,
            recordedBy = (root["recordedBy"] as? JsonPrimitive)?.contentOrNull ?: "",
            setCookieAllowList = (root["setCookieAllowList"] as? JsonObject)
                ?.mapValues { CookieMode.fromWire((it.value as? JsonPrimitive)?.contentOrNull) }.orEmpty(),
        )
        val bodies = exchanges.associate { e ->
            // Only `bodies/<sha256 hex>.bin`, as every capture writer names them: a manifest cannot point the
            // loader at another file (L5).
            require(BODY_FILE.matches(e.bodyFile)) { "Capture body path ${e.bodyFile} in $dir is not bodies/<sha256>.bin" }
            val bytes = File(dir, e.bodyFile).readBytes()
            val digest = Digests.sha256(bytes)
            require(digest == e.sha256 && bytes.size == e.size) { "Capture body ${e.bodyFile} in $dir does not match its recorded SHA-256" }
            e.key to (e to bytes)
        }
        return CaptureSet(dir, manifest, bodies)
    }
}

