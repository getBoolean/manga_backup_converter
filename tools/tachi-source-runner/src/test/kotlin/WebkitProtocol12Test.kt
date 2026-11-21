package mangabackup.tachi

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.Frame
import mangabackup.tachi.protocol.WorkerError
import mangabackup.tachi.protocol.optStr
import mangabackup.tachi.webkit.BrowserReplacement
import mangabackup.tachi.webkit.OriginRules
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.util.Base64
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/** Protocol 1.2 browser translation against a fake supervisor that reports session capabilities. */
class WebkitProtocol12Test {
    /**
     * A 1.2 fake port. Its open reply carries [available]/[unavailable]. On a load it reports the
     * main-frame request the way the session's interception mode says: observe sends an event and goes
     * on; replace holds the load until the worker sends `host.browser.respond` (failing after
     * [respondWaitMs], which is what a worker that answered on the blocked thread would hit).
     */
    class FakePort12(
        private val h: () -> WorkerHarness,
        private val available: List<String> = emptyList(),
        private val unavailable: Map<String, String> = emptyMap(),
        private val refuseReplace: Boolean = false,
        private val respondWaitMs: Long = 5_000,
    ) : (Frame) -> JsonObject {
        val ops = CopyOnWriteArrayList<String>()
        val frames = CopyOnWriteArrayList<Frame>()
        val channels = CopyOnWriteArrayList<String>()
        val modes = CopyOnWriteArrayList<String>()
        val respond = CompletableFuture<Frame>()

        @Volatile
        var mode = "none"

        override fun invoke(frame: Frame): JsonObject {
            ops += frame.op!!
            frames += frame
            val p = frame.payload!!
            return when (frame.op) {
                "host.browser.open" -> buildJsonObject {
                    put("session", "s-1")
                    put("capabilities", buildJsonObject {
                        put("available", JsonArray(available.map { JsonPrimitive(it) }))
                        put("unavailable", JsonObject(unavailable.mapValues { JsonPrimitive(it.value) }))
                    })
                }
                "host.browser.setMessageHandler" -> {
                    channels += p.optStr("name")!!
                    JsonObject(emptyMap())
                }
                "host.browser.setRequestInterception" -> {
                    val m = p.optStr("mode")!!
                    modes += m
                    if (m == "replace" && refuseReplace) {
                        throw WorkerError(ErrorCode.CAPABILITY_UNAVAILABLE, "no replacement timeout configured", "setRequestReplacer")
                    }
                    mode = m
                    JsonObject(emptyMap())
                }
                "host.browser.respond" -> {
                    respond.complete(frame)
                    JsonObject(emptyMap())
                }
                "host.browser.evaluate" -> buildJsonObject {
                    put("result", "null")
                    put("scriptError", "Error: boom")
                }
                "host.browser.loadData", "host.browser.load" -> {
                    val url = p.optStr("baseUrl") ?: p.optStr("url")!!
                    if (frame.op == "host.browser.load" && mode != "none") {
                        h().client.event("host.browser.request", requestEvent(url, held = mode == "replace"))
                        if (mode == "replace") {
                            // The deadlock case: this load's rres waits until the worker answers the held request.
                            respond.get(respondWaitMs, TimeUnit.MILLISECONDS)
                        }
                    }
                    Thread {
                        Thread.sleep(50)
                        for (name in channels) h().client.event("host.browser.message", buildJsonObject {
                            put("session", "s-1")
                            put("name", name)
                            put("message", "solved")
                        })
                    }.start()
                    buildJsonObject {
                        put("finalUrl", url)
                        put("status", 200)
                    }
                }
                "host.browser.getCookies" -> buildJsonObject { put("cookies", JsonArray(emptyList())) }
                else -> JsonObject(emptyMap())
            }
        }

        fun requestEvent(url: String, held: Boolean, session: String = "s-1") = buildJsonObject {
            put("session", session)
            put("requestId", if (held) JsonPrimitive("q-1") else JsonNull)
            put("method", "GET")
            put("url", url)
            put("headers", buildJsonObject { put("sec-ch-ua", "\"Chromium\";v=\"130\"") })
            put("bodyBase64", JsonNull)
            put("bodyOmitted", false)
            put("mainFrame", true)
            put("redirect", false)
            put("context", "document")
        }
    }

