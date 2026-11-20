package mangabackup.tachi

import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mangabackup.tachi.extensions.ExtensionLoader
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotSame
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.TimeUnit

class MultiPackageTest {
    private fun jar(name: String) = File(TestSupport.fixtureJars, "fixture-$name.jar")

    @Test
    fun `a factory exports several sources with distinct IDs, including an overridden int64 ID`() {
        WorkerHarness().use { h ->
            val pkg = h.loadFixture("multi")
            val ids = pkg.sources.map { it["sourceId"]!!.jsonPrimitive.content }
            assertEquals(3, ids.toSet().size)
            assertTrue("9223372036854775807" in ids, "Source.id override preserved exactly: $ids")
            val overridden = h.hits(h.search(pkg, "q", sourceId = "9223372036854775807"))[0]
            assertEquals("Overridden:q", overridden["title"]!!.jsonPrimitive.content)
            assertEquals("9223372036854775807", overridden["ref"]!!.jsonObject["source"]!!.jsonObject["sourceId"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun `identically named classes do not collide, host API types are shared, unloading frees the loader`() {
        val envA = TestSupport.environment("fixture.a")
        val envB = TestSupport.environment("fixture.b")
        var a: mangabackup.tachi.extensions.ExtensionPackage? = ExtensionLoader.load(jar("a"), envA)
        val b = ExtensionLoader.load(jar("b"), envB)
        checkNamespaces(a!!, b)
        val loaderRef = closeAndForget(a)
        a = null
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (loaderRef.get() != null && System.nanoTime() < deadline) {
            System.gc()
            Thread.sleep(50)
        }
        assertEquals(null, loaderRef.get(), "package A's class loader was not released")
        a = null
        // B is untouched.
        assertEquals("b", b.loader.loadClass("fixture.shared.Dup").getField("TAG").get(null))
        b.close()
    }

    private fun checkNamespaces(a: mangabackup.tachi.extensions.ExtensionPackage, b: mangabackup.tachi.extensions.ExtensionPackage) {
        val dupA = a.loader.loadClass("fixture.shared.Dup")
        val dupB = b.loader.loadClass("fixture.shared.Dup")
        assertNotSame(dupA, dupB)
        assertEquals("a", dupA.getField("TAG").get(null))
        assertEquals("b", dupB.getField("TAG").get(null))
        assertSame(HttpSource::class.java, a.loader.loadClass("eu.kanade.tachiyomi.source.online.HttpSource"))
        assertSame(a.loader.loadClass("okhttp3.OkHttpClient"), b.loader.loadClass("okhttp3.OkHttpClient"))
        assertTrue(a.sources.single() is HttpSource)
    }

    private fun closeAndForget(pkg: mangabackup.tachi.extensions.ExtensionPackage?): WeakReference<ClassLoader> {
        val ref = WeakReference<ClassLoader>(pkg!!.loader)
        pkg.close()
        return ref
    }

    @Test
    fun `cookies and preferences stay inside their package while packages run concurrently`() {
        val site = FakeSite(searchDelayMs = 300)
        WorkerHarness(site.transport()).use { h ->
            val a = h.loadFixture("a")
            val b = h.loadFixture("b")
            val fa = h.client.send("search", a.packageId, h.searchPayload(a, "setpref:alpha")).second
            val fb = h.client.send("search", b.packageId, h.searchPayload(b, "plain")).second
            fa.get(10, TimeUnit.SECONDS)
            fb.get(10, TimeUnit.SECONDS)
            val second = h.hits(h.search(b, "again"))[0]["title"]!!.jsonPrimitive.content
            assertTrue(second.contains("[b/none]"), "B saw A's preference: $second")
            val third = h.hits(h.search(a, "again"))[0]["title"]!!.jsonPrimitive.content
            assertTrue(third.contains("[a/alpha]"), third)
            val bRequests = site.requests.filter { it.startsWith("fixture-b.test") }
            assertTrue(bRequests.none { it.contains("visited-fixture-a.test") }, "A's cookie reached B: $bRequests")
            assertTrue(site.requests.last { it.startsWith("fixture-a.test") }.contains("visited-fixture-a.test=alpha"))
        }
    }

    @Test
    fun `operations of one package are serialized while different packages run in parallel`() {
        val site = FakeSite(searchDelayMs = 500)
        WorkerHarness(site.transport()).use { h ->
            val a = h.loadFixture("a")
            val b = h.loadFixture("b")
            var start = System.nanoTime()
            val parallel = listOf(
                h.client.send("search", a.packageId, h.searchPayload(a, "1")).second,
                h.client.send("search", b.packageId, h.searchPayload(b, "2")).second,
            )
            parallel.forEach { it.get(10, TimeUnit.SECONDS) }
            val parallelMs = (System.nanoTime() - start) / 1_000_000
            start = System.nanoTime()
            val serial = listOf(
                h.client.send("search", a.packageId, h.searchPayload(a, "3")).second,
                h.client.send("search", a.packageId, h.searchPayload(a, "4")).second,
            )
            serial.forEach { it.get(10, TimeUnit.SECONDS) }
            val serialMs = (System.nanoTime() - start) / 1_000_000
            assertTrue(parallelMs < 950, "two packages did not overlap: $parallelMs ms")
            assertTrue(serialMs >= 1000, "one package ran two operations at once: $serialMs ms")
        }
    }
}
