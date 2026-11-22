package mangabackup.tachi.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.serializer

/**
 * Worker protocol v1 (packages/source_runtime/doc/protocol-v1.md; Dart types in
 * protocol_payloads.dart are the source of truth). UTF-8 JSON lines, one frame
 * per line, at most [MAX_FRAME_BYTES] encoded bytes.
 */
object Wire {
    const val VERSION = 1

    /**
     * Highest minor version of [VERSION] this worker speaks (1.1: string sets, source scopes,
     * trustedSigners; 1.2: browser capabilities, page-start scripts, request interception; 1.3: show
     * outcomes, `host.browser.endInteraction`, `interaction.started` / `interaction.ended`, awaited evaluate).
     */
    const val MINOR_VERSION = 3
    const val MAX_FRAME_BYTES = 16 * 1024 * 1024
    const val MAX_SAFE_INTEGER = 9007199254740991L

    /**
     * Payload codec: unknown fields are ignored (as the Dart decoders ignore them), strings must be JSON
     * strings, and `null` fields are written, as Dart's `toJson` writes them.
     */
    val json = Json { encodeDefaults = true; explicitNulls = true; ignoreUnknownKeys = true }

    /** Frame envelopes leave absent fields out. */
    private val frameJson = Json { encodeDefaults = true; explicitNulls = false; ignoreUnknownKeys = true }

    /** Decodes a payload, reporting any shape error as a [ProtocolViolation] (`protocol-violation`). */
    fun <T> decode(serializer: KSerializer<T>, element: JsonElement, what: String): T = try {
        json.decodeFromJsonElement(serializer, element)
    } catch (e: IllegalArgumentException) {
        // SerializationException (missing field, wrong JSON type) is an IllegalArgumentException.
        throw ProtocolViolation("$what: ${e.message}")
    }

    inline fun <reified T> decode(element: JsonElement, what: String = T::class.simpleName ?: "payload"): T =
        decode(serializer<T>(), element, what)

    /** Decodes an event payload; a malformed one is null (events are dropped, never fatal). */
    inline fun <reified T> decodeOrNull(element: JsonElement): T? = try {
        json.decodeFromJsonElement(serializer<T>(), element)
    } catch (_: IllegalArgumentException) {
        null
    }

    fun <T> encode(serializer: KSerializer<T>, value: T): JsonObject = json.encodeToJsonElement(serializer, value) as JsonObject

    inline fun <reified T> encode(value: T): JsonObject = encode(serializer<T>(), value)

    internal fun encodeFrame(frame: Frame): String = frameJson.encodeToString(Frame.serializer(), frame)

    internal fun decodeFrame(element: JsonElement): Frame = frameJson.decodeFromJsonElement(Frame.serializer(), element)
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
        /** Reads an `err` leniently: it arrives on the frame reader, which must never fail on it. */
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

/** The frame's `t`. */
@Serializable
enum class FrameType {
    @SerialName("req") REQ,
    @SerialName("res") RES,
    @SerialName("cancel") CANCEL,
    @SerialName("rreq") RREQ,
    @SerialName("rres") RRES,
    @SerialName("event") EVENT,
}

/** One protocol frame. */
@Serializable
data class Frame(
    val v: Int = Wire.VERSION,
    val t: FrameType,
    val id: String,
    val gen: Long,
    val op: String? = null,
    val pkg: String? = null,
    val of: String? = null,
    val payload: JsonObject? = null,
    val ok: JsonObject? = null,
    val err: JsonObject? = null,
) {
    fun encode(): String = Wire.encodeFrame(this)

    companion object {
        fun parse(line: String): Frame {
            val element = try {
                Wire.json.parseToJsonElement(line)
            } catch (e: Exception) {
                throw ProtocolViolation("frame is not JSON: ${e.message}")
            }
            val o = element as? JsonObject ?: throw ProtocolViolation("frame is not a JSON object")
            val v = (o["v"] as? JsonPrimitive)?.longOrNull
            if (v != Wire.VERSION.toLong()) throw ProtocolViolation("unsupported protocol version $v")
            return try {
                Wire.decodeFrame(o)
            } catch (e: IllegalArgumentException) {
                throw ProtocolViolation("bad frame: ${e.message}")
            }
        }
    }
}

/** An integer within ±(2^53 − 1) given as a JSON number, or null. */
fun JsonElement.safeIntegerOrNull(): Long? {
    val p = this as? JsonPrimitive ?: return null
    if (p.isString) return null
    return p.longOrNull?.takeIf { it in -Wire.MAX_SAFE_INTEGER..Wire.MAX_SAFE_INTEGER }
}

/**
 * A JSON settings value: string, bool, integer within ±(2^53 − 1), or (1.1) an
 * array of strings, which is a string set backing `getStringSet`.
 */
fun JsonElement.settingsValue(key: String): Any {
    if (this is JsonArray) {
        return map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: throw ProtocolViolation("settings value '$key' may only hold strings in an array") }
            .toSortedSet()
    }
    val p = this as? JsonPrimitive ?: throw ProtocolViolation("settings value '$key' must be a string, bool, int or string array")
    if (p.isString) return p.content
    p.booleanOrNull?.let { return it }
    val l = p.longOrNull
    if (l != null && l in -Wire.MAX_SAFE_INTEGER..Wire.MAX_SAFE_INTEGER && p.doubleOrNull != null) return l
    throw ProtocolViolation("settings value '$key' must be a string, bool, int or string array")
}
