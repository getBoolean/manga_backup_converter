package mangabackup.tachi

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.protocol.ArtifactBinding
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.WorkerClient
import mangabackup.tachi.protocol.WorkerError
import mangabackup.tachi.protocol.optStr
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

class WorkerLifecycleTest {
    @Test
    fun `a blocking source is cancelled cooperatively within the grace period`() {
        WorkerHarness().use { h ->
            val pkg = h.loadFixture("busy")
            val (id, future) = h.client.send("search", pkg.packageId, h.searchPayload(pkg, "slow"))
            Thread.sleep(300)
            val start = System.nanoTime()
            h.client.cancel(id)
            val reply = future.get(TEST_LIMITS.getValue("cancelGraceMs"), TimeUnit.MILLISECONDS)
            assertEquals(ErrorCode.CANCELLED, reply.err!!.optStr("code"))
            assertTrue((System.nanoTime() - start) / 1_000_000 < TEST_LIMITS.getValue("cancelGraceMs"))
            // The package is usable afterwards.
            assertEquals("ok", h.hits(h.search(pkg, "ok"))[0]["title"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun `a busy loop does not settle after cancel, so a restart reloads every package and rehydrates refs`() {
        val javaHome = File(System.getProperty("tachi.javaHome"))
        val classpath = System.getProperty("tachi.workerClasspath")
        val args = TEST_LIMITS.flatMap { (k, v) -> listOf("--limit", "$k=$v") } + listOf("--trusted-signer", TestSupport.KEIYOUSHI_SIGNER)
        val busyJar = File(TestSupport.fixtureJars, "fixture-busy.jar")
        val multiJar = File(TestSupport.fixtureJars, "fixture-multi.jar")
        fun loadAll(client: WorkerClient): Map<String, WorkerHarness.Loaded> =
            listOf("fixture.busy" to busyJar, "fixture.multi" to multiJar).associate { (pkg, jar) ->
                val binding = ArtifactBinding(Digests.sha256(jar), "jar", "1")
                val ok = client.call("package.load", pkg, kotlinx.serialization.json.buildJsonObject {
                    put("artifact", binding.toJson())
                    put("path", kotlinx.serialization.json.JsonPrimitive(jar.absolutePath))
                    put("settings", WorkerHarnessSettings.empty)
                })
                pkg to WorkerHarness.Loaded(pkg, binding, (ok["sources"] as kotlinx.serialization.json.JsonArray).map { it.jsonObject }, "rev-0")
            }
        val (first, process) = WorkerClient.subprocess(javaHome, classpath, args, generation = 1)
        val handshake = first.handshake()
        assertEquals("2", handshake["limits"]!!.jsonObject["poolSize"]!!.jsonPrimitive.content)
        val loaded = loadAll(first)
        val multiLoaded = loaded.getValue("fixture.multi")
        val busyLoaded = loaded.getValue("fixture.busy")
        val helper = PayloadHelper()
        val hit = (first.call("search", "fixture.multi", helper.search(multiLoaded, "q"))["hits"] as kotlinx.serialization.json.JsonArray)[0].jsonObject

        val (busyId, busyReply) = first.send("search", "fixture.busy", helper.search(busyLoaded, "busy"))
        Thread.sleep(300)
        first.cancel(busyId)
        val settled = try {
            busyReply.get(TEST_LIMITS.getValue("cancelGraceMs"), TimeUnit.MILLISECONDS)
            true
        } catch (_: TimeoutException) {
            false
        }
        assertFalse(settled, "a non-cooperative busy loop cannot settle; the supervisor must restart the worker")
        val start = System.nanoTime()
        process.destroyForcibly().waitFor(10, TimeUnit.SECONDS)
        first.close()

        val (second, process2) = WorkerClient.subprocess(javaHome, classpath, args, generation = 2)
        try {
            second.handshake()
            loadAll(second)
            // KTD3: the confirmation is rehydrated from its durable reference, without the old handle.
            val details = second.call("details", "fixture.multi", helper.detailsWithoutHandle(multiLoaded, hit))
            val restartMs = (System.nanoTime() - start) / 1_000_000
            assertEquals("One:q", details["metadata"]!!.jsonObject["title"]!!.jsonPrimitive.content)
            System.err.println("[test] restart-and-rehydrate took $restartMs ms")
            second.call("shutdown")
            assertTrue(process2.waitFor(10, TimeUnit.SECONDS))
        } finally {
            second.close()
            process2.destroyForcibly()
        }
    }

    @Test
    fun `the worker refuses a JRE below the security floor`() {
        assertFalse(jreMeetsFloor(Runtime.Version.parse("21.0.12")))
        assertFalse(jreMeetsFloor(Runtime.Version.parse("17.0.20")))
        assertTrue(jreMeetsFloor(Runtime.Version.parse("21.0.13")))
        assertTrue(jreMeetsFloor(Runtime.Version.parse("25")))
        assertTrue(jreMeetsFloor(), "tests must run on the Corretto floor or later")
    }

    @Test
    fun `shutdown replies and ends the worker`() {
        val h = WorkerHarness()
        h.client.call("shutdown")
        assertTrue(h.client.awaitExit(5_000))
        val e = runCatching { h.client.call("handshake", timeoutMs = 2_000) }.exceptionOrNull()
        assertTrue(e != null)
        h.client.close()
    }

    @Suppress("unused")
    private val unused: WorkerError? = null
}

object WorkerHarnessSettings {
    val empty = kotlinx.serialization.json.buildJsonObject {
        put("values", kotlinx.serialization.json.JsonObject(emptyMap()))
        put("secrets", kotlinx.serialization.json.JsonObject(emptyMap()))
        put("revision", kotlinx.serialization.json.JsonPrimitive("rev-0"))
    }
}

class PayloadHelper {
    private fun identity(l: WorkerHarness.Loaded, sourceId: String) = kotlinx.serialization.json.buildJsonObject {
        put("ecosystem", kotlinx.serialization.json.JsonPrimitive("tachi"))
        put("packageId", kotlinx.serialization.json.JsonPrimitive(l.packageId))
        put("sourceId", kotlinx.serialization.json.JsonPrimitive(sourceId))
        put("artifact", l.artifact.toJson())
    }

    fun search(l: WorkerHarness.Loaded, query: String) = kotlinx.serialization.json.buildJsonObject {
        put("source", identity(l, l.sources.first()["sourceId"]!!.jsonPrimitive.content))
        put("settingsRevision", kotlinx.serialization.json.JsonPrimitive(l.revision))
        put("query", kotlinx.serialization.json.JsonPrimitive(query))
    }

    fun detailsWithoutHandle(l: WorkerHarness.Loaded, hit: kotlinx.serialization.json.JsonObject) = kotlinx.serialization.json.buildJsonObject {
        put("source", hit["ref"]!!.jsonObject["source"]!!)
        put("settingsRevision", kotlinx.serialization.json.JsonPrimitive(l.revision))
        put("ref", hit["ref"]!!)
    }
}

