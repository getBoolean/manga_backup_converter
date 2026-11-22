package mangabackup.tachi

import mangabackup.tachi.extensions.ApkConverter
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.DeterministicDex2jar
import mangabackup.tachi.extensions.DexTranslator
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.Worker
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.objectweb.asm.ClassReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.security.MessageDigest
import java.util.zip.Adler32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * R8 emits class names that differ only by case unless `-dontusemixedcaseclassnames` is set. APK → JAR
 * preparation must keep both classes on case-insensitive file systems (NTFS, APFS defaults), and must fail
 * closed if a class is ever lost between the DEX and the JAR. The DEX is authored here, not taken from an
 * extension.
 */
class CaseCollisionConversionTest {
    private val classes = listOf("Lx/a;", "Lx/A;", "Lx/b;")

    @Test
    fun `classes whose names differ only by case both survive conversion`() {
        val dir = TestSupport.tempDir("case")
        try {
            // Show the hazard is real where the test runs: on a case-insensitive volume a directory sink folds the two.
            val probe = File(dir, "probe").apply { mkdirs() }
            File(probe, "a.class").writeText("lower")
            File(probe, "A.class").writeText("upper")
            val caseInsensitive = probe.list()!!.size == 1
            if (System.getProperty("os.name").startsWith("Windows")) assertTrue(caseInsensitive, "temp volume is case-insensitive on Windows")
            System.err.println("[test] temp volume case-insensitive: $caseInsensitive")

            val apk = apkWith(dexDefining(classes), dir)
            val out = File(dir, "converted.jar")
            ApkConverter.convert(apk, out)
            ZipFile(out).use { zip ->
                val names = zip.entries().asSequence().map { it.name }.filter { it.endsWith(".class") }.toList()
                assertEquals(listOf("x/A.class", "x/a.class", "x/b.class"), names)
                for (name in names) {
                    val bytes = zip.getInputStream(zip.getEntry(name)).use { it.readBytes() }
                    assertEquals(name.removeSuffix(".class"), ClassReader(bytes).className, "entry $name holds its own class")
                }
            }

            // Same bytes on a second conversion (fresh dex2jar loader).
            val again = File(dir, "again.jar")
            ApkConverter.convert(apk, again)
            assertArrayEquals(out.readBytes(), again.readBytes())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `a conversion that loses a case-colliding class fails as artifact-incompatible`() {
        val dir = TestSupport.tempDir("case")
        try {
            val apk = apkWith(dexDefining(classes), dir)
            // The failure the old directory sink had on case-insensitive volumes: entries whose names fold to the same
            // lower-case path overwrite each other, so one class silently disappears.
            val folding = {
                val real = DeterministicDex2jar.newTranslator()
                object : DexTranslator {
                    override fun translate(apkName: String, dexName: String, dexBytes: ByteArray): Map<String, ByteArray> {
                        val byPath = LinkedHashMap<String, Pair<String, ByteArray>>()
                        for ((name, bytes) in real.translate(apkName, dexName, dexBytes)) byPath[name.lowercase()] = name to bytes
                        return byPath.values.associate { it }
                    }
                }
            }
            val out = File(dir, "converted.jar")
            val e = assertThrows(ArtifactException::class.java) { ApkConverter.convert(apk, out, folding) }
            assertTrue(e.message!!.contains("define 3 class(es) but conversion produced 2"), e.message)
            assertTrue(!out.exists(), "no JAR is written when the count check fails")
            assertEquals(ErrorCode.ARTIFACT_INCOMPATIBLE, Worker.mapError(e, null).code)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `the DEX class count is read from the header`() {
        assertEquals(3L, ApkConverter.classDefsSize("t.apk", "classes.dex", dexDefining(classes)))
        assertThrows(ArtifactException::class.java) { ApkConverter.classDefsSize("t.apk", "classes.dex", ByteArray(0x70)) }
    }

    private fun apkWith(dex: ByteArray, dir: File): File {
        val apk = File(dir, "synthetic.apk")
        ZipOutputStream(apk.outputStream()).use { zos ->
            zos.putNextEntry(ZipEntry("classes.dex"))
            zos.write(dex)
            zos.closeEntry()
            zos.putNextEntry(ZipEntry("AndroidManifest.xml"))
            zos.write(ByteArray(8))
            zos.closeEntry()
        }
        return apk
    }

    /**
     * A minimal valid DEX (version 035) defining public empty classes that extend `java.lang.Object`:
     * header, string_ids, type_ids, class_defs, then string_data and the map_list in the data section.
     */
    private fun dexDefining(descriptors: List<String>): ByteArray {
        val strings = (descriptors + "Ljava/lang/Object;").distinct().sortedWith { a, b -> compareUtf16(a, b) }
        val types = strings // every string here is a type descriptor; type_ids sort by string index
        val objectType = types.indexOf("Ljava/lang/Object;")
        // Class definitions must list superclasses first; Object is external, so any order is valid. Use type order.
        val defs = descriptors.map { types.indexOf(it) }.sorted()

        val headerSize = 0x70
        val stringIdsOff = headerSize
        val typeIdsOff = stringIdsOff + 4 * strings.size
        val classDefsOff = typeIdsOff + 4 * types.size
        val dataOff = classDefsOff + 32 * defs.size
        val stringData = ByteArrayOutputStream()
        val stringDataOffs = strings.map { s ->
            val off = dataOff + stringData.size()
            // ASCII only, so MUTF-8 bytes equal the UTF-16 length.
            writeUleb128(stringData, s.length)
            stringData.write(s.toByteArray(Charsets.US_ASCII))
            stringData.write(0)
            off
        }
        val mapOff = (dataOff + stringData.size() + 3) and 3.inv()
        val mapItems = listOf(
            intArrayOf(0x0000, 1, 0),
            intArrayOf(0x0001, strings.size, stringIdsOff),
            intArrayOf(0x0002, types.size, typeIdsOff),
            intArrayOf(0x0006, defs.size, classDefsOff),
            intArrayOf(0x2002, strings.size, dataOff),
            intArrayOf(0x1000, 1, mapOff),
        )
        val fileSize = mapOff + 4 + 12 * mapItems.size
        val b = ByteBuffer.allocate(fileSize).order(ByteOrder.LITTLE_ENDIAN)
        b.put("dex\n035\u0000".toByteArray(Charsets.US_ASCII))
        b.position(32)
        b.putInt(fileSize).putInt(headerSize).putInt(0x12345678)
        b.putInt(0).putInt(0) // link
        b.putInt(mapOff)
        b.putInt(strings.size).putInt(stringIdsOff)
        b.putInt(types.size).putInt(typeIdsOff)
        b.putInt(0).putInt(0) // protos
        b.putInt(0).putInt(0) // fields
        b.putInt(0).putInt(0) // methods
        b.putInt(defs.size).putInt(classDefsOff)
        b.putInt(fileSize - dataOff).putInt(dataOff)
        check(b.position() == headerSize)
        stringDataOffs.forEach { b.putInt(it) }
        types.indices.forEach { b.putInt(it) }
        for (type in defs) {
            b.putInt(type).putInt(0x0001 /* ACC_PUBLIC */).putInt(objectType)
            b.putInt(0) // interfaces_off
            b.putInt(-1) // source_file_idx = NO_INDEX
            b.putInt(0).putInt(0).putInt(0) // annotations, class_data, static_values
        }
        b.put(stringData.toByteArray())
        b.position(mapOff)
        b.putInt(mapItems.size)
        for ((type, size, off) in mapItems) {
            b.putShort(type.toShort()).putShort(0).putInt(size).putInt(off)
        }
        val dex = b.array()
        val sha1 = MessageDigest.getInstance("SHA-1").digest(dex.copyOfRange(32, dex.size))
        System.arraycopy(sha1, 0, dex, 12, 20)
        val adler = Adler32().apply { update(dex, 12, dex.size - 12) }.value.toInt()
        ByteBuffer.wrap(dex, 8, 4).order(ByteOrder.LITTLE_ENDIAN).putInt(adler)
        return dex
    }

    private fun compareUtf16(a: String, b: String): Int = a.compareTo(b) // String.compareTo orders by UTF-16 code unit

    private fun writeUleb128(out: ByteArrayOutputStream, value: Int) {
        var v = value
        while (v >= 0x80) {
            out.write((v and 0x7f) or 0x80)
            v = v ushr 7
        }
        out.write(v)
    }
}
