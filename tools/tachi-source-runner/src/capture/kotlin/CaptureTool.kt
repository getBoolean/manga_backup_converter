package mangabackup.tachi.capture

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.host.SizingReport
import mangabackup.tachi.host.replay.CaptureFormat
import mangabackup.tachi.host.replay.ExchangeHandler
import mangabackup.tachi.host.replay.LoopbackTransport
import mangabackup.tachi.protocol.ArtifactBinding
import mangabackup.tachi.protocol.WorkerClient
import mangabackup.tachi.protocol.WorkerOptions
import mockwebserver3.MockResponse
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okio.Buffer
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

/**
 * Manual, one-time capture of the qualification sources (never run by tests).
 *
 *   ./gradlew capture -PcaptureArgs="record mangadex C:/tmp/cap/all.mangadex"
 *   ./gradlew capture -PcaptureArgs="rehearse mangadex C:/tmp/cap-rehearsal"
 *
 * `record` drives the real extension through the worker (repository JAR path)
 * with a loopback recorder that forwards each request once to the live site,
 * at least 1.5 s apart and without retries, and keeps only content-type,
 * location and retry-after response headers. It then replays the same
 * operations through the dex2jar-converted APK against what was recorded, so
 * both artifact paths share one capture and a divergent request is visible
 * immediately. `rehearse` runs the same flow with an offline forwarder.
 */
data class Target(
    val key: String,
    val dir: String,
    val packageId: String,
    val jar: String,
    val apk: String,
    val version: String,
    val sourceId: String,
    val query: String,
    val licence: String,
    /** Cookies whose Set-Cookie the capture keeps (protocol 1.3 capture rule); none unless a scenario names one. */
    val setCookieAllowList: Map<String, CaptureFormat.CookieMode> = emptyMap(),
)

val TARGETS = listOf(
    Target(
        "mangadex", "all.mangadex", "eu.kanade.tachiyomi.extension.all.mangadex",
        "tachiyomi-all.mangadex-v1.6.4.jar", "tachiyomi-all.mangadex-v1.6.4.apk", "1.6.4", "2499283573021220255", "Onimai",
        "Third-party MangaDex API response; not openly licensed; retained only as an interoperability test fixture.",
    ),
    Target(
        "weebcentral", "en.weebcentral", "eu.kanade.tachiyomi.extension.en.weebcentral",
        "tachiyomi-en.weebcentral-v1.6.27.jar", "tachiyomi-en.weebcentral-v1.6.27.apk", "1.6.27", "2131019126180322627", "Onimai",
        "Third-party Weeb Central page content; not openly licensed; retained only as an interoperability test fixture.",
    ),
    Target(
        "mangafire", "all.mangafire", "eu.kanade.tachiyomi.extension.all.mangafire",
        "tachiyomi-all.mangafire-v1.6.38.jar", "tachiyomi-all.mangafire-v1.6.38.apk", "1.6.38", "6084907896154116083", "Onimai",
        "Third-party MangaFire page content; not openly licensed; retained only as an interoperability test fixture.",
    ),
)

const val KEIYOUSHI_SIGNER = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
const val MIN_INTERVAL_MS = 1_500L

