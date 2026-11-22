package mangabackup.tachi

import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.serialization.json.jsonPrimitive
import mangabackup.tachi.extensions.ApkConverter
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.ArtifactVerifier
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.extensions.ExtensionLoader
import mangabackup.tachi.extensions.ExtensionManifest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.File
import java.io.RandomAccessFile
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/** KTD5 artifact paths: verification precedes conversion and class loading; both paths enumerate identical sources. */
class ArtifactPathTest {
    @Test
    fun `repository JARs verify against the keiyoushi signer`() {
        for (q in TestSupport.ALL) {
            val v = ArtifactVerifier.verifyJar(TestSupport.jar(q), setOf(TestSupport.KEIYOUSHI_SIGNER))
            assertEquals(TestSupport.KEIYOUSHI_SIGNER, v.signerSha256)
        }
    }

    @Test
    fun `APKs verify against the same signer`() {
        for (q in TestSupport.ALL) {
            val v = ArtifactVerifier.verifyApk(TestSupport.apk(q), setOf(TestSupport.KEIYOUSHI_SIGNER))
            assertEquals(TestSupport.KEIYOUSHI_SIGNER, v.signerSha256)
            assertTrue(v.schemes.isNotEmpty())
        }
    }

    @Test
    fun `JAR and converted APK enumerate exactly the index source IDs`() {
        for (q in TestSupport.ALL) {
            val expected = TestSupport.indexSources(q).associate {
                it["id"]!!.jsonPrimitive.content to (it["name"]!!.jsonPrimitive.content to it["language"]!!.jsonPrimitive.content)
            }
            for ((label, staged) in listOf("jar" to TestSupport.stagedJar(q), "apk" to TestSupport.convertedApk(q))) {
                val pkg = ExtensionLoader.load(staged, TestSupport.environment(q.packageId), Digests.sha256(staged))
                try {
                    val actual = pkg.sources.associate { s -> s.id.toString() to (s.name to (s as HttpSource).lang) }
                    assertEquals(expected, actual, "${q.dir} $label sources")
                } finally {
                    pkg.close()
                }
            }
        }
    }

    @Test
    fun `resources survive both paths`() {
        val q = TestSupport.MANGAFIRE
        for (staged in listOf(TestSupport.stagedJar(q), TestSupport.convertedApk(q))) {
            ZipFile(staged).use { zip ->
                assertNotNull(zip.getEntry("assets/solver.html"), "${staged.name} lost assets/solver.html")
                assertNotNull(zip.getEntry("AndroidManifest.xml"))
            }
            val manifest = ExtensionManifest.read(staged)
            assertEquals(q.packageId, manifest.packageName)
            assertEquals("1.6", manifest.libVersion)
            assertEquals(listOf("keiyoushi.source.Generated"), manifest.factoryClasses)
        }
    }

    @Test
    fun `dex2jar conversion yields the same entries every time`() {
        // dex2jar's register allocation is not reproducible across conversions in one JVM
        // (static transformer state), so bytes may differ; the entry set and resources may not.
        // The staged output is re-hashed and admitted by digest, so byte identity is not relied on.
        val q = TestSupport.WEEBCENTRAL
        fun names(f: File) = ZipFile(f).use { z -> z.entries().asSequence().map { it.name }.toSortedSet() }
        assertEquals(names(TestSupport.convertedApk(q)), names(TestSupport.convertedApk(q)))
    }

    @Test
    fun `a tampered APK never reaches dex2jar`() {
        val src = File(TestSupport.tempDir("tamper"), "x.apk")
        TestSupport.apk(TestSupport.WEEBCENTRAL).copyTo(src)
        flipByteInsideEntry(src, "classes.dex")
        val before = ApkConverter.conversions
        assertThrows<ArtifactException> { ArtifactVerifier.verifyApk(src, setOf(TestSupport.KEIYOUSHI_SIGNER)) }
        assertEquals(before, ApkConverter.conversions)
    }

