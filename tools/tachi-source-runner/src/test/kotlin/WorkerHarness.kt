package mangabackup.tachi

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.host.HostTransport
import mangabackup.tachi.host.SizingReport
import mangabackup.tachi.host.replay.ExchangeHandler
import mangabackup.tachi.host.replay.LoopbackTransport
import mangabackup.tachi.protocol.ArtifactBinding
import mangabackup.tachi.protocol.WorkerClient
import mangabackup.tachi.protocol.WorkerOptions
import mockwebserver3.MockResponse
import java.io.File

/** Small, explicit limits for contract tests (KTD25: tests use override values). */
val TEST_LIMITS = mapOf(
    "poolSize" to 2L,
    "operationDeadlineMs" to 30_000L,
    "cancelGraceMs" to 2_000L,
    "interactionTimeoutMs" to 10_000L,
    "shutdownGraceMs" to 2_000L,
)

/** An in-process worker plus helpers that speak the protocol the way the supervisor does. */
class WorkerHarness(
    transport: HostTransport = HostTransport.LIVE,
    limits: Map<String, Long> = TEST_LIMITS,
    browser: Boolean = true,
    val stateRoot: File = TestSupport.tempDir("worker"),
    /** The minor version the fake supervisor offers in the handshake. */
    minor: Int = mangabackup.tachi.protocol.Wire.MINOR_VERSION,
    /** Platform hooks; a test platform supplies operation deadlines (the desktop has none of its own). */
    platform: mangabackup.tachi.protocol.WorkerPlatform = mangabackup.tachi.protocol.DesktopPlatform,
) : AutoCloseable {
    val options = WorkerOptions(
        sizing = SizingReport.resolve(limits, rule = null)!!,
        transport = transport,
        networkMode = "test",
        stateRoot = stateRoot,
        browser = browser,
        platform = platform,
    )
    val client: WorkerClient
    private val thread: Thread
    val handshake: JsonObject

    init {
        val (c, t) = WorkerClient.inProcess(options)
        client = c
        thread = t
        handshake = client.handshake(minor)
    }

    data class Loaded(val packageId: String, val artifact: ArtifactBinding, val sources: List<JsonObject>, val revision: String)

    /** A `SettingsPayload`; [sources] maps a source ID to its own (values, secrets) overrides (1.1). */
    fun settings(
        values: Map<String, Any> = emptyMap(),
        secrets: Map<String, String> = emptyMap(),
        revision: String = "rev-1",
        sources: Map<String, Pair<Map<String, Any>, Map<String, String>>> = emptyMap(),
    ) = buildJsonObject {
        put("values", settingsValues(values))
        put("secrets", JsonObject(secrets.mapValues { JsonPrimitive(it.value) }))
        if (sources.isNotEmpty()) {
            put("sources", JsonObject(sources.mapValues { (_, scope) ->
                buildJsonObject {
                    put("values", settingsValues(scope.first))
                    put("secrets", JsonObject(scope.second.mapValues { JsonPrimitive(it.value) }))
                }
            }))
        }
        put("revision", revision)
    }

    private fun settingsValues(values: Map<String, Any>) = JsonObject(values.mapValues { (_, v) ->
        when (v) {
            is String -> JsonPrimitive(v)
            is Boolean -> JsonPrimitive(v)
            is Number -> JsonPrimitive(v)
            is Collection<*> -> JsonArray(v.map { JsonPrimitive(it as String) })
            else -> error("bad settings value $v")
        }
    })

    fun prepare(
        packageId: String,
        input: File,
        kind: String,
        version: String,
        trustedSigners: List<String> = listOf(TestSupport.KEIYOUSHI_SIGNER),
    ): Pair<ArtifactBinding, File> {
        val out = File(TestSupport.tempDir("staged"), "staged.jar")
        val ok = client.call("artifact.prepare", packageId, prepareRequest(input, kind, version, out, trustedSigners))
        val binding = mangabackup.tachi.protocol.Wire.decode<mangabackup.tachi.protocol.ArtifactBinding>(ok["artifact"]!!.jsonObject)
        check(Digests.sha256(out) == binding.sha256) { "reported digest does not match the staged output" }
        return binding to out
    }

    fun prepareRequest(input: File, kind: String, version: String, out: File, trustedSigners: List<String>?) = buildJsonObject {
        put("artifact", mangabackup.tachi.protocol.Wire.encode(ArtifactBinding(Digests.sha256(input), kind, version)))
        put("inputPath", input.absolutePath)
        put("outputPath", out.absolutePath)
        if (trustedSigners != null) put("trustedSigners", JsonArray(trustedSigners.map { JsonPrimitive(it) }))
    }

    fun load(packageId: String, staged: File, binding: ArtifactBinding = ArtifactBinding(Digests.sha256(staged), "jar", "1"), settings: JsonObject = settings()): Loaded {
        val ok = client.call("package.load", packageId, buildJsonObject {
            put("artifact", mangabackup.tachi.protocol.Wire.encode(binding))
            put("path", staged.absolutePath)
            put("settings", settings)
        })
        return Loaded(packageId, binding, ok["sources"]!!.jsonArray.map { it.jsonObject }, settings["revision"]!!.jsonPrimitive.content)
    }

    fun loadFixture(name: String, packageId: String = "fixture.$name", settings: JsonObject = settings()): Loaded =
        load(packageId, File(TestSupport.fixtureJars, "fixture-$name.jar"), settings = settings)

    fun identity(loaded: Loaded, sourceId: String = loaded.sources.first()["sourceId"]!!.jsonPrimitive.content) = buildJsonObject {
        put("ecosystem", "tachi")
        put("packageId", loaded.packageId)
        put("sourceId", sourceId)
        put("artifact", mangabackup.tachi.protocol.Wire.encode(loaded.artifact))
    }

    fun searchPayload(loaded: Loaded, query: String, sourceId: String? = null, cursor: String? = null) = buildJsonObject {
        put("source", sourceId?.let { identity(loaded, it) } ?: identity(loaded))
        put("settingsRevision", loaded.revision)
        put("query", query)
        put("cursor", cursor)
    }

    fun search(loaded: Loaded, query: String, sourceId: String? = null): JsonObject =
        client.call("search", loaded.packageId, searchPayload(loaded, query, sourceId))

    fun details(loaded: Loaded, hit: JsonObject, useHandle: Boolean = true, sourceId: String? = null): JsonObject =
        client.call("details", loaded.packageId, buildJsonObject {
            put("source", sourceId?.let { identity(loaded, it) } ?: identity(loaded))
            put("settingsRevision", loaded.revision)
            put("ref", hit["ref"]!!)
            if (useHandle) put("handle", hit["handle"]!!)
        })

    fun hits(result: JsonObject): List<JsonObject> = (result["hits"] as JsonArray).map { it.jsonObject }

    override fun close() {
        try {
            client.call("shutdown", timeoutMs = 10_000)
        } catch (_: Exception) {
        }
        client.close()
        thread.join(5_000)
        stateRoot.deleteRecursively()
    }
}

