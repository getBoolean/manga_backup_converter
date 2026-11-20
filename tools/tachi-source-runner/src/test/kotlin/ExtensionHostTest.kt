package mangabackup.tachi

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.host.HostSettings
import mangabackup.tachi.host.InMemorySharedPreferences
import mangabackup.tachi.protocol.ArtifactBinding
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.WorkerError
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.File

class ExtensionHostTest {
    @Test
    fun `artifact prepare stages verified JARs and converts verified APKs, and the worker loads both`() {
        WorkerHarness().use { h ->
            for (q in TestSupport.ALL) {
                for (kind in listOf("jar", "apk")) {
                    val input = if (kind == "jar") TestSupport.jar(q) else TestSupport.apk(q)
                    val (binding, staged) = h.prepare(q.packageId, input, kind, q.version)
                    val loaded = h.load(q.packageId, staged, binding)
                    assertEquals(TestSupport.indexIds(q), loaded.sources.map { it["sourceId"]!!.jsonPrimitive.content }.toSet(), "${q.dir} $kind")
                    val caps = loaded.sources.first()["capabilities"]!!.jsonObject
                    assertEquals(listOf("tachi-1.6"), caps["apiFamilies"]!!.jsonArray.map { it.jsonPrimitive.content })
                    if (q == TestSupport.MANGAFIRE) assertEquals("true", caps["requiresBrowser"]!!.jsonPrimitive.content)
                }
            }
        }
    }

    @Test
    fun `prepare refuses a digest mismatch or tampered input and leaves no output behind`() {
        WorkerHarness().use { h ->
            val q = TestSupport.WEEBCENTRAL
            val out = File(TestSupport.tempDir("refuse"), "out.jar")
            val e = assertThrows<WorkerError> {
                h.client.call("artifact.prepare", q.packageId, buildJsonObject {
                    put("artifact", ArtifactBinding("00".repeat(32), "jar", q.version).toJson())
                    put("inputPath", TestSupport.jar(q).absolutePath)
                    put("outputPath", out.absolutePath)
                })
            }
            assertEquals(ErrorCode.ARTIFACT_INCOMPATIBLE, e.code)
            assertFalse(out.exists())
            val resigned = File(TestSupport.tempDir("resigned"), "r.jar")
            TestSigning.resign(TestSupport.jar(q), resigned)
            val e2 = assertThrows<WorkerError> { h.prepare(q.packageId, resigned, "jar", q.version) }
            assertEquals(ErrorCode.ARTIFACT_INCOMPATIBLE, e2.code)
        }
    }

    @Test
    fun `package load re-verifies the staged digest`() {
        WorkerHarness().use { h ->
            val staged = File(TestSupport.fixtureJars, "fixture-a.jar")
            val e = assertThrows<WorkerError> { h.load("fixture.a", staged, ArtifactBinding("ab".repeat(32), "jar", "1")) }
            assertEquals(ErrorCode.ARTIFACT_INCOMPATIBLE, e.code)
            val e2 = assertThrows<WorkerError> { h.load("fixture.a", staged, ArtifactBinding(Digests.sha256(staged), "apk", "1")) }
            assertEquals(ErrorCode.ARTIFACT_INCOMPATIBLE, e2.code)
        }
    }

