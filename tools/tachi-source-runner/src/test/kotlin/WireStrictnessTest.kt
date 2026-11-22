package mangabackup.tachi

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.WorkerError
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.File

/**
 * How strictly the worker decodes supervisor payloads, through the protocol only (so it holds whatever
 * decodes them): every field of the wrong JSON type, a missing required field, and an integer outside
 * ±(2^53 − 1) is a `protocol-violation`, as the Dart decoders in protocol_payloads.dart reject them.
 */
class WireStrictnessTest {
    private fun violation(block: () -> Unit): WorkerError {
        val e = assertThrows<WorkerError> { block() }
        assertEquals(ErrorCode.PROTOCOL_VIOLATION, e.code, e.message)
        return e
    }

    private fun JsonObject.with(key: String, value: JsonElement?) = JsonObject(if (value == null) this - key else this + (key to value))

    @Test
    fun `artifact prepare rejects mistyped and missing fields`() {
        WorkerHarness().use { h ->
            val input = File(TestSupport.fixtureJars, "fixture-multi.jar")
            val out = File(TestSupport.tempDir("staged"), "staged.jar")
            val good = h.prepareRequest(input, "jar", "1", out, listOf(TestSupport.KEIYOUSHI_SIGNER))
            val artifact = good["artifact"]!!.jsonObject
            fun prepare(p: JsonObject) = h.client.call("artifact.prepare", "strict.pkg", p)
            violation { prepare(good.with("artifact", artifact.with("sha256", JsonPrimitive(5)))) }
            violation { prepare(good.with("artifact", artifact.with("kind", null))) }
            violation { prepare(good.with("inputPath", null)) }
            violation { prepare(good.with("outputPath", JsonPrimitive(true))) }
            violation { prepare(good.with("trustedSigners", JsonArray(listOf(JsonPrimitive(1))))) }
            violation { prepare(good.with("artifact", JsonPrimitive("not an object"))) }
        }
    }

    @Test
    fun `package load rejects settings values outside the protocol's types`() {
        WorkerHarness().use { h ->
            val staged = File(TestSupport.fixtureJars, "fixture-prefs.jar")
            val binding = mangabackup.tachi.protocol.ArtifactBinding(Digests.sha256(staged), "jar", "1")
            fun settings(values: JsonObject = JsonObject(emptyMap()), secrets: JsonElement = JsonObject(emptyMap()), revision: JsonElement = JsonPrimitive("r")) =
                buildJsonObject {
                    put("values", values)
                    put("secrets", secrets)
                    put("revision", revision)
                }
            fun load(s: JsonObject) = h.load("fixture.prefs", staged, binding, s)
            violation { load(settings(values = JsonObject(mapOf("a" to JsonPrimitive(1.5))))) }
            violation { load(settings(values = JsonObject(mapOf("a" to JsonPrimitive(9007199254740992L))))) }
            violation { load(settings(values = JsonObject(mapOf("a" to JsonNull)))) }
            violation { load(settings(values = JsonObject(mapOf("a" to JsonArray(listOf(JsonPrimitive(1))))))) }
            violation { load(settings(values = JsonObject(mapOf("a" to buildJsonObject { put("x", 1) })))) }
            violation { load(settings(secrets = JsonObject(mapOf("token" to JsonPrimitive(1))))) }
            violation { load(settings(revision = JsonNull)) }
            violation { load(settings(revision = JsonPrimitive(3))) }
            violation { load(settings().with("values", null)) }
            violation { load(settings().with("sources", JsonObject(mapOf("1" to JsonPrimitive("x"))))) }
            // The edges of the protocol's integers, string sets and source scopes are accepted.
            val ok = load(
                settings(
                    values = JsonObject(
                        mapOf(
                            "max" to JsonPrimitive(9007199254740991L),
                            "min" to JsonPrimitive(-9007199254740991L),
                            "flag" to JsonPrimitive(true),
                            "set" to JsonArray(listOf(JsonPrimitive("b"), JsonPrimitive("a"))),
                        ),
                    ),
                ).with("sources", JsonObject(mapOf("1" to buildJsonObject { put("values", buildJsonObject { put("x", "y") }) }))),
            )
            assertEquals(true, ok.sources.isNotEmpty())
        }
    }

    @Test
    fun `source operations reject mistyped fields`() {
        WorkerHarness().use { h ->
            val pkg = h.loadFixture("multi")
            val good = h.searchPayload(pkg, "q")
            fun search(p: JsonObject) = h.client.call("search", pkg.packageId, p)
            violation { search(good.with("query", JsonPrimitive(1))) }
            violation { search(good.with("query", null)) }
            violation { search(good.with("settingsRevision", JsonPrimitive(false))) }
            violation { search(good.with("cursor", JsonPrimitive(2))) }
            violation { search(good.with("source", good["source"]!!.jsonObject.with("artifact", null))) }
            violation {
                h.client.call("details", pkg.packageId, buildJsonObject {
                    put("source", good["source"]!!)
                    put("settingsRevision", pkg.revision)
                    put("ref", buildJsonObject { put("mangaId", "x") })
                })
            }
            violation {
                h.client.call("settings.update", pkg.packageId, buildJsonObject { put("settings", JsonPrimitive("x")) })
            }
        }
    }
}
