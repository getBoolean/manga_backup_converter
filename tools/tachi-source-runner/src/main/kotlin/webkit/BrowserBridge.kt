package mangabackup.tachi.webkit

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import mangabackup.tachi.host.CapabilityUnavailableException
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.Worker
import mangabackup.tachi.protocol.WorkerError
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Worker side of the KTD20 browser translation: turns WebView shim calls into
 * `host.browser.*` reverse requests for the package's in-flight operation, and
 * routes `host.browser.message` and (1.2) `host.browser.request` events back to
 * the WebView that owns the session. Sessions are closed before their operation
 * replies, because no reverse request may follow the reply.
 */
class BrowserBridge(private val worker: Worker) {
    private val sessionsByOperation = ConcurrentHashMap<String, MutableSet<WebViewTranslation>>()
    private val bySession = ConcurrentHashMap<String, WebViewTranslation>()

    /** The minor protocol version agreed with the supervisor. */
    val protocolMinor: Long get() = worker.protocolMinor

    /** Allowed navigation targets (KTD20): http(s) and about:blank. */
    fun isNavigable(url: String): Boolean = url == "about:blank" || isWebUrl(url)

    fun isWebUrl(url: String): Boolean {
        val uri = try {
            java.net.URI(url)
        } catch (_: Exception) {
            return false
        }
        val scheme = uri.scheme?.lowercase() ?: return false
        return (scheme == "http" || scheme == "https") && !uri.host.isNullOrEmpty()
    }

    fun request(environment: PackageEnvironment, op: String, payload: JsonObject): CompletableFuture<JsonObject> {
        val operation = environment.currentOperation
            ?: return CompletableFuture.failedFuture(
                CapabilityUnavailableException("$op outside an operation: no request can carry it", op),
            )
        return worker.reverseRequest(operation.requestId, op, payload)
    }

    fun register(operationId: String, view: WebViewTranslation) {
        sessionsByOperation.computeIfAbsent(operationId) { ConcurrentHashMap.newKeySet() } += view
    }

    fun bindSession(session: String, view: WebViewTranslation) {
        bySession[session] = view
    }

    fun unbindSession(session: String) {
        bySession.remove(session)
    }

    /** A `host.browser.message` event. A malformed one (for example a non-string message) is dropped, never fatal. */
    fun onMessage(payload: JsonObject) {
        fun str(key: String) = (payload[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val session = str("session") ?: return
        val name = str("name") ?: return
        val message = str("message") ?: return
        bySession[session]?.deliverMessage(name, message)
    }

    /**
     * A `host.browser.request` event (1.2), called on the frame reader thread. Only decoding and
     * routing happen here; the extension's `shouldInterceptRequest` runs on a browser thread, so a
     * handler that blocks (or makes its own reverse request) cannot stop the reader from delivering
     * the `rres` frames everything else is waiting for. A malformed event is dropped.
     */
    fun onRequest(payload: JsonObject) {
        val event = BrowserRequestEvent.parse(payload) ?: return
        bySession[event.session]?.onPlatformRequest(event)
    }

    /**
     * Sends `host.browser.respond` without waiting for its `rres`: the reply arrives on the frame
     * reader, which must never block on it. Not sent when none of the package's operations is in
     * flight (the orphan rule); the held request then proceeds after the supervisor's timeout.
     */
    fun respond(environment: PackageEnvironment, payload: JsonObject) {
        val operation = environment.currentOperation ?: return
        worker.reverseRequest(operation.requestId, "host.browser.respond", payload).exceptionally { null }
    }

    /** Closes every session an operation opened; bounded so a stuck port cannot hold the reply. */
    fun closeSessionsOf(operationId: String) {
        val views = sessionsByOperation.remove(operationId) ?: return
        val closes = views.mapNotNull { it.closeSession() }
        for (c in closes) {
            try {
                c.get(CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)
            } catch (_: Exception) {
                // The supervisor deletes the session's storage when it fences or closes it.
            }
        }
    }

    fun cancelOperation(operationId: String) {
        sessionsByOperation[operationId]?.forEach { it.cancelPending() }
    }

    fun operationFinished(operationId: String) {
        sessionsByOperation.remove(operationId)?.forEach { it.cancelPending() }
    }

    companion object {
        const val CLOSE_WAIT_MS = 2_000L

        fun isCapabilityFailure(t: Throwable): Boolean {
            val e = generateSequence(t) { it.cause }.firstOrNull { it is WorkerError } as? WorkerError ?: return false
            return e.code == ErrorCode.CAPABILITY_UNAVAILABLE || e.code == ErrorCode.INTERACTION_REQUIRED
        }
    }
}

