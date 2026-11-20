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
 * routes `host.browser.message` events back to the WebView that registered the
 * channel. Sessions are closed before their operation replies, because no
 * reverse request may follow the reply.
 */
class BrowserBridge(private val worker: Worker) {
    private val sessionsByOperation = ConcurrentHashMap<String, MutableSet<WebViewTranslation>>()
    private val bySession = ConcurrentHashMap<String, WebViewTranslation>()

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

