package mangabackup.tachi.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import kotlin.system.exitProcess

/**
 * The runtime artifact manifest (`tachi-runtime.json`) that packaging places at the root of the
 * worker install, beside `lib/`. `package:tachi_plugin_loader` reads it (`TachiWorkerLocation`).
 *
 * It carries the one limit the worker cannot report itself: the handshake deadline, which the
 * supervisor needs before the worker has said anything. The value comes from the committed sizing
 * rule ([SizingRule.handshakeDeadlineMs]), so the manifest and the handshake's `sizing` report agree.
 * `java` is omitted: the caller supplies the runtime (`TACHI_JAVA_HOME`/`JAVA_HOME`) unless a bundling
 * step adds it.
 */
object RuntimeManifest {
    const val FORMAT = 1
    const val FILE_NAME = "tachi-runtime.json"

    /**
     * The manifest for [rule]. A rule without a startup measurement yields no `handshakeDeadlineMs`
     * (the loader then fails naming it, as before) rather than an invented value.
     */
    fun build(rule: SizingRule): JsonObject = buildJsonObject {
        put("format", FORMAT)
        put("worker", "tachi-jvm")
        put("classpath", "lib")
        put("mainClass", "mangabackup.tachi.MainKt")
        rule.handshakeDeadlineMs?.let {
            put("handshakeDeadlineMs", it)
            put("handshakeDeadlineSource", rule.source)
        }
    }

    /** `RuntimeManifest <output.json>`: writes the manifest from the committed rule (used by Gradle packaging). */
    @JvmStatic
    fun main(args: Array<String>) {
        val out = args.singleOrNull()?.let(::File) ?: run {
            System.err.println("usage: RuntimeManifest <output.json>")
            exitProcess(64)
        }
        val rule = SizingRule.committed() ?: run {
            System.err.println("no committed sizing rule (${SizingRule.RESOURCE})")
            exitProcess(2)
        }
        if (rule.handshakeDeadlineMs == null) {
            System.err.println("warning: ${SizingRule.RESOURCE} has no startup measurement; $FILE_NAME carries no handshakeDeadlineMs (run ./gradlew benchmark)")
        }
        out.parentFile?.mkdirs()
        out.writeText(Json { prettyPrint = true }.encodeToString(JsonObject.serializer(), build(rule)) + "\n")
    }
}
