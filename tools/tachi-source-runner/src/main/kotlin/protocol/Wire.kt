package mangabackup.tachi.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Worker protocol v1 (packages/source_runtime/doc/protocol-v1.md; Dart types in
 * protocol_payloads.dart are the source of truth). UTF-8 JSON lines, one frame
 * per line, at most [MAX_FRAME_BYTES] encoded bytes.
 */
object Wire {
    const val VERSION = 1
    const val MAX_FRAME_BYTES = 16 * 1024 * 1024
    const val MAX_SAFE_INTEGER = 9007199254740991L

    val json = Json { encodeDefaults = true; explicitNulls = true }
}

/** Protocol error codes (`err.code`). */
object ErrorCode {
    const val TIMEOUT = "timeout"
    const val CANCELLED = "cancelled"
    const val UNSUPPORTED_API = "unsupported-api"
    const val INTERACTION_REQUIRED = "interaction-required"
    const val STALE_REFERENCE = "stale-reference"
    const val ARTIFACT_INCOMPATIBLE = "artifact-incompatible"
    const val WORKER_RESTARTED = "worker-restarted"
    const val SOURCE_ERROR = "source-error"
    const val CAPABILITY_UNAVAILABLE = "capability-unavailable"
    const val PROTOCOL_VIOLATION = "protocol-violation"
    const val RUNTIME_UNAVAILABLE = "runtime-unavailable"

    val ALL = setOf(
        TIMEOUT, CANCELLED, UNSUPPORTED_API, INTERACTION_REQUIRED, STALE_REFERENCE, ARTIFACT_INCOMPATIBLE,
        WORKER_RESTARTED, SOURCE_ERROR, CAPABILITY_UNAVAILABLE, PROTOCOL_VIOLATION, RUNTIME_UNAVAILABLE,
    )
}

/** A failure that becomes an `err` object. */
class WorkerError(val code: String, message: String, val operation: String? = null, cause: Throwable? = null) :
    Exception(message, cause) {
    fun toJson(): JsonObject = buildJsonObject {
        put("code", code)
        put("message", message ?: code)
        if (operation != null) put("operation", operation)
    }

    companion object {
        fun fromJson(o: JsonObject): WorkerError {
            val code = (o["code"] as? JsonPrimitive)?.contentOrNull ?: ErrorCode.SOURCE_ERROR
            return WorkerError(
                if (code in ErrorCode.ALL) code else ErrorCode.SOURCE_ERROR,
                (o["message"] as? JsonPrimitive)?.contentOrNull ?: code,
                (o["operation"] as? JsonPrimitive)?.contentOrNull,
            )
        }
    }
}

class ProtocolViolation(message: String) : Exception(message)

/** One protocol frame. */
data class Frame(
    val t: String,
    val id: String,
    val gen: Long,
    val op: String? = null,
    val pkg: String? = null,
    val of: String? = null,
    val payload: JsonObject? = null,
    val ok: JsonObject? = null,
    val err: JsonObject? = null,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("v", Wire.VERSION)
        put("t", t)
        put("id", id)
        put("gen", gen)
        if (op != null) put("op", op)
        if (pkg != null) put("pkg", pkg)
        if (of != null) put("of", of)
        if (payload != null) put("payload", payload)
        if (ok != null) put("ok", ok)
        if (err != null) put("err", err)
    }

    fun encode(): String = Wire.json.encodeToString(JsonObject.serializer(), toJson())

    companion object {
        val TYPES = setOf("req", "res", "cancel", "rreq", "rres", "event")

        fun parse(line: String): Frame {
            val element = try {
                Wire.json.parseToJsonElement(line)
            } catch (e: Exception) {
                throw ProtocolViolation("frame is not JSON: ${e.message}")
            }
            val o = element as? JsonObject ?: throw ProtocolViolation("frame is not a JSON object")
            val v = (o["v"] as? JsonPrimitive)?.longOrNull
            if (v != Wire.VERSION.toLong()) throw ProtocolViolation("unsupported protocol version $v")
            val t = o.str("t")
            if (t !in TYPES) throw ProtocolViolation("unknown frame type $t")
            val gen = (o["gen"] as? JsonPrimitive)?.longOrNull ?: throw ProtocolViolation("frame has no integer gen")
            return Frame(
                t = t,
                id = o.str("id"),
                gen = gen,
                op = o.optStr("op"),
                pkg = o.optStr("pkg"),
                of = o.optStr("of"),
                payload = o.optObj("payload"),
                ok = o.optObj("ok"),
                err = o.optObj("err"),
            )
        }
    }
}

// --- strict field access, mirroring the Dart decoders -------------------------------------

private fun bad(key: String, expected: String): Nothing = throw ProtocolViolation("field '$key' must be $expected")

fun JsonObject.str(key: String): String {
    val p = this[key] as? JsonPrimitive ?: bad(key, "a string")
    if (!p.isString) bad(key, "a string")
    return p.content
}

fun JsonObject.optStr(key: String): String? = when (val e = this[key]) {
    null, JsonNull -> null
    is JsonPrimitive -> if (e.isString) e.content else bad(key, "a string or null")
    else -> bad(key, "a string or null")
}

fun JsonObject.int(key: String): Long {
    val p = this[key] as? JsonPrimitive ?: bad(key, "an integer")
    if (p.isString) bad(key, "an integer")
    val v = p.longOrNull ?: bad(key, "an integer")
    if (v > Wire.MAX_SAFE_INTEGER || v < -Wire.MAX_SAFE_INTEGER) bad(key, "within ±(2^53 − 1)")
    return v
}

fun JsonObject.bool(key: String): Boolean {
    val p = this[key] as? JsonPrimitive ?: bad(key, "a boolean")
    if (p.isString) bad(key, "a boolean")
    return p.booleanOrNull ?: bad(key, "a boolean")
}

fun JsonObject.obj(key: String): JsonObject = this[key] as? JsonObject ?: bad(key, "an object")

fun JsonObject.optObj(key: String): JsonObject? = when (val e = this[key]) {
    null, JsonNull -> null
    is JsonObject -> e
    else -> bad(key, "an object or null")
}

fun JsonObject.arr(key: String): JsonArray = this[key] as? JsonArray ?: bad(key, "an array")

fun JsonObject.optArr(key: String): JsonArray? = when (val e = this[key]) {
    null, JsonNull -> null
    is JsonArray -> e
    else -> bad(key, "an array or null")
}

fun JsonElement.asStringStrict(what: String): String {
    val p = this as? JsonPrimitive ?: throw ProtocolViolation("$what must be a string")
    if (!p.isString) throw ProtocolViolation("$what must be a string")
    return p.content
}

/** A JSON settings value: string, bool, or integer within ±(2^53 − 1). */
fun JsonElement.settingsValue(key: String): Any {
    val p = this as? JsonPrimitive ?: throw ProtocolViolation("settings value '$key' must be a string, bool or int")
    if (p.isString) return p.content
    p.booleanOrNull?.let { return it }
    val l = p.longOrNull
    if (l != null && l in -Wire.MAX_SAFE_INTEGER..Wire.MAX_SAFE_INTEGER && p.doubleOrNull != null) return l
    throw ProtocolViolation("settings value '$key' must be a string, bool or int")
}

