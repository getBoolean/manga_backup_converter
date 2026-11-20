package mangabackup.tachi

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangabackup.tachi.host.replay.CaptureFormat
import mangabackup.tachi.host.replay.LoopbackTransport
import mangabackup.tachi.host.replay.ReplayLog
import mangabackup.tachi.host.replay.ReplayTransport
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.Frame
import mangabackup.tachi.protocol.WorkerError
import mangabackup.tachi.protocol.optStr
import mockwebserver3.MockResponse
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/**
 * U3 step 5: the qualification sources' original code runs against committed
 * captures only. Any uncaptured request gets a 599 and fails the test.
 */
class CapturedProofTest {
    data class Case(val q: TestSupport.Qualification, val sourceId: String, val query: String, val minChapters: Int)

    private val cases = listOf(
        Case(TestSupport.MANGADEX, "2499283573021220255", "Onimai", 1),
        Case(TestSupport.WEEBCENTRAL, "2131019126180322627", "Onimai", 100),
        Case(TestSupport.MANGAFIRE, "6084907896154116083", "Onimai", 50),
    )

    private fun captureDir(q: TestSupport.Qualification) = File(TestSupport.fixtures, q.dir)

    private fun runFlow(h: WorkerHarness, c: Case, kind: String, settings: JsonObject = h.settings()): String {
        val input = if (kind == "jar") TestSupport.jar(c.q) else TestSupport.apk(c.q)
        val (binding, staged) = h.prepare(c.q.packageId, input, kind, c.q.version)
        val loaded = h.load(c.q.packageId, staged, binding, settings)
        val hits = h.hits(h.search(loaded, c.query, c.sourceId))
        assertTrue(hits.isNotEmpty(), "${c.q.dir} $kind: no hits")
        val hit = hits.firstOrNull { it["title"]!!.jsonPrimitive.content.contains(c.query, ignoreCase = true) } ?: hits.first()
        val details = h.details(loaded, hit, sourceId = c.sourceId)
        val rehydrated = h.details(loaded, hit, useHandle = false, sourceId = c.sourceId)
        assertEquals(details, rehydrated, "durable-ref details differ from handle details")
        val chapters = (details["chapters"] as JsonArray).map { it.jsonObject }
        assertTrue(chapters.size >= c.minChapters, "${c.q.dir} $kind: ${chapters.size} chapters")
        assertTrue(chapters.all { it["chapterId"]!!.jsonPrimitive.content.isNotEmpty() })
        val meta = details["metadata"]!!.jsonObject
        return "${hits.map { it["title"] }}|$meta|${chapters.map { listOf(it["chapterId"], it["title"], it["chapterNumber"], it["dateUploaded"], it["scanlators"]) }}"
    }

    @Test
    fun `MangaDex, WeebCentral and MangaFire run from captures on both artifact paths with equivalent results`() {
        for (c in cases) {
            val transport = ReplayTransport.start(listOf(captureDir(c.q)))
            WorkerHarness(transport).use { h ->
                val jar = runFlow(h, c, "jar")
                val apk = runFlow(h, c, "apk")
                assertEquals(jar, apk, "${c.q.dir}: JAR and converted APK disagree")
                assertEquals(emptyList<CaptureFormat.Key>(), transport.log.misses, "${c.q.dir} made uncaptured requests")
                dumpTranscript(c.q.dir, h.client.transcript)
            }
            transport.close()
        }
    }

    /** Writes the frame transcript when `tachi.transcriptDir` is set, for the Dart payload conformance check. */
    private fun dumpTranscript(name: String, lines: List<String>) {
        val dir = System.getProperty("tachi.transcriptDir") ?: return
        File(dir).mkdirs()
        File(dir, "$name.jsonl").writeText(lines.joinToString("\n") + "\n")
    }

