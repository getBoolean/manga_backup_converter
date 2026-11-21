package mangabackup.tachi

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.Frame
import mangabackup.tachi.protocol.WorkerError
import mangabackup.tachi.protocol.WorkerPlatform
import mangabackup.tachi.protocol.optStr
import mangabackup.tachi.webkit.WebViewTranslation
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Protocol 1.3 browser behaviour (interaction outcomes, deadline pause, awaited evaluate) against a fake supervisor. */
class WebkitProtocol13Test {
    /** How the fake platform ends a `host.browser.show`. */
    sealed interface Show {
        /** Waits for `host.browser.endInteraction`; with [message], a page message on `bridge` arrives first. */
        data class OnEnd(val message: Boolean = true) : Show

        /**
         * The user closes the window after [ms] ([laterMs] for every show after the first);
         * [outcome] false answers as a pre-1.3 supervisor would.
         */
        data class Close(val ms: Long, val outcome: Boolean = true, val laterMs: Long = ms) : Show

        /** The interaction bound elapses after [ms] and the show fails with [code]. */
        data class Bound(val ms: Long, val code: String) : Show
    }

    /**
     * A 1.3 fake supervisor and port. Like the real supervisor it sends one `interaction.started` /
     * `interaction.ended` pair per operation however many shows overlap, writes `ended` before the
     * last show's `rres`, and answers `endInteraction` for a session with no pending show as `cancelled`.
     */
    class FakePort13(private val h: () -> WorkerHarness, private val show: Show, private val events: Boolean = true) : (Frame) -> JsonObject {
        val frames = CopyOnWriteArrayList<Frame>()
        private val sessions = AtomicInteger()
        private val shows = AtomicInteger()
        private val ends = ConcurrentHashMap<String, CompletableFuture<Unit>>()
        private val active = HashMap<String, Int>()
        val hang = CountDownLatch(1)

        val ops: List<String> get() = frames.map { it.op!! }

        override fun invoke(frame: Frame): JsonObject {
            frames += frame
            val p = frame.payload!!
            return when (frame.op) {
                "host.browser.open" -> buildJsonObject { put("session", "s-${sessions.incrementAndGet()}") }
                "host.browser.loadData", "host.browser.load" -> buildJsonObject {
                    put("finalUrl", p.optStr("baseUrl") ?: p.optStr("url")!!)
                    put("status", 200)
                }
                "host.browser.getCookies" -> buildJsonObject { put("cookies", JsonArray(emptyList())) }
                "host.browser.evaluate" -> evaluate(p.optStr("script")!!)
                "host.browser.show" -> show(frame.of!!, p.optStr("session")!!)
                "host.browser.endInteraction" -> {
                    val pending = ends[p.optStr("session")!!] ?: throw WorkerError(ErrorCode.CANCELLED, "no show pending")
                    pending.complete(Unit)
                    JsonObject(emptyMap())
                }
                else -> JsonObject(emptyMap())
            }
        }

        private fun evaluate(script: String): JsonObject = when {
            script.startsWith("new Promise(() =>") -> {
                hang.await(30, TimeUnit.SECONDS)
                throw WorkerError(ErrorCode.CANCELLED, "session closed")
            }
            // The host awaited the promise: the reply carries the settled value, as the desktop helper's wrapper does.
            script.startsWith("new Promise") -> {
                Thread.sleep(200)
                buildJsonObject { put("result", "{\"ok\":1}") }
            }
            script.startsWith("Promise.reject") -> buildJsonObject {
                put("result", "null")
                put("scriptError", "Error: boom")
            }
            script == "1 + 1" -> buildJsonObject { put("result", "2") }
            else -> buildJsonObject { put("result", "null") }
        }

        private fun event(op: String, of: String, key: String, value: Long) {
            if (events) h().client.event(op, buildJsonObject {
                put("of", of)
                put(key, value)
            })
        }

        private fun show(of: String, session: String): JsonObject {
            val started = System.nanoTime()
            val index = shows.getAndIncrement()
            synchronized(active) {
                val n = active.getOrDefault(of, 0)
                active[of] = n + 1
                if (n == 0) event("interaction.started", of, "timeoutMs", TIMEOUT_MS)
            }
            fun end() = synchronized(active) {
                val n = active.getValue(of) - 1
                if (n == 0) active.remove(of) else active[of] = n
                if (n == 0) event("interaction.ended", of, "pausedMs", (System.nanoTime() - started) / 1_000_000)
            }
            try {
                when (show) {
                    is Show.OnEnd -> {
                        val pending = CompletableFuture<Unit>()
                        ends[session] = pending
                        if (show.message) h().client.event("host.browser.message", buildJsonObject {
                            put("session", session)
                            put("name", "bridge")
                            put("message", "solved")
                        })
                        pending.get(10, TimeUnit.SECONDS)
                        ends.remove(session)
                        end()
                        return buildJsonObject { put("outcome", "completed") }
                    }
                    is Show.Close -> {
                        Thread.sleep(if (index == 0) show.ms else show.laterMs)
                        end()
                        return if (show.outcome) buildJsonObject { put("outcome", "closed") } else JsonObject(emptyMap())
                    }
                    is Show.Bound -> {
                        Thread.sleep(show.ms)
                        end()
                        throw WorkerError(show.code, "browser interaction exceeded its ${show.ms} ms bound")
                    }
                }
            } catch (e: java.util.concurrent.TimeoutException) {
                end()
                throw WorkerError(ErrorCode.INTERACTION_REQUIRED, "no endInteraction arrived")
            }
        }