    @Test
    fun `an extensions-lib 1_5 source runs through the legacy Rx adapter`() {
        val site = mangabackup.tachi.host.replay.LoopbackTransport { _, url, _, _ ->
            val body = if (url.encodedPath == "/search") "/l/1|Legacy hit" else "Legacy Title"
            mockwebserver3.MockResponse.Builder().code(200).body(body).build()
        }
        WorkerHarness(site).use { h ->
            val pkg = h.loadFixture("legacy")
            assertEquals(listOf("tachi-1.5"), pkg.sources.first()["capabilities"]!!.jsonObject["apiFamilies"]!!.jsonArray.map { it.jsonPrimitive.content })
            val hit = h.hits(h.search(pkg, "x")).single()
            val details = h.details(pkg, hit)
            assertEquals("Legacy Title", details["metadata"]!!.jsonObject["title"]!!.jsonPrimitive.content)
            assertEquals("Chapter 1", details["chapters"]!!.jsonArray[0].jsonObject["title"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun `unsupported APIs, the missing JS engine and a missing artifact package are distinct errors`() {
        WorkerHarness().use { h ->
            val pkg = h.loadFixture("busy")
            val unsupported = assertThrows<WorkerError> { h.search(pkg, "unsupported") }
            assertEquals(ErrorCode.CAPABILITY_UNAVAILABLE, unsupported.code)
            assertEquals("host.api:Context.getCacheDir", unsupported.operation)
            val js = assertThrows<WorkerError> { h.search(pkg, "js") }
            assertEquals(ErrorCode.CAPABILITY_UNAVAILABLE, js.code)
            assertTrue(js.operation!!.startsWith("host.api:eu.kanade.tachiyomi.network.JavaScriptEngine"), js.operation)
            val mismatch = assertThrows<WorkerError> { h.load("fixture.other", File(TestSupport.fixtureJars, "fixture-busy.jar")) }
            assertEquals(ErrorCode.ARTIFACT_INCOMPATIBLE, mismatch.code)
        }
    }

    @Test
    fun `search-produced fields survive details, which also rehydrates from the durable ref alone`() {
        WorkerHarness(FakeSite().transport()).use { h ->
            val pkg = h.loadFixture("multi")
            val hit = h.hits(h.search(pkg, "q"))[0]
            assertEquals("A, B", hit["ref"]!!.jsonObject["context"]!!.jsonObject["genre"]!!.jsonPrimitive.content)
            for (useHandle in listOf(true, false)) {
                val meta = h.details(pkg, hit, useHandle)["metadata"]!!.jsonObject
                assertEquals("One:q", meta["title"]!!.jsonPrimitive.content)
                assertEquals(listOf("A", "B"), meta["tags"]!!.jsonArray.map { it.jsonPrimitive.content }, "genre kept from search")
                assertEquals("details of /m/One", meta["description"]!!.jsonPrimitive.content)
            }
        }
    }

    @Test
    fun `a seeded password never reaches disk`() {
        val secret = "hunter2-" + System.nanoTime()
        val site = FakeSite()
        val root = TestSupport.tempDir("secret")
        WorkerHarness(site.transport(), stateRoot = root).use { h ->
            val pkg = h.loadFixture("a", settings = h.settings(values = mapOf("lang" to "en"), secrets = mapOf("password" to secret)))
            h.search(pkg, "x")
            h.client.call("package.unload", pkg.packageId)
            assertTrue(root.walkTopDown().filter { it.isFile }.none { it.readBytes().toString(Charsets.ISO_8859_1).contains(secret) })
        }
        val tmp = File(System.getProperty("java.io.tmpdir"))
        val recent = tmp.walkTopDown().maxDepth(3).filter { it.isFile && it.lastModified() > System.currentTimeMillis() - 120_000 && it.length() < 4_000_000 }
        assertTrue(recent.none { runCatching { it.readBytes().toString(Charsets.ISO_8859_1).contains(secret) }.getOrDefault(false) }, "secret found in a temp file")
    }

    @Test
    fun `settings snapshots seed per-store preferences with typed values`() {
        val settings = HostSettings(mapOf("lang" to "en", "source_1/lang" to "fr", "count" to 3L, "nsfw" to false), mapOf("token" to "t"), "r")
        val one = InMemorySharedPreferences(settings.seedFor("source_1"))
        val two = InMemorySharedPreferences(settings.seedFor("source_2"))
        assertEquals("fr", one.getString("lang", null))
        assertEquals("en", two.getString("lang", null))
        assertEquals(3, one.getInt("count", 0))
        assertEquals(3L, one.getLong("count", 0))
        assertFalse(one.getBoolean("nsfw", true))
        assertEquals("t", two.getString("token", null))
        assertThrows<ClassCastException> { one.getBoolean("lang", false) }
    }
}

