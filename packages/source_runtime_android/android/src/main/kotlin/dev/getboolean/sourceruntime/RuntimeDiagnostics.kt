package dev.getboolean.sourceruntime

import android.os.Debug
import android.os.Process
import android.util.Log
import androidx.annotation.Keep
import org.json.JSONObject

/**
 * Process diagnostics used to bound JNI reference ownership (KTD23).
 *
 * There is no public API for the JNI global reference table. ART prints it,
 * with a per-class summary and the total, to logcat when
 * `Debug.dumpReferenceTables()` (hidden) runs, and an app may read its own log
 * lines. Java garbage is collected first so that only live references count.
 */
@Keep
object RuntimeDiagnostics {
    private const val TAG = "SourceRuntimeDiag"
    private val TOTAL = Regex("""^\s*Last \d+ entries \(of (\d+)\):""")
    private val SUMMARY_LINE = Regex("""^\s*(\d+) of (.+?)(?: \(\d+ unique instances?\))?\s*$""")

    /**
     * Returns `{"total": n, "classes": {"<class>": count, ...}}` for this
     * process's JNI global reference table, or `{"total": -1}` if the runtime
     * does not expose a parseable dump.
     */
    fun jniGlobalReferenceSummary(): String {
        collectJavaGarbage()
        val marker = "ref-dump-${System.nanoTime()}"
        Log.i(TAG, marker)
        try {
            Debug::class.java.getMethod("dumpReferenceTables").invoke(null)
        } catch (e: ReflectiveOperationException) {
            Log.w(TAG, "dumpReferenceTables unavailable: $e")
            return JSONObject().put("total", -1).put("reason", e.toString()).toString()
        }
        val logcat = ProcessBuilder(
            "logcat", "-d", "-v", "raw", "--pid=${Process.myPid()}",
        ).redirectErrorStream(true).start()
        val lines = logcat.inputStream.bufferedReader().use { it.readLines() }
        logcat.waitFor()
        return parse(lines, marker).toString()
    }

    /** Runs Java GC and pending finalizers twice. */
    fun collectJavaGarbage() {
        repeat(2) {
            Runtime.getRuntime().gc()
            System.runFinalization()
        }
    }

    private fun parse(lines: List<String>, marker: String): JSONObject {
        val start = lines.indexOfLast { it.contains(marker) }
        if (start < 0) return JSONObject().put("total", -1).put("reason", "no dump in logcat")
        var total = -1
        val classes = JSONObject()
        var inGlobal = false
        var inSummary = false
        for (line in lines.subList(start, lines.size)) {
            when {
                line.startsWith("global reference table dump") -> inGlobal = true
                !inGlobal -> continue
                line.contains("reference table dump") -> break // next (weak) table
                total < 0 && TOTAL.containsMatchIn(line) -> total = TOTAL.find(line)!!.groupValues[1].toInt()
                line.trim() == "Summary:" -> inSummary = true
                inSummary -> SUMMARY_LINE.find(line)?.let {
                    val name = it.groupValues[2]
                    classes.put(name, classes.optInt(name) + it.groupValues[1].toInt())
                }
            }
        }
        return JSONObject().put("total", total).put("classes", classes)
    }
}