        companion object {
            const val TIMEOUT_MS = 10_000L
        }
    }

    private fun <T> withPort(
        show: Show,
        events: Boolean = true,
        minor: Int = 3,
        platform: WorkerPlatform = mangabackup.tachi.protocol.DesktopPlatform,
        block: (WorkerHarness, FakePort13, WorkerHarness.Loaded) -> T,
    ): T {
        lateinit var h: WorkerHarness
        val port = FakePort13({ h }, show, events)
        h = WorkerHarness(minor = minor, platform = platform)
        return h.use {
            h.client.reverseHandler = port
            try {
                block(h, port, h.loadFixture("webview"))
            } finally {
                port.hang.countDown()
            }
        }
    }

    private fun title(h: WorkerHarness, pkg: WorkerHarness.Loaded, query: String) =
        h.hits(h.search(pkg, query))[0]["title"]!!.jsonPrimitive.content

    private fun events(h: WorkerHarness, op: String) = h.client.transcript.count { it.startsWith(">>") && "\"op\":\"$op\"" in it }

    @Test
    fun `a message on a completion channel ends the show from the frame reader and reads outcome completed`() {
        withPort(Show.OnEnd()) { h, port, pkg ->
            assertEquals("outcome=completed", title(h, pkg, "show"))
            assertEquals(1, port.ops.count { it == "host.browser.endInteraction" }, port.ops.toString())
            val end = port.frames.first { it.op == "host.browser.endInteraction" }
            val show = port.frames.first { it.op == "host.browser.show" }
            assertEquals(show.payload!!.optStr("session"), end.payload!!.optStr("session"))
            assertEquals(show.of, end.of, "endInteraction is sent for the operation whose show is pending")
        }
    }

    @Test
    fun `the extension's own completion signal ends the show`() {
        withPort(Show.OnEnd()) { h, port, pkg ->
            assertEquals("outcome=completed", title(h, pkg, "showexplicit"))
            assertEquals(1, port.ops.count { it == "host.browser.endInteraction" })
        }
    }

    @Test
    fun `a user close reads outcome closed and sends no endInteraction`() {
        withPort(Show.Close(100)) { h, port, pkg ->
            assertEquals("outcome=closed", title(h, pkg, "show"))
            assertTrue("host.browser.endInteraction" !in port.ops)
            // The interaction's cookies are pulled into the package jar before the extension hears the outcome.
            val afterShow = port.ops.subList(port.ops.indexOf("host.browser.show"), port.ops.size)
            assertTrue("host.browser.getCookies" in afterShow, port.ops.toString())
        }
    }

    @Test
    fun `the interaction bound is interaction-required, including an older peer's timeout`() {
        for (code in listOf(ErrorCode.INTERACTION_REQUIRED, ErrorCode.TIMEOUT)) {
            withPort(Show.Bound(100, code)) { h, _, pkg ->
                val e = assertThrows<WorkerError> { h.search(pkg, "show") }
                assertEquals(ErrorCode.INTERACTION_REQUIRED, e.code, "$code: ${e.message}")
                assertEquals("host.browser.show", e.operation)
            }
        }
    }

    @Test
    fun `a bound that the source waits out past the worker deadline is still interaction-required`() {
        // `showignore` keeps waiting after the failed show, so the worker's own deadline stops it later.
        val platform = TestDeadlinePlatform(budgetMs = 1_000)
        withPort(Show.Bound(200, ErrorCode.INTERACTION_REQUIRED), platform = platform) { h, _, pkg ->
            val e = assertThrows<WorkerError> { h.search(pkg, "showignore") }
            assertEquals(ErrorCode.INTERACTION_REQUIRED, e.code, e.message)
            assertTrue(platform.guards.last().expired, "the deadline did not fire; the case proves nothing")
        }
    }

    @Test
    fun `the worker deadline pauses between interaction started and ended`() {
        val platform = TestDeadlinePlatform(budgetMs = 1_500)
        withPort(Show.Close(3_000), platform = platform) { h, _, pkg ->
            assertEquals("outcome=closed", title(h, pkg, "show"))
            val guard = platform.guards.last()
            assertEquals(1, guard.pauses.get())
            assertEquals(1, guard.resumes.get())
            val arms = guard.timer.arms
            assertEquals(3, arms.size, arms.toString())
            assertEquals(1_500L, arms[0])
            assertTrue(arms[1] > FakePort13.TIMEOUT_MS && arms[1] <= FakePort13.TIMEOUT_MS + 1_500, "paused arm $arms")
            assertTrue(arms[2] in 1..1_500, "resumed with the remaining budget: $arms")
            assertTrue(!guard.expired)
        }
    }

