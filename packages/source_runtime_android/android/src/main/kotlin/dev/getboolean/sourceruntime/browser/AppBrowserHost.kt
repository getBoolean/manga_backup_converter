package dev.getboolean.sourceruntime.browser

import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.Keep
import androidx.webkit.ProfileStore
import androidx.webkit.ScriptHandler
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * Replies and events of [AppBrowserHost]; implemented in Dart as a JNIgen
 * listener (KTD23). Every method is void, so the Dart side registers it as an
 * asynchronous listener: no Java thread ever waits on Dart.
 */
@Keep
interface AppBrowserListener {
    /** The outcome of call [callId]: `ok` with a JSON payload, or a JSON `{code, message}` failure. */
    fun onReply(callId: Long, ok: Boolean, payload: String)

    /** An unsolicited event of session [sessionId] (`""` for host events). */
    fun onEvent(sessionId: String, kind: String, payload: String)
}

/**
 * The app-process WebView behind the Android `BrowserPort` (KTD19, KTD20,
 * U12). Dart drives it through JNIgen with JSON commands; this class owns
 * every WebView and touches them only on the main looper.
 *
 * - **Threading:** [call] only posts to the main looper and returns. Results
 *   travel back through [AppBrowserListener]; no main-thread work waits for
 *   Dart and no Dart call waits for the main thread.
 * - **Storage:** with androidx.webkit multi-profile, every session gets its
 *   own profile (`srt-<n>`), so sources never share cookies or web storage;
 *   closing deletes it. Without multi-profile all sessions share the default
 *   profile and the Dart port reports isolation unavailable. Start-up
 *   ([OP_INIT]) deletes every profile a previous process left behind.
 * - **Pages:** `file:` and `content:` access are off; only http(s),
 *   `about:blank` and http(s)-based data documents load (KTD20).
 * - **Messages:** one private engine message listener per session
 *   (`WebViewCompat.addWebMessageListener`), registered before the first
 *   load, reports the engine-attested origin of the posting frame; Dart
 *   applies the origin rule. Channel objects are page scripts that forward
 *   to it.
 */
@Keep
class AppBrowserHost(context: Context, private val listener: AppBrowserListener) {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val sessions = HashMap<String, BrowserSessionView>()
    private var multiProfile = false
    private var proxy: RefusingProxy? = null

    @Volatile private var disposed = false

    private val foreground: (Int) -> Unit = { started -> event("", "foreground", JSONObject().put("started", started)) }

    init {
        ActivityTracker.install(app, foreground)
    }

    /** Runs [op] with JSON [args] on the main looper; its outcome arrives as [AppBrowserListener.onReply]. */
    fun call(callId: Long, op: String, args: String) {
        main.post {
            if (disposed) {
                reply(callId, false, failure("disposed", "The browser host was disposed"))
                return@post
            }
            try {
                dispatch(callId, op, JSONObject(args))
            } catch (t: Throwable) {
                reply(callId, false, failure("error", "${t.javaClass.simpleName}: ${t.message}"))
            }
        }
    }

    /** Destroys every WebView without deleting data (the port's kill hook), then stops listening. */
    fun dispose() {
        main.post {
            for (s in sessions.values.toList()) s.destroyView()
            sessions.clear()
            disposed = true
            ActivityTracker.remove(foreground)
        }
    }

    internal fun session(id: String): BrowserSessionView? = sessions[id]

    internal fun event(session: String, kind: String, payload: JSONObject) {
        if (!disposed) listener.onEvent(session, kind, payload.toString())
    }

    private fun reply(callId: Long, ok: Boolean, payload: JSONObject) {
        listener.onReply(callId, ok, payload.toString())
    }

    private fun ok(callId: Long, payload: JSONObject = JSONObject()) = reply(callId, true, payload)