    private fun title(h: WorkerHarness, pkg: WorkerHarness.Loaded, query: String) =
        h.hits(h.search(pkg, query))[0]["title"]!!.jsonPrimitive.content

    private fun withPort(minor: Int = 2, port: (() -> WorkerHarness) -> FakePort12, block: (WorkerHarness, FakePort12, WorkerHarness.Loaded) -> Unit) {
        lateinit var h: WorkerHarness
        val p = port { h }
        h = WorkerHarness(minor = minor)
        h.use {
            h.client.reverseHandler = p
            block(h, p, h.loadFixture("webview"))
        }
    }

    @Test
    fun `the worker negotiates minor 3, and the lower minor of an older supervisor`() {
        WorkerHarness().use { assertEquals("3", it.handshake["protocolMinor"]!!.jsonPrimitive.content) }
        WorkerHarness(minor = 1).use { assertEquals("1", it.handshake["protocolMinor"]!!.jsonPrimitive.content) }
    }

    @Test
    fun `addDocumentStartJavaScript becomes an origin-checked page-start script, and remove says it cannot`() {
        withPort(port = { FakePort12(it, available = listOf("pageStartScripts")) }) { h, port, pkg ->
            val result = h.search(pkg, "docstart")
            assertEquals("no-glue:solved|remove=UnsupportedOperationException", h.hits(result)[0]["title"]!!.jsonPrimitive.content)
            assertTrue(result["warnings"].toString().contains("cannot remove a page-start script"), result["warnings"].toString())
            val script = port.frames.single { it.op == "host.browser.addPageStartScript" }.payload!!.optStr("script")!!
            assertTrue(script.contains("window.__fixture = 1"), script)
            assertTrue(script.contains("[[\"https\",\"webview.test\",false,\"443\"]]"), script)
            // Channel objects first, then page-start scripts, then the load.
            assertEquals(
                listOf("host.browser.open", "host.browser.setMessageHandler", "host.browser.addPageStartScript"),
                port.ops.take(3),
            )
            assertTrue(port.ops.indexOf("host.browser.loadData") > port.ops.indexOf("host.browser.addPageStartScript"))
        }
    }

    @Test
    fun `a session without pageStartScripts, or a 1_1 supervisor, fails addDocumentStartJavaScript by name`() {
        withPort(port = { FakePort12(it, unavailable = mapOf("pageStartScripts" to "engine cannot inject")) }) { h, port, pkg ->
            val e = assertThrows<WorkerError> { h.search(pkg, "docstart") }
            assertEquals(ErrorCode.CAPABILITY_UNAVAILABLE, e.code)
            assertEquals("addPageStartScript", e.operation)
            assertTrue(e.message!!.contains("pageStartScripts") && e.message!!.contains("engine cannot inject"), e.message)
            assertTrue("host.browser.addPageStartScript" !in port.ops)
        }
        withPort(minor = 1, port = { FakePort12(it, available = listOf("pageStartScripts", "replaceRequests")) }) { h, port, pkg ->
            val e = assertThrows<WorkerError> { h.search(pkg, "docstart") }
            assertEquals("addPageStartScript", e.operation)
            // A 1.1 supervisor gets no 1.2 reverse requests at all, and interception stays on the shim's own path.
            assertEquals("no-glue:solved", title(h, pkg, "load"))
            assertTrue(port.ops.none { it == "host.browser.addPageStartScript" || it == "host.browser.setRequestInterception" }, "${port.ops}")
        }
    }

    @Test
    fun `observe tier - the handler sees reported requests, and the missing subresource view is a warning`() {
        val reason = "WebKit cannot observe http(s) subresource requests"
        withPort(port = { FakePort12(it, available = listOf("observeNavigations", "observeRequestHeaders"), unavailable = mapOf("observeSubresources" to reason)) }) { h, port, pkg ->
            val result = h.search(pkg, "observe")
            val title = h.hits(result)[0]["title"]!!.jsonPrimitive.content
            assertEquals("no-glue:solved|seen=GET https://webview.test/page main=true ua=\"Chromium\";v=\"130\"", title)
            assertEquals(listOf("observe"), port.modes)
            val warnings = result["warnings"].toString()
            assertTrue(warnings.contains("subresource observation unavailable") && warnings.contains(reason), warnings)
            assertTrue("host.browser.respond" !in port.ops, "observe events are never answered")
        }
    }

