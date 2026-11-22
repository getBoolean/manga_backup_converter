package mangabackup.tachi

import eu.kanade.tachiyomi.network.interceptor.CloudflareChallengeSolver
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.CloudflareSolution
import mangabackup.tachi.host.InteractionRequiredException
import mangabackup.tachi.host.PackageCookieJar
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.util.concurrent.CopyOnWriteArrayList

/**
 * U12 (carried from U11): cookies a WebView acquired reach the package's HTTP
 * jar, and a Cloudflare challenge goes to the platform's challenge solver
 * when one is installed (Android interactive runs), else fails as
 * interaction-required.
 */
class BrowserCookiesAndChallengeTest {
    @AfterEach
    fun reset() {
        CloudflareInterceptor.challengeSolver = null
    }

    @Test
    fun `browser cookies are copied into the package jar on each request`() {
        val jar = PackageCookieJar()
        val browser = CopyOnWriteArrayList<Cookie>()
        jar.browserCookies = { url -> browser.filter { it.matches(url) } }
        val url = "https://site.test/page".toHttpUrl()
        assertTrue(jar.loadForRequest(url).isEmpty())
        browser += Cookie.Builder().name("cf_clearance").value("ok").hostOnlyDomain("site.test").path("/").build()
        assertEquals(listOf("cf_clearance"), jar.loadForRequest(url).map { it.name })
        // The copy stays in the package's jar after the browser store is wiped.
        browser.clear()
        assertEquals(listOf("cf_clearance"), jar.all().map { it.name })
        assertTrue(jar.loadForRequest("https://other.test/".toHttpUrl()).isEmpty())
    }

    @Test
    fun `a failing browser reader never breaks the request`() {
        val jar = PackageCookieJar()
        jar.browserCookies = { throw IllegalStateException("main looper timed out") }
        assertTrue(jar.loadForRequest("https://site.test/".toHttpUrl()).isEmpty())
    }

    /**
     * Answers like Cloudflare until the package jar holds cf_clearance for the
     * URL. An application interceptor after [CloudflareInterceptor], so no
     * connection or DNS lookup ever happens; it reads the jar as OkHttp's
     * bridge would for the Cookie header.
     */
    private class CloudflareSite(private val jar: PackageCookieJar) : Interceptor {
        val seen = CopyOnWriteArrayList<String>()

        override fun intercept(chain: Interceptor.Chain): Response {
            val cookie = jar.loadForRequest(chain.request().url).joinToString("; ") { "${it.name}=${it.value}" }
            seen += cookie
            val cleared = cookie.contains("cf_clearance=")
            val body = if (cleared) "<html>ok</html>" else "<html><title>Just a moment...</title><script src=\"/cdn-cgi/challenge-platform/x.js\"></script></html>"
            return Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(if (cleared) 200 else 403)
                .message("x")
                .header("Server", "cloudflare")
                .body(body.toResponseBody("text/html".toMediaType()))
                .build()
        }
    }

    private fun client(jar: PackageCookieJar, site: CloudflareSite) = OkHttpClient.Builder()
        .cookieJar(jar)
        .addInterceptor(CloudflareInterceptor())
        .addInterceptor(site)
        .build()

    private fun request() = Request.Builder().url("https://site.test/manga").header("User-Agent", "UA/1").build()

    @Test
    fun `without a solver a challenge fails as interaction-required`() {
        val jar = PackageCookieJar()
        val site = CloudflareSite(jar)
        assertThrows<InteractionRequiredException> { client(jar, site).newCall(request()).execute() }
        assertEquals(1, site.seen.size)
    }

    @Test
    fun `a solved challenge retries once with the cookies the browser acquired`() {
        val jar = PackageCookieJar()
        val browser = CopyOnWriteArrayList<Cookie>()
        jar.browserCookies = { url -> browser.filter { it.matches(url) } }
        val shown = CopyOnWriteArrayList<Pair<String, String?>>()
        CloudflareInterceptor.challengeSolver = CloudflareChallengeSolver { challenge ->
            shown += challenge.url to challenge.userAgent
            browser += Cookie.Builder().name("cf_clearance").value("solved").hostOnlyDomain("site.test").path("/").build()
            CloudflareSolution()
        }
        val site = CloudflareSite(jar)
        client(jar, site).newCall(request()).execute().use { assertEquals(200, it.code) }
        assertEquals(listOf("https://site.test/manga" to "UA/1"), shown.toList())
        assertEquals(2, site.seen.size)
    }

    @Test
    fun `a challenge the user did not finish fails as interaction-required`() {
        val jar = PackageCookieJar()
        CloudflareInterceptor.challengeSolver = CloudflareChallengeSolver { null }
        val site = CloudflareSite(jar)
        assertThrows<InteractionRequiredException> { client(jar, site).newCall(request()).execute() }
        assertEquals(1, site.seen.size)
    }
}