    private fun dispatch(callId: Long, op: String, a: JSONObject) {
        when (op) {
            OP_INIT -> init(callId, a)
            OP_WIPE_ALL -> wipeAll(callId)
            OP_OPEN -> open(callId, a)
            OP_STATE -> ok(callId, state())
            OP_ABANDON -> {
                for (s in sessions.values.toList()) s.destroyView()
                sessions.clear()
                ok(callId)
            }
            OP_PROBE_PROFILE -> ProfileProbe.run(app) { ok(callId, it) }
            "recreateInteraction" -> ok(callId, JSONObject().put("recreated", BrowserInteractionActivity.recreateCurrent()))
            "closeInteraction" -> ok(callId, JSONObject().put("closed", BrowserInteractionActivity.closeCurrentAsUser()))
            else -> {
                val s = sessions[a.getString("session")]
                if (s == null) {
                    reply(callId, false, failure("closed", "No open session ${a.optString("session")}"))
                    return
                }
                s.dispatch(callId, op, a)
            }
        }
    }

    // --- start-up ------------------------------------------------------------

    private fun init(callId: Long, a: JSONObject) {
        multiProfile = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) && !a.optBoolean("disableProfiles")
        val features = JSONObject()
        for (f in FEATURES) features.put(f, WebViewFeature.isFeatureSupported(f))
        val pkg = runCatching { WebView.getCurrentWebViewPackage() }.getOrNull()
        val info = JSONObject()
            .put("multiProfile", multiProfile)
            .put("features", features)
            .put("webViewPackage", pkg?.let { "${it.packageName} ${it.versionName}" } ?: JSONObject.NULL)
            .put("startedActivities", ActivityTracker.started)
        if (!a.optBoolean("offline")) {
            ok(callId, info)
            return
        }
        // Replay mode (tests only): every WebView request of this process goes
        // to a loopback proxy that refuses it, with no DIRECT fallback, so no
        // request and no DNS lookup reaches the network. Loopback hosts keep
        // Chromium's implicit bypass, so a test's own 127.0.0.1 server answers.
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            reply(callId, false, failure("capability", "Replay mode needs PROXY_OVERRIDE, which this WebView lacks"))
            return
        }
        val refuser = proxy ?: RefusingProxy().also { proxy = it }
        val config = androidx.webkit.ProxyConfig.Builder().addProxyRule("127.0.0.1:${refuser.port}").build()
        androidx.webkit.ProxyController.getInstance().setProxyOverride(config, { it.run() }) {
            ok(callId, info.put("offlineProxy", "127.0.0.1:${refuser.port}"))
        }
    }

    /**
     * Empties every port-owned profile not in use by an open session, and the
     * default profile (KTD20 start-up rule). Each profile is deleted where
     * Chromium allows it, and otherwise kept, verified empty, for reuse.
     */
    private fun wipeAll(callId: Long) {
        for (s in sessions.values.toList()) s.destroyView()
        sessions.clear()
        val names = if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            ProfileStore.getInstance().allProfileNames.filter { it.startsWith(PROFILE_PREFIX) && it !in ProfilePool.inUse }
        } else {
            emptyList()
        }
        val profiles = JSONObject()
        var allEmpty = true
        fun next(i: Int) {
            if (i == names.size) {
                wipeStore(CookieManager.getInstance(), WebStorage.getInstance()) { confirmed, detail ->
                    val out = JSONObject().put("profiles", profiles).put("default", detail)
                    if (confirmed && allEmpty) {
                        ok(callId, out)
                    } else {
                        reply(callId, false, out.put("code", "unconfirmed").put("message", "Start-up wipe not confirmed: $out"))
                    }
                }
                return
            }
            ProfilePool.wipe(app, names[i], clearCache = true) { empty, detail ->
                if (!empty) allEmpty = false
                profiles.put(names[i], detail)
                next(i + 1)
            }
        }
        next(0)
    }

    private fun state(): JSONObject {
        val profiles = JSONArray()
        if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            for (name in ProfileStore.getInstance().allProfileNames) profiles.put(name)
        }
        return JSONObject()
            .put("sessions", JSONArray(sessions.keys.sorted()))
            .put("profiles", profiles)
            .put("freeProfiles", JSONArray(ProfilePool.free.toList()))
            .put("startedActivities", ActivityTracker.started)
            .put("interactionActivity", BrowserInteractionActivity.current?.sessionId ?: JSONObject.NULL)
            .put("refusedRequests", JSONArray(proxy?.refused?.toList() ?: emptyList<String>()))
    }

    // --- sessions ---------------------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled")
    private fun open(callId: Long, a: JSONObject) {
        val id = a.getString("session")
        val bridge = a.getString("bridge")
        val wrapper = MutableContextWrapper(app)
        val view = WebView(wrapper)
        var profile: String? = null
        if (multiProfile) {
            // Assigned before anything else touches the WebView, as setProfile requires.
            val name = ProfilePool.acquire()
            WebViewCompat.setProfile(view, name)
            profile = name
        }
        val s = BrowserSessionView(this, id, view, wrapper, profile, bridge)
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            a.optString("userAgent").takeIf { it.isNotEmpty() }?.let { userAgentString = it }
        }
        view.webViewClient = s.client
        WebViewCompat.addWebMessageListener(view, bridge, setOf("*")) { _, message, origin, isMainFrame, _ ->
            s.onBridge(message, origin, isMainFrame)
        }
        sessions[id] = s
        ok(callId, JSONObject().put("profile", profile ?: JSONObject.NULL))
    }

    internal fun removeSession(id: String) {
        sessions.remove(id)
    }

    internal fun okReply(callId: Long, payload: JSONObject = JSONObject()) = ok(callId, payload)

    internal fun failReply(callId: Long, code: String, message: String, url: String? = null) =
        reply(callId, false, failure(code, message).also { if (url != null) it.put("url", url) })

    internal companion object {
        const val OP_INIT = "init"
        const val OP_WIPE_ALL = "wipeAll"
        const val OP_OPEN = "open"
        const val OP_STATE = "state"
        const val OP_ABANDON = "abandon"
        const val OP_PROBE_PROFILE = "probeProfile"
        const val PROFILE_PREFIX = "srt-"
        val FEATURES = listOf(
            WebViewFeature.MULTI_PROFILE,
            WebViewFeature.WEB_MESSAGE_LISTENER,
            WebViewFeature.DOCUMENT_START_SCRIPT,
            WebViewFeature.PROXY_OVERRIDE,
            WebViewFeature.GET_COOKIE_INFO,
        )

        fun failure(code: String, message: String): JSONObject = JSONObject().put("code", code).put("message", message)

        fun isWebUrl(url: String?): Boolean {
            val u = runCatching { Uri.parse(url) }.getOrNull() ?: return false
            val scheme = u.scheme?.lowercase()
            return (scheme == "http" || scheme == "https") && !u.host.isNullOrEmpty()
        }

        fun isNavigable(url: String?): Boolean = isWebUrl(url) || url == "about:blank"

        /**
         * Removes [cookies] and [storage] and confirms both are empty: no
         * cookies remain and web storage reports no origin.
         */
        fun wipeStore(cookies: CookieManager, storage: WebStorage, done: (Boolean, JSONObject) -> Unit) {
            storage.deleteAllData()
            cookies.removeAllCookies {
                cookies.flush()
                storage.getOrigins { origins ->
                    val left = (origins as? Map<*, *>)?.size ?: 0
                    val hasCookies = cookies.hasCookies()
                    done(!hasCookies && left == 0, JSONObject().put("cookiesLeft", hasCookies).put("storageOriginsLeft", left))
                }
            }
        }
    }
}

