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
 * are never stored; responses keep only content-type, location and retry-after.
 */
object CaptureFormat {
    const val FORMAT = 1
    const val MANIFEST = "capture.json"
    const val BODIES = "bodies"
    const val VOLATILE_VALUE = "*"
    val RECORDED_RESPONSE_HEADERS = setOf("content-type", "location", "retry-after")

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

    data class Exchange(val key: Key, val status: Int, val headers: Map<String, String>, val bodyFile: String, val sourceUrl: String, val sha256: String, val size: Int, val licence: String)

    data class Manifest(
        val ecosystem: String,
        val source: String,
        val recordedAt: Instant,
        val notes: String,
        val volatileQueryParameters: Set<String>,
        val exchanges: List<Exchange>,
        val recordedBy: String = "tools/tachi-source-runner capture",
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
        )
        val bodies = exchanges.associate { e ->
            val bytes = File(dir, e.bodyFile).readBytes()
            val digest = Digests.sha256(bytes)
            require(digest == e.sha256 && bytes.size == e.size) { "Capture body ${e.bodyFile} in $dir does not match its recorded SHA-256" }
            e.key to (e to bytes)
        }
        return CaptureSet(dir, manifest, bodies)
    }

    @Suppress("unused")
    private val unused: JsonArray? = null
}