    @Test
    fun `a tampered JAR is refused`() {
        val src = File(TestSupport.tempDir("tamper"), "x.jar")
        TestSupport.jar(TestSupport.WEEBCENTRAL).copyTo(src)
        flipByteInsideEntry(src, "AndroidManifest.xml")
        assertThrows<ArtifactException> { ArtifactVerifier.verifyJar(src, setOf(TestSupport.KEIYOUSHI_SIGNER)) }
    }

    @Test
    fun `a signed JAR with one appended unsigned class is refused`() {
        val src = TestSupport.jar(TestSupport.WEEBCENTRAL)
        val out = File(TestSupport.tempDir("append"), "appended.jar")
        ZipFile(src).use { zip ->
            ZipOutputStream(out.outputStream()).use { zos ->
                for (e in zip.entries()) {
                    zos.putNextEntry(ZipEntry(e.name))
                    zip.getInputStream(e).use { it.copyTo(zos) }
                    zos.closeEntry()
                }
                zos.putNextEntry(ZipEntry("keiyoushi/Injected.class"))
                zos.write(byteArrayOf(0xCA.toByte(), 0xFE.toByte(), 0xBA.toByte(), 0xBE.toByte()))
                zos.closeEntry()
            }
        }
        val e = assertThrows<ArtifactException> { ArtifactVerifier.verifyJar(out, setOf(TestSupport.KEIYOUSHI_SIGNER)) }
        assertTrue(e.message!!.contains("keiyoushi/Injected.class"), e.message)
    }

    @Test
    fun `a JAR signed by a different key is refused`() {
        val out = File(TestSupport.tempDir("resign"), "resigned.jar")
        TestSigning.resign(TestSupport.jar(TestSupport.WEEBCENTRAL), out)
        // It is a validly signed JAR, just not by the trusted signer.
        val v = ArtifactVerifier.verifyJar(out, setOf(TestSigning.certificateSha256))
        assertEquals(TestSigning.certificateSha256, v.signerSha256)
        assertThrows<ArtifactException> { ArtifactVerifier.verifyJar(out, setOf(TestSupport.KEIYOUSHI_SIGNER)) }
    }

    @Test
    fun `no trusted signer means no admission`() {
        assertThrows<ArtifactException> { ArtifactVerifier.verifyJar(TestSupport.jar(TestSupport.MANGADEX), emptySet()) }
        assertThrows<ArtifactException> { ArtifactVerifier.verifyApk(TestSupport.apk(TestSupport.MANGADEX), emptySet()) }
    }

    /** Flips one byte in the stored data of [entryName] without touching ZIP structure. */
    private fun flipByteInsideEntry(file: File, entryName: String) {
        val offset = ZipFile(file).use { zip ->
            val entry = zip.getEntry(entryName)!!
            // Local header: 30 bytes + name + extra; read them from the file.
            localDataOffset(file, entry) + entry.compressedSize / 2
        }
        RandomAccessFile(file, "rw").use { raf ->
            raf.seek(offset)
            val b = raf.read()
            raf.seek(offset)
            raf.write(b xor 0xFF)
        }
    }

    private fun localDataOffset(file: File, entry: ZipEntry): Long {
        RandomAccessFile(file, "r").use { raf ->
            val len = raf.length()
            // Find the local header by scanning for the signature followed by the entry name.
            val name = entry.name.toByteArray()
            val buf = ByteArray(len.toInt())
            raf.readFully(buf)
            var i = 0
            while (i < buf.size - 30) {
                if (buf[i] == 0x50.toByte() && buf[i + 1] == 0x4b.toByte() && buf[i + 2] == 3.toByte() && buf[i + 3] == 4.toByte()) {
                    val nameLen = (buf[i + 26].toInt() and 0xff) or ((buf[i + 27].toInt() and 0xff) shl 8)
                    val extraLen = (buf[i + 28].toInt() and 0xff) or ((buf[i + 29].toInt() and 0xff) shl 8)
                    if (nameLen == name.size && buf.copyOfRange(i + 30, i + 30 + nameLen).contentEquals(name)) {
                        return (i + 30 + nameLen + extraLen).toLong()
                    }
                }
                i++
            }
            error("local header for ${entry.name} not found")
        }
    }
}

