package mangabackup.tachi.extensions

import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Handle
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes

/** Translates one dex file to class files (`name.class` → bytes). Implemented inside [DeterministicDex2jar]'s loader. */
interface DexTranslator {
    fun translate(apkName: String, dexName: String, dexBytes: ByteArray): Map<String, ByteArray>
}

/**
 * Runs dex2jar so that the same dex always produces the same bytes (KTD5 session identity uses the
 * prepared digest).
 *
 * dex2jar's IR passes (SSA, un-SSA, register assignment, type analysis) keep their working sets in
 * `HashMap`/`HashSet` keyed by IR objects without `hashCode`, so iteration follows identity hash codes.
 * Those depend on the allocating thread's hash state, so two conversions in one JVM assigned registers
 * differently (and separate JVMs matched only because their start-up happened to be identical).
 *
 * The fix is applied to dex2jar's own bytecode, not its results: every conversion gets a fresh class
 * loader that defines dex2jar (`com.googlecode.*`) with each `HashMap`/`HashSet` instantiation
 * (constructor calls, `::new` method handles, and subclasses' superclass) replaced by
 * `LinkedHashMap`/`LinkedHashSet`. Those are subclasses with the same constructors, so every declared
 * type still links, and iteration becomes insertion order, which only depends on the input. A fresh
 * loader per conversion also resets any static state dex2jar keeps. The glue in
 * `mangabackup.tachi.extensions.d2j` is defined by the same loader because it links dex2jar types;
 * ASM, Kotlin and the JDK stay parent-owned.
 */
object DeterministicDex2jar {
    private const val TRANSLATOR = "mangabackup.tachi.extensions.d2j.Dex2jarTranslator"
    private val ORDERED = mapOf("java/util/HashMap" to "java/util/LinkedHashMap", "java/util/HashSet" to "java/util/LinkedHashSet")

    /** A translator in a new loader: no state carries over from an earlier conversion. */
    fun newTranslator(): DexTranslator {
        val loader = OrderedCollectionsLoader(DeterministicDex2jar::class.java.classLoader)
        return loader.loadClass(TRANSLATOR).getDeclaredConstructor().newInstance() as DexTranslator
    }

    private class OrderedCollectionsLoader(parent: ClassLoader) : ClassLoader("tachi-dex2jar", parent) {
        override fun loadClass(name: String, resolve: Boolean): Class<*> {
            if (!name.startsWith("com.googlecode.") && !name.startsWith("mangabackup.tachi.extensions.d2j.")) {
                return super.loadClass(name, resolve)
            }
            synchronized(getClassLoadingLock(name)) {
                val c = findLoadedClass(name) ?: run {
                    val bytes = parent.getResourceAsStream(name.replace('.', '/') + ".class")?.use { it.readBytes() }
                        ?: throw ClassNotFoundException(name)
                    val defined = if (name.startsWith("com.googlecode.")) rewrite(bytes) else bytes
                    defineClass(name, defined, 0, defined.size)
                }
                if (resolve) resolveClass(c)
                return c
            }
        }
    }

    /** Replaces HashMap/HashSet instantiation with the insertion-ordered subclasses. */
    fun rewrite(bytes: ByteArray): ByteArray {
        val reader = ClassReader(bytes)
        val writer = ClassWriter(reader, 0)
        reader.accept(object : ClassVisitor(Opcodes.ASM9, writer) {
            override fun visit(version: Int, access: Int, name: String, signature: String?, superName: String?, interfaces: Array<out String>?) {
                super.visit(version, access, name, signature, ORDERED[superName] ?: superName, interfaces)
            }

            override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): MethodVisitor {
                val mv = super.visitMethod(access, name, descriptor, signature, exceptions)
                return object : MethodVisitor(Opcodes.ASM9, mv) {
                    override fun visitTypeInsn(opcode: Int, type: String) {
                        super.visitTypeInsn(opcode, if (opcode == Opcodes.NEW) ORDERED[type] ?: type else type)
                    }

                    override fun visitMethodInsn(opcode: Int, owner: String, name: String, descriptor: String, isInterface: Boolean) {
                        val o = if (opcode == Opcodes.INVOKESPECIAL && name == "<init>") ORDERED[owner] ?: owner else owner
                        super.visitMethodInsn(opcode, o, name, descriptor, isInterface)
                    }

                    override fun visitInvokeDynamicInsn(name: String, descriptor: String, bsm: Handle, vararg args: Any?) {
                        val mapped = args.map { a ->
                            if (a is Handle && a.tag == Opcodes.H_NEWINVOKESPECIAL && a.owner in ORDERED) {
                                Handle(a.tag, ORDERED.getValue(a.owner), a.name, a.desc, a.isInterface)
                            } else {
                                a
                            }
                        }
                        super.visitInvokeDynamicInsn(name, descriptor, bsm, *mapped.toTypedArray())
                    }
                }
            }
        }, 0)
        return writer.toByteArray()
    }
}
