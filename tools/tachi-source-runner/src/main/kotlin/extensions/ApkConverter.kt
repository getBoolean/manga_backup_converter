package mangabackup.tachi.extensions

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.time.LocalDateTime
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * APK → JVM JAR through pinned dex2jar (KTD5). Runs only after
 * [ArtifactVerifier.verifyApk]. Every class from every `classes*.dex` is
 * translated; resources (AndroidManifest.xml, resources.arsc, res/, assets/)
 * are carried over unchanged. The output is byte-deterministic: dex2jar runs with
 * insertion-ordered collections in a fresh loader ([DeterministicDex2jar]), frames are
 * recomputed in sorted class order with a deterministic hierarchy ([FrameComputer]),
 * and entries are sorted with a fixed, zone-free timestamp. The same APK therefore
 * always gives the same prepared digest, in one JVM and across restarts.
 */
object ApkConverter {
    /** dex2jar version pinned in gradle/libs.versions.toml; part of the cache identity. */
    const val DEX2JAR_VERSION = "2.4.39"

    /**
     * Identity of the whole conversion: dex2jar plus the host's own passes
     * (constructor-elision fix, frame recomputation). Bump when any changes.
     */
    const val CONVERTER_VERSION = "dex2jar-$DEX2JAR_VERSION+ctorfix.1+frames.1+ordered.1+casesafe.1"

    /** Hook for tests: counts conversions so tampered input can be shown never to reach dex2jar. */
    @Volatile
    var conversions = 0
        private set

    fun convert(apk: File, output: File) = convert(apk, output, DeterministicDex2jar::newTranslator)

    /** [newTranslator] is a seam for tests that force a lossy translation; production always uses [DeterministicDex2jar]. */
    internal fun convert(apk: File, output: File, newTranslator: () -> DexTranslator) {
        conversions++
        val entries = sortedMapOf<String, ByteArray>()
        var dexClasses = 0L
        ZipFile(apk).use { zip ->
            val dexNames = zip.entries().asSequence().map { it.name }
                .filter { it.matches(Regex("classes\\d*\\.dex")) }
                .sortedWith(compareBy({ it.length }, { it }))
                .toList()
            if (dexNames.isEmpty()) throw ArtifactException("${apk.name} contains no classes.dex")
            for (dexName in dexNames) {
                val dexBytes = zip.getInputStream(zip.getEntry(dexName)).use { it.readBytes() }
                dexClasses += classDefsSize(apk.name, dexName, dexBytes)
                translate(apk.name, dexName, dexBytes, newTranslator(), entries)
            }
            // Fail closed if any class went missing between the DEX and the JAR (e.g. a sink that folds
            // `a.class` and `A.class` together on a case-insensitive file system).
            if (entries.size.toLong() != dexClasses) {
                throw ArtifactException("${apk.name}: the DEX files define $dexClasses class(es) but conversion produced ${entries.size}")
            }
            for (entry in zip.entries()) {
                val name = entry.name
                if (entry.isDirectory || name.matches(Regex("classes\\d*\\.dex")) || ArtifactVerifier.isSignatureFile(name)) continue
                if (name.startsWith("META-INF/") && (name.endsWith(".version") || name.endsWith(".kotlin_module"))) {
                    // Build metadata, not needed at runtime.
                }
                if (entries.containsKey(name)) throw ArtifactException("${apk.name}: resource $name collides with a converted class")
                entries[name] = zip.getInputStream(entry).use { it.readBytes() }
            }
        }
        FrameComputer(entries, ApkConverter::class.java.classLoader).recomputeAll()
        writeDeterministicJar(entries, output)
    }

    private fun translate(apkName: String, dexName: String, dexBytes: ByteArray, translator: DexTranslator, into: MutableMap<String, ByteArray>) {
        for ((name, bytes) in translator.translate(apkName, dexName, dexBytes)) {
            if (into.containsKey(name)) throw ArtifactException("$apkName: duplicate class $name across dex files")
            into[name] = bytes
        }
    }

    /** `class_defs_size` from the DEX header (u4 little-endian at 0x60), read independently of dex2jar. */
    internal fun classDefsSize(apkName: String, dexName: String, dex: ByteArray): Long {
        if (dex.size < 0x70 || !dex.copyOfRange(0, 4).contentEquals(byteArrayOf(0x64, 0x65, 0x78, 0x0a))) {
            throw ArtifactException("$apkName/$dexName is not a DEX file")
        }
        return java.nio.ByteBuffer.wrap(dex, 0x60, 4).order(java.nio.ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL
    }

    fun writeDeterministicJar(entries: Map<String, ByteArray>, output: File) {
        val bytes = ByteArrayOutputStream()
        ZipOutputStream(bytes).use { zos ->
            for ((name, data) in entries.toSortedMap()) {
                val e = ZipEntry(name)
                // setTimeLocal stores the DOS date/time as given; setTime(millis) would convert through the
                // JVM's default time zone, so the bytes would depend on where the conversion ran.
                e.timeLocal = FIXED_TIME
                zos.putNextEntry(e)
                zos.write(data)
                zos.closeEntry()
            }
        }
        writeAtomically(output.toPath(), bytes.toByteArray())
    }

    fun writeAtomically(target: Path, data: ByteArray) {
        target.parent?.let { Files.createDirectories(it) }
        val tmp = Files.createTempFile(target.parent ?: Path.of("."), ".stage-", ".tmp")
        try {
            Files.write(tmp, data)
            Files.move(tmp, target, java.nio.file.StandardCopyOption.REPLACE_EXISTING, java.nio.file.StandardCopyOption.ATOMIC_MOVE)
        } finally {
            Files.deleteIfExists(tmp)
        }
    }

    // 2000-01-01T00:00 (DOS local time, no zone): ZIP timestamps before 1980 are not representable.
    private val FIXED_TIME: LocalDateTime = LocalDateTime.of(2000, 1, 1, 0, 0)
}

