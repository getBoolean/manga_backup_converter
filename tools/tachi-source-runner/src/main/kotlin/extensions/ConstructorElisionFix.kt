package mangabackup.tachi.extensions

import com.googlecode.d2j.DexConstants
import com.googlecode.d2j.Method
import com.googlecode.d2j.reader.BaseDexFileReader
import com.googlecode.d2j.reader.Op
import com.googlecode.d2j.visitors.DexClassVisitor
import com.googlecode.d2j.visitors.DexCodeVisitor
import com.googlecode.d2j.visitors.DexFileVisitor
import com.googlecode.d2j.visitors.DexMethodVisitor

/**
 * The Android bytecode patch the APK path needs (the KTD5 "patching" question).
 *
 * R8 removes trivial constructors when dexing, which ART tolerates and the JVM
 * verifier rejects. Two shapes occur in the qualification APKs:
 *
 * 1. `new-instance X; invoke-direct S.<init>` with S a superclass of X (X's
 *    constructor only called `super()`). The JVM requires the `<init>` of X
 *    itself; dex2jar turns the pair into `new S`, which then fails wherever an
 *    `X` is expected.
 * 2. Inside a constructor of X, `invoke-direct {this}, S.<init>` with S an
 *    indirect superclass (the direct superclass's trivial constructor was
 *    removed). The JVM requires the direct superclass's (or X's own) `<init>`.
 *
 * This reader wrapper restores the removed constructors before translation:
 * each is a synthetic `C.<init>(params)` that calls its direct superclass,
 * ending at S, and the call sites are retargeted. Repository JARs are verified
 * class files and never contain these shapes, so nothing changes on that path.
 * The patch is versioned in [ApkConverter.CONVERTER_VERSION].
 */
class ConstructorElisionFix(private val delegate: BaseDexFileReader) : BaseDexFileReader by delegate {
    private data class Ctor(val owner: String, val params: List<String>)

    private val superOf = HashMap<String, String?>()
    private val existing = HashSet<Ctor>()

    /** Constructor to synthesize → owner of the constructor it calls. */
    private val synthesized = LinkedHashMap<Ctor, String>()

    /** Constructors restored, as `X.<init>(params) -> S`; for diagnostics and tests. */
    val restored: List<String> get() = synthesized.map { (c, s) -> "${c.owner}.<init>(${c.params.joinToString("")}) -> $s" }

    init {
        val requests = ArrayList<Pair<Ctor, String>>()
        delegate.accept(ScanVisitor(requests), 0)
        for ((ctor, target) in requests) ensure(ctor, target)
    }

    /**
     * Makes `ctor` callable: returns true if it exists or was synthesized as a
     * chain of direct-superclass calls ending at [target]'s constructor.
     */
    private fun ensure(ctor: Ctor, target: String): Boolean {
        if (ctor.owner == target || ctor in existing || ctor in synthesized) return true
        if (ctor.params.any { it == "J" || it == "D" }) return false
        if (!superOf.containsKey(ctor.owner)) return false
        val parent = superOf[ctor.owner] ?: return false
        if (parent != target && !ensure(Ctor(parent, ctor.params), target)) return false
        synthesized[ctor] = parent
        return true
    }

    private fun callable(ctor: Ctor) = ctor in existing || ctor in synthesized

    override fun accept(dv: DexFileVisitor) = delegate.accept(PatchVisitor(dv))

    override fun accept(dv: DexFileVisitor, config: Int) = delegate.accept(PatchVisitor(dv), config)

    override fun accept(dv: DexFileVisitor, classIdx: Int, config: Int) = delegate.accept(PatchVisitor(dv), classIdx, config)

    private fun isInit(op: Op, method: Method) =
        (op == Op.INVOKE_DIRECT || op == Op.INVOKE_DIRECT_RANGE) && method.name == "<init>"

    private fun registerSize(type: String) = if (type == "J" || type == "D") 2 else 1