    /** MangaFire answers its first API call with the shape-selecting captcha, then serves the capture. */
    private fun challengeTransport(log: ReplayLog, served403: AtomicBoolean): LoopbackTransport {
        val captures = listOf(CaptureFormat.load(captureDir(TestSupport.MANGAFIRE)))
        return LoopbackTransport { method, url, _, body ->
            if (url.encodedPath == "/api/titles" && served403.compareAndSet(false, true)) {
                MockResponse.Builder().code(403).setHeader("content-type", "application/json").body("{\"error\":\"captcha_required\"}").build()
            } else {
                ReplayTransport.respond(captures, log, method, url, body)
            }
        }
    }

    private class SolvingPort(private val h: () -> WorkerHarness, private val failOpen: String? = null) : (Frame) -> JsonObject {
        val ops = CopyOnWriteArrayList<Frame>()
        private val channels = CopyOnWriteArrayList<String>()

        override fun invoke(f: Frame): JsonObject {
            ops += f
            val p = f.payload!!
            return when (f.op) {
                "host.browser.open" -> {
                    failOpen?.let { throw WorkerError(it, "fake port: $it", "host.browser.open") }
                    buildJsonObject { put("session", "s-mf") }
                }
                "host.browser.setMessageHandler" -> {
                    channels += p.optStr("name")!!
                    JsonObject(emptyMap())
                }
                "host.browser.loadData" -> {
                    Thread {
                        Thread.sleep(100)
                        for (name in channels) {
                            h().client.event("host.browser.message", buildJsonObject {
                                put("session", "s-mf")
                                put("name", name)
                                put("message", "true")
                            })
                        }
                    }.start()
                    buildJsonObject { put("finalUrl", p.optStr("baseUrl")!!) }
                }
                "host.browser.getCookies" -> buildJsonObject { put("cookies", JsonArray(emptyList())) }
                else -> JsonObject(emptyMap())
            }
        }
    }

    private fun solveSettings(h: WorkerHarness) = h.settings(values = mapOf("solve_captcha" to true))

    @Test
    fun `MangaFire's challenge runs the real helper through the shim's addJavascriptInterface fallback and completes`() {
        val log = ReplayLog()
        val served = AtomicBoolean(false)
        lateinit var h: WorkerHarness
        val port = SolvingPort({ h })
        h = WorkerHarness(challengeTransport(log, served))
        h.use {
            h.client.reverseHandler = port
            runFlow(h, cases[2], "jar", solveSettings(h))
            assertTrue(served.get(), "the challenge did not fire")
            val ops = port.ops.map { it.op }
            assertTrue("host.browser.setMessageHandler" in ops, "no JavascriptInterface fallback: $ops")
            val load = port.ops.first { it.op == "host.browser.loadData" }.payload!!
            assertEquals("https://mangafire.to/@waf/solver", load.optStr("baseUrl"))
            assertTrue(load.optStr("html")!!.isNotEmpty(), "solver.html resource reached the browser")
            assertEquals(emptyList<CaptureFormat.Key>(), log.misses)
            dumpTranscript("mangafire-challenge", h.client.transcript)
        }
    }

    @Test
    fun `a MangaFire challenge reports interaction-required or capability-unavailable against the fake port`() {
        for (code in listOf(ErrorCode.INTERACTION_REQUIRED, ErrorCode.CAPABILITY_UNAVAILABLE)) {
            lateinit var h: WorkerHarness
            val port = SolvingPort({ h }, failOpen = code)
            h = WorkerHarness(challengeTransport(ReplayLog(), AtomicBoolean(false)))
            h.use {
                h.client.reverseHandler = port
                val c = cases[2]
                val (binding, staged) = h.prepare(c.q.packageId, TestSupport.jar(c.q), "jar", c.q.version)
                val loaded = h.load(c.q.packageId, staged, binding, solveSettings(h))
                val e = assertThrows<WorkerError> { h.search(loaded, c.query, c.sourceId) }
                assertEquals(code, e.code, e.message)
            }
        }
    }
}
