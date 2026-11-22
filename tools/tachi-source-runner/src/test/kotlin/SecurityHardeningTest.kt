package mangabackup.tachi

import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.ArtifactVerifier
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.extensions.ExtensionLoader
import mangabackup.tachi.host.replay.CaptureFormat
import mangabackup.tachi.host.replay.ReplayEgressGuard
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ProxySelector
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.URLClassLoader
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/** L3 (replay egress) and L5 (staged artifact, APK entries, capture paths) hardening. */
class SecurityHardeningTest {
    @Test
    fun `a staged JAR replaced after its digest check is never loaded`() {
        val dir = TestSupport.tempDir("swap")
        val staged = File(dir, "staged.jar")
        File(TestSupport.fixtureJars, "fixture-a.jar").copyTo(staged)
        val verified = Digests.sha256(staged)
        // Swapped between the worker's check and the class loader opening it.
        File(TestSupport.fixtureJars, "fixture-b.jar").copyTo(staged, overwrite = true)
        val env = TestSupport.environment("fixture.swap")
        val e = assertThrows<ArtifactException> { ExtensionLoader.load(staged, env, verified) }
        assertTrue(e.message!!.contains("changed after verification"), e.message)
        env.close()
    }

    @Test
    fun `the class loader reads a private snapshot, not the staged file`() {
        val staged = File(TestSupport.fixtureJars, "fixture-a.jar")
        val env = TestSupport.environment("fixture.a")
        val pkg = mangabackup.tachi.host.PackageScope.bind(env) { ExtensionLoader.load(staged, env, Digests.sha256(staged)) }
        try {
            val loader = pkg.sources.first().javaClass.classLoader as URLClassLoader
            val loaded = File(loader.urLs.single().toURI())
            assertTrue(loaded.canonicalPath.startsWith(env.stateDir.canonicalPath), "$loaded")
            assertEquals(Digests.sha256(staged), Digests.sha256(loaded))
        } finally {
            pkg.close()
        }
    }

    @Test
    fun `an APK with a duplicated entry name is refused before apksig`() {
        val src = TestSupport.apk(TestSupport.WEEBCENTRAL)
        val out = File(TestSupport.tempDir("dup"), "dup.apk")
        val first = ZipFile(src).use { it.entries().asSequence().first { e -> !e.isDirectory }.name }
        // Same length as the original name, rewritten to it after writing.
        val twin = first.dropLast(1) + (if (first.last() == 'Q') 'R' else 'Q')
        ZipFile(src).use { zip ->
            ZipOutputStream(out.outputStream()).use { zos ->
                for (e in zip.entries()) {
                    zos.putNextEntry(ZipEntry(e.name))
                    zip.getInputStream(e).use { it.copyTo(zos) }
                    zos.closeEntry()
                }
                zos.putNextEntry(ZipEntry(twin))
                zos.write("other copy".toByteArray())
                zos.closeEntry()
            }
        }
        val bytes = out.readBytes()
        val from = twin.toByteArray()
        val to = first.toByteArray()
        var i = 0
        while (i <= bytes.size - from.size) {
            if ((from.indices).all { bytes[i + it] == from[it] }) to.copyInto(bytes, i)
            i++
        }
        out.writeBytes(bytes)
        val e = assertThrows<ArtifactException> { ArtifactVerifier.verifyApk(out, setOf(TestSupport.KEIYOUSHI_SIGNER)) }
        assertTrue(e.message!!.contains("duplicate") || e.message!!.contains("not a valid ZIP"), e.message)
    }

    @Test
    fun `a capture manifest cannot name a body outside bodies`() {
        val src = File(TestSupport.fixtures, "en.weebcentral")
        val dir = File(TestSupport.tempDir("capture"), "en.weebcentral")
        File(src, CaptureFormat.MANIFEST).copyTo(File(dir, CaptureFormat.MANIFEST))
        File(src, CaptureFormat.BODIES).copyRecursively(File(dir, CaptureFormat.BODIES))
        CaptureFormat.load(dir)
        val manifest = File(dir, CaptureFormat.MANIFEST)
        val body = Regex("\"(bodies/[0-9a-f]{64}\\.bin)\"").find(manifest.readText())!!.groupValues[1]
        // A traversal that still lands on a real file with the recorded digest.
        manifest.writeText(manifest.readText().replaceFirst("\"$body\"", "\"bodies/../$body\""))
        val e = assertThrows<IllegalArgumentException> { CaptureFormat.load(dir) }
        assertTrue(e.message!!.contains("bodies/<sha256>.bin"), e.message)
    }

    @Test
    fun `in replay, HttpURLConnection and raw sockets cannot leave the machine`() {
        val guard = ReplayEgressGuard.start()
        val previous = ProxySelector.getDefault()
        ProxySelector.setDefault(guard.selector)
        try {
            // TEST-NET-1 literal and a name: both go to the refusing proxy (no DNS, no route attempt).
            for (url in listOf("http://192.0.2.1/x", "https://replay-egress.invalid/x")) {
                val c = URI(url).toURL().openConnection() as HttpURLConnection
                c.connectTimeout = 5000
                c.readTimeout = 5000
                assertThrows<IOException> { c.inputStream.use { it.readBytes() } }
            }
            assertThrows<IOException> { Socket().use { it.connect(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(192.toByte(), 0, 2, 1)), 80), 5000) } }
            val deadline = System.nanoTime() + 5_000_000_000L
            while (guard.refused < 3 && System.nanoTime() < deadline) Thread.sleep(20)
            assertTrue(guard.refused >= 3, "refused ${guard.refused}")
            // Loopback stays direct (the replay servers live there).
            ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
                Socket().use { it.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), 5000) }
                server.accept().close()
            }
        } finally {
            ProxySelector.setDefault(previous)
            guard.close()
        }
    }
}
