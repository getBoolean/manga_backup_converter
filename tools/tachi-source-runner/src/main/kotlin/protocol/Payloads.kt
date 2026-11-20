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

object SettingsCodec {
    fun from(o: JsonObject): HostSettings {
        val values = o.obj("values").mapValues { (k, v) -> v.settingsValue(k) }
        val secrets = o.obj("secrets").mapValues { (k, v) -> v.asStringStrict("secret '$k'") }
        return HostSettings(values, secrets, o.str("revision"))
    }
}

fun stringArray(values: Iterable<String>): JsonArray = buildJsonArray { values.forEach { add(JsonPrimitive(it)) } }

/** `SourceCapabilities`. */
fun capabilitiesJson(operations: List<String>, apiFamilies: List<String>, requiresBrowser: Boolean) = buildJsonObject {
    put("operations", stringArray(operations))
    put("apiFamilies", stringArray(apiFamilies))
    put("requiresBrowser", requiresBrowser)
}
