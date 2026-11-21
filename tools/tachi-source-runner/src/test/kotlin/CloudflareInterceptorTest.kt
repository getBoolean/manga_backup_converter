package mangabackup.tachi

import eu.kanade.tachiyomi.network.interceptor.CloudflareChallengeSolver
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.CloudflareSolution
import mangabackup.tachi.host.InteractionRequiredException
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Cookie
import okhttp3.Headers
import okhttp3.Request
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * The interceptor's side of the browser solve (the solver itself runs against the real helper in the CLI's
 * `tachi_cloudflare_challenge_test.dart`): detection, retry with the clearance and the pinned user agent,
 * single-flight solves, and interaction-required when there is no solver or the retry is still challenged.
 */
class CloudflareInterceptorTest {
    private lateinit var server: MockWebServer
    private val passing = AtomicInteger()

    /** Serves 200 only to a request carrying `cf_clearance=ok` and the browser user agent. */
    private val site = object : Dispatcher() {
        override fun dispatch(request: RecordedRequest): MockResponse {
            val cookie = request.headers["Cookie"].orEmpty()
            val ua = request.headers["User-Agent"].orEmpty()
            return if ("cf_clearance=ok" in cookie && ua == BROWSER_UA) {
                passing.incrementAndGet()
                MockResponse.Builder().code(200).body("passed").build()
            } else {
                MockResponse.Builder().code(403)
                    .headers(Headers.headersOf("Server", "cloudflare", "Content-Type", "text/html"))
                    .body("<title>Just a moment...</title><script src=/cdn-cgi/challenge-platform/x.js></script>")
                    .build()
            }
        }
    }

    @BeforeEach
    fun start() {
        server = MockWebServer()
        server.dispatcher = site
        server.start()
    }

    @AfterEach
    fun stop() {
        CloudflareInterceptor.challengeSolver = null
        server.close()
    }

    private fun get(env: mangabackup.tachi.host.PackageEnvironment) =
        env.network.client.newCall(Request.Builder().url(server.url("/page")).header("User-Agent", "Extension/1.0").build())

    /** A solver that "solves" by putting the clearance into the jar, as the real one does via getCookies. */
    private fun solving(count: AtomicInteger, delayMs: Long = 0) = CloudflareChallengeSolver { challenge ->
        val request = challenge.request
        count.incrementAndGet()
        Thread.sleep(delayMs)
        challenge.environment!!.cookieJar.saveFromResponse(request.url, listOf(Cookie.Builder().name("cf_clearance").value("ok").domain(request.url.host).path("/").build()))
        CloudflareSolution(BROWSER_UA)
    }

    @Test
    fun `without a solver a challenge fails as interaction-required`() {
        val env = TestSupport.environment("fixture.cf1")
        val e = assertThrows<InteractionRequiredException> { get(env).execute() }
        assertEquals("host.browser.show", e.operation)
    }

    @Test
    fun `a solved challenge retries with the clearance and the pinned browser user agent`() {
        val solves = AtomicInteger()
        CloudflareInterceptor.challengeSolver = solving(solves)
        val env = TestSupport.environment("fixture.cf2")
        get(env).execute().use { assertEquals("passed", it.body.string()) }
        // Later requests carry the pinned user agent without solving again.
        get(env).execute().use { assertEquals(200, it.code) }
        assertEquals(1, solves.get())
        assertEquals(2, passing.get())
    }

    @Test
    fun `concurrent challenged requests share one solve`() {
        val solves = AtomicInteger()
        CloudflareInterceptor.challengeSolver = solving(solves, delayMs = 300)
        val env = TestSupport.environment("fixture.cf3")
        val pool = Executors.newFixedThreadPool(3)
        try {
            val codes = pool.invokeAll(List(3) { Callable { get(env).execute().use { it.code } } }).map { it.get() }
            assertEquals(listOf(200, 200, 200), codes)
        } finally {
            pool.shutdownNow()
        }
        assertEquals(1, solves.get())
    }

    @Test
    fun `a solve longer than the call timeout does not time the call out`() {
        // The interaction bound (minutes) is far longer than a client's callTimeout; the user's time in the
        // browser must not count against the HTTP call.
        CloudflareInterceptor.challengeSolver = solving(AtomicInteger(), delayMs = 900)
        val env = TestSupport.environment("fixture.cf6")
        val client = env.network.client.newBuilder().callTimeout(java.time.Duration.ofMillis(400)).build()
        client.newCall(Request.Builder().url(server.url("/page")).header("User-Agent", "Extension/1.0").build()).execute()
            .use { assertEquals(200, it.code) }
    }

    @Test
    fun `a retry that is still challenged is interaction-required`() {
        CloudflareInterceptor.challengeSolver = CloudflareChallengeSolver { CloudflareSolution("Other/1.0") }
        val env = TestSupport.environment("fixture.cf4")
        val e = assertThrows<InteractionRequiredException> { get(env).execute() }
        assertTrue("still challenges" in e.message!!)
    }

    @Test
    fun `a solver failure propagates unchanged`() {
        CloudflareInterceptor.challengeSolver = CloudflareChallengeSolver { throw InteractionRequiredException("closed", "host.browser.show") }
        val env = TestSupport.environment("fixture.cf5")
        val e = assertThrows<InteractionRequiredException> { get(env).execute() }
        assertEquals("closed", e.message)
    }

    private companion object {
        const val BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Browser/1.0"
    }
}