/** One session's WebView, confined to the main looper. */
internal class BrowserSessionView(
    private val host: AppBrowserHost,
    val id: String,
    view: WebView,
    val contextWrapper: MutableContextWrapper,
    private val profile: String?,
    private val bridge: String,
) {
    var webView: WebView? = view
        private set

    private var scripts = mutableListOf<ScriptHandler>()

    @Volatile private var observe = false

    /** The pending main-frame load: its call, requested URL and whether its start was seen. */
    private var nav: Nav? = null

    private class Nav(val callId: Long, val url: String, var started: Boolean = false, var status: Int? = null)

    val client = object : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url.toString()
            if (!request.isForMainFrame) return !AppBrowserHost.isNavigable(url) && !url.startsWith("about:")
            if (AppBrowserHost.isNavigable(url)) return false
            refuse(url)
            return true
        }

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            val n = nav ?: return
            if (url == n.url) n.started = true
            if (url != null && !AppBrowserHost.isNavigable(url) && !(url.startsWith("data:") && n.started)) refuse(url)
        }

        override fun onPageFinished(view: WebView, url: String?) {
            val n = nav ?: return
            if (!n.started) return
            nav = null
            val final = view.url ?: url ?: n.url
            if (!AppBrowserHost.isNavigable(final)) {
                host.failReply(n.callId, "scheme", "Ended on a non-web URL")
                return
            }
            host.okReply(n.callId, JSONObject().put("url", final).put("status", n.status ?: JSONObject.NULL))
        }

        override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
            if (request.isForMainFrame) nav?.status = response.statusCode
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (!request.isForMainFrame) return
            val n = nav ?: return
            nav = null
            val desc = error.description?.toString() ?: ""
            val url = request.url.toString()
            // Chromium refuses a redirect to file: (ERR_UNSAFE_REDIRECT) before any client callback.
            if (!AppBrowserHost.isNavigable(url) || desc.contains("UNSAFE_REDIRECT")) {
                host.failReply(n.callId, "scheme", "Navigation to a non-web URL was refused ($desc)")
            } else {
                host.failReply(n.callId, "navigation", "$desc (${error.errorCode})", url)
            }
        }

        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val url = request.url
            val scheme = url.scheme?.lowercase()
            if (scheme != "http" && scheme != "https") {
                // Local and app-custom schemes never load in a session (KTD20).
                return if (scheme == "data" || scheme == "blob" || scheme == "about") null else blocked()
            }
            if (observe) {
                val headers = JSONObject()
                for ((k, v) in request.requestHeaders) headers.put(k, v)
                host.event(
                    id,
                    "request",
                    JSONObject()
                        .put("url", url.toString())
                        .put("method", request.method)
                        .put("headers", headers)
                        .put("mainFrame", request.isForMainFrame)
                        .put("redirect", request.isRedirect),
                )
            }
            return null
        }
    }

    private fun blocked() = WebResourceResponse("text/plain", "utf-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    private fun refuse(url: String) {
        val n = nav ?: return
        nav = null
        webView?.stopLoading()
        host.failReply(n.callId, "scheme", "Navigation to scheme \"${Uri.parse(url).scheme}\" is not allowed (only http, https, about:blank)")
    }

    fun onBridge(message: WebMessageCompat, origin: Uri, isMainFrame: Boolean) {
        val data = message.data ?: return
        host.event(
            id,
            "bridge",
            JSONObject()
                .put("data", data)
                .put("origin", origin.toString())
                .put("mainFrame", isMainFrame)
                .put("document", webView?.url ?: JSONObject.NULL),
        )
    }

    fun dispatch(callId: Long, op: String, a: JSONObject) {
        val view = webView ?: return host.failReply(callId, "closed", "Session $id is closed")
        when (op) {
            "loadUrl" -> {
                nav?.let { host.failReply(it.callId, "superseded", "Superseded by a new load") }
                val url = a.getString("url")
                nav = Nav(callId, url)
                val headers = HashMap<String, String>()
                a.optJSONObject("headers")?.let { h -> h.keys().forEach { headers[it] = h.getString(it) } }
                view.loadUrl(url, headers)
            }
            "loadData" -> {
                nav?.let { host.failReply(it.callId, "superseded", "Superseded by a new load") }
                val base = a.getString("baseUrl")
                nav = Nav(callId, base)
                view.loadDataWithBaseURL(base, a.getString("html"), "text/html", "utf-8", null)
            }
            "evaluate" -> view.evaluateJavascript(a.getString("script")) { value ->
                if (webView == null) host.failReply(callId, "closed", "Session $id closed") else host.okReply(callId, JSONObject().put("value", value ?: "null"))
            }
            "setStartScripts" -> {
                for (h in scripts) h.remove()
                scripts.clear()
                val list = a.getJSONArray("scripts")
                for (i in 0 until list.length()) {
                    scripts += WebViewCompat.addDocumentStartJavaScript(view, list.getString(i), setOf("*"))
                }
                host.okReply(callId)
            }
            "setObserver" -> {
                observe = a.getBoolean("enabled")
                host.okReply(callId)
            }
            "getCookies" -> {
                val raw = cookies().getCookie(a.getString("url"))
                val out = JSONArray()
                raw?.split(';')?.map { it.trim() }?.filter { it.isNotEmpty() }?.forEach { pair ->
                    val eq = pair.indexOf('=')
                    out.put(JSONObject().put("name", if (eq < 0) pair else pair.substring(0, eq)).put("value", if (eq < 0) "" else pair.substring(eq + 1)))
                }
                host.okReply(callId, JSONObject().put("cookies", out))
            }
            "setCookie" -> cookies().setCookie(a.getString("url"), a.getString("header")) { set ->
                cookies().flush()
                if (set) host.okReply(callId) else host.failReply(callId, "capability", "WebView rejected the cookie")
            }
            "setUserAgent" -> {
                view.settings.userAgentString = a.getString("userAgent")
                host.okReply(callId)
            }
            "show" -> BrowserInteractionActivity.show(host, this, callId)
            "hide" -> {
                BrowserInteractionActivity.hide(id)
                host.okReply(callId)
            }
            "stop" -> {
                view.stopLoading()
                nav?.let { host.failReply(it.callId, "superseded", "Load stopped") }
                nav = null
                host.okReply(callId)
            }
            "close" -> close(callId)
            else -> host.failReply(callId, "error", "Unknown operation $op")
        }
    }

    private fun cookies(): CookieManager =
        if (profile != null) ProfileStore.getInstance().getProfile(profile)!!.cookieManager else CookieManager.getInstance()

    private fun storage(): WebStorage =
        if (profile != null) ProfileStore.getInstance().getProfile(profile)!!.webStorage else WebStorage.getInstance()

    /** Destroys the WebView without deleting data (a process death, for the kill-and-restart case). */
    fun destroyView() {
        BrowserInteractionActivity.hide(id)
        nav?.let { host.failReply(it.callId, "closed", "Session $id closed") }
        nav = null
        val view = webView ?: return
        webView = null
        observe = false
        (view.parent as? ViewGroup)?.removeView(view)
        view.stopLoading()
        view.destroy()
    }

    /**
     * Deletes the session's cookies, web storage and HTTP cache and confirms
     * that none remain (KTD9). With a profile, the profile is then deleted,
     * or, while Chromium still holds it after the WebView's destruction,
     * kept verified empty for a later session (see [ProfilePool]).
     */
    private fun close(callId: Long) {
        webView?.clearCache(true)
        if (profile != null) {
            destroyView()
            host.removeSession(id)
            ProfilePool.release(profile) { empty, detail ->
                if (empty) host.okReply(callId, detail) else host.failReply(callId, "unconfirmed", "Storage deletion not confirmed: $detail")
            }
            return
        }
        val cookies = cookies()
        val storage = storage()
        destroyView()
        host.removeSession(id)
        AppBrowserHost.wipeStore(cookies, storage) { confirmed, detail ->
            if (confirmed) host.okReply(callId, detail) else host.failReply(callId, "unconfirmed", "Storage deletion left data: $detail")
        }
    }
}

