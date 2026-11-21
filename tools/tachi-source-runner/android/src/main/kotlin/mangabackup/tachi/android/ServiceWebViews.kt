package mangabackup.tachi.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebStorage
import android.webkit.WebView
import androidx.webkit.WebViewFeature
import mangabackup.tachi.host.CapabilityUnavailableException
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.protocol.WorkerBrowser
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Lifecycle of the WebViews Tachi extensions create themselves inside the
 * `:source_runtime` process (KTD19). The service never routes them through a
 * BrowserPort, so it applies KTD20's storage rule itself.
 *
 * Isolation: androidx.webkit profiles can isolate cookies and storage, but a
 * profile must be assigned with `WebViewCompat.setProfile` before anything
 * else touches the WebView, and the extension constructs and configures its
 * own `android.webkit.WebView`. Without rewriting extension bytecode there is
 * no point at which the host can assign it, so per-source browser isolation
 * is reported unavailable (with the reason) even where the installed WebView
 * supports multi-profile. Every source in the process shares the default
 * profile; the service wipes it when a browser-using source's session closes
 * and before any WebView exists after a (re)start, and fails the browser
 * capability if the wipe cannot be confirmed.
 */
class ServiceWebViews(private val context: Context) : WorkerBrowser {
    private val main = Handler(Looper.getMainLooper())
    private val used = AtomicBoolean(false)

    /** Packages whose code references android.webkit.WebView (set by the platform at load). */
    private val browserPackages = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<PackageEnvironment, Boolean>())

    fun packageLoaded(environment: PackageEnvironment, referencesWebView: Boolean) {
        if (referencesWebView) browserPackages += environment
    }

    fun packageClosed(environment: PackageEnvironment) {
        if (browserPackages.remove(environment)) wipeOrThrow("package ${environment.packageId} closed")
    }

    override fun sourceSessionClosed(environment: PackageEnvironment, sourceId: String) {
        if (environment in browserPackages) wipeOrThrow("source $sourceId session closed")
    }

    @Volatile private var multiProfile: String? = null

    /**
     * Reported in the handshake and receipts. The feature probe initializes
     * WebView, so it runs on the main looper (bounded) and is cached.
     */
    fun isolationReport(): Map<String, String> {
        val probed = multiProfile ?: run {
            val result = java.util.concurrent.atomic.AtomicReference("unknown (probe timed out)")
            val done = CountDownLatch(1)
            main.post {
                result.set(runCatching { WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE).toString() }.getOrElse { "unknown ($it)" })
                done.countDown()
            }
            if (Looper.myLooper() != Looper.getMainLooper()) done.await(WIPE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            result.get().also { if (done.count == 0L) multiProfile = it }
        }
        val pkg = runCatching { WebView.getCurrentWebViewPackage() }.getOrNull()
        return mapOf(
            "webViewPackage" to (pkg?.let { "${it.packageName} ${it.versionName}" } ?: "unavailable"),
            "webViewMultiProfile" to probed,
            "sourceBrowserIsolation" to "unavailable",
            "sourceBrowserIsolationReason" to
                "extension-created android.webkit.WebView instances cannot be assigned an androidx.webkit profile before first use " +
                "without rewriting extension bytecode; the service wipes the shared profile at session close and on start (KTD19)",
        )
    }

    /** Deletes cookies and web storage of this process's WebView profile; true when confirmed empty. */
    fun wipe(): Boolean {
        check(Looper.myLooper() != Looper.getMainLooper()) { "wipe must not block the main thread" }
        val done = CountDownLatch(1)
        val confirmed = AtomicBoolean(false)
        main.post {
            try {
                val cookies = CookieManager.getInstance()
                WebStorage.getInstance().deleteAllData()
                cookies.removeAllCookies {
                    cookies.flush()
                    confirmed.set(!cookies.hasCookies())
                    done.countDown()
                }
            } catch (e: Throwable) {
                done.countDown()
            }
        }
        if (!done.await(WIPE_TIMEOUT_SECONDS, TimeUnit.SECONDS)) return false
        used.set(true)
        return confirmed.get()
    }

    private fun wipeOrThrow(reason: String) {
        if (!wipe()) {
            throw CapabilityUnavailableException("could not confirm the WebView storage wipe after $reason", "host.browser.wipe")
        }
    }

    companion object {
        /** Data directory suffix of the service process's WebView (KTD19). */
        const val DATA_DIRECTORY_SUFFIX = "source_runtime"
        const val WIPE_TIMEOUT_SECONDS = 15L

        /**
         * Removes every byte of WebView data the service process left behind
         * (a killed service cannot wipe at close). Must run before anything in
         * the process touches WebView or CookieManager. Returns the paths it removed.
         */
        fun wipeDataDirectories(context: Context): List<String> {
            val removed = mutableListOf<String>()
            val candidates = listOf(
                File(context.dataDir, "app_webview_$DATA_DIRECTORY_SUFFIX"),
                File(context.cacheDir, "WebView/$DATA_DIRECTORY_SUFFIX"),
                File(context.dataDir, "cache/WebView/$DATA_DIRECTORY_SUFFIX"),
            )
            for (dir in candidates) {
                if (dir.exists() && dir.deleteRecursively()) removed += dir.name
            }
            return removed
        }
    }
}
