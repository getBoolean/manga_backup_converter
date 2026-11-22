package mangabackup.tachi

import mangabackup.tachi.extensions.LinkChecker
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.FieldVisitor
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes

/**
 * The host must expose every member of the extensions-lib 1.6 ABI the
 * extensions compiled against, and every external reference the qualification
 * artifacts actually make must link. Mihon's sources differ from the stub
 * library in places, so neither check is implied by compiling the host.
 */
class AbiConformanceTest {
    private val host = javaClass.classLoader

    private fun members(internalName: String, seen: MutableSet<String> = HashSet()): Set<String> {
        if (!seen.add(internalName)) return emptySet()
        val stream = host.getResourceAsStream("$internalName.class") ?: return emptySet()
        val out = HashSet<String>()
        var superName: String? = null
        var interfaces: Array<String> = emptyArray()
        stream.use {
            val reader = ClassReader(it)
            superName = reader.superName
            interfaces = reader.interfaces
            reader.accept(object : ClassVisitor(Opcodes.ASM9) {
                override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): MethodVisitor? {
                    out += "fun $name $descriptor"
                    return null
                }

                override fun visitField(access: Int, name: String, descriptor: String, signature: String?, value: Any?): FieldVisitor? {
                    out += "field $name $descriptor"
                    return null
                }
            }, ClassReader.SKIP_CODE)
        }
        superName?.let { out += members(it, seen) }
        interfaces.forEach { out += members(it, seen) }
        return out
    }

    @Test
    fun `host exposes every extensions-lib 1_6 ABI member`() {
        val api = javaClass.getResource("/abi/extensions-lib-1.6.api")!!.readText()
        val classHeader = Regex("""^public .*class ([\w/$]+)""")
        val member = Regex("""^\s+public .*?(fun|field) (\S+) (\S+)""")
        val missing = ArrayList<String>()
        var current: String? = null
        var checked = 0
        for (line in api.lines()) {
            classHeader.find(line)?.let {
                current = it.groupValues[1]
                if (host.getResource("$current.class") == null) missing += "class $current"
                return@let
            }
            val m = member.find(line) ?: continue
            val owner = current ?: continue
            val (kind, name, rest) = m.destructured
            val key = if (kind == "fun") "fun $name $rest" else "field $name $rest"
            checked++
            if (key !in members(owner)) missing += "$owner: $key"
        }
        assertTrue(checked > 150, "parsed only $checked ABI members")
        assertEquals(emptyList<String>(), missing, "host is missing extensions-lib ABI members")
    }

    @Test
    fun `every external reference of the qualification JARs links against the host`() {
        val checker = LinkChecker(host)
        for (q in TestSupport.ALL) {
            val missing = checker.check(TestSupport.jar(q))
            assertEquals(emptyList<LinkChecker.Ref>(), missing, "${q.dir} has unresolved references")
        }
    }

    @Test
    fun `every external reference of the dex2jar-converted APKs links against the host`() {
        val checker = LinkChecker(host)
        for (q in TestSupport.ALL) {
            val missing = checker.check(TestSupport.convertedApk(q))
            assertEquals(emptyList<LinkChecker.Ref>(), missing, "${q.dir} (APK) has unresolved references")
        }
    }
}

