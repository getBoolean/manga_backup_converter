package mangabackup.tachi

import kotlinx.serialization.json.JsonPrimitive
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
                    put("trustedSigners", kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive(TestSupport.KEIYOUSHI_SIGNER))))
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
    fun `prepare trusts only the request's signers - absent, empty or other signers are refused with no fallback`() {
        WorkerHarness().use { h ->
            val q = TestSupport.WEEBCENTRAL
            for ((kind, input) in listOf("jar" to TestSupport.jar(q), "apk" to TestSupport.apk(q))) {
                for (signers in listOf(null, emptyList(), listOf("ab".repeat(32)))) {
                    val out = File(TestSupport.tempDir("trust"), "out.jar")
                    val e = assertThrows<WorkerError>("$kind with $signers") {
                        h.client.call("artifact.prepare", q.packageId, h.prepareRequest(input, kind, q.version, out, signers))
                    }
                    assertEquals(ErrorCode.ARTIFACT_INCOMPATIBLE, e.code, "$kind with $signers")
                    assertFalse(out.exists())
                }
            }
            // The same artifact passes with the pinned signer, in upper case or not.
            h.prepare(q.packageId, TestSupport.jar(q), "jar", q.version, listOf(TestSupport.KEIYOUSHI_SIGNER.uppercase()))
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
        val settings = HostSettings(
            mapOf("lang" to "en", "count" to 3L, "nsfw" to false),
            mapOf("token" to "t"),
            "r",
            sources = mapOf("1" to HostSettings.SourceScope(mapOf("lang" to "fr"), mapOf("token" to "one"))),
        )
        val one = InMemorySharedPreferences(settings.seedFor("source_1"))
        val two = InMemorySharedPreferences(settings.seedFor("source_2"))
        val other = InMemorySharedPreferences(settings.seedFor("1"))
        assertEquals("fr", one.getString("lang", null))
        assertEquals("one", one.getString("token", null))
        assertEquals("en", two.getString("lang", null))
        assertEquals("en", other.getString("lang", null), "a scope seeds only its source_<id> store")
        assertEquals(3, one.getInt("count", 0))
        assertEquals(3L, one.getLong("count", 0))
        assertFalse(one.getBoolean("nsfw", true))
        assertEquals("t", two.getString("token", null))
        assertThrows<ClassCastException> { one.getBoolean("lang", false) }
    }

    @Test
    fun `settings payloads decode string sets and source scopes, and slash keys are plain keys`() {
        val decoded = mangabackup.tachi.protocol.SettingsCodec.from(
            kotlinx.serialization.json.Json.parseToJsonElement(
                """{"values":{"tags":["b","a","b"],"source_1/lang":"literal","lang":"en"},"secrets":{},
                  |"sources":{"1":{"values":{"tags":["z"]},"secrets":{"password":"p"}},"2":{}},"revision":"r"}""".trimMargin(),
            ).jsonObject,
        )
        val one = InMemorySharedPreferences(decoded.seedFor("source_1"))
        val two = InMemorySharedPreferences(decoded.seedFor("source_2"))
        assertEquals(setOf("z"), one.getStringSet("tags", null))
        assertEquals("p", one.getString("password", null))
        assertEquals(listOf("a", "b"), two.getStringSet("tags", null)!!.toList())
        assertEquals(null, two.getString("password", null))
        assertEquals("en", one.getString("lang", null), "the retired storeName/key convention no longer scopes")
        assertEquals("literal", two.getString("source_1/lang", null))
        assertThrows<ClassCastException> { two.getString("tags", null) }
        for (bad in listOf("""[1]""", """["a",null]""", """[["a"]]""")) {
            assertThrows<mangabackup.tachi.protocol.ProtocolViolation>(bad) {
                mangabackup.tachi.protocol.SettingsCodec.from(
                    kotlinx.serialization.json.Json.parseToJsonElement("""{"values":{"k":$bad},"secrets":{},"revision":"r"}""").jsonObject,
                )
            }
        }
    }

    @Test
    fun `package load and settings update seed each source_id store from its effective settings, string sets included`() {
        WorkerHarness().use { h ->
            fun titles(pkg: WorkerHarness.Loaded) = listOf("101", "102").map { h.hits(h.search(pkg, "q", sourceId = it))[0]["title"]!!.jsonPrimitive.content }
            val pkg = h.loadFixture("prefs", settings = h.settings(
                values = mapOf("lang" to "en", "tags" to listOf("b", "a")),
                sources = mapOf("102" to (mapOf<String, Any>("lang" to "ja", "tags" to listOf("z")) to mapOf("password" to "pw"))),
            ))
            assertEquals(listOf("lang=en;tags=a,b;password=unset", "lang=ja;tags=z;password=set"), titles(pkg))
            h.client.call("settings.update", pkg.packageId, buildJsonObject {
                put("settings", h.settings(values = mapOf("lang" to "fr"), sources = mapOf("101" to (mapOf<String, Any>("tags" to listOf("c")) to emptyMap())), revision = "rev-2"))
            })
            assertEquals(listOf("lang=fr;tags=c;password=unset", "lang=fr;tags=;password=unset"), titles(pkg.copy(revision = "rev-2")))
        }
    }

    @Test
    fun `settings update replaces the snapshot, stales old refs, and dispose and unload release state`() {
        WorkerHarness(FakeSite().transport()).use { h ->
            val pkg = h.loadFixture("a")
            val hit = h.hits(h.search(pkg, "setpref:one"))[0]
            assertTrue(h.hits(h.search(pkg, "x"))[0]["title"]!!.jsonPrimitive.content.contains("[a/one]"))
            val sourceId = pkg.sources.first()["sourceId"]!!.jsonPrimitive.content
            h.client.call("settings.update", pkg.packageId, buildJsonObject {
                put("settings", h.settings(sources = mapOf(sourceId to (mapOf<String, Any>("mark" to "seeded") to emptyMap())), revision = "rev-2"))
            })
            val updated = pkg.copy(revision = "rev-2")
            assertTrue(h.hits(h.search(updated, "x"))[0]["title"]!!.jsonPrimitive.content.contains("[a/seeded]"), "snapshot replaced extension writes")
            assertEquals(ErrorCode.STALE_REFERENCE, assertThrows<WorkerError> { h.details(updated, hit) }.code, "ref confirmed under rev-1")

            val fresh = h.hits(h.search(updated, "y"))[0]
            h.client.call("dispose", pkg.packageId, buildJsonObject {
                put("source", h.identity(updated))
                put("handles", kotlinx.serialization.json.JsonArray(listOf(fresh["handle"]!!)))
            })
            assertEquals(ErrorCode.STALE_REFERENCE, assertThrows<WorkerError> { h.details(updated, fresh) }.code, "disposed handle")
            assertEquals("Details /m/1", h.details(updated, fresh, useHandle = false)["metadata"]!!.jsonObject["title"]!!.jsonPrimitive.content, "durable ref survives dispose")

            h.client.call("package.unload", pkg.packageId)
            assertEquals(ErrorCode.RUNTIME_UNAVAILABLE, assertThrows<WorkerError> { h.search(updated, "z") }.code)
        }
    }

    @Test
    fun `a package that has run operations releases its class loader on unload`() {
        val site = FakeSite()
        val transport = site.transport()
        val ref = runAndClose(transport)
        val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(20)
        while (ref.get() != null && System.nanoTime() < deadline) {
            System.gc()
            Thread.sleep(100)
        }
        transport.close()
        assertEquals(null, ref.get(), "class loader still reachable after search and details")
    }

    private fun runAndClose(transport: mangabackup.tachi.host.HostTransport): java.lang.ref.WeakReference<ClassLoader> {
        val env = mangabackup.tachi.host.PackageEnvironment("fixture.a", TestSupport.tempDir("unload"), transport, "UA", HostSettings.EMPTY)
        mangabackup.tachi.host.HostInjekt.install()
        val pkg = mangabackup.tachi.host.PackageScope.bind(env) { mangabackup.tachi.extensions.ExtensionLoader.load(File(TestSupport.fixtureJars, "fixture-a.jar"), env) }
        val source = pkg.sources.single() as eu.kanade.tachiyomi.source.CatalogueSource
        kotlinx.coroutines.runBlocking {
            mangabackup.tachi.host.PackageScope.bind(env) {
                val page = source.getSearchManga(1, "q", source.getFilterList())
                source.getMangaUpdate(page.mangas.first(), emptyList(), true, true)
            }
        }
        val ref = java.lang.ref.WeakReference<ClassLoader>(pkg.loader)
        pkg.close()
        return ref
    }

    @Test
    fun `an unsupported extension API version is unsupported-api`() {
        val src = File(TestSupport.fixtureJars, "fixture-busy.jar")
        val out = File(TestSupport.tempDir("lib13"), "lib13.jar")
        rewriteJar(src, out) { name, bytes ->
            if (name == "AndroidManifest.xml") String(bytes).replace("android:value=\"1.6\"", "android:value=\"1.3\"").toByteArray() else bytes
        }
        WorkerHarness().use { h ->
            assertEquals(ErrorCode.UNSUPPORTED_API, assertThrows<WorkerError> { h.load("fixture.busy", out) }.code)
        }
    }

    @Test
    fun `a missing host class is named, at load and during an operation`() {
        // A factory whose constructor touches android.graphics.Canvas, which the host does not supply.
        val cw = org.objectweb.asm.ClassWriter(org.objectweb.asm.ClassWriter.COMPUTE_FRAMES or org.objectweb.asm.ClassWriter.COMPUTE_MAXS)
        cw.visit(org.objectweb.asm.Opcodes.V17, org.objectweb.asm.Opcodes.ACC_PUBLIC, "fixture/missing/Factory", null, "java/lang/Object", arrayOf("eu/kanade/tachiyomi/source/SourceFactory"))
        cw.visitMethod(org.objectweb.asm.Opcodes.ACC_PUBLIC, "<init>", "()V", null, null).apply {
            visitCode()
            visitVarInsn(org.objectweb.asm.Opcodes.ALOAD, 0)
            visitMethodInsn(org.objectweb.asm.Opcodes.INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false)
            visitTypeInsn(org.objectweb.asm.Opcodes.NEW, "android/graphics/Canvas")
            visitInsn(org.objectweb.asm.Opcodes.POP)
            visitInsn(org.objectweb.asm.Opcodes.RETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        cw.visitEnd()
        val src = File(TestSupport.fixtureJars, "fixture-busy.jar")
        val out = File(TestSupport.tempDir("missing"), "missing.jar")
        rewriteJar(src, out, extra = mapOf("fixture/missing/Factory.class" to cw.toByteArray())) { name, bytes ->
            if (name == "AndroidManifest.xml") String(bytes).replace("fixture.busy.Factory", "fixture.missing.Factory").toByteArray() else bytes
        }
        WorkerHarness().use { h ->
            val e = assertThrows<WorkerError> { h.load("fixture.busy", out) }
            assertEquals(ErrorCode.ARTIFACT_INCOMPATIBLE, e.code)
            assertTrue(e.message!!.contains("android.graphics.Canvas"), e.message)
        }
        val during = mangabackup.tachi.protocol.Worker.mapError(java.io.IOException("wrapped", NoClassDefFoundError("android/graphics/Canvas")), null)
        assertEquals(ErrorCode.CAPABILITY_UNAVAILABLE, during.code)
        assertEquals("host.class:android.graphics.Canvas", during.operation)
    }

    private fun rewriteJar(src: File, out: File, extra: Map<String, ByteArray> = emptyMap(), edit: (String, ByteArray) -> ByteArray) {
        java.util.zip.ZipFile(src).use { zip ->
            java.util.zip.ZipOutputStream(out.outputStream()).use { zos ->
                for (e in zip.entries()) {
                    zos.putNextEntry(java.util.zip.ZipEntry(e.name))
                    zos.write(edit(e.name, zip.getInputStream(e).use { it.readBytes() }))
                    zos.closeEntry()
                }
                for ((name, bytes) in extra) {
                    zos.putNextEntry(java.util.zip.ZipEntry(name))
                    zos.write(bytes)
                    zos.closeEntry()
                }
            }
        }
    }
}
