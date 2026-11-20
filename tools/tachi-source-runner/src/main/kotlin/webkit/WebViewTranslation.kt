package mangabackup.tachi.webkit

import android.net.Uri
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
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
 * `addJavascriptInterface` objects reached through page messages on the
 * channel of the same name. Observe-only interception sees main-frame
 * navigations; a non-null interception response, a synchronous
 * `@JavascriptInterface` return value and non-http(s) schemes are named
 * capability errors.
 */
class WebViewTranslation(private val view: WebView, private val bridge: BrowserBridge) : WebViewBackend {
    private val environment: PackageEnvironment = PackageEnvironment.of(view.context)
    private val operationId: String? = environment.currentOperation?.requestId
    private val sourceId: String? = environment.currentOperation?.sourceId
    private var chain: CompletableFuture<Any?> = CompletableFuture.completedFuture(null)
    private val interfaces = ConcurrentHashMap<String, Any>()

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
        val opened = call("host.browser.open", payload).optStr("session")
            ?: throw WorkerError(ErrorCode.PROTOCOL_VIOLATION, "host.browser.open reply has no session")
        session = opened
        bridge.bindSession(opened, this)
        for (name in interfaces.keys) setHandler(opened, name, true)
        return opened
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

    /** KTD20 observe-only tier: platform browsers cannot show subresource requests to the extension. */
    private fun noteInterceptionTier() {
        val overrides = generateSequence<Class<*>>(view.webViewClient.javaClass) { it.superclass }
            .takeWhile { it != android.webkit.WebViewClient::class.java }
            .any { c -> c.declaredMethods.any { it.name == "shouldInterceptRequest" } }
        if (overrides) environment.currentOperation?.addWarning(SUBRESOURCE_WARNING)
    }

    private fun onMain(block: () -> Unit) {
        WebkitHost.mainHandler.post { if (!view.isDestroyed) block() }
    }

    override fun loadUrl(url: String, headers: Map<String, String>) {
        currentUrl = url
        val request = SimpleRequest(url, headers, mainFrame = true)
        noteInterceptionTier()
        enqueue {
            if (!bridge.isNavigable(url)) {
                recordAndThrow(CapabilityUnavailableException("Scheme of $url is not allowed (only http, https, about:blank)", "host.browser.load"))
            }
            val intercepted = onMainBlocking { view.webViewClient.shouldInterceptRequest(view, request) }
            if (intercepted != null) {
                recordAndThrow(CapabilityUnavailableException("Replacing a response from shouldInterceptRequest is unsupported by the platform browser", "android.webkit.shouldInterceptRequest.replace"))
            }
            val s = requireSession()
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
        noteInterceptionTier()
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
        interfaces[name] = target
        enqueue {
            session?.let { setHandler(it, name, true) }
            null
        }
    }

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
                CapabilityUnavailableException("JavascriptInterface '$name' has no void @JavascriptInterface method taking one String", "android.webkit.JavascriptInterface"),
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

    private fun messageMethod(target: Any): Method? {
        val candidates = target.javaClass.methods.filter {
            it.isAnnotationPresent(JavascriptInterface::class.java) && it.parameterCount == 1 && it.parameterTypes[0] == String::class.java
        }
        return candidates.firstOrNull { it.name == "postMessage" } ?: candidates.singleOrNull()
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

    private class SimpleRequest(private val url: String, private val headers: Map<String, String>, private val mainFrame: Boolean) : WebResourceRequest {
        override fun getUrl(): Uri = Uri.parse(url)
        override fun isForMainFrame(): Boolean = mainFrame
        override fun isRedirect(): Boolean = false
        override fun hasGesture(): Boolean = false
        override fun getMethod(): String = "GET"
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
        private val EXECUTOR = Executors.newCachedThreadPool { r -> Thread(r, "tachi-browser").apply { isDaemon = true } }
    }
}
