package mangabackup.tachi.android.debug

import android.content.Context
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import mangabackup.tachi.android.AndroidWorkerRuntime
import mangabackup.tachi.host.HostTransport
import mangabackup.tachi.host.replay.CaptureFormat
import mangabackup.tachi.host.replay.LoopbackTransport
import mangabackup.tachi.host.replay.ReplayLog
import mangabackup.tachi.host.replay.ReplayTransport
import mockwebserver3.MockResponse
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Debug-build test hooks for the Android worker (found by reflection from
 * [AndroidWorkerRuntime]; release builds do not contain this class).
 *
 * Replay: the committed captures under `fixtures/source_captures/tachi/<name>/`
 * reach the device only through the plugin's debug asset folder. They are
 * copied into the service's cache and served through the same fail-closed
 * loopback transport the desktop tests use; an uncaptured request gets a 599.
 */
class DebugWorkerHooks : AndroidWorkerRuntime.DebugHooks {
    override fun replayTransport(context: Context, captures: List<String>, challengePaths: List<String>): HostTransport {
        val dirs = captures.map { copyCapture(context, it) }
        val sets = dirs.map { CaptureFormat.load(it) }
        val log = ReplayLog()
        replayLog = log
        challengesServed.set(0)
        val pending = challengePaths.toMutableSet()
        return LoopbackTransport { method, url, _, body ->
            val challenge = synchronized(pending) { pending.remove(url.encodedPath) }
            if (challenge) {
                challengesServed.incrementAndGet()
                MockResponse.Builder().code(403).setHeader("content-type", "application/json")
                    .body("{\"error\":\"captcha_required\"}").build()
            } else {
                ReplayTransport.respond(sets, log, method, url, body)
            }
        }
    }

    override fun blockBrowserNetwork(context: Context): String {
        val proxy = refusingProxy
        // No DIRECT fallback: Chromium falls back to it when the proxy refuses a tunnel, which would
        // send the request to the network. removeImplicitRules() also routes loopback through the refuser.
        val config = ProxyConfig.Builder().addProxyRule("127.0.0.1:${proxy.localPort}").removeImplicitRules().build()
        val done = CountDownLatch(1)
        // ProxyController must be driven from the main looper of this process.
        // WebView must be initialized on the main thread; never on the Binder or worker thread.
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            try {
                if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
                    proxyStatus = "unavailable: WebView lacks PROXY_OVERRIDE"
                    done.countDown()
                    return@post
                }
                ProxyController.getInstance().setProxyOverride(config, Executor { it.run() }) { done.countDown() }
            } catch (t: Throwable) {
                proxyStatus = "setProxyOverride failed: $t"
                done.countDown()
            }
        }
        val applied = done.await(30, TimeUnit.SECONDS)
        if (proxyStatus == null) proxyStatus = if (applied) "applied" else "not confirmed within 30 s"
        // Fail closed: without a confirmed override the process's WebViews would reach the network
        // (and resolve hosts through DNS), so the worker refuses to start in replay mode. U14 found
        // this on API 28's image WebView 69, which lacks PROXY_OVERRIDE.
        check(proxyStatus == "applied") { "--offline-browser cannot block WebView network: $proxyStatus" }
        return "loopback refusing proxy on 127.0.0.1:${proxy.localPort} ($proxyStatus)"
    }

    private fun copyCapture(context: Context, name: String): File {
        require(Regex("^[A-Za-z0-9._-]+$").matches(name)) { "bad capture name $name" }
        val target = File(context.cacheDir, "replay/$name").apply {
            deleteRecursively()
            File(this, "bodies").mkdirs()
        }
        context.assets.open("$name/capture.json").use { input -> File(target, "capture.json").outputStream().use { input.copyTo(it) } }
        for (body in context.assets.list("$name/bodies").orEmpty()) {
            context.assets.open("$name/bodies/$body").use { input -> File(target, "bodies/$body").outputStream().use { input.copyTo(it) } }
        }
        return target
    }

    companion object {
        @Volatile
        var replayLog: ReplayLog? = null

        @Volatile
        var proxyStatus: String? = null
        val challengesServed = AtomicInteger()

        /** Request lines the refusing proxy received (WebView traffic that never reached a server). */
        val refusedRequests = CopyOnWriteArrayList<String>()

        private val refusingProxy: ServerSocket by lazy {
            ServerSocket(0, 16, InetAddress.getLoopbackAddress()).also { server ->
                Thread({
                    while (!server.isClosed) {
                        val socket = runCatching { server.accept() }.getOrNull() ?: break
                        Thread({
                            socket.use { s ->
                                val line = s.getInputStream().bufferedReader().readLine().orEmpty()
                                refusedRequests += line
                                s.getOutputStream().write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                                s.getOutputStream().flush()
                            }
                        }, "refusing-proxy-conn").apply { isDaemon = true }.start()
                    }
                }, "refusing-proxy").apply { isDaemon = true }.start()
            }
        }

        /** Replay and browser-network evidence for diagnostics. */
        fun report(): Map<String, Any> = mapOf(
            "replayServed" to (replayLog?.served?.size ?: 0),
            "replayMisses" to (replayLog?.misses?.map { it.toString() } ?: emptyList<String>()),
            "challengesServed" to challengesServed.get(),
            "refusedBrowserRequests" to refusedRequests.toList(),
            "browserProxy" to (proxyStatus ?: "not requested"),
        )
    }
}
