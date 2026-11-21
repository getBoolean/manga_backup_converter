package eu.kanade.tachiyomi.network.interceptor

import mangabackup.tachi.host.InteractionRequiredException
import mangabackup.tachi.shim.HostFailures
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Replacement for Mihon's WebView-solving Cloudflare interceptor. It detects
 * the challenge page instead of returning its HTML as data.
 *
 * - With a [challengeSolver] (Android, interactive runs: the service shows
 *   the challenge in its visible challenge Activity), the solver runs once;
 *   when it reports the challenge closed, the request is sent again, carrying
 *   the cookies the browser acquired (see [mangabackup.tachi.host.PackageCookieJar]).
 * - Without one (desktop, iOS, unattended Android), or when the challenge is
 *   still there, the call fails as interaction-required.
 */
class CloudflareInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        if (!isChallenge(response)) return response
        response.close()
        val solver = challengeSolver
        val userAgent = chain.request().header("User-Agent")
        if (solver != null && solver(chain.request().url.toString(), userAgent)) {
            val retried = chain.proceed(chain.request())
            if (!isChallenge(retried)) return retried
            retried.close()
        }
        val failure = InteractionRequiredException(
            "Cloudflare challenge at ${chain.request().url.host} needs a visible browser interaction",
            operation = "host.browser.show",
        )
        HostFailures.record(failure)
        throw failure
    }

    private fun isChallenge(response: Response): Boolean {
        if (response.code !in CHALLENGE_CODES) return false
        val server = response.header("Server").orEmpty()
        val peek = try {
            response.peekBody(PEEK_BYTES).string()
        } catch (_: Exception) {
            return false
        }
        return CHALLENGE_MARKERS.any { peek.contains(it) } &&
            (server.contains("cloudflare", ignoreCase = true) || peek.contains("cloudflare", ignoreCase = true))
    }

    companion object {
        /**
         * Shows a challenge at a URL to the user with the request's user agent
         * and returns whether the user finished it (true) or it could not be
         * shown or timed out (false). Set by the Android service in
         * interactive runs only; `null` everywhere else.
         */
        @Volatile
        var challengeSolver: ((url: String, userAgent: String?) -> Boolean)? = null

        private val CHALLENGE_CODES = setOf(403, 429, 503)
        const val PEEK_BYTES = 64L * 1024
        val CHALLENGE_MARKERS = listOf("cf-chl", "challenge-platform", "cf_chl_opt", "Just a moment...")
    }
}