/** Counts started Activities of this process (process-wide foreground state). */
internal object ActivityTracker : android.app.Application.ActivityLifecycleCallbacks {
    @Volatile var started = 0
        private set

    @Volatile var top: android.app.Activity? = null
        private set

    private val listeners = ConcurrentHashMap<(Int) -> Unit, Boolean>()
    private var installed = false

    fun install(context: Context, onChange: (Int) -> Unit) {
        listeners[onChange] = true
        if (installed) return
        installed = true
        (context.applicationContext as android.app.Application).registerActivityLifecycleCallbacks(this)
        // Activities started before the first host existed.
        started = currentlyStarted(context)
    }

    fun remove(onChange: (Int) -> Unit) {
        listeners.remove(onChange)
    }

    private fun currentlyStarted(context: Context): Int {
        val am = context.getSystemService(android.app.ActivityManager::class.java) ?: return 0
        val visible = am.runningAppProcesses.orEmpty().any {
            it.pid == android.os.Process.myPid() &&
                it.importance <= android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
        }
        return if (visible) 1 else 0
    }

    override fun onActivityStarted(activity: android.app.Activity) {
        started++
        listeners.keys.forEach { it(started) }
    }

    override fun onActivityStopped(activity: android.app.Activity) {
        started = (started - 1).coerceAtLeast(0)
        listeners.keys.forEach { it(started) }
    }

