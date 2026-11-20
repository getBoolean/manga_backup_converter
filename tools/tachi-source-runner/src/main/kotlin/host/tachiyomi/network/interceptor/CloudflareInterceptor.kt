package eu.kanade.tachiyomi.network.interceptor

import mangabackup.tachi.host.InteractionRequiredException
import mangabackup.tachi.shim.HostFailures
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Desktop replacement for Mihon's WebView-solving Cloudflare interceptor. A
 * Cloudflare challenge needs a visible browser, which the desktop worker can
 * only reach through the supervisor's BrowserPort; until that join (U8) the
 * interceptor detects the challenge page and fails the call as
 * interaction-required instead of returning the challenge HTML as data.
 */
class CloudflareInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        if (response.code !in CHALLENGE_CODES) return response
        val server = response.header("Server").orEmpty()
        val peek = try {
            response.peekBody(PEEK_BYTES).string()
        } catch (_: Exception) {
            return response
        }
        val challenge = CHALLENGE_MARKERS.any { peek.contains(it) } &&
            (server.contains("cloudflare", ignoreCase = true) || peek.contains("cloudflare", ignoreCase = true))
        if (!challenge) return response
        response.close()
        val failure = InteractionRequiredException(
            "Cloudflare challenge at ${chain.request().url.host} needs a visible browser interaction",
            operation = "host.browser.show",
        )
        HostFailures.record(failure)
        throw failure
    }

    private companion object {
        val CHALLENGE_CODES = setOf(403, 429, 503)
        const val PEEK_BYTES = 64L * 1024
        val CHALLENGE_MARKERS = listOf("cf-chl", "challenge-platform", "cf_chl_opt", "Just a moment...")
    }
}