/** Forwards to the live site once per capture key and records the decoded response. */
class Recorder(
    private val licence: String,
    private val offline: Boolean,
    private val setCookieAllowList: Map<String, CaptureFormat.CookieMode> = emptyMap(),
) : ExchangeHandler {
    data class Recorded(val exchange: CaptureFormat.Exchange, val body: ByteArray, val liveHeaders: Headers)

    val recorded = LinkedHashMap<CaptureFormat.Key, Recorded>()
    var liveRequests = 0
        private set
    var replayedRequests = 0
        private set
    @Volatile
    var allowLive = true
    private var last = 0L

    private val client = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    @Synchronized
    override fun handle(method: String, url: HttpUrl, headers: Headers, body: ByteArray): MockResponse {
        val key = CaptureFormat.key(method, url, body, emptySet())
        val existing = recorded[key]
        if (existing != null) {
            replayedRequests++
            return respond(existing)
        }
        if (!allowLive) {
            System.err.println("[capture] request not recorded on the JAR path: $key")
            return MockResponse.Builder().code(599).body("not recorded").build()
        }
        val wait = last + MIN_INTERVAL_MS - System.currentTimeMillis()
        if (wait > 0) Thread.sleep(wait)
        last = System.currentTimeMillis()
        liveRequests++
        System.err.println("[capture] live ${key.method} ${key.url}")
        val (status, liveHeaders, bytes) = if (offline) {
            Triple(404, Headers.headersOf("content-type", "text/plain"), "offline rehearsal".toByteArray())
        } else {
            val forwarded = Request.Builder().url(url).apply {
                for ((name, value) in headers) {
                    if (name.lowercase() in DROPPED_REQUEST_HEADERS) continue
                    addHeader(name, value)
                }
                method(method, if (method == "GET" || method == "HEAD") null else body.toRequestBody(headers["Content-Type"]?.toMediaTypeOrNull()))
            }.build()
            client.newCall(forwarded).execute().use { r -> Triple(r.code, r.headers, r.body.bytes()) }
        }
        val digest = Digests.sha256(bytes)
        val kept = liveHeaders.names().map { it.lowercase() }.filter { it in CaptureFormat.RECORDED_RESPONSE_HEADERS }
            .associateWith { liveHeaders[it]!! }
        val setCookies = liveHeaders.values("Set-Cookie")
        val cookies = CaptureFormat.recordedCookies(setCookies, setCookieAllowList)
        // Fail closed: a redacted token must not reach the capture through the body instead.
        val secrets = setCookies.flatMap(CaptureFormat::parseSetCookieHeader)
            .filter { setCookieAllowList[it.name] == CaptureFormat.CookieMode.REDACT && it.value.isNotEmpty() }
        val text = String(bytes, Charsets.UTF_8)
        secrets.firstOrNull { text.contains(it.value) }?.let { error("the redacted cookie ${it.name} appears in the body of $key") }
        val exchange = CaptureFormat.Exchange(key, status, kept, "${CaptureFormat.BODIES}/$digest.bin", key.url, digest, bytes.size, licence, cookies)
        val rec = Recorded(exchange, bytes, liveHeaders)
        recorded[key] = rec
        return respond(rec)
    }

    private fun respond(r: Recorded): MockResponse {
        // Live cookies flow back to the worker during the recording session, but are never stored.
        val b = MockResponse.Builder().code(r.exchange.status).body(Buffer().write(r.body))
        for ((name, value) in r.liveHeaders) {
            if (name.lowercase() in DROPPED_RESPONSE_HEADERS) continue
            b.addHeader(name, value)
        }
        return b.build()
    }

    fun write(dir: File, target: Target, notes: String) {
        val bodies = File(dir, CaptureFormat.BODIES)
        bodies.deleteRecursively()
        bodies.mkdirs()
        for (r in recorded.values) File(dir, r.exchange.bodyFile).writeBytes(r.body)
        val manifest = CaptureFormat.Manifest(
            "tachi", target.dir, Instant.now(), notes, emptySet(), recorded.values.map { it.exchange },
            setCookieAllowList = target.setCookieAllowList,
        )
        File(dir, CaptureFormat.MANIFEST).writeText(manifest.encode())
    }

    companion object {
        val DROPPED_REQUEST_HEADERS = setOf("host", "content-length", "connection", "accept-encoding", "transfer-encoding", "proxy-connection")
        val DROPPED_RESPONSE_HEADERS = setOf("content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive")
    }
}

/** A documented body edit applied before committing a capture. */
data class BodyEdit(val description: String, val pattern: Regex, val replacement: String)

/**
 * Edits that remove request-, client- or edge-identifying values from captured
 * bodies without changing what the extension parses. Each is recorded in the
 * manifest notes.
 */
