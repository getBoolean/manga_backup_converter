package eu.kanade.tachiyomi.network.interceptor

import mangabackup.tachi.host.HostOperationException
import mangabackup.tachi.host.InteractionRequiredException
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.shim.HostFailures
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import okio.AsyncTimeout
import java.util.concurrent.ConcurrentHashMap

/**
 * Replacement for Mihon's WebView-solving Cloudflare interceptor. It detects the challenge page instead
 * of returning its HTML as data.
 *
 * - With a [challengeSolver] (interactive runs, installed by the worker's `--interactive-challenges MS`
 *   flag): the solver shows the challenge to the user. The Android service opens its visible challenge
 *   Activity; the desktop worker shows the supervisor's browser window (`host.browser.show`). When it
 *   reports the challenge finished, the request is sent again once, carrying the cookies the browser
 *   acquired (on Android through [mangabackup.tachi.host.PackageCookieJar.browserCookies]; on desktop the
 *   solver copied them into the package's own jar) and, when the solver reports one, the browser's user
 *   agent, which Cloudflare binds the clearance to: it is pinned for the host so later requests match.
 * - Without one (unattended runs), or when the challenge is still there, the call fails as
 *   interaction-required.
 *
 * Solves are single-flight per host: a request that waited for another thread's solve retries with its
 * clearance before starting a second one. While a solver runs, the operation's own platform deadline is
 * paused ([mangabackup.tachi.host.OperationContext.pauseDeadline]); the desktop supervisor pauses its
 * deadline for the shown window itself.
 */
class CloudflareInterceptor(private val environment: PackageEnvironment? = null) : Interceptor {
    /** The user agent a solved clearance is bound to, by host. */
    private val pinnedUserAgents = ConcurrentHashMap<String, String>()
    private val locks = ConcurrentHashMap<String, Any>()

    /** Completed solves by host, so a request that waited on another thread's solve does not solve again. */
    private val solvedGenerations = ConcurrentHashMap<String, Int>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = withPinnedUserAgent(chain.request())
        val host = request.url.host
        // Read before the request goes out: a solve another thread finishes while this request is in flight
        // must count, or this request would solve again against a page that no longer challenges.
        val generationBefore = generation(host)
        val response = chain.proceed(request)
        if (!isChallenge(response)) return response
        response.close()
        val solver = challengeSolver ?: throw interactionRequired(host, null)
        // The user's time in the browser (bounded by the interaction limit, minutes) must not count against the
        // call's own timeout: stop it while waiting for and running the solve, and start it afresh for the retry.
        val callTimeout = chain.call().timeout() as? AsyncTimeout
        callTimeout?.exit()
        try {
            synchronized(locks.computeIfAbsent(host) { Any() }) {
                if (generation(host) == generationBefore) {
                    val solution = solve(solver, CloudflareChallenge(request, environment))
                        ?: throw interactionRequired(host, "the challenge was not finished")
                    solution.userAgent?.let { pinnedUserAgents[host] = it }
                    solvedGenerations.merge(host, 1, Int::plus)
                }
            }
        } finally {
            callTimeout?.enter()
        }
        val retry = chain.proceed(withPinnedUserAgent(chain.request()))
        if (!isChallenge(retry)) return retry
        retry.close()
        throw interactionRequired(host, "the challenge was finished in the browser, but the site still challenges the request")
    }

    private fun solve(solver: CloudflareChallengeSolver, challenge: CloudflareChallenge): CloudflareSolution? {
        val operation = environment?.currentOperation
        operation?.pauseDeadline()
        try {
            return solver.solve(challenge)
        } catch (e: HostOperationException) {
            HostFailures.record(e)
            throw e
        } finally {
            operation?.resumeDeadline()
        }
    }

    private fun generation(host: String): Int = solvedGenerations[host] ?: 0

    private fun withPinnedUserAgent(request: Request): Request {
        val ua = pinnedUserAgents[request.url.host] ?: return request
        return if (request.header(USER_AGENT) == ua) request else request.newBuilder().header(USER_AGENT, ua).build()
    }

    private fun interactionRequired(host: String, detail: String?): InteractionRequiredException {
        val failure = InteractionRequiredException(
            "Cloudflare challenge at $host needs a visible browser interaction" + (detail?.let { ": $it" } ?: ""),
            operation = "host.browser.show",
        )
        HostFailures.record(failure)
        return failure
    }

    companion object {
        /** Installed by the worker in interactive runs only (`--interactive-challenges`); `null` everywhere else. */
        @Volatile
        var challengeSolver: CloudflareChallengeSolver? = null

        internal const val USER_AGENT = "User-Agent"
        private val CHALLENGE_CODES = setOf(403, 429, 503)
        const val PEEK_BYTES = 64L * 1024
        val CHALLENGE_MARKERS = listOf("cf-chl", "challenge-platform", "cf_chl_opt", "Just a moment...")

        /** A Cloudflare challenge: a challenge status and `cf-mitigated: challenge`, or a marker and Cloudflare named. */
        fun isChallenge(response: Response): Boolean {
            if (response.code !in CHALLENGE_CODES) return false
            if (response.header("cf-mitigated").equals("challenge", ignoreCase = true)) return true
            val server = response.header("Server").orEmpty()
            val peek = try {
                response.peekBody(PEEK_BYTES).string()
            } catch (_: Exception) {
                return false
            }
            return CHALLENGE_MARKERS.any { peek.contains(it) } &&
                (server.contains("cloudflare", ignoreCase = true) || peek.contains("cloudflare", ignoreCase = true))
        }
    }
}

// The solver types are top-level, not nested in CloudflareInterceptor: resolving a nested type walks the
// outer class's supertypes (okhttp3.Interceptor), which the Android service module that installs its solver
// does not have on its compile classpath.

/** A challenged request: [url] and [userAgent] as sent, and the package it belongs to (`null` in tests). */
class CloudflareChallenge(val request: Request, val environment: PackageEnvironment?) {
    val url: String get() = request.url.toString()
    val userAgent: String? get() = request.header(CloudflareInterceptor.USER_AGENT)
}

/** A finished challenge: the user agent the browser presented while solving, when the solver knows it. */
data class CloudflareSolution(val userAgent: String? = null)

/**
 * Shows a Cloudflare challenge to the user and returns a [CloudflareSolution] when they finished it, or
 * `null` when it could not be shown or was not finished. May instead throw a host failure
 * (interaction-required with the reason, cancelled), which the operation reports.
 */
fun interface CloudflareChallengeSolver {
    fun solve(challenge: CloudflareChallenge): CloudflareSolution?
}
