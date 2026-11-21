package mangabackup.tachi

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangabackup.tachi.host.SizingRule
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.Frame
import mangabackup.tachi.protocol.WorkerError
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

class ProtocolTest {
    @Test
    fun `handshake reports protocol v1, API families and the sizing inputs and derived limits`() {
        WorkerHarness().use { h ->
            val ok = h.client.call("handshake", payload = buildJsonObject {
                put("protocolVersions", kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive(1))))
                put("maxFrameBytes", 16777216)
            })
            assertEquals(1, ok["protocolVersion"]!!.jsonPrimitive.content.toInt())
            assertEquals(0, ok["protocolMinor"]!!.jsonPrimitive.content.toInt(), "a 1.0 supervisor (no protocolMinor) gets 1.0")
            assertEquals("tachi-jvm", ok["worker"]!!.jsonPrimitive.content)
            val caps = ok["capabilities"]!!.jsonObject
            assertEquals(listOf("tachi-1.4", "tachi-1.5", "tachi-1.6"), caps["apiFamilies"]!!.jsonArray.map { it.jsonPrimitive.content })
            assertEquals("true", caps["browser"]!!.jsonPrimitive.content)
            val sizing = ok["sizing"]!!.jsonObject
            assertTrue(sizing["inputs"]!!.jsonObject.containsKey("cores"))
            assertEquals("2", ok["limits"]!!.jsonObject["poolSize"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun `handshake negotiates the lower of the offered minor and 2, and rejects a malformed minor`() {
        WorkerHarness().use { h ->
            fun offer(minor: kotlinx.serialization.json.JsonElement) = h.client.call("handshake", payload = buildJsonObject {
                put("protocolVersions", kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive(1))))
                put("protocolMinor", minor)
                put("maxFrameBytes", 16777216)
            })
            assertEquals(1, offer(JsonPrimitive(1))["protocolMinor"]!!.jsonPrimitive.content.toInt())
            assertEquals(2, offer(JsonPrimitive(2))["protocolMinor"]!!.jsonPrimitive.content.toInt())
            assertEquals(3, offer(JsonPrimitive(3))["protocolMinor"]!!.jsonPrimitive.content.toInt())
            assertEquals(3, offer(JsonPrimitive(7))["protocolMinor"]!!.jsonPrimitive.content.toInt())
            assertEquals(0, offer(JsonPrimitive(0))["protocolMinor"]!!.jsonPrimitive.content.toInt())
            assertEquals(ErrorCode.PROTOCOL_VIOLATION, assertThrows<WorkerError> { offer(JsonPrimitive(-1)) }.code)
            assertEquals(ErrorCode.PROTOCOL_VIOLATION, assertThrows<WorkerError> { offer(JsonPrimitive("1")) }.code)
        }
    }

    @Test
    fun `sizing rule derives every limit from measured inputs`() {
        val rule = SizingRule("test", 1.0, 256.0, 64.0, 2000.0, 3.0, 400.0, 900.0, 2.0, 300_000, maxPoolSize = 6)
        val limits = rule.derive(SizingRule.Inputs(cores = 8, maxHeapMiB = 512))
        assertEquals(4, limits.poolSize) // heap-bound: (512-256)/64
        assertEquals(6000, limits.operationDeadlineMs)
        assertEquals(1800, limits.cancelGraceMs)
        assertEquals(1800, limits.shutdownGraceMs)
        assertEquals(1, rule.derive(SizingRule.Inputs(cores = 1, maxHeapMiB = 100)).poolSize)
        assertEquals(6, rule.derive(SizingRule.Inputs(cores = 32, maxHeapMiB = 4096)).poolSize, "never beyond the measured concurrency")
    }