    override fun onActivityResumed(activity: android.app.Activity) {
        top = activity
    }

    override fun onActivityPaused(activity: android.app.Activity) {
        if (top === activity) top = null
    }

    override fun onActivityCreated(activity: android.app.Activity, savedInstanceState: android.os.Bundle?) {}

    override fun onActivitySaveInstanceState(activity: android.app.Activity, outState: android.os.Bundle) {}

    override fun onActivityDestroyed(activity: android.app.Activity) {}
}

/**
 * Port-owned androidx.webkit profiles of this process (main looper only).
 *
 * Chromium refuses `ProfileStore.deleteProfile` while it still holds a
 * profile, which it may do after the profile's last WebView is destroyed
 * (U12 emulator receipt). A released profile is therefore emptied first
 * (cookies, web storage, HTTP cache) and confirmed empty; it is then deleted
 * when Chromium allows it, and otherwise parked in [free] and handed to the
 * next session. Either way no session sees another session's data, and a
 * profile that cannot be confirmed empty is never reused.
 */
internal object ProfilePool {
    val inUse = HashSet<String>()
    val free = ArrayDeque<String>()
    private var counter = 0
    private val main = Handler(Looper.getMainLooper())

    fun acquire(): String {
        val name = free.removeFirstOrNull() ?: "${AppBrowserHost.PROFILE_PREFIX}${System.currentTimeMillis()}-${counter++}"
        ProfileStore.getInstance().getOrCreateProfile(name)
        inUse += name
        return name
    }

