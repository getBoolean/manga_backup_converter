package mangabackup.tachi.extensions

import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.dex.DexExceptionHandler
import com.googlecode.d2j.node.DexMethodNode
import org.objectweb.asm.MethodVisitor
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.FileSystems
import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * APK → JVM JAR through pinned dex2jar (KTD5). Runs only after
 * [ArtifactVerifier.verifyApk]. Every class from every `classes*.dex` is
 * translated; resources (AndroidManifest.xml, resources.arsc, res/, assets/)
 * are carried over unchanged. Entries are sorted with fixed timestamps. dex2jar's
 * register allocation can differ between conversions in the same JVM (cause not
 * identified; separate processes produced identical output), so the bytes are not
 * guaranteed identical; callers re-hash the staged output and never rely on it.
 */
object ApkConverter {
    /** dex2jar version pinned in gradle/libs.versions.toml; part of the cache identity. */
    const val DEX2JAR_VERSION = "2.4.39"

    /**
     * Identity of the whole conversion: dex2jar plus the host's own passes
     * (constructor-elision fix, frame recomputation). Bump when any changes.
     */
    const val CONVERTER_VERSION = "dex2jar-$DEX2JAR_VERSION+ctorfix.1+frames.1"

    /** Hook for tests: counts conversions so tampered input can be shown never to reach dex2jar. */
    @Volatile
    var conversions = 0
        private set

    fun convert(apk: File, output: File) {
        conversions++
        val entries = sortedMapOf<String, ByteArray>()
        ZipFile(apk).use { zip ->
            val dexNames = zip.entries().asSequence().map { it.name }
                .filter { it.matches(Regex("classes\\d*\\.dex")) }
                .sortedWith(compareBy({ it.length }, { it }))
                .toList()
            if (dexNames.isEmpty()) throw ArtifactException("${apk.name} contains no classes.dex")
            for (dexName in dexNames) {
                val dexBytes = zip.getInputStream(zip.getEntry(dexName)).use { it.readBytes() }
                translate(apk.name, dexName, dexBytes, entries)
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

    private fun translate(apkName: String, dexName: String, dexBytes: ByteArray, into: MutableMap<String, ByteArray>) {
        val errors = ArrayList<String>()
        val handler = object : DexExceptionHandler {
            override fun handleFileException(e: Exception) {
                errors += "file: ${e.message}"
            }

            override fun handleMethodTranslateException(method: Method, methodNode: DexMethodNode, mv: MethodVisitor, e: Exception) {
                errors += "${method.owner}.${method.name}${method.desc}: ${e.javaClass.simpleName}: ${e.message}"
            }
        }
        val tmp = Files.createTempFile("d2j-", ".jar")
        try {
            Files.delete(tmp)
            FileSystems.newFileSystem(tmp, mapOf("create" to "true")).use { fs ->
                Dex2jar.from(ConstructorElisionFix(com.googlecode.d2j.reader.MultiDexFileReader.open(dexBytes)))
                    .withExceptionHandler(handler)
                    // Keep Kotlin's mangled names (`constructor-impl`): renaming them breaks linking.
                    .dontSanitizeNames(true)
                    .setRandom(java.util.Random(0L))
                    // Frames are computed afterwards by FrameComputer, which knows the
                    // extension's own class hierarchy (dex2jar's pass falls back to Object).
                    .computeFrames(false)
                    .reUseReg(false)
                    .topoLogicalSort()
                    .skipDebug(false)
                    .optimizeSynchronized()
                    .printIR(false)
                    .noCode(false)
                    .skipExceptions(false)
                    .to(fs.getPath("/"))
            }
            if (errors.isNotEmpty()) {
                throw ArtifactException("$apkName/$dexName: dex2jar failed for ${errors.size} item(s): ${errors.take(5).joinToString("; ")}")
            }
            ZipFile(tmp.toFile()).use { zip ->
                for (entry in zip.entries()) {
                    if (entry.isDirectory || !entry.name.endsWith(".class")) continue
                    if (into.containsKey(entry.name)) throw ArtifactException("$apkName: duplicate class ${entry.name} across dex files")
                    into[entry.name] = zip.getInputStream(entry).use { it.readBytes() }
                }
            }
        } finally {
            Files.deleteIfExists(tmp)
        }
    }

    fun writeDeterministicJar(entries: Map<String, ByteArray>, output: File) {
        val bytes = ByteArrayOutputStream()
        ZipOutputStream(bytes).use { zos ->
            for ((name, data) in entries.toSortedMap()) {
                val e = ZipEntry(name)
                e.time = FIXED_TIME
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

    // 2000-01-01T00:00:00Z: ZIP timestamps before 1980 are not representable.
    private const val FIXED_TIME = 946684800000L
}