    @Test
    fun `observe tier - a non-null response is a named capability error`() {
        withPort(port = { FakePort12(it, available = listOf("observeNavigations")) }) { h, _, pkg ->
            val e = assertThrows<WorkerError> { h.search(pkg, "intercept") }
            assertEquals(ErrorCode.CAPABILITY_UNAVAILABLE, e.code)
            assertEquals("android.webkit.shouldInterceptRequest.replace", e.operation)
        }
    }

    @Test
    fun `replace tier - a held main-frame request is answered while the worker's own load is pending`() {
        val all = listOf("observeNavigations", "observeSubresources", "observeRequestHeaders", "replaceRequests", "pageStartScripts")
        withPort(port = { FakePort12(it, available = all) }) { h, port, pkg ->
            val started = System.nanoTime()
            val result = h.search(pkg, "replace")
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            assertTrue(h.hits(result)[0]["title"]!!.jsonPrimitive.content.startsWith("no-glue:solved|seen=GET https://webview.test/page main=true"))
            assertEquals(listOf("replace"), port.modes)
            assertTrue(elapsedMs < 5_000, "the held load did not wait out the fake's respond timeout ($elapsedMs ms)")
            assertTrue(!result["warnings"].toString().contains("subresource"), "the replace tier sees subresources")

            val respond = port.respond.get(1, TimeUnit.SECONDS)
            val searchId = h.client.transcript.last { it.contains("\"op\":\"search\"") }.let { Frame.parse(it.removePrefix(">> ")).id }
            assertEquals(searchId, respond.of, "respond is a reverse request of the in-flight operation")
            val payload = respond.payload!!
            assertEquals("q-1", payload.optStr("requestId"))
            val response = payload["response"]!!.jsonObject
            assertEquals(200, response["status"]!!.jsonPrimitive.content.toInt())
            assertEquals("Replaced", response.optStr("reason"))
            assertEquals("1", response["headers"]!!.jsonObject.optStr("X-Fixture"))
            assertEquals("text/html; charset=utf-8", response["headers"]!!.jsonObject.optStr("Content-Type"))
            assertEquals("replaced", String(Base64.getDecoder().decode(response.optStr("bodyBase64"))))

            // No operation in flight: a late held request for the closed session is never answered.
            val rreqsBefore = h.client.reverseRequests.size
            h.client.event("host.browser.request", port.requestEvent("https://webview.test/late", held = true))
            Thread.sleep(300)
            assertEquals(rreqsBefore, h.client.reverseRequests.size, "no reverse request after the operation replied")
        }
    }

    @Test
    fun `replace refused by the supervisor falls back to observe`() {
        withPort(port = { FakePort12(it, available = listOf("observeNavigations", "observeSubresources", "replaceRequests"), refuseReplace = true) }) { h, port, pkg ->
            assertTrue(title(h, pkg, "observe").startsWith("no-glue:solved|seen=GET"))
            assertEquals(listOf("replace", "observe"), port.modes)
        }
    }

    @Test
    fun `a redirect replacement is refused by name and the held request proceeds`() {
        withPort(port = { FakePort12(it, available = listOf("observeNavigations", "replaceRequests")) }) { h, port, pkg ->
            val e = assertThrows<WorkerError> { h.search(pkg, "redirect") }
            assertEquals(ErrorCode.CAPABILITY_UNAVAILABLE, e.code)
            assertEquals(BrowserReplacement.OPERATION_REDIRECT, e.operation)
            val respond = port.respond.get(5, TimeUnit.SECONDS)
            assertEquals(JsonNull, respond.payload!!["response"])
        }
    }

    @Test
    fun `a handler that throws an Error still answers the held request, with null`() {
        withPort(port = { FakePort12(it, available = listOf("observeNavigations", "replaceRequests"), respondWaitMs = 3_000) }) { h, port, pkg ->
            assertEquals("no-glue:solved", title(h, pkg, "throws"))
            assertEquals(JsonNull, port.respond.get(1, TimeUnit.SECONDS).payload!!["response"])
        }
    }