    @Test
    fun `without overrides the worker derives every limit from the committed sizing rule and reports it`() {
        val javaHome = java.io.File(System.getProperty("tachi.javaHome"))
        val (client, process) = mangabackup.tachi.protocol.WorkerClient.subprocess(javaHome, System.getProperty("tachi.workerClasspath"), emptyList())
        try {
            val ok = client.handshake()
            val sizing = ok["sizing"]!!.jsonObject
            assertTrue(sizing["rule"]!!.jsonObject["source"]!!.jsonPrimitive.content.contains("docs/validation/source-runners/desktop/"))
            assertEquals(0, sizing["overridden"]!!.jsonArray.size)
            val limits = ok["limits"]!!.jsonObject
            for (key in mangabackup.tachi.host.WorkerLimits.KEYS) assertTrue(limits[key]!!.jsonPrimitive.content.toLong() > 0, key)
            client.call("shutdown")
        } finally {
            client.close()
            process.destroyForcibly()
        }
    }

    @Test
    fun `operations before the handshake and unknown operations are protocol violations`() {
        val (client, _) = mangabackup.tachi.protocol.WorkerClient.inProcess(WorkerHarness().options)
        val e = assertThrows<WorkerError> { client.call("search", "x.y", JsonObject(emptyMap())) }
        assertEquals(ErrorCode.PROTOCOL_VIOLATION, e.code)
        client.handshake()
        val e2 = assertThrows<WorkerError> { client.call("frobnicate", "x.y") }
        assertEquals(ErrorCode.PROTOCOL_VIOLATION, e2.code)
        val e3 = assertThrows<WorkerError> { client.call("search", "x.y", JsonObject(emptyMap())) }
        assertEquals(ErrorCode.RUNTIME_UNAVAILABLE, e3.code)
        client.close()
    }

    @Test
    fun `search and details replies carry durable refs, decimal source IDs and exact chapter numbers`() {
        val site = FakeSite()
        WorkerHarness(site.transport()).use { h ->
            val pkg = h.loadFixture("a")
            val sourceId = pkg.sources.first()["sourceId"]!!.jsonPrimitive
            assertTrue(sourceId.isString)
            val result = h.search(pkg, "onimai")
            val hits = h.hits(result)
            assertEquals(2, hits.size)
            assertEquals("2", result["nextCursor"]!!.jsonPrimitive.content)
            assertEquals(listOf("Author One", "Author Two"), hits[0]["authors"]!!.jsonArray.map { it.jsonPrimitive.content })
            val details = h.details(pkg, hits[0])
            val chapters = details["chapters"]!!.jsonArray.map { it.jsonObject }
            assertEquals("1.1", chapters[0]["chapterNumber"].toString())
            assertEquals("null", chapters[1]["chapterNumber"].toString(), "negative sentinel numbers are not sent as numbers")
            assertEquals(listOf("Group A", "Group B"), chapters[0]["scanlators"]!!.jsonArray.map { it.jsonPrimitive.content })
            assertEquals("2023-11-14T22:13:20Z", chapters[0]["dateUploaded"]!!.jsonPrimitive.content)
            assertEquals("completed", details["metadata"]!!.jsonObject["status"]!!.jsonPrimitive.content)
            // Every frame the worker wrote is a well-formed v1 frame of the current generation.
            for (line in h.client.transcript.filter { it.startsWith("<< ") }) {
                val frame = Frame.parse(line.removePrefix("<< "))
                assertEquals(1L, frame.gen)
            }
        }
    }

    @Test
    fun `a stale settings revision or foreign handle is a stale-reference`() {
        WorkerHarness(FakeSite().transport()).use { h ->
            val pkg = h.loadFixture("a")
            val hit = h.hits(h.search(pkg, "x"))[0]
            val stale = pkg.copy(revision = "other")
            assertEquals(ErrorCode.STALE_REFERENCE, assertThrows<WorkerError> { h.search(stale, "x") }.code)
            val forged = buildJsonObject {
                hit.forEach { (k, v) -> put(k, v) }
                put("handle", "h999")
            }
            assertEquals(ErrorCode.STALE_REFERENCE, assertThrows<WorkerError> { h.details(pkg, forged) }.code)
            assertNull(null)
        }
    }
}

