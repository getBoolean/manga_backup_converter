package mangabackup.tachi

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mangabackup.tachi.host.HostTransport
import mangabackup.tachi.host.RuntimeManifest
import mangabackup.tachi.host.SizingReport
import mangabackup.tachi.host.SizingRule
import mangabackup.tachi.protocol.DesktopPlatform
import mangabackup.tachi.protocol.WorkerClient
import mangabackup.tachi.protocol.WorkerOptions
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** KTD25: the handshake deadline is derived from measured start-up and reaches the supervisor through the runtime manifest. */
class HandshakeDeadlineTest {
    private val rule = SizingRule(
        "test", 1.0, 64.0, 4.0, 1000.0, 5.0, 5.0, 50.0, 3.0, 300_000, maxPoolSize = 3,
        maxStartupToHandshakeMs = 612.3, handshakeFactor = 10.0,
    )

    @Test
    fun `the rule derives the handshake deadline from the worst measured start-up and the headroom factor`() {
        assertEquals(6123L, rule.handshakeDeadlineMs)
        assertEquals(6123L, SizingRule.parse(rule.toJson().toString()).handshakeDeadlineMs, "round-trips through the committed JSON")
        // A rule benchmarked before start-up was measured has no deadline; nothing is invented.
        assertNull(rule.copy(maxStartupToHandshakeMs = null).handshakeDeadlineMs)
        assertNull(SizingRule.parse(rule.copy(maxStartupToHandshakeMs = null, handshakeFactor = null).toJson().toString()).handshakeDeadlineMs)
    }

    @Test
    fun `the committed rule carries a start-up measurement`() {
        val committed = SizingRule.committed()!!
        assertNotNull(committed.handshakeDeadlineMs, "rerun ./gradlew benchmark: the committed rule has no maxStartupToHandshakeMs")
        assertTrue(committed.handshakeDeadlineMs!! > committed.maxStartupToHandshakeMs!!)
    }

    @Test
    fun `the handshake reports the deadline in limits and sizing, without making it an adoptable limit`() {
        val options = WorkerOptions(
            sizing = SizingReport.resolve(emptyMap(), rule = rule)!!,
            transport = HostTransport.LIVE,
            networkMode = "test",
            stateRoot = TestSupport.tempDir("hs"),
            browser = false,
            platform = DesktopPlatform,
        )
        val (client, thread) = WorkerClient.inProcess(options)
        try {
            val ok = client.handshake()
            assertEquals("6123", ok["limits"]!!.jsonObject["handshakeDeadlineMs"]!!.jsonPrimitive.content)
            val sizing = ok["sizing"]!!.jsonObject
            assertEquals("6123", sizing["derived"]!!.jsonObject["handshakeDeadlineMs"]!!.jsonPrimitive.content)
            assertEquals("612.3", sizing["rule"]!!.jsonObject["maxStartupToHandshakeMs"]!!.jsonPrimitive.content)
            client.call("shutdown")
        } finally {
            client.close()
            thread.join(5_000)
            options.stateRoot.deleteRecursively()
        }
        // Explicit overrides still resolve without it: --limit never needs a handshake deadline.
        assertNotNull(SizingReport.resolve(TEST_LIMITS, rule = null))
    }

    @Test
    fun `the runtime manifest has the shape tachi_plugin_loader reads`() {
        val m = RuntimeManifest.build(rule)
        assertEquals(1, m["format"]!!.jsonPrimitive.content.toInt())
        assertEquals("tachi-jvm", m["worker"]!!.jsonPrimitive.content)
        assertEquals("lib", m["classpath"]!!.jsonPrimitive.content)
        assertEquals("mangabackup.tachi.MainKt", m["mainClass"]!!.jsonPrimitive.content)
        assertEquals(6123L, m["handshakeDeadlineMs"]!!.jsonPrimitive.content.toLong())
        assertNull(m["java"], "the runtime comes from TACHI_JAVA_HOME/JAVA_HOME unless bundling adds it")
        assertNull(RuntimeManifest.build(rule.copy(handshakeFactor = null))["handshakeDeadlineMs"])
    }
}