    @Test
    fun `scriptError is ignored - a throwing evaluate reads as null`() {
        withPort(port = { FakePort12(it, available = listOf("scriptErrors")) }) { h, _, pkg ->
            assertEquals("no-glue:eval=null", title(h, pkg, "evalerr"))
        }
    }

    @Test
    fun `any identifier is a channel name, ipc included`() {
        withPort(port = { FakePort12(it) }) { h, port, pkg ->
            assertEquals("no-glue:solved", title(h, pkg, "ipc"))
            assertEquals(listOf("ipc"), port.channels.distinct())
        }
    }

    @Test
    fun `origin rules follow the androidx grammar`() {
        assertNull(OriginRules.parse("*"))
        assertEquals(OriginRules.Rule("https", "example.com", false, "443"), OriginRules.parse("https://example.com"))
        assertEquals(OriginRules.Rule("http", "example.com", true, "8080"), OriginRules.parse("http://*.Example.com:8080"))
        assertEquals(OriginRules.Rule("https", "[::1]", false, "99"), OriginRules.parse("https://[::1]:99"))
        assertEquals(OriginRules.NEVER, OriginRules.parse("my-app-scheme://")!!.scheme, "custom schemes are valid and never match")
        assertThrows<IllegalArgumentException> { OriginRules.parse("my-app-scheme://host") }
        assertThrows<IllegalArgumentException> { OriginRules.parse("ftp://example.com") }
        assertThrows<IllegalArgumentException> { OriginRules.parse("https://example.com/path") }
        assertThrows<IllegalArgumentException> { OriginRules.wrap("x()", emptySet()) }
        assertEquals("x()", OriginRules.wrap("x()", setOf("https://a.test", "*")))
    }

    /** Runs the wrapped script under node with a fake `location`; skipped where node is not installed. */
    @Test
    fun `the origin check runs the script only in matching frames`() {
        val node = listOf("node", "node.exe").firstNotNullOfOrNull { exe ->
            System.getenv("PATH").orEmpty().split(java.io.File.pathSeparator).map { java.io.File(it, exe) }.firstOrNull { it.isFile }
        }
        assumeTrue(node != null, "node is not on PATH")
        val wrapped = OriginRules.wrap("ran = true;", setOf("https://example.com", "http://*.sub.test:8080", "my-app-scheme://"))
        fun runs(href: String): Boolean {
            val u = java.net.URI(href)
            val js = "var location = {protocol: '${u.scheme}:', hostname: '${u.host ?: ""}', port: '${if (u.port < 0) "" else u.port}'};" +
                "var ran = false;\n$wrapped\nprocess.stdout.write(String(ran));"
            // A file, not `-e`: Windows argument quoting mangles the script's double quotes.
            val file = java.io.File(TestSupport.tempDir("origin"), "check.js").apply { writeText(js) }
            val p = ProcessBuilder(node!!.absolutePath, file.absolutePath).redirectErrorStream(true).start()
            val out = p.inputStream.readBytes().decodeToString()
            assertTrue(p.waitFor(20, TimeUnit.SECONDS))
            file.parentFile.deleteRecursively()
            assertTrue(out.trim() == "true" || out.trim() == "false", out)
            return out.trim() == "true"
        }
        assertTrue(runs("https://example.com/a"))
        assertTrue(runs("https://example.com:443/a"))
        assertTrue(!runs("https://example.com:8443/a"), "explicit other port")
        assertTrue(!runs("http://example.com/a"), "other scheme")
        assertTrue(!runs("https://www.example.com/a"), "no wildcard: subdomains do not match")
        assertTrue(!runs("http://sub.test:8080/"), "a *. rule matches subdomains, not the domain itself (androidx)")
        assertTrue(runs("http://a.sub.test:8080/"))
        assertTrue(runs("http://a.b.sub.test:8080/"))
        assertTrue(!runs("http://notsub.test:8080/"))
        assertTrue(!runs("http://a.sub.test/"), "default port 80 is not 8080")
    }
}
