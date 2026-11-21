package mangabackup.tachi.extensions.d2j

import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.dex.DexExceptionHandler
import com.googlecode.d2j.node.DexMethodNode
import com.googlecode.d2j.reader.MultiDexFileReader
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.DexTranslator
import org.objectweb.asm.MethodVisitor
import java.nio.file.FileSystems
import java.nio.file.Files
import java.util.zip.ZipFile

/**
 * The dex2jar call itself. This class, [ConstructorElisionFix] and every
 * dex2jar class are loaded by [mangabackup.tachi.extensions.DeterministicDex2jar]'s
 * loader, never by the application class loader, so dex2jar runs with
 * insertion-ordered collections. Only JDK types and parent-owned
 * [DexTranslator]/[ArtifactException] cross the loader boundary.
 */
class Dex2jarTranslator : DexTranslator {
    override fun translate(apkName: String, dexName: String, dexBytes: ByteArray): Map<String, ByteArray> {
        val errors = ArrayList<String>()
        val handler = object : DexExceptionHandler {
            override fun handleFileException(e: Exception) {
                errors += "file: ${e.message}"
            }

            override fun handleMethodTranslateException(method: Method, methodNode: DexMethodNode, mv: MethodVisitor, e: Exception) {
                errors += "${method.owner}.${method.name}${method.desc}: ${e.javaClass.simpleName}: ${e.message}"
            }
        }
        val out = sortedMapOf<String, ByteArray>()
        val tmp = Files.createTempFile("d2j-", ".jar")
        try {
            Files.delete(tmp)
            FileSystems.newFileSystem(tmp, mapOf("create" to "true")).use { fs ->
                Dex2jar.from(ConstructorElisionFix(MultiDexFileReader.open(dexBytes)))
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
                    out[entry.name] = zip.getInputStream(entry).use { it.readBytes() }
                }
            }
        } finally {
            Files.deleteIfExists(tmp)
        }
        return out
    }
}
