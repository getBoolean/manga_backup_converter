package mangabackup.tachi

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mangabackup.tachi.extensions.ApkConverter
import mangabackup.tachi.extensions.DeterministicDex2jar
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.protocol.WorkerClient
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotSame
import org.junit.jupiter.api.Test
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * APK → JAR preparation is byte-deterministic (session identity uses the prepared digest, so a resumed
 * conversion must not reopen decisions). Checked in one JVM, on different threads and in different
 * orders, and across worker processes started with different time zones, collectors and heap sizes.
 */
class DeterministicConversionTest {
    private fun convert(q: TestSupport.Qualification): String = Digests.sha256(TestSupport.convertedApk(q))

    @Test
    fun `the same APK prepares to the same bytes in one JVM and across restarted workers`() {
        val first = TestSupport.ALL.associate { it.dir to convert(it) }
        // Second round: reversed order, on another thread, after the JIT and identity-hash state have moved on.
        val pool = Executors.newSingleThreadExecutor()
        val second = try {
            pool.submit<Map<String, String>> { TestSupport.ALL.reversed().associate { it.dir to convert(it) } }.get(10, TimeUnit.MINUTES)
        } finally {
            pool.shutdownNow()
        }
        assertEquals(first, second, "two conversions in one JVM")
        System.err.println("[test] prepared APK digests: $first")

        val javaHome = File(System.getProperty("tachi.javaHome"))
        val classpath = System.getProperty("tachi.workerClasspath")
        val args = TEST_LIMITS.flatMap { (k, v) -> listOf("--limit", "$k=$v") }
        val variants = listOf(
            listOf("-Duser.timezone=Pacific/Kiritimati", "-XX:+UseSerialGC", "-Xmx512m") to TestSupport.ALL,
            listOf("-Duser.timezone=America/Los_Angeles", "-XX:+UseParallelGC", "-Xmx1g") to TestSupport.ALL.reversed(),
        )
        for ((jvmArgs, order) in variants) {
            val (client, process) = WorkerClient.subprocess(javaHome, classpath, args, extraJvmArgs = jvmArgs)
            try {
                client.handshake()
                val h = PrepareOnly(client)
                val digests = order.associate { q -> q.dir to h.prepare(q) }
                assertEquals(first, digests, "worker process started with $jvmArgs")
                client.call("shutdown")
                process.waitFor(10, TimeUnit.SECONDS)
            } finally {
                client.close()
            }
        }
    }

    @Test
    fun `each conversion gets its own dex2jar loader with insertion-ordered collections`() {
        val a = DeterministicDex2jar.newTranslator()
        val b = DeterministicDex2jar.newTranslator()
        assertNotSame(a.javaClass.classLoader, b.javaClass.classLoader, "no dex2jar static state carries over")
        assertNotSame(ApkConverter::class.java.classLoader, a.javaClass.classLoader)

        // A class that extends HashMap and builds HashSets, the shapes the rewrite must cover.
        val w = ClassWriter(ClassWriter.COMPUTE_MAXS)
        w.visit(Opcodes.V21, Opcodes.ACC_PUBLIC, "x/M", null, "java/util/HashMap", null)
        val mv: MethodVisitor = w.visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null)
        mv.visitCode()
        mv.visitVarInsn(Opcodes.ALOAD, 0)
        mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/util/HashMap", "<init>", "()V", false)
        mv.visitTypeInsn(Opcodes.NEW, "java/util/HashSet")
        mv.visitInsn(Opcodes.DUP)
        mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/util/HashSet", "<init>", "()V", false)
        mv.visitInsn(Opcodes.POP)
        mv.visitInsn(Opcodes.RETURN)
        mv.visitMaxs(0, 0)
        mv.visitEnd()
        w.visitEnd()
        val seen = ArrayList<String>()
        var superName: String? = null
        ClassReader(DeterministicDex2jar.rewrite(w.toByteArray())).accept(object : ClassVisitor(Opcodes.ASM9) {
            override fun visit(version: Int, access: Int, name: String, signature: String?, s: String?, interfaces: Array<out String>?) {
                superName = s
            }

            override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?) =
                object : MethodVisitor(Opcodes.ASM9) {
                    override fun visitTypeInsn(opcode: Int, type: String) {
                        seen += "new $type"
                    }

                    override fun visitMethodInsn(opcode: Int, owner: String, name: String, descriptor: String, isInterface: Boolean) {
                        seen += "$owner.$name"
                    }
                }
        }, 0)
        assertEquals("java/util/LinkedHashMap", superName)
        assertEquals(listOf("java/util/LinkedHashMap.<init>", "new java/util/LinkedHashSet", "java/util/LinkedHashSet.<init>"), seen)
    }

    /** `artifact.prepare` of each APK through a worker process. */
    private class PrepareOnly(private val client: WorkerClient) {
        fun prepare(q: TestSupport.Qualification): String {
            val out = File(TestSupport.tempDir("det"), "staged.jar")
            val harnessRequest = kotlinx.serialization.json.buildJsonObject {
                put("artifact", mangabackup.tachi.protocol.ArtifactBinding(Digests.sha256(TestSupport.apk(q)), "apk", q.version).toJson())
                put("inputPath", kotlinx.serialization.json.JsonPrimitive(TestSupport.apk(q).absolutePath))
                put("outputPath", kotlinx.serialization.json.JsonPrimitive(out.absolutePath))
                put("trustedSigners", kotlinx.serialization.json.JsonArray(listOf(kotlinx.serialization.json.JsonPrimitive(TestSupport.KEIYOUSHI_SIGNER))))
            }
            val ok = client.call("artifact.prepare", q.packageId, harnessRequest, timeoutMs = 300_000)
            val reported = ok["artifact"]!!.jsonObject["sha256"]!!.jsonPrimitive.content
            assertEquals(Digests.sha256(out), reported)
            out.parentFile.deleteRecursively()
            return reported
        }
    }
}
