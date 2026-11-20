package mangabackup.tachi

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.Frame
import mangabackup.tachi.protocol.WorkerError
import mangabackup.tachi.protocol.optStr
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.util.concurrent.CopyOnWriteArrayList

/** KTD20 translation shim against a fake BrowserPort played by the test (as U1's fake does for the supervisor). */
class WebkitShimTest {
    /** A fake port: opens sessions, answers loads, and has the page post `reply` on every registered channel. */
    class FakePort(private val h: () -> WorkerHarness, private val reply: String = "solved", private val failOpenWith: String? = null) : (Frame) -> JsonObject {
        val ops = CopyOnWriteArrayList<String>()
        private val channels = CopyOnWriteArrayList<String>()

        override fun invoke(frame: Frame): JsonObject {
            ops += frame.op!!
            val p = frame.payload!!
            return when (frame.op) {
                "host.browser.open" -> {
                    failOpenWith?.let { throw WorkerError(it, "fake port: $it", "host.browser.open") }
                    buildJsonObject { put("session", "s-1") }
                }
                "host.browser.setMessageHandler" -> {
                    channels += p.optStr("name")!!
                    JsonObject(emptyMap())
                }
                "host.browser.loadData", "host.browser.load" -> {
                    val base = p.optStr("baseUrl") ?: p.optStr("url")!!
                    // The page runs its script after load and posts on the registered channels.
                    Thread {
                        Thread.sleep(50)
                        for (name in channels) h().client.event("host.browser.message", buildJsonObject {
                            put("session", "s-1")
                            put("name", name)
                            put("message", reply)
                        })
                    }.start()
                    buildJsonObject {
                        put("finalUrl", base)
                        put("status", 200)
                    }
                }
                "host.browser.getCookies" -> buildJsonObject { put("cookies", kotlinx.serialization.json.JsonArray(emptyList())) }
                else -> JsonObject(emptyMap())
            }
        }
    }

    @Test
    fun `runWebViewBlocking-style main-looper code completes through the shim, with no Chromium glue`() {
        lateinit var h: WorkerHarness
        val port = FakePort({ h })
        h = WorkerHarness()
        h.use {
            h.client.reverseHandler = port
            val pkg = h.loadFixture("webview")
            val title = h.hits(h.search(pkg, "go"))[0]["title"]!!.jsonPrimitive.content
            assertEquals("no-glue:solved", title)
            val warnings = h.search(pkg, "go")["warnings"].toString()
            assertTrue(warnings.contains("subresource observation unavailable"), warnings)
            assertEquals("host.browser.open", port.ops.first())
            assertTrue("host.browser.setMessageHandler" in port.ops)
            assertTrue("host.browser.loadData" in port.ops)
            assertTrue("host.browser.close" in port.ops, "the session is closed before the operation replies: ${port.ops}")
            // Every reverse request named the search that caused it.
            val searchIds = h.client.transcript.filter { it.contains("\"op\":\"search\"") }.map { Frame.parse(it.removePrefix(">> ")).id }
            assertTrue(h.client.reverseRequests.all { it.of in searchIds })
        }
    }

    @Test
    fun `non-http base URLs are refused as capability-unavailable`() {
        lateinit var h: WorkerHarness
        val port = FakePort({ h })
        h = WorkerHarness()
        h.use {
            h.client.reverseHandler = port
            val pkg = h.loadFixture("webview")
            val e = assertThrows<WorkerError> { h.search(pkg, "file") }
            assertEquals(ErrorCode.CAPABILITY_UNAVAILABLE, e.code)
            assertEquals("host.browser.loadData", e.operation)
            assertTrue("host.browser.loadData" !in port.ops)
        }
    }

    @Test
    fun `replacing a response from shouldInterceptRequest is a named capability error`() {
        lateinit var h: WorkerHarness
        val port = FakePort({ h })
        h = WorkerHarness()
        h.use {
            h.client.reverseHandler = port
            val pkg = h.loadFixture("webview")
            val e = assertThrows<WorkerError> { h.search(pkg, "intercept") }
            assertEquals(ErrorCode.CAPABILITY_UNAVAILABLE, e.code)
            assertEquals("android.webkit.shouldInterceptRequest.replace", e.operation)
            assertEquals("no-glue:solved", h.hits(h.search(pkg, "load"))[0]["title"]!!.jsonPrimitive.content, "observe-only loadUrl still works")
        }
    }

    @Test
    fun `a port that needs a visible interaction surfaces as interaction-required`() {
        lateinit var h: WorkerHarness
        val port = FakePort({ h }, failOpenWith = ErrorCode.INTERACTION_REQUIRED)
        h = WorkerHarness()
        h.use {
            h.client.reverseHandler = port
            val pkg = h.loadFixture("webview")
            val e = assertThrows<WorkerError> { h.search(pkg, "go") }
            assertEquals(ErrorCode.INTERACTION_REQUIRED, e.code)
        }
    }

    @Test
    fun `without a browser port the browser capability is unavailable`() {
        WorkerHarness().use { h ->
            val pkg = h.loadFixture("webview")
            val e = assertThrows<WorkerError> { h.search(pkg, "go") }
            assertEquals(ErrorCode.CAPABILITY_UNAVAILABLE, e.code)
        }
    }
}