    @Test
    fun `without the events the same show runs into the worker deadline`() {
        val platform = TestDeadlinePlatform(budgetMs = 1_500)
        withPort(Show.Close(3_000), events = false, platform = platform) { h, _, pkg ->
            val e = assertThrows<WorkerError> { h.search(pkg, "show") }
            assertEquals(ErrorCode.TIMEOUT, e.code, e.message)
            assertEquals(0, platform.guards.last().pauses.get())
        }
    }

    @Test
    fun `overlapping shows of one operation pause once and resume only when the last ends`() {
        // The first show closes well inside the budget and the second long after it: a worker that resumed on
        // the first show's rres would run into its deadline while the second is still pending.
        val platform = TestDeadlinePlatform(budgetMs = 1_500)
        withPort(Show.Close(300, laterMs = 3_000), platform = platform) { h, port, pkg ->
            assertEquals("outcome=closed,outcome=closed", title(h, pkg, "showtwice"))
            assertEquals(2, port.ops.count { it == "host.browser.show" })
            assertEquals(1, events(h, "interaction.started"))
            assertEquals(1, events(h, "interaction.ended"))
            val guard = platform.guards.last()
            assertEquals(1, guard.pauses.get())
            assertEquals(1, guard.resumes.get())
            assertTrue(!guard.expired)
        }
    }

    @Test
    fun `stray and malformed interaction events are dropped`() {
        val platform = TestDeadlinePlatform(budgetMs = 30_000)
        withPort(Show.Close(50), platform = platform) { h, _, pkg ->
            h.client.event("interaction.ended", buildJsonObject { put("of", "1-999") })
            h.client.event("interaction.started", buildJsonObject { put("of", 7) })
            h.client.event("interaction.started", buildJsonObject { put("timeoutMs", 5) })
            assertEquals("outcome=closed", title(h, pkg, "show"))
        }
    }

    @Test
    fun `a 1_2 supervisor's show has no outcome, and the worker neither sends endInteraction nor pauses`() {
        val platform = TestDeadlinePlatform(budgetMs = 30_000)
        withPort(Show.Close(300, outcome = false), minor = 2, platform = platform) { h, port, pkg ->
            assertEquals("outcome=closed", title(h, pkg, "showexplicit"))
            assertTrue("host.browser.endInteraction" !in port.ops)
            assertEquals(0, platform.guards.last().pauses.get(), "events from a peer that did not negotiate 1.3 are ignored")
        }
    }

    @Test
    fun `endInteraction without protocol 1_3 is reported as a warning`() {
        withPort(Show.Close(300, outcome = false), minor = 2) { h, _, pkg ->
            // `show` completes on a bridge message, which only the fake 1.3 path sends; post one by hand.
            val result = h.client.send("search", pkg.packageId, h.searchPayload(pkg, "show"))
            Thread.sleep(150)
            h.client.event("host.browser.message", buildJsonObject {
                put("session", "s-1")
                put("name", "bridge")
                put("message", "solved")
            })
            val reply = result.second.get(30, TimeUnit.SECONDS)
            val warnings = reply.ok!!["warnings"].toString()
            assertTrue(WebViewTranslation.END_INTERACTION_WARNING in warnings, warnings)
        }
    }

    @Test
    fun `evaluate passes a promise's settled value through, in order with later calls`() {
        withPort(Show.Close(0)) { h, port, pkg ->
            assertEquals("eval={\"ok\":1};2", title(h, pkg, "evalpromise"))
            val evaluates = port.frames.filter { it.op == "host.browser.evaluate" }.map { it.payload!!.optStr("script") }
            assertEquals(2, evaluates.size)
            assertEquals("1 + 1", evaluates[1])
        }
    }

    @Test
    fun `a rejected promise reads as null, like a throwing script`() {
        withPort(Show.Close(0)) { h, _, pkg -> assertEquals("eval=null", title(h, pkg, "evalreject")) }
    }

    @Test
    fun `a promise that never settles waits until the operation is cancelled`() {
        withPort(Show.Close(0)) { h, port, pkg ->
            val (id, reply) = h.client.send("search", pkg.packageId, h.searchPayload(pkg, "evalhang"))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while ("host.browser.evaluate" !in port.ops && System.nanoTime() < deadline) Thread.sleep(20)
            assertTrue("host.browser.evaluate" in port.ops)
            Thread.sleep(200)
            assertTrue(!reply.isDone, "the evaluate did not wait for the promise")
            h.client.cancel(id)
            val frame = reply.get(10, TimeUnit.SECONDS)
            assertEquals(ErrorCode.CANCELLED, WorkerError.fromJson(frame.err!!).code)
        }
    }
}
