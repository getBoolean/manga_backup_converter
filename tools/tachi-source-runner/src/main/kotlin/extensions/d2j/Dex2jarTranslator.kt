package mangabackup.tachi.extensions.d2j

import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.dex.DexExceptionHandler
import com.googlecode.d2j.node.DexMethodNode
import com.googlecode.d2j.reader.MultiDexFileReader
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.DexTranslator
import org.objectweb.asm.MethodVisitor
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream

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
        // In memory, never through a file system: a directory sink would let classes whose names differ only
        // by case (`a.class`/`A.class`, which R8 emits unless -dontusemixedcaseclassnames) overwrite each other on
        // case-insensitive volumes (NTFS, APFS defaults), and a zip file system needs jdk.zipfs, which the iOS
        // runtime image lacks. doTranslate(ByteArrayOutputStream) runs the same per-class ClassWriter path as
        // to(Path) and frames each class as [int nameLen][UTF-8 internal name][int classLen][class bytes].
        val framed = ByteArrayOutputStream()
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
            .doTranslate(framed)
        if (errors.isNotEmpty()) {
            throw ArtifactException("$apkName/$dexName: dex2jar failed for ${errors.size} item(s): ${errors.take(5).joinToString("; ")}")
        }
        val out = sortedMapOf<String, ByteArray>()
        val input = DataInputStream(ByteArrayInputStream(framed.toByteArray()))
        while (input.available() > 0) {
            val name = String(ByteArray(input.readInt()).also(input::readFully), Charsets.UTF_8) + ".class"
            val bytes = ByteArray(input.readInt()).also(input::readFully)
            if (out.put(name, bytes) != null) throw ArtifactException("$apkName/$dexName: dex2jar produced $name twice")
        }
        return out
    }
}
