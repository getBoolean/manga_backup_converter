package mangabackup.tachi.extensions

import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes

/**
 * Recomputes stack map frames for dex2jar output. Class files of version 50
 * and later need frames for the JVM verifier, and computing them needs the
 * common superclass of two types. ASM's default looks classes up through its
 * own class loader, which cannot see the extension's classes, and falls back
 * to java/lang/Object, producing frames the verifier rejects. This resolver
 * answers from the converted classes first, then the host class path.
 */
class FrameComputer(private val classes: MutableMap<String, ByteArray>, private val host: ClassLoader) {
    private data class Node(val superName: String?, val interfaces: List<String>, val isInterface: Boolean)

    private val cache = HashMap<String, Node?>()

    private fun node(name: String): Node? = cache.getOrPut(name) {
        val bytes = classes["$name.class"] ?: host.getResourceAsStream("$name.class")?.use { it.readBytes() } ?: return@getOrPut null
        val reader = ClassReader(bytes)
        Node(reader.superName, reader.interfaces.toList(), reader.access and Opcodes.ACC_INTERFACE != 0)
    }

    private fun supertypes(name: String): Set<String> {
        val out = LinkedHashSet<String>()
        val queue = ArrayDeque(listOf(name))
        while (queue.isNotEmpty()) {
            val n = queue.removeFirst()
            if (!out.add(n)) continue
            val node = node(n) ?: continue
            node.superName?.let { queue += it }
            queue += node.interfaces
        }
        return out
    }

    private fun commonSuperClass(a: String, b: String): String {
        if (a == b) return a
        if (a in supertypes(b)) return a
        if (b in supertypes(a)) return b
        val na = node(a)
        val nb = node(b)
        if (na == null || nb == null || na.isInterface || nb.isInterface) return "java/lang/Object"
        var current: String? = na.superName
        val bSupers = supertypes(b)
        while (current != null) {
            if (current in bSupers) return current
            current = node(current)?.superName
        }
        return "java/lang/Object"
    }

    fun recomputeAll() {
        for (name in classes.keys.filter { it.endsWith(".class") }.sorted()) {
            val reader = ClassReader(classes.getValue(name))
            val writer = object : ClassWriter(COMPUTE_FRAMES) {
                override fun getCommonSuperClass(type1: String, type2: String): String = commonSuperClass(type1, type2)
            }
            reader.accept(writer, ClassReader.SKIP_FRAMES)
            classes[name] = writer.toByteArray()
        }
    }
}
