package mangabackup.tachi.extensions

import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.FieldVisitor
import org.objectweb.asm.Handle
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import org.objectweb.asm.Type
import java.io.File
import java.util.zip.ZipFile

/**
 * Static link check of an extension JAR against the host class path: every
 * class, method and field the extension references outside itself must
 * resolve in the host (JVM resolution order: class, superclasses, then
 * superinterfaces). Used by tests to prove the host surface covers the
 * qualification artifacts, and by the worker to name a missing host class.
 */
class LinkChecker(private val host: ClassLoader) {
    data class Ref(val kind: String, val owner: String, val name: String, val desc: String) {
        override fun toString(): String = if (kind == "class") "class $owner" else "$kind $owner.$name$desc"
    }

    private class Info(val name: String, val superName: String?, val interfaces: List<String>, val members: Set<String>)

    private val cache = HashMap<String, Info?>()

    private fun info(internalName: String): Info? = cache.getOrPut(internalName) {
        val stream = host.getResourceAsStream("$internalName.class") ?: return@getOrPut null
        stream.use { input ->
            val reader = ClassReader(input)
            val members = HashSet<String>()
            reader.accept(
                object : ClassVisitor(Opcodes.ASM9) {
                    override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): MethodVisitor? {
                        members += "m:$name$descriptor"
                        return null
                    }

                    override fun visitField(access: Int, name: String, descriptor: String, signature: String?, value: Any?): FieldVisitor? {
                        members += "f:$name:$descriptor"
                        return null
                    }
                },
                ClassReader.SKIP_CODE or ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES,
            )
            Info(reader.className, reader.superName, reader.interfaces.toList(), members)
        }
    }

    private fun resolves(owner: String, key: String, seen: MutableSet<String> = HashSet()): Boolean {
        if (!seen.add(owner)) return false
        val i = info(owner) ?: return false
        if (key in i.members) return true
        if (i.superName != null && resolves(i.superName, key, seen)) return true
        return i.interfaces.any { resolves(it, key, seen) }
    }

    private fun isSignaturePolymorphic(owner: String): Boolean =
        owner == "java/lang/invoke/MethodHandle" || owner == "java/lang/invoke/VarHandle"

    /** Returns every unresolved external reference of [jar], sorted. */
    fun check(jar: File): List<Ref> {
        val own = HashSet<String>()
        val refs = LinkedHashSet<Ref>()
        ZipFile(jar).use { zip ->
            val classEntries = zip.entries().asSequence().filter { !it.isDirectory && it.name.endsWith(".class") }.toList()
            for (e in classEntries) own += e.name.removeSuffix(".class")
            for (e in classEntries) {
                zip.getInputStream(e).use { collect(ClassReader(it), refs) }
            }
        }
        val missing = ArrayList<Ref>()
        for (ref in refs) {
            val owner = elementType(ref.owner) ?: continue
            if (owner in own) continue
            when (ref.kind) {
                "class" -> if (info(owner) == null) missing += Ref("class", owner, "", "")
                "method" -> if (!isSignaturePolymorphic(owner)) {
                    if (info(owner) == null) missing += Ref("class", owner, "", "")
                    else if (!resolves(owner, "m:${ref.name}${ref.desc}")) missing += ref
                }
                "field" -> if (info(owner) == null) missing += Ref("class", owner, "", "")
                else if (!resolves(owner, "f:${ref.name}:${ref.desc}")) missing += ref
            }
        }
        return missing.distinct().sortedBy { it.toString() }
    }

    private fun elementType(internalName: String): String? {
        if (!internalName.startsWith("[")) return internalName
        val t = Type.getType(internalName).elementType
        return if (t.sort == Type.OBJECT) t.internalName else null
    }

    private fun collect(reader: ClassReader, refs: MutableSet<Ref>) {
        fun type(t: Type) {
            when (t.sort) {
                Type.OBJECT -> refs += Ref("class", t.internalName, "", "")
                Type.ARRAY -> type(t.elementType)
                Type.METHOD -> {
                    type(t.returnType)
                    t.argumentTypes.forEach { type(it) }
                }
            }
        }
        reader.accept(
            object : ClassVisitor(Opcodes.ASM9) {
                override fun visit(version: Int, access: Int, name: String, signature: String?, superName: String?, interfaces: Array<out String>?) {
                    superName?.let { refs += Ref("class", it, "", "") }
                    interfaces?.forEach { refs += Ref("class", it, "", "") }
                }

                override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): MethodVisitor {
                    type(Type.getMethodType(descriptor))
                    return object : MethodVisitor(Opcodes.ASM9) {
                        override fun visitMethodInsn(opcode: Int, owner: String, name: String, descriptor: String, isInterface: Boolean) {
                            refs += Ref("method", owner, name, descriptor)
                        }

                        override fun visitFieldInsn(opcode: Int, owner: String, name: String, descriptor: String) {
                            refs += Ref("field", owner, name, descriptor)
                        }

                        override fun visitTypeInsn(opcode: Int, type: String) {
                            refs += Ref("class", type, "", "")
                        }

                        override fun visitLdcInsn(value: Any?) {
                            if (value is Type) type(value)
                        }

                        override fun visitInvokeDynamicInsn(name: String, descriptor: String, bsm: Handle, vararg bsmArgs: Any?) {
                            for (arg in bsmArgs) {
                                if (arg is Handle) refs += Ref("method", arg.owner, arg.name, arg.desc)
                            }
                        }
                    }
                }
            },
            ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES,
        )
    }
}