    /** Empties a session's profile after its WebView was destroyed (it cleared its cache first). */
    fun release(name: String, done: (Boolean, JSONObject) -> Unit) {
        inUse -= name
        wipe(null, name, clearCache = false, done = done)
    }

    /**
     * Empties [name] and deletes it, or parks it in [free] when Chromium
     * still holds it. [clearCache] clears its HTTP cache through a throw-away
     * WebView (the start-up path, where no session WebView exists).
     */
    fun wipe(context: Context?, name: String, clearCache: Boolean, done: (Boolean, JSONObject) -> Unit) {
        val store = ProfileStore.getInstance()
        val profile = store.getProfile(name) ?: return done(true, JSONObject().put("missing", true))
        free.remove(name)
        if (clearCache && context != null) {
            runCatching {
                val temp = WebView(context)
                WebViewCompat.setProfile(temp, name)
                temp.clearCache(true)
                temp.destroy()
            }
        }
        AppBrowserHost.wipeStore(profile.cookieManager, profile.webStorage) { empty, detail ->
            fun delete(attempt: Int) {
                val deleted = runCatching { store.deleteProfile(name) }
                if (deleted.isFailure && attempt < DELETE_RETRIES) {
                    main.postDelayed({ delete(attempt + 1) }, DELETE_RETRY_MS)
                    return
                }
                val gone = name !in store.allProfileNames
                detail.put("profileDeleted", gone).put("deleteAttempts", attempt + 1)
                deleted.exceptionOrNull()?.let { detail.put("deleteError", "${it.javaClass.simpleName}: ${it.message}") }
                if (!gone && empty) {
                    free.addLast(name)
                    detail.put("parkedEmpty", true)
                }
                done(empty, detail)
            }
            delete(0)
        }
    }

    private const val DELETE_RETRIES = 5
    private const val DELETE_RETRY_MS = 50L
}