/**
 * Fake plain-text site for [fixture.common.SimpleSite]. `/search` echoes the
 * query, mark and class tag; `/m/<id>` returns details with two chapters.
 */
class FakeSite(private val searchDelayMs: Long = 0) : ExchangeHandler {
    val requests = java.util.concurrent.CopyOnWriteArrayList<String>()

    override fun handle(method: String, url: okhttp3.HttpUrl, headers: okhttp3.Headers, body: ByteArray): MockResponse {
        requests += "${url.host}${url.encodedPath}?${url.encodedQuery.orEmpty()} cookie=${headers["Cookie"].orEmpty()}"
        val cookieOut = "visited-${url.host}=${url.queryParameter("mark") ?: "x"}; Path=/"
        return when {
            url.encodedPath == "/search" -> {
                if (searchDelayMs > 0) Thread.sleep(searchDelayMs)
                val q = url.queryParameter("q").orEmpty()
                val tag = url.queryParameter("tag")
                val mark = url.queryParameter("mark")
                MockResponse.Builder().code(200).setHeader("Set-Cookie", cookieOut)
                    .body("/m/1|Result $q [$tag/$mark]|Author One, Author Two\n/m/2|Second $q|Author Three").build()
            }
            url.encodedPath.startsWith("/m/") ->
                MockResponse.Builder().code(200).body("Details ${url.encodedPath}|Author One|2|/c/1;Chapter 1;1.1,/c/2;Chapter 2;-1").build()
            else -> MockResponse.Builder().code(404).body("not found").build()
        }
    }

    fun transport() = LoopbackTransport(this)
}

