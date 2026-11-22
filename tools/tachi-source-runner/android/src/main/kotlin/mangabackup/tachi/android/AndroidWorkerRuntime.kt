package mangabackup.tachi.android

import android.content.Context
import mangabackup.tachi.host.HostTransport
import mangabackup.tachi.host.SizingReport
import mangabackup.tachi.protocol.ProcessPlatform
import mangabackup.tachi.protocol.Worker
import mangabackup.tachi.protocol.WorkerOptions
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/**
 * Builds the shared protocol [Worker] for the `:source_runtime` service.
 *
 * Arguments follow the desktop worker's command line, so the app-process
 * supervisor passes the same `WorkerSpec.arguments`:
 * - `--limit NAME=VALUE` overrides a KTD25 limit (tests use small values);
 * - `--replay NAME` serves the committed capture `NAME` from the debug asset
 *   folder and fails every other request (debug builds only);
 * - `--challenge-once PATH` (debug) answers the first request to PATH with
 *   MangaFire's captcha 403 before replaying, to drive the browser path;
 * - `--offline-browser` (debug) points the process's WebViews at a loopback
 *   proxy that refuses every request, so no page load reaches a server;
 * - `--interactive-challenges MS` lets a Cloudflare challenge open the
 *   service's visible challenge Activity for at most MS milliseconds while
 *   the app is visible; without it (unattended) challenges fail as
 *   interaction-required.
 * Release builds refuse every debug-only argument.
 */
object AndroidWorkerRuntime {
    /** Debug-only hooks, found reflectively so release builds carry none of them. */
    interface DebugHooks {
        fun replayTransport(context: Context, captures: List<String>, challengePaths: List<String>): HostTransport

        /** Refuses every WebView request in this process; returns a description for the handshake. */
        fun blockBrowserNetwork(context: Context): String
    }

    private val debugHooks: DebugHooks? by lazy {
        runCatching {
            Class.forName("mangabackup.tachi.android.debug.DebugWorkerHooks").getDeclaredConstructor().newInstance() as DebugHooks
        }.getOrNull()
    }

    val debugHooksAvailable: Boolean get() = debugHooks != null

    class Started(
        val worker: Worker,
        val options: WorkerOptions,
        val notes: Map<String, String>,
        /** Bound of an interactive challenge, or null when challenges are not shown (unattended). */
        val challengeTimeoutMs: Long?,
    )

    fun start(context: Context, runtime: AndroidPackageRuntime, args: List<String>, input: InputStream, output: OutputStream): Started {
        val replay = ArrayList<String>()
        val challenge = ArrayList<String>()
        val limits = LinkedHashMap<String, Long>()
        var offlineBrowser = false
        var challengeTimeoutMs: Long? = null
        var i = 0
        fun value(): String = args.getOrNull(++i) ?: throw IllegalArgumentException("${args[i - 1]} needs a value")
        while (i < args.size) {
            when (val a = args[i]) {
                "--replay" -> replay += value()
                "--challenge-once" -> challenge += value()
                "--offline-browser" -> offlineBrowser = true
                "--interactive-challenges" -> challengeTimeoutMs = value().toLongOrNull()?.takeIf { it > 0 }
                    ?: throw IllegalArgumentException("--interactive-challenges needs a positive millisecond bound")
                "--limit" -> {
                    val (k, v) = value().split('=', limit = 2).takeIf { it.size == 2 } ?: throw IllegalArgumentException("--limit needs NAME=VALUE")
                    limits[k] = v.toLongOrNull() ?: throw IllegalArgumentException("--limit $k needs an integer")
                }
                else -> throw IllegalArgumentException("unknown worker argument $a")
            }
            i++
        }
        val needsDebug = replay.isNotEmpty() || challenge.isNotEmpty() || offlineBrowser
        val hooks = debugHooks
        if (needsDebug && hooks == null) throw IllegalArgumentException("replay and offline browser modes exist only in debug builds")
        val notes = LinkedHashMap<String, String>()
        val transport = if (replay.isEmpty()) HostTransport.LIVE else hooks!!.replayTransport(context, replay, challenge)
        if (offlineBrowser) notes["browserNetwork"] = hooks!!.blockBrowserNetwork(context)
        runtime.notes.putAll(notes)
        val sizing = SizingReport.resolve(limits) ?: throw IllegalStateException("no committed Android sizing rule and --limit does not set every limit")
        val root = File(context.noBackupFilesDir, "source_runtime/state").apply {
            deleteRecursively()
            mkdirs()
        }
        val options = WorkerOptions(
            sizing = sizing,
            transport = transport,
            networkMode = if (replay.isEmpty()) "live" else "replay",
            stateRoot = root,
            // Tachi's WebViews are real ones in this process; the worker sends no host.browser.* requests.
            browser = false,
            // Its own process: the supervisor owns its deadlines, and original DEX is loaded as verified.
            platform = ProcessPlatform("android", android.os.Process.myPid().toLong()),
        )
        return Started(Worker(input, output, options, runtime), options, notes, challengeTimeoutMs)
    }
}
