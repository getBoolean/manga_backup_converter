package mangabackup.tachi.webkit

import android.net.Uri
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import androidx.webkit.ScriptHandler
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import mangabackup.tachi.host.CapabilityUnavailableException
import mangabackup.tachi.host.HostOperationException
import mangabackup.tachi.host.InteractionRequiredException
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.WorkerError
import mangabackup.tachi.protocol.optStr
import mangabackup.tachi.shim.WebViewBackend
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.lang.reflect.Method
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * One android.webkit.WebView translated to a BrowserPort session (KTD20).
 *
 * Calls arrive on the main looper and return at once; the browser work runs on
 * a bridge thread as an ordered chain of reverse requests, and results come
 * back to the main looper as WebViewClient callbacks, as on Android.
 *
 * Supported: load URL / load data with an http(s) base URL, evaluate script,
 * user agent, cookies (synced with the package jar around each load), and
 * `addJavascriptInterface` objects reached through the protocol 1.1 browser
 * message channel: the platform installs `window.<name>.postMessage(string)`
 * in every same-origin http(s) page, so only the object's
 * `@JavascriptInterface void postMessage(String)` is reachable, and `<name>`
 * must be a plain JavaScript identifier (any identifier, `ipc` included). The
 * platform drops other-origin, opaque-origin and non-string messages.
 *
 * Protocol 1.2 (only when negotiated; the session's `capabilities` decide):
 * - `WebViewCompat.addDocumentStartJavaScript` -> `host.browser.addPageStartScript`,
 *   with `allowedOriginRules` emulated by [OriginRules]. `ScriptHandler.remove()`
 *   throws `UnsupportedOperationException` and warns: the port cannot remove a script.
 * - `shouldInterceptRequest`: the replace tier when the session has
 *   `replaceRequests` (falling back to observe if the supervisor refuses it),
 *   otherwise observe; held requests are answered with `host.browser.respond`.
 *   A non-null response on an observe-only session is a named capability error.
 * - `evaluate`'s `scriptError` is ignored, keeping Android's `evaluateJavascript`
 *   semantics (a throwing script yields `"null"`).
 * Without 1.2, or with no observe feature, interception falls back to calling
 * `shouldInterceptRequest` for main-frame `loadUrl` navigations only. A
 * synchronous `@JavascriptInterface` return value and non-http(s) schemes are
 * named capability errors.
 */
class WebViewTranslation(private val view: WebView, private val bridge: BrowserBridge) : WebViewBackend {
    private val environment: PackageEnvironment = PackageEnvironment.of(view.context)
    private val operationId: String? = environment.currentOperation?.requestId
    private val sourceId: String? = environment.currentOperation?.sourceId
    private var chain: CompletableFuture<Any?> = CompletableFuture.completedFuture(null)
    private val interfaces = ConcurrentHashMap<String, Any>()

    /** Page-start scripts (already origin-wrapped) in registration order, replayed when the session opens. */
    private val pageStartScripts = java.util.concurrent.CopyOnWriteArrayList<String>()

    /** Features of the open session (1.2); empty without capabilities. */
    @Volatile
    private var available: Set<String> = emptySet()

    /** The interception mode set on the session: `none`, `observe` or `replace`. */
    @Volatile
    private var interception = MODE_NONE

    @Volatile
    private var session: String? = null

    @Volatile
    private var userAgent: String? = null

    @Volatile
    private var currentUrl: String? = null

    @Volatile
    private var closed = false

    init {
        operationId?.let { bridge.register(it, this) }
    }

    private fun enqueue(step: () -> Any?) {
        synchronized(this) {
            chain = chain.handleAsync({ _, _ -> null }, EXECUTOR).thenApplyAsync({ if (closed) null else step() }, EXECUTOR)
            chain.exceptionally { failure -> onFailure(failure); null }
        }
    }

    private fun call(op: String, payload: JsonObject): JsonObject =
        try {
            bridge.request(environment, op, payload).get()
        } catch (e: java.util.concurrent.ExecutionException) {
            throw e.cause ?: e
        }

    private fun requireSession(): String {
        session?.let { return it }
        val payload = buildJsonObject {
            put("sourceId", sourceId ?: throw CapabilityUnavailableException("WebView outside a source operation", "host.browser.open"))
            userAgent?.let { put("userAgent", it) }
        }
        val reply = call("host.browser.open", payload)
        val opened = reply.optStr("session")
            ?: throw WorkerError(ErrorCode.PROTOCOL_VIOLATION, "host.browser.open reply has no session")
        if (bridge.protocolMinor >= 2) available = BrowserFeature.available(reply)
        session = opened
        bridge.bindSession(opened, this)
        // Channel objects first, then page-start scripts in registration order (protocol 1.2 order rule).
        for (name in interfaces.keys) setHandler(opened, name, true)
        for (script in pageStartScripts) sendPageStartScript(opened, script, reply)
        configureInterception(opened, reply)
        return opened
    }

    private fun sendPageStartScript(session: String, script: String, openReply: JsonObject? = null) {
        if (bridge.protocolMinor < 2 || BrowserFeature.PAGE_START_SCRIPTS !in available) {
            val reason = openReply?.let { BrowserFeature.reason(it, BrowserFeature.PAGE_START_SCRIPTS) }
                ?: if (bridge.protocolMinor < 2) "the supervisor speaks protocol 1.${bridge.protocolMinor}" else "not reported by the browser implementation"
            throw CapabilityUnavailableException("addDocumentStartJavaScript needs pageStartScripts, which this browser session lacks: $reason", "addPageStartScript")
        }
        call("host.browser.addPageStartScript", buildJsonObject {
            put("session", session)
            put("script", script)
        })
    }

    private fun overridesIntercept(): Boolean =
        generateSequence<Class<*>>(view.webViewClient.javaClass) { it.superclass }
            .takeWhile { it != android.webkit.WebViewClient::class.java }
            .any { c -> c.declaredMethods.any { it.name == "shouldInterceptRequest" } }

    /**
     * Chooses the interception tier once the session's capabilities are known (KTD20): replace when
     * the session can substitute responses, observe when it can see requests, otherwise none, where
     * the shim itself shows main-frame `loadUrl` navigations to the handler. Every tier that cannot
     * see subresources records the degraded capability.
     */
    private fun configureInterception(session: String, openReply: JsonObject) {
        if (!overridesIntercept()) return
        if (bridge.protocolMinor >= 2) {
            if (BrowserFeature.REPLACE_REQUESTS in available && setInterception(session, MODE_REPLACE)) {
                interception = MODE_REPLACE
                return
            }
            val observable = BrowserFeature.OBSERVE_NAVIGATIONS in available || BrowserFeature.OBSERVE_SUBRESOURCES in available
            if (observable && setInterception(session, MODE_OBSERVE)) {
                interception = MODE_OBSERVE
                if (BrowserFeature.OBSERVE_SUBRESOURCES !in available) {
                    val reason = BrowserFeature.reason(openReply, BrowserFeature.OBSERVE_SUBRESOURCES)
                    environment.currentOperation?.addWarning(OBSERVE_WARNING + (reason?.let { ": $it" } ?: ""))
                }
                return
            }
        }
        environment.currentOperation?.addWarning(SUBRESOURCE_WARNING)
    }

    /** Sets the interception mode; false when the supervisor refuses it as capability-unavailable. */
    private fun setInterception(session: String, mode: String): Boolean = try {
        call("host.browser.setRequestInterception", buildJsonObject {
            put("session", session)
            put("mode", mode)
        })
        true
    } catch (e: WorkerError) {
        if (e.code != ErrorCode.CAPABILITY_UNAVAILABLE) throw e
        System.err.println("[webkit] request interception mode $mode refused: ${e.message}")
        false
    }

    private fun setHandler(session: String, name: String, enabled: Boolean) {
        call("host.browser.setMessageHandler", buildJsonObject {
            put("session", session)
            put("name", name)
            put("enabled", enabled)
        })
    }

    private fun recordAndThrow(e: HostOperationException): Nothing {
        environment.currentOperation?.recordHostFailure(e)
        throw e
    }

    private fun pushCookies(session: String, url: String) {
        val httpUrl = url.toHttpUrlOrNull() ?: return
        for (cookie in environment.cookieJar.loadForRequest(httpUrl)) {
            call("host.browser.setCookie", buildJsonObject {
                put("session", session)
                put("url", url)
                put("cookie", cookieJson(cookie))
            })
        }
    }

    private fun pullCookies(session: String, url: String) {
        val httpUrl = url.toHttpUrlOrNull() ?: return
        val reply = call("host.browser.getCookies", buildJsonObject {
            put("session", session)
            put("url", url)
        })
        val cookies = (reply["cookies"] as? JsonArray ?: return).mapNotNull { element ->
            val o = element.jsonObject
            val builder = Cookie.Builder().name(o.optStr("name") ?: return@mapNotNull null).value(o.optStr("value").orEmpty())
            val domain = o.optStr("domain")?.removePrefix(".") ?: httpUrl.host
            builder.domain(domain).path(o.optStr("path") ?: "/")
            o.optStr("expires")?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() }.getOrNull() }?.let(builder::expiresAt)
            if ((o["secure"] as? JsonPrimitive)?.content == "true") builder.secure()
            if ((o["httpOnly"] as? JsonPrimitive)?.content == "true") builder.httpOnly()
            runCatching { builder.build() }.getOrNull()
        }
        environment.cookieJar.saveFromResponse(httpUrl, cookies)
    }

    private fun cookieJson(c: Cookie) = buildJsonObject {
        put("name", c.name)
        put("value", c.value)
        put("domain", c.domain)
        put("path", c.path)
        if (c.persistent) put("expires", java.time.Instant.ofEpochMilli(c.expiresAt).toString())
        put("secure", c.secure)
        put("httpOnly", c.httpOnly)
    }

    private fun onMain(block: () -> Unit) {
        WebkitHost.mainHandler.post { if (!view.isDestroyed) block() }
    }

    override fun loadUrl(url: String, headers: Map<String, String>) {
        currentUrl = url
        val request = SimpleRequest(url, headers, mainFrame = true)
        enqueue {
            if (!bridge.isNavigable(url)) {
                recordAndThrow(CapabilityUnavailableException("Scheme of $url is not allowed (only http, https, about:blank)", "host.browser.load"))
            }
            val s = requireSession()
            if (interception == MODE_NONE && overridesIntercept()) {
                // No platform interception: show the handler the navigation it would have seen first.
                val intercepted = onMainBlocking { view.webViewClient.shouldInterceptRequest(view, request) }
                if (intercepted != null) recordAndThrow(replaceUnsupported())
            }
            pushCookies(s, url)
            onMain { view.webViewClient.onPageStarted(view, url, null) }
            val page = call("host.browser.load", buildJsonObject {
                put("session", s)
                put("url", url)
                if (headers.isNotEmpty()) put("headers", JsonObject(headers.mapValues { JsonPrimitive(it.value) }))
            })
            val finalUrl = page.optStr("finalUrl") ?: url
            currentUrl = finalUrl
            pullCookies(s, finalUrl)
            onMain { view.webViewClient.onPageFinished(view, finalUrl) }
            null
        }
    }

    override fun loadDataWithBaseUrl(baseUrl: String?, data: String, mimeType: String?, encoding: String?, historyUrl: String?) {
        val base = baseUrl ?: "about:blank"
        currentUrl = base
        enqueue {
            if (!bridge.isWebUrl(base)) {
                recordAndThrow(CapabilityUnavailableException("loadData needs an http(s) base URL, got $base", "host.browser.loadData"))
            }
            val s = requireSession()
            pushCookies(s, base)
            onMain { view.webViewClient.onPageStarted(view, base, null) }
            val page = call("host.browser.loadData", buildJsonObject {
                put("session", s)
                put("html", data)
                put("baseUrl", base)
            })
            val finalUrl = page.optStr("finalUrl") ?: base
            currentUrl = finalUrl
            pullCookies(s, finalUrl)
            onMain { view.webViewClient.onPageFinished(view, finalUrl) }
            null
        }
    }

    override fun evaluateJavascript(script: String, callback: ValueCallback<String>?) {
        // 1.2 `scriptError` is deliberately ignored: Android reports a throwing script as "null".
        enqueue {
            val s = requireSession()
            val result = call("host.browser.evaluate", buildJsonObject {
                put("session", s)
                put("script", script)
            }).optStr("result") ?: "null"
            if (callback != null) onMain { callback.onReceiveValue(result) }
            null
        }
    }

    override fun addJavascriptInterface(target: Any, name: String) {
        if (!CHANNEL_NAME.matches(name)) {
            // The channel contract only carries identifier names; anything else is refused by every BrowserPort.
            environment.currentOperation?.recordHostFailure(
                CapabilityUnavailableException("JavascriptInterface name '$name' is not a plain JavaScript identifier", "android.webkit.JavascriptInterface"),
            )
            return
        }
        interfaces[name] = target
        enqueue {
            session?.let { setHandler(it, name, true) }
            null
        }
    }

    override fun addDocumentStartJavaScript(script: String, allowedOriginRules: Set<String>): ScriptHandler {
        val wrapped = OriginRules.wrap(script, allowedOriginRules)
        pageStartScripts += wrapped
        enqueue {
            session?.let { sendPageStartScript(it, wrapped) }
            null
        }
        val operation = environment.currentOperation
        return ScriptHandler {
            // Says so instead of pretending: the port has no removal (protocol 1.2). Not recorded as the
            // operation's failure, because an extension may handle it; the warning keeps it visible.
            operation?.addWarning(SCRIPT_REMOVE_WARNING)
            throw UnsupportedOperationException(
                "ScriptHandler.remove is unsupported by the desktop browser port: page-start scripts last until the browser session closes",
            )
        }
    }

    /**
     * A `host.browser.request` event for this session, delivered from the frame reader. The handler
     * runs on a browser thread (Android also calls `shouldInterceptRequest` off the main thread), never
     * on the request chain, which may be blocked waiting for the very load this request belongs to.
     * Nothing runs, and nothing is answered, once the package has no operation in flight.
     */
    fun onPlatformRequest(event: BrowserRequestEvent) {
        if (closed || environment.currentOperation == null) return
        EXECUTOR.execute {
            mangabackup.tachi.host.PackageScope.bind(environment) { handlePlatformRequest(event) }
        }
    }

    private fun handlePlatformRequest(event: BrowserRequestEvent) {
        val requestId = event.requestId
        var replacement: JsonObject? = null
        try {
            val request = SimpleRequest(event.url, event.headers, event.mainFrame, event.method, event.redirect)
            val response = view.webViewClient.shouldInterceptRequest(view, request)
            if (requestId == null) {
                // Observe tier: the request has already proceeded, so a replacement cannot be honoured.
                if (response != null) onFailure(replaceUnsupported())
                return
            }
            replacement = response?.let(BrowserReplacement::encode)
        } catch (e: CapabilityUnavailableException) {
            onFailure(e)
        } catch (t: Throwable) {
            // Any failure (an Error from the handler, an unreadable response stream) still answers a held
            // request below, with null, so the page never waits out the replacement timeout.
            if (t is VirtualMachineError) throw t
            System.err.println("[webkit] shouldInterceptRequest failed: $t")
        } finally {
            if (requestId != null) {
                bridge.respond(environment, buildJsonObject {
                    put("session", event.session)
                    put("requestId", requestId)
                    put("response", replacement ?: kotlinx.serialization.json.JsonNull)
                })
            }
        }
    }

    private fun replaceUnsupported() = CapabilityUnavailableException(
        "Replacing a response from shouldInterceptRequest needs the replace tier (replaceRequests), which this browser session lacks",
        "android.webkit.shouldInterceptRequest.replace",
    )

    override fun removeJavascriptInterface(name: String) {
        interfaces.remove(name)
        enqueue {
            session?.let { setHandler(it, name, false) }
            null
        }
    }

    override fun setUserAgent(userAgent: String) {
        this.userAgent = userAgent
        enqueue {
            session?.let { s ->
                call("host.browser.setUserAgent", buildJsonObject {
                    put("session", s)
                    put("userAgent", userAgent)
                })
            }
            null
        }
    }

    override fun stopLoading() = Unit

    override fun getUrl(): String? = currentUrl

    override fun destroy() {
        enqueue {
            closeSession()?.get()
            null
        }
    }

    /** Sends host.browser.close if a session is open; returns its completion. */
    fun closeSession(): CompletableFuture<JsonObject>? {
        val s = session ?: return null
        session = null
        closed = true
        bridge.unbindSession(s)
        return bridge.request(environment, "host.browser.close", buildJsonObject { put("session", s) })
            .exceptionally { JsonObject(emptyMap()) }
    }

    fun cancelPending() {
        closed = true
    }

    /** A page message on channel [name]: invoke the registered interface object's handler on a bridge thread. */
    fun deliverMessage(name: String, message: String) {
        val target = interfaces[name] ?: return
        val method = messageMethod(target) ?: run {
            environment.currentOperation?.recordHostFailure(
                CapabilityUnavailableException("JavascriptInterface '$name' has no @JavascriptInterface postMessage(String) method", "android.webkit.JavascriptInterface"),
            )
            return
        }
        if (method.returnType != Void.TYPE) {
            environment.currentOperation?.recordHostFailure(
                CapabilityUnavailableException("Synchronous @JavascriptInterface return values cannot cross the platform message channel", "android.webkit.JavascriptInterface.return"),
            )
        }
        EXECUTOR.execute {
            try {
                method.isAccessible = true
                method.invoke(target, message)
            } catch (e: Exception) {
                System.err.println("[webkit] JavascriptInterface '$name' threw: ${e.cause ?: e}")
            }
        }
    }

    /** The channel's page API is `postMessage(string)`, so that is the only method a page message can reach. */
    private fun messageMethod(target: Any): Method? = target.javaClass.methods.firstOrNull {
        it.name == "postMessage" && it.isAnnotationPresent(JavascriptInterface::class.java) &&
            it.parameterCount == 1 && it.parameterTypes[0] == String::class.java
    }

    private fun onFailure(failure: Throwable) {
        val cause = (failure as? java.util.concurrent.CompletionException)?.cause ?: failure
        val host = when (cause) {
            is HostOperationException -> cause
            is WorkerError -> when (cause.code) {
                ErrorCode.INTERACTION_REQUIRED -> InteractionRequiredException(cause.message ?: "interaction required", cause.operation, cause)
                ErrorCode.CAPABILITY_UNAVAILABLE -> CapabilityUnavailableException(cause.message ?: "capability unavailable", cause.operation ?: "host.browser", cause)
                else -> null
            }
            else -> null
        }
        if (host != null) {
            environment.currentOperation?.recordHostFailure(host)
            // Fail fast: helpers such as runWebViewBlocking watch their OkHttp call and give up
            // when it is cancelled, instead of waiting out their own timeout.
            environment.cancelActiveCalls()
        }
        val url = currentUrl ?: "about:blank"
        onMain {
            view.webViewClient.onReceivedError(view, SimpleRequest(url, emptyMap(), mainFrame = true), SimpleError(cause.message ?: cause.toString()))
        }
    }

    private fun <T> onMainBlocking(block: () -> T): T {
        val future = CompletableFuture<T>()
        WebkitHost.mainHandler.post {
            try {
                future.complete(block())
            } catch (t: Throwable) {
                future.completeExceptionally(t)
            }
        }
        return future.get()
    }

    private class SimpleRequest(
        private val url: String,
        private val headers: Map<String, String>,
        private val mainFrame: Boolean,
        private val method: String = "GET",
        private val redirect: Boolean = false,
    ) : WebResourceRequest {
        override fun getUrl(): Uri = Uri.parse(url)
        override fun isForMainFrame(): Boolean = mainFrame
        override fun isRedirect(): Boolean = redirect
        override fun hasGesture(): Boolean = false
        override fun getMethod(): String = method
        override fun getRequestHeaders(): Map<String, String> = headers
    }

    private class SimpleError(private val description: String) : WebResourceError() {
        override fun getErrorCode(): Int = ERROR_UNKNOWN
        override fun getDescription(): CharSequence = description
    }

    companion object {
        const val ERROR_UNKNOWN = -1
        const val SUBRESOURCE_WARNING =
            "degraded: subresource observation unavailable (shouldInterceptRequest sees main-frame loadUrl navigations only)"
        const val OBSERVE_WARNING =
            "degraded: subresource observation unavailable (shouldInterceptRequest sees the navigations the browser reports)"
        const val SCRIPT_REMOVE_WARNING =
            "androidx.webkit.ScriptHandler.remove: the browser port cannot remove a page-start script; it stays until the session closes"
        const val MODE_NONE = "none"
        const val MODE_OBSERVE = "observe"
        const val MODE_REPLACE = "replace"
        private val EXECUTOR = Executors.newCachedThreadPool { r -> Thread(r, "tachi-browser").apply { isDaemon = true } }

        /** Channel names the browser message channel accepts (protocol 1.1, `BrowserMessageChannel`). */
        val CHANNEL_NAME = Regex("^[A-Za-z_$][A-Za-z0-9_$]*$")
    }
}
