package dev.getboolean.sourceruntime.tachi

import android.content.Context
import android.system.Os
import android.webkit.CookieManager
import mangabackup.tachi.android.AndroidPackageScope
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Evidence the U11 tests read from the `:source_runtime` process through the
 * gate's `diagnostics` call. It reports state, never secret values: a needle
 * search answers only whether and where a value appears.
 */
internal object ServiceDiagnostics {
    private const val MAX_SCAN_BYTES = 8L * 1024 * 1024

    fun collect(context: Context, worker: WorkerHost, startupWipe: List<String>, args: JSONObject): JSONObject {
        val out = JSONObject()
            .put("pid", android.os.Process.myPid())
            .put("workerOpen", worker.isOpen)
            .put("liveLoaders", AndroidPackageScope.liveLoaders())
            .put("startupWipe", JSONArray(startupWipe))
            .put("descriptorFramesSent", FrameTransport.descriptorFramesSent.get())
            .put("descriptorFramesReceived", FrameTransport.descriptorFramesReceived.get())
            .put("descriptorsClosed", FrameTransport.descriptorsClosed.get())
            .put("staged", staged(worker))
            .put("webViewDataDirs", webViewDirs(context))
            .put("browserIsolation", JSONObject(worker.runtime.webViews.isolationReport()))
        args.optJSONArray("needles")?.let { needles ->
            val hits = JSONObject()
            for (i in 0 until needles.length()) {
                val needle = needles.getString(i)
                hits.put("needle$i", JSONArray(scan(context.dataDir, needle.toByteArray())))
            }
            out.put("needleHits", hits)
            out.put("sharedPrefsFiles", JSONArray(File(context.dataDir, "shared_prefs").list()?.sorted().orEmpty()))
        }
        args.optJSONArray("cookieUrls")?.let { urls ->
            val cookies = JSONObject()
            // CookieManager initializes WebView: main looper only, bounded.
            val done = java.util.concurrent.CountDownLatch(1)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                try {
                    val manager = CookieManager.getInstance()
                    for (i in 0 until urls.length()) {
                        val url = urls.getString(i)
                        // Only names: values may be session secrets.
                        val names = manager.getCookie(url)?.split(';')?.map { it.substringBefore('=').trim() }.orEmpty()
                        cookies.put(url, JSONArray(names))
                    }
                } finally {
                    done.countDown()
                }
            }
            done.await(15, java.util.concurrent.TimeUnit.SECONDS)
            out.put("cookieNames", cookies)
        }
        args.optJSONObject("webStorage")?.let { out.put("webStorage", webStorage(context, it)) }
        debugReport()?.let { out.put("debug", JSONObject(it)) }
        return out
    }

    /**
     * Web storage probe (U12, carried from U11): a WebView on the service's
     * main looper loads a data document with the http(s) [origin] as base URL
     * (no network), optionally stores `localStorage["srt-probe"]`, and reads
     * it back with the origins `WebStorage` reports. Proves the session-close
     * and start-up wipes remove web storage, not only cookies.
     */
    @android.annotation.SuppressLint("SetJavaScriptEnabled")
    private fun webStorage(context: Context, args: JSONObject): JSONObject {
        val origin = args.getString("origin")
        val set = args.optString("set").takeIf { it.isNotEmpty() }
        val out = JSONObject().put("origin", origin)
        val done = java.util.concurrent.CountDownLatch(1)
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        main.post {
            try {
                val view = android.webkit.WebView(context)
                view.settings.javaScriptEnabled = true
                view.settings.domStorageEnabled = true
                view.webViewClient = object : android.webkit.WebViewClient() {
                    override fun onPageFinished(webView: android.webkit.WebView, url: String?) {
                        val script = (if (set != null) "localStorage.setItem('srt-probe', ${JSONObject.quote(set)}); " else "") +
                            "localStorage.getItem('srt-probe')"
                        webView.evaluateJavascript(script) { value ->
                            out.put("value", value)
                            android.webkit.WebStorage.getInstance().getOrigins { origins ->
                                out.put("storageOrigins", JSONArray((origins as? Map<*, *>)?.keys?.map { it.toString() }.orEmpty()))
                                webView.destroy()
                                done.countDown()
                            }
                        }
                    }
                }
                view.loadDataWithBaseURL(origin, "<html><body>probe</body></html>", "text/html", "utf-8", null)
            } catch (t: Throwable) {
                out.put("error", t.toString())
                done.countDown()
            }
        }
        if (!done.await(15, java.util.concurrent.TimeUnit.SECONDS)) out.put("error", "timed out")
        return out
    }

    private fun staged(worker: WorkerHost): JSONArray {
        val dir = worker.runtime.staging.directory
        val files = dir.listFiles()?.filter { it.isFile }?.sortedBy { it.name }.orEmpty()
        return JSONArray(files.map { f ->
            JSONObject().put("name", f.name).put("mode", modeString(Os.stat(f.absolutePath).st_mode)).put("canWrite", f.canWrite())
        })
    }

    private fun webViewDirs(context: Context): JSONArray {
        val names = context.dataDir.list()?.filter { it.startsWith("app_webview") }?.sorted().orEmpty()
        return JSONArray(names.map { name ->
            val dir = File(context.dataDir, name)
            JSONObject().put("name", name).put("bytes", dir.walkTopDown().filter { it.isFile }.sumOf { it.length() })
        })
    }

    /** Relative paths under [root] whose contents contain [needle]. */
    private fun scan(root: File, needle: ByteArray): List<String> {
        if (needle.isEmpty()) return emptyList()
        val hits = mutableListOf<String>()
        root.walkTopDown()
            .onEnter { dir -> dir.name != "lib" && dir.name != "code_cache" }
            .filter { it.isFile && it.length() in 1..MAX_SCAN_BYTES }
            .forEach { f ->
                val bytes = runCatching { f.readBytes() }.getOrNull() ?: return@forEach
                if (indexOf(bytes, needle) >= 0) hits += f.relativeTo(root).path
            }
        return hits
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        outer@ for (i in 0..haystack.size - needle.size) {
            for (j in needle.indices) if (haystack[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }

    private fun modeString(mode: Int): String {
        val bits = listOf(0x100, 0x80, 0x40, 0x20, 0x10, 0x8, 0x4, 0x2, 0x1)
        val chars = "rwxrwxrwx"
        return bits.mapIndexed { i, b -> if (mode and b != 0) chars[i] else '-' }.joinToString("")
    }

    @Suppress("UNCHECKED_CAST")
    private fun debugReport(): Map<String, Any>? = runCatching {
        val companion = Class.forName("mangabackup.tachi.android.debug.DebugWorkerHooks").getField("Companion").get(null)
        companion.javaClass.getMethod("report").invoke(companion) as Map<String, Any>
    }.getOrNull()
}
