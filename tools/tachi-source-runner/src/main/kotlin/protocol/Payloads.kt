package mangabackup.tachi.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import mangabackup.tachi.host.HostSettings

/** `ArtifactBinding`. */
data class ArtifactBinding(val sha256: String, val kind: String, val version: String) {
    fun toJson() = buildJsonObject {
        put("sha256", sha256)
        put("kind", kind)
        put("version", version)
    }

    companion object {
        fun from(o: JsonObject) = ArtifactBinding(o.str("sha256"), o.str("kind"), o.str("version"))
    }
}

/** `SourceIdentity`. */
data class SourceIdentity(val ecosystem: String, val packageId: String, val sourceId: String, val artifact: ArtifactBinding) {
    fun toJson() = buildJsonObject {
        put("ecosystem", ecosystem)
        put("packageId", packageId)
        put("sourceId", sourceId)
        put("artifact", artifact.toJson())
    }

    companion object {
        fun from(o: JsonObject) = SourceIdentity(o.str("ecosystem"), o.str("packageId"), o.str("sourceId"), ArtifactBinding.from(o.obj("artifact")))
    }
}

/** `NativeMangaRef`. */
data class NativeMangaRef(val source: SourceIdentity, val mangaId: String, val settingsRevision: String, val context: JsonObject) {
    fun toJson() = buildJsonObject {
        put("source", source.toJson())
        put("mangaId", mangaId)
        put("settingsRevision", settingsRevision)
        put("context", context)
    }

    companion object {
        fun from(o: JsonObject) = NativeMangaRef(SourceIdentity.from(o.obj("source")), o.str("mangaId"), o.str("settingsRevision"), o.optObj("context") ?: JsonObject(emptyMap()))
    }
}

/** Decodes a `SettingsPayload`, including 1.1 string sets and per-source scopes (`sources`). */
object SettingsCodec {
    fun from(o: JsonObject): HostSettings {
        val sources = o.optObj("sources")?.mapValues { (id, scope) ->
            val s = scope as? JsonObject ?: throw ProtocolViolation("settings scope '$id' must be an object")
            HostSettings.SourceScope(values(s.optObj("values"), "sources.$id."), secrets(s.optObj("secrets"), "sources.$id."))
        } ?: emptyMap()
        return HostSettings(values(o.obj("values"), ""), secrets(o.obj("secrets"), ""), o.str("revision"), sources)
    }

    private fun values(o: JsonObject?, prefix: String): Map<String, Any> =
        o?.mapValues { (k, v) -> v.settingsValue("$prefix$k") } ?: emptyMap()

    private fun secrets(o: JsonObject?, prefix: String): Map<String, String> =
        o?.mapValues { (k, v) -> v.asStringStrict("secret '$prefix$k'") } ?: emptyMap()
}

fun stringArray(values: Iterable<String>): JsonArray = buildJsonArray { values.forEach { add(JsonPrimitive(it)) } }

/** `SourceCapabilities`. */
fun capabilitiesJson(operations: List<String>, apiFamilies: List<String>, requiresBrowser: Boolean) = buildJsonObject {
    put("operations", stringArray(operations))
    put("apiFamilies", stringArray(apiFamilies))
    put("requiresBrowser", requiresBrowser)
}