val BODY_EDITS = mapOf(
    "weebcentral" to listOf(
        BodyEdit(
            "Cloudflare challenge-platform parameters (window.__CF${'$'}cv${'$'}params: r = Ray ID of the recording request, t = timestamp) replaced with zeros",
            Regex("""window\.__CF\${'$'}cv\${'$'}params=\{r:'[0-9a-f]+',t:'[A-Za-z0-9+/=]+'\}"""),
            "window.__CF${'$'}cv${'$'}params={r:'0000000000000000',t:'MA=='}",
        ),
    ),
)

/** Applies [BODY_EDITS] to a raw recording and writes the committed capture with recomputed digests. */
fun finalize(target: Target, raw: File, out: File) {
    val set = CaptureFormat.load(raw)
    val edits = BODY_EDITS[target.key].orEmpty()
    val applied = LinkedHashMap<String, Int>()
    val bodiesDir = File(out, CaptureFormat.BODIES)
    bodiesDir.deleteRecursively()
    bodiesDir.mkdirs()
    val exchanges = set.manifest.exchanges.map { e ->
        var text = File(raw, e.bodyFile).readBytes()
        for (edit in edits) {
            val s = String(text, Charsets.UTF_8)
            val n = edit.pattern.findAll(s).count()
            if (n > 0) {
                applied[edit.description] = (applied[edit.description] ?: 0) + n
                text = edit.pattern.replace(s) { edit.replacement }.toByteArray(Charsets.UTF_8)
            }
        }
        val digest = Digests.sha256(text)
        val file = "${CaptureFormat.BODIES}/$digest.bin"
        File(out, file).writeBytes(text)
        e.copy(bodyFile = file, sha256 = digest, size = text.size)
    }
    val editNotes = if (applied.isEmpty()) "No body edits were needed (no request-, client- or location-identifying values found)."
    else "Body edits (digests recomputed after editing): " + applied.entries.joinToString("; ") { "${it.key} (${it.value}x)" } + "."
    val manifest = set.manifest.copy(
        notes = set.manifest.notes + " Only content-type/location/retry-after response headers and no request headers are stored. " + editNotes,
        exchanges = exchanges,
    )
    File(out, CaptureFormat.MANIFEST).writeText(manifest.encode())
    CaptureFormat.load(out)
    System.err.println("[capture] finalized ${exchanges.size} exchanges into $out; $editNotes")
}

fun main(args: Array<String>) {
    if (args.size == 4 && args[0] == "finalize") {
        val target = TARGETS.first { it.key == args[1] }
        finalize(target, File(args[2]), File(args[3]))
        exitProcess(0)
    }
    if (args.size < 3 || args[0] !in setOf("record", "rehearse")) {
        System.err.println("usage: capture record|rehearse <mangadex|weebcentral|mangafire> <outputDir>")
        exitProcess(64)
    }
    val target = TARGETS.firstOrNull { it.key == args[1] } ?: run {
        System.err.println("unknown source ${args[1]}")
        exitProcess(64)
    }
    val out = File(args[2]).apply { mkdirs() }
    val fixtures = File("fixtures/source_captures/tachi/${target.dir}")
    val recorder = Recorder(target.licence, offline = args[0] == "rehearse", setCookieAllowList = target.setCookieAllowList)
    val transport = LoopbackTransport(recorder)
    val limits = mapOf("poolSize" to 1L, "operationDeadlineMs" to 300_000L, "cancelGraceMs" to 5_000L, "interactionTimeoutMs" to 60_000L, "shutdownGraceMs" to 5_000L)
    val options = WorkerOptions(
        sizing = SizingReport.resolve(limits, rule = null)!!,
        transport = transport,
        networkMode = "record",
        stateRoot = Files.createTempDirectory("tachi-capture-").toFile(),
        browser = false,
    )
    val (client, _) = WorkerClient.inProcess(options)
    val log = StringBuilder()
    try {
        client.handshake()
        val jarResult = runFlow(client, target, File(fixtures, target.jar), "jar", log)
        log.appendLine("jar path: ${recorder.liveRequests} live requests")
        recorder.allowLive = false
        val before = recorder.replayedRequests
        val apkResult = runCatching { runFlow(client, target, File(fixtures, target.apk), "apk", log) }
        log.appendLine("apk path: ${recorder.replayedRequests - before} requests served from the JAR recording; ${apkResult.exceptionOrNull()?.let { "failed: $it" } ?: "ok"}")
        log.appendLine("jar/apk results equal: ${apkResult.getOrNull() == jarResult}")
    } catch (e: Exception) {
        log.appendLine("FAILED: $e")
        e.printStackTrace()
    } finally {
        recorder.write(out, target, "Recorded by tools/tachi-source-runner capture (JAR path, query '${target.query}'); replayed by the tachi-source-runner JVM tests.")
        File(out, "capture-log.txt").writeText(log.toString())
        System.err.println(log)
        runCatching { client.call("shutdown", timeoutMs = 10_000) }
        client.close()
        transport.close()
    }
    exitProcess(0)
}

