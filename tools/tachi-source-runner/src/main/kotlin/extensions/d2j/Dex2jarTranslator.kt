package mangabackup.tachi.extensions.d2j

import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.dex.DexExceptionHandler
import com.googlecode.d2j.node.DexMethodNode
import com.googlecode.d2j.reader.MultiDexFileReader
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.DexTranslator
import org.objectweb.asm.MethodVisitor
import java.nio.file.Files

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
        // A plain directory, not a zip file system: the iOS runtime image has no jdk.zipfs (U9). Classes are
        // collected into a sorted map and re-packed deterministically by ApkConverter, so the output stays
        // byte-identical.
        val tmp = Files.createTempDirectory("d2j-")
        try {
            run {
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
                    .to(tmp)
            }
            if (errors.isNotEmpty()) {
                throw ArtifactException("$apkName/$dexName: dex2jar failed for ${errors.size} item(s): ${errors.take(5).joinToString("; ")}")
            }
            Files.walk(tmp).use { paths ->
                for (path in paths.sorted().toList()) {
                    if (!Files.isRegularFile(path)) continue
                    val name = tmp.relativize(path).toString().replace(java.io.File.separatorChar, '/')
                    if (!name.endsWith(".class")) continue
                    out[name] = Files.readAllBytes(path)
                }
            }
        } finally {
            tmp.toFile().deleteRecursively()
        }
        return out
    }
}
