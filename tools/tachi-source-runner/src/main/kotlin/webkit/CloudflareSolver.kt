package mangabackup.tachi.webkit

import eu.kanade.tachiyomi.network.interceptor.CloudflareChallenge
import eu.kanade.tachiyomi.network.interceptor.CloudflareChallengeSolver
import eu.kanade.tachiyomi.network.interceptor.CloudflareSolution
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import mangabackup.tachi.host.HostCancelledException
import mangabackup.tachi.host.HostOperationException
import mangabackup.tachi.host.InteractionRequiredException
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.HostBrowserClose
import mangabackup.tachi.protocol.HostBrowserEvaluate
import mangabackup.tachi.protocol.HostBrowserEvaluated
import mangabackup.tachi.protocol.HostBrowserLoad
import mangabackup.tachi.protocol.HostBrowserOp
import mangabackup.tachi.protocol.HostBrowserOpen
import mangabackup.tachi.protocol.HostBrowserOpened
import mangabackup.tachi.protocol.HostBrowserRequest
import mangabackup.tachi.protocol.HostBrowserShow
import mangabackup.tachi.protocol.HostBrowserShown
import mangabackup.tachi.protocol.Wire
import mangabackup.tachi.protocol.WorkerError
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Solves a Cloudflare challenge in the supervisor's browser (KTD20, protocol 1.3 `host.browser.show`).
 *
 * Installed by the desktop worker's `--interactive-challenges MS` (interactive runs; the CLI passes it only
 * then). Opens a session for the operation's source with the request's user agent, pushes the package's
 * cookies, loads the challenged URL with the request's headers, and shows the window. The port still
 * decides whether a window may appear: an unattended port answers the show with interaction-required. While the show is pending the solver polls the session's cookies; a new
 * `cf_clearance` is the page's completion signal, so it sends `host.browser.endInteraction`, which hides
 * the window. The supervisor pauses the operation's deadline for the whole show and tells the worker
 * (`interaction.started` / `interaction.ended`), so the worker's own deadline is paused too.
 *
 * Afterwards the session's cookies go into the challenged package's own jar (cookies never cross packages,
 * and each session's storage is deleted when it closes) and the browser's `navigator.userAgent` is
 * returned for the interceptor to pin. A show is given up after [boundMs] (the flag's bound) even if the
 * supervisor's own interaction bound is longer. A window the user closed without a clearance, the interaction
 * bound, and an unattended run are interaction-required; a cancelled operation is cancelled. The session
 * is closed in every case.
 */
class CloudflareSolver(private val bridge: BrowserBridge, private val boundMs: Long) : CloudflareChallengeSolver {
    override fun solve(challenge: CloudflareChallenge): CloudflareSolution {
        val request = challenge.request
        val environment: PackageEnvironment = challenge.environment
            ?: throw InteractionRequiredException("Cloudflare challenge outside a package", SHOW)
        val operation = environment.currentOperation
            ?: throw InteractionRequiredException("Cloudflare challenge outside a source operation", SHOW)
        val sourceId = operation.sourceId
            ?: throw InteractionRequiredException("Cloudflare challenge outside a source operation", SHOW)
        // Without endInteraction the show could only end when the user closes the window.
        if (!bridge.supports(HostBrowserOp.END_INTERACTION)) {
            throw InteractionRequiredException(
                "Cloudflare challenge at ${request.url.host}: the supervisor speaks protocol 1.${bridge.protocolMinor}, " +
                    "which cannot end a shown window on completion",
                SHOW,
            )
        }
        fun call(r: HostBrowserRequest): JsonObject = await(bridge.request(environment, r))
        val cookies = BrowserCookies(environment.cookieJar, ::call)
        val url = request.url.toString()
        val userAgent = request.header(USER_AGENT) ?: environment.defaultUserAgent
        val session = Wire.decode<HostBrowserOpened>(call(HostBrowserOpen(sourceId, userAgent)), "host.browser.open reply").session
            ?: throw WorkerError(ErrorCode.PROTOCOL_VIOLATION, "host.browser.open reply has no session")
        try {
            cookies.push(session, url)
            val before = clearance(cookies, session, url)
            val forwarded = request.headers.filter { (name, _) -> name.lowercase() !in UNFORWARDED_HEADERS }
            call(HostBrowserLoad(session, url, forwarded.associate { it.first to it.second }))
            val outcome = show(environment, cookies, session, url, before) { operation.isCancelled }
            cookies.pull(session, url)
            val after = clearance(cookies, session, url)
            if (after == null || after == before) {
                throw InteractionRequiredException(
                    "Cloudflare challenge at ${request.url.host}: the browser window was $outcome without a clearance",
                    SHOW,
                )
            }
            val evaluated = Wire.decode<HostBrowserEvaluated>(call(HostBrowserEvaluate(session, "navigator.userAgent")), "host.browser.evaluate reply").result
            val browserUserAgent = evaluated?.let { runCatching { (Json.parseToJsonElement(it) as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }.getOrNull() }
            return CloudflareSolution(browserUserAgent ?: userAgent)
        } finally {
            try {
                bridge.request(environment, HostBrowserClose(session)).get(bridge.closeWaitMs, TimeUnit.MILLISECONDS)
            } catch (_: Exception) {
                // The supervisor deletes the session's storage when the operation's generation is fenced or closed.
            }
        }
    }

    /**
     * Sends `host.browser.show` and waits for it, polling the session's cookies; returns the outcome
     * (`completed` or `closed`). Ends the show once a new clearance appears.
     */
    private fun show(
        environment: PackageEnvironment,
        cookies: BrowserCookies,
        session: String,
        url: String,
        before: String?,
        cancelled: () -> Boolean,
    ): String {
        val shown = bridge.request(environment, HostBrowserShow(session))
        val giveUpAt = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(boundMs)
        var ended = false
        while (true) {
            try {
                return Wire.decode<HostBrowserShown>(await(shown, POLL_MS), "host.browser.show reply").outcome ?: OUTCOME_CLOSED
            } catch (_: TimeoutException) {
                // Still showing.
            }
            if (cancelled()) {
                shown.cancel(false)
                throw HostCancelledException("Cloudflare challenge cancelled with its operation")
            }
            if (System.nanoTime() > giveUpAt) {
                shown.cancel(false)
                throw InteractionRequiredException("Cloudflare challenge not finished within $boundMs ms", SHOW)
            }
            if (!ended) {
                val now = try {
                    clearance(cookies, session, url)
                } catch (e: HostOperationException) {
                    if (e.code == ErrorCode.CANCELLED) null else throw e
                }
                if (now != null && now != before) {
                    ended = true
                    bridge.endInteraction(environment, session)
                }
            }
        }
    }

    private fun clearance(cookies: BrowserCookies, session: String, url: String): String? =
        cookies.read(session, url).firstOrNull { it.name == CLEARANCE_COOKIE }?.value

    /** Waits for a reverse request, mapping its protocol error to the host failure the worker reports. */
    private fun await(future: CompletableFuture<JsonObject>, timeoutMs: Long? = null): JsonObject {
        try {
            return if (timeoutMs == null) future.get() else future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: ExecutionException) {
            val cause = e.cause ?: e
            if (cause !is WorkerError) throw cause
            throw when (cause.code) {
                // The interaction bound; an older peer reports it as timeout.
                ErrorCode.INTERACTION_REQUIRED, ErrorCode.TIMEOUT ->
                    InteractionRequiredException(cause.message ?: "browser interaction required", cause.operation ?: SHOW, cause)
                ErrorCode.CANCELLED -> HostCancelledException(cause.message ?: "cancelled")
                else -> HostOperationException(cause.message ?: cause.code, cause.code, cause.operation, cause)
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw HostCancelledException("Cloudflare challenge interrupted")
        }
    }

    private companion object {
        val SHOW = HostBrowserOp.SHOW.wire
        const val USER_AGENT = "User-Agent"
        const val CLEARANCE_COOKIE = "cf_clearance"
        const val OUTCOME_CLOSED = "closed"
        const val POLL_MS = 500L

        /** Headers the browser sets itself (cookies come from the jar, the user agent from the session). */
        val UNFORWARDED_HEADERS = setOf("cookie", "user-agent", "host", "content-length", "connection", "accept-encoding", "transfer-encoding")
    }
}