/** prepare → load → search → details (handle) → details (durable ref only); returns a comparable summary. */
fun runFlow(client: WorkerClient, target: Target, artifact: File, kind: String, log: StringBuilder): String {
    val staged = Files.createTempFile("capture-staged-", ".jar").toFile()
    val prepared = client.call("artifact.prepare", target.packageId, buildJsonObject {
        put("artifact", ArtifactBinding(Digests.sha256(artifact), kind, target.version).toJson())
        put("inputPath", artifact.absolutePath)
        put("outputPath", staged.absolutePath)
        put("trustedSigners", buildJsonArray { add(JsonPrimitive(KEIYOUSHI_SIGNER)) })
    })
    val binding = ArtifactBinding.from(prepared["artifact"]!!.jsonObject)
    val settings = buildJsonObject {
        put("values", JsonObject(emptyMap()))
        put("secrets", JsonObject(emptyMap()))
        put("revision", "capture")
    }
    client.call("package.load", target.packageId, buildJsonObject {
        put("artifact", binding.toJson())
        put("path", staged.absolutePath)
        put("settings", settings)
    })
    val identity = buildJsonObject {
        put("ecosystem", "tachi")
        put("packageId", target.packageId)
        put("sourceId", target.sourceId)
        put("artifact", binding.toJson())
    }
    val search = client.call("search", target.packageId, buildJsonObject {
        put("source", identity)
        put("settingsRevision", "capture")
        put("query", target.query)
        put("cursor", kotlinx.serialization.json.JsonNull)
    }, timeoutMs = 300_000)
    val hits = (search["hits"] as JsonArray).map { it.jsonObject }
    log.appendLine("$kind search '${target.query}': ${hits.size} hits")
    val hit = hits.firstOrNull { it["title"]!!.jsonPrimitive.content.contains(target.query, ignoreCase = true) } ?: hits.firstOrNull()
        ?: return "no hits"
    val details = client.call("details", target.packageId, buildJsonObject {
        put("source", identity)
        put("settingsRevision", "capture")
        put("ref", hit["ref"]!!)
        put("handle", hit["handle"]!!)
    }, timeoutMs = 300_000)
    val again = client.call("details", target.packageId, buildJsonObject {
        put("source", identity)
        put("settingsRevision", "capture")
        put("ref", hit["ref"]!!)
    }, timeoutMs = 300_000)
    val chapters = (details["chapters"] as JsonArray).size
    log.appendLine("$kind details '${hit["title"]!!.jsonPrimitive.content}': $chapters chapters; durable-ref details equal: ${again == details}")
    staged.delete()
    return "${hits.map { it["title"] }}|${details["metadata"]}|$chapters|${JsonPrimitive(chapters)}"
}
