package mangabackup.tachi

import mangabackup.tachi.host.HostTransport
import mangabackup.tachi.host.SizingReport
import mangabackup.tachi.host.replay.ReplayTransport
import mangabackup.tachi.protocol.Worker
import mangabackup.tachi.protocol.WorkerOptions
import java.io.File
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.PrintStream
import java.nio.file.Files
import kotlin.system.exitProcess

/** KTD1 security floor: Amazon Corretto 21.0.13.1 or later (Java4Shell fix). Raised with each security release. */
val JRE_FLOOR: Runtime.Version = Runtime.Version.parse("21.0.13.1")

fun jreMeetsFloor(version: Runtime.Version = Runtime.version()): Boolean = version.compareToIgnoreOptional(JRE_FLOOR) >= 0

private fun usage(message: String): Nothing {
    System.err.println("tachi-source-runner: $message")
    System.err.println(
        "usage: tachi-source-runner [--trusted-signer HEX]... [--trust-file FILE] [--replay CAPTURE_DIR]... " +
            "[--state-dir DIR] [--limit NAME=VALUE]... [--no-browser]",
    )
    exitProcess(64)
}

fun main(args: Array<String>) {
    // Protocol frames own stdout. Anything else that prints goes to stderr.
    val frames = FileOutputStream(FileDescriptor.out)
    System.setOut(PrintStream(FileOutputStream(FileDescriptor.err), true, Charsets.UTF_8))

    if (!jreMeetsFloor()) {
        System.err.println("tachi-source-runner: Java ${Runtime.version()} is below the security floor $JRE_FLOOR; refusing to start")
        exitProcess(3)
    }

    val trusted = LinkedHashSet<String>()
    val replay = ArrayList<File>()
    val limits = LinkedHashMap<String, Long>()
    var stateDir: File? = null
    var browser = true
    var i = 0
    fun value(): String = args.getOrNull(++i) ?: usage("${args[i - 1]} needs a value")
    while (i < args.size) {
        when (val a = args[i]) {
            "--trusted-signer" -> trusted += value().lowercase()
            "--trust-file" -> File(value()).readLines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }.forEach { trusted += it.lowercase() }
            "--replay" -> replay += File(value())
            "--state-dir" -> stateDir = File(value())
            "--limit" -> {
                val (k, v) = value().split('=', limit = 2).takeIf { it.size == 2 } ?: usage("--limit needs NAME=VALUE")
                limits[k] = v.toLongOrNull() ?: usage("--limit $k needs an integer")
            }
            "--no-browser" -> browser = false
            else -> usage("unknown argument $a")
        }
        i++
    }
    val sizing = SizingReport.resolve(limits)
        ?: usage("no committed sizing rule (tachi-worker-sizing.json) and --limit does not set every limit")
    val transport: HostTransport = if (replay.isEmpty()) HostTransport.LIVE else ReplayTransport.start(replay)
    val root = stateDir ?: Files.createTempDirectory("tachi-worker-").toFile()
    val options = WorkerOptions(
        sizing = sizing,
        trustedSigners = trusted,
        transport = transport,
        networkMode = if (replay.isEmpty()) "live" else "replay",
        stateRoot = root,
        browser = browser,
    )
    if (replay.isNotEmpty()) System.err.println("[worker] network mode: replay from ${replay.joinToString()} (fails closed on any uncaptured request)")
    val code = try {
        Worker(System.`in`, frames, options).run()
    } finally {
        (transport as? AutoCloseable)?.close()
        if (stateDir == null) root.deleteRecursively()
    }
    exitProcess(code)
}