    /**
     * Classifies each `<init>` call: returns the class whose constructor the
     * JVM needs here (the new instance's class, or the direct superclass for a
     * constructor's own super call), or null when the call is already valid.
     */
    private abstract inner class InitCallTracker(next: DexCodeVisitor?, private val className: String, private val method: Method) :
        DexCodeVisitor(next) {
        private val pending = HashMap<Int, String>()
        private var thisRegister = -1

        override fun visitRegister(total: Int) {
            if (method.name == "<init>") thisRegister = total - 1 - method.parameterTypes.sumOf { registerSize(it) }
            super.visitRegister(total)
        }

        override fun visitTypeStmt(op: Op, a: Int, b: Int, type: String) {
            if (op == Op.NEW_INSTANCE) pending[a] = type else pending.remove(a)
            super.visitTypeStmt(op, a, b, type)
        }

        override fun visitMethodStmt(op: Op, args: IntArray, method: Method) {
            if (isInit(op, method) && args.isNotEmpty()) {
                val newType = pending.remove(args[0])
                val required = when {
                    newType != null -> newType.takeIf { it != method.owner }
                    args[0] == thisRegister -> superOf[className]?.takeIf { method.owner != className && method.owner != it }
                    else -> null
                }
                if (required != null) {
                    onMismatch(op, args, method, Ctor(required, method.parameterTypes.toList()))
                    return
                }
            }
            super.visitMethodStmt(op, args, method)
        }

        abstract fun onMismatch(op: Op, args: IntArray, method: Method, needed: Ctor)
    }

    private inner class ScanVisitor(private val requests: MutableList<Pair<Ctor, String>>) : DexFileVisitor() {
        override fun visit(accessFlags: Int, className: String, superClass: String?, interfaceNames: Array<out String>?): DexClassVisitor {
            superOf[className] = superClass
            return object : DexClassVisitor() {
                override fun visitMethod(accessFlags: Int, method: Method): DexMethodVisitor {
                    if (method.name == "<init>") existing += Ctor(className, method.parameterTypes.toList())
                    return object : DexMethodVisitor() {
                        override fun visitCode(): DexCodeVisitor = object : InitCallTracker(null, className, method) {
                            override fun onMismatch(op: Op, args: IntArray, method: Method, needed: Ctor) {
                                requests += needed to method.owner
                            }
                        }
                    }
                }
            }
        }
    }

    private inner class PatchVisitor(next: DexFileVisitor) : DexFileVisitor(next) {
        override fun visit(accessFlags: Int, className: String, superClass: String?, interfaceNames: Array<out String>?): DexClassVisitor? {
            val cv = super.visit(accessFlags, className, superClass, interfaceNames) ?: return null
            return object : DexClassVisitor(cv) {
                override fun visitMethod(accessFlags: Int, method: Method): DexMethodVisitor? {
                    val mv = super.visitMethod(accessFlags, method) ?: return null
                    return object : DexMethodVisitor(mv) {
                        override fun visitCode(): DexCodeVisitor? {
                            val code = super.visitCode() ?: return null
                            return object : InitCallTracker(code, className, method) {
                                override fun onMismatch(op: Op, args: IntArray, method: Method, needed: Ctor) {
                                    val target = if (callable(needed)) Method(needed.owner, "<init>", method.parameterTypes, "V") else method
                                    visitor.visitMethodStmt(op, args, target)
                                }
                            }
                        }
                    }
                }

                override fun visitEnd() {
                    for ((ctor, parent) in synthesized) {
                        if (ctor.owner == className) emitDelegatingConstructor(this, ctor, parent)
                    }
                    super.visitEnd()
                }
            }
        }
    }

    private fun emitDelegatingConstructor(cv: DexClassVisitor, ctor: Ctor, parent: String) {
        val params = ctor.params.toTypedArray()
        val mv = cv.visitMethod(
            DexConstants.ACC_PUBLIC or DexConstants.ACC_CONSTRUCTOR or DexConstants.ACC_SYNTHETIC,
            Method(ctor.owner, "<init>", params, "V"),
        ) ?: return
        val code = mv.visitCode()
        if (code != null) {
            val registers = 1 + params.size
            code.visitRegister(registers)
            code.visitMethodStmt(Op.INVOKE_DIRECT, IntArray(registers) { it }, Method(parent, "<init>", params, "V"))
            code.visitStmt0R(Op.RETURN_VOID)
            code.visitEnd()
        }
        mv.visitEnd()
    }
}
