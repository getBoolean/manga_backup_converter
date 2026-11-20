package mangabackup.tachi.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/** Every KTD4 limit the worker reports. Values come from [SizingRule] or explicit overrides, never constants. */
data class WorkerLimits(
    val poolSize: Int,
    val operationDeadlineMs: Long,
    val cancelGraceMs: Long,
    val interactionTimeoutMs: Long,
    val shutdownGraceMs: Long,
) {
    fun toJson() = buildJsonObject {
        put("poolSize", poolSize)
        put("operationDeadlineMs", operationDeadlineMs)
        put("cancelGraceMs", cancelGraceMs)
        put("interactionTimeoutMs", interactionTimeoutMs)
        put("shutdownGraceMs", shutdownGraceMs)
    }

    fun override(values: Map<String, Long>): WorkerLimits = WorkerLimits(
        poolSize = values["poolSize"]?.toInt() ?: poolSize,
        operationDeadlineMs = values["operationDeadlineMs"] ?: operationDeadlineMs,
        cancelGraceMs = values["cancelGraceMs"] ?: cancelGraceMs,
        interactionTimeoutMs = values["interactionTimeoutMs"] ?: interactionTimeoutMs,
        shutdownGraceMs = values["shutdownGraceMs"] ?: shutdownGraceMs,
    )

    companion object {
        val KEYS = setOf("poolSize", "operationDeadlineMs", "cancelGraceMs", "interactionTimeoutMs", "shutdownGraceMs")

        fun fromOverrides(values: Map<String, Long>): WorkerLimits? {
            if (!values.keys.containsAll(KEYS)) return null
            return WorkerLimits(0, 0, 0, 0, 0).override(values)
        }
    }
}

/**
 * The adaptive sizing rule produced by the KTD25 benchmark
 * (tools/tachi-source-runner/benchmark, results in
 * docs/validation/source-runners/desktop/). Inputs measured at startup: logical
 * cores and maximum heap. The rule's coefficients are committed as the
 * `tachi-worker-sizing.json` resource; a worker without it refuses to derive
 * limits rather than invent them.
 *
 *  poolSize            = clamp(floor(cores × coresFactor), 1, floor((maxHeapMiB − baseHeapMiB) / perPackageHeapMiB))
 *  operationDeadlineMs = ceil(p99OperationMs × deadlineFactor)
 *  cancelGraceMs       = ceil(maxCancelSettleMs × graceFactor)
 *  shutdownGraceMs     = ceil(maxShutdownMs × graceFactor)
 *  interactionTimeoutMs = interactionTimeoutMs (a user-facing bound recorded with the rule)
 */
data class SizingRule(
    val source: String,
    val coresFactor: Double,
    val baseHeapMiB: Double,
    val perPackageHeapMiB: Double,
    val p99OperationMs: Double,
    val deadlineFactor: Double,
    val maxCancelSettleMs: Double,
    val maxShutdownMs: Double,
    val graceFactor: Double,
    val interactionTimeoutMs: Long,
) {
    data class Inputs(val cores: Int, val maxHeapMiB: Long)

    fun derive(inputs: Inputs): WorkerLimits {
        val byCores = kotlin.math.floor(inputs.cores * coresFactor).toInt()
        val byHeap = kotlin.math.floor((inputs.maxHeapMiB - baseHeapMiB) / perPackageHeapMiB).toInt()
        val pool = maxOf(1, minOf(byCores, byHeap))
        return WorkerLimits(
            poolSize = pool,
            operationDeadlineMs = kotlin.math.ceil(p99OperationMs * deadlineFactor).toLong(),
            cancelGraceMs = kotlin.math.ceil(maxCancelSettleMs * graceFactor).toLong(),
            interactionTimeoutMs = interactionTimeoutMs,
            shutdownGraceMs = kotlin.math.ceil(maxShutdownMs * graceFactor).toLong(),
        )
    }

    fun toJson(): JsonObject = buildJsonObject {
        put("source", source)
        put("coresFactor", coresFactor)
        put("baseHeapMiB", baseHeapMiB)
        put("perPackageHeapMiB", perPackageHeapMiB)
        put("p99OperationMs", p99OperationMs)
        put("deadlineFactor", deadlineFactor)
        put("maxCancelSettleMs", maxCancelSettleMs)
        put("maxShutdownMs", maxShutdownMs)
        put("graceFactor", graceFactor)
        put("interactionTimeoutMs", interactionTimeoutMs)
    }

    companion object {
        const val RESOURCE = "/tachi-worker-sizing.json"

        fun parse(text: String): SizingRule {
            val o = Json.parseToJsonElement(text).jsonObject
            fun d(k: String) = o[k]!!.jsonPrimitive.double
            return SizingRule(
                source = o["source"]!!.jsonPrimitive.content,
                coresFactor = d("coresFactor"),
                baseHeapMiB = d("baseHeapMiB"),
                perPackageHeapMiB = d("perPackageHeapMiB"),
                p99OperationMs = d("p99OperationMs"),
                deadlineFactor = d("deadlineFactor"),
                maxCancelSettleMs = d("maxCancelSettleMs"),
                maxShutdownMs = d("maxShutdownMs"),
                graceFactor = d("graceFactor"),
                interactionTimeoutMs = o["interactionTimeoutMs"]!!.jsonPrimitive.long,
            )
        }

        fun committed(): SizingRule? = SizingRule::class.java.getResource(RESOURCE)?.readText()?.let(::parse)

        fun measureInputs(): Inputs = Inputs(Runtime.getRuntime().availableProcessors(), Runtime.getRuntime().maxMemory() / (1024 * 1024))
    }
}

/** What the handshake reports about sizing (KTD25). */
data class SizingReport(val rule: SizingRule?, val inputs: SizingRule.Inputs, val limits: WorkerLimits, val overridden: Set<String>) {
    fun toJson() = buildJsonObject {
        put("rule", rule?.toJson() ?: kotlinx.serialization.json.JsonNull)
        put("inputs", buildJsonObject {
            put("cores", inputs.cores)
            put("maxHeapMiB", inputs.maxHeapMiB)
        })
        put("derived", limits.toJson())
        put("overridden", kotlinx.serialization.json.JsonArray(overridden.sorted().map { kotlinx.serialization.json.JsonPrimitive(it) }))
    }

    companion object {
        /** Derives limits from the committed rule, applying explicit overrides; null if neither covers every limit. */
        fun resolve(overrides: Map<String, Long>, rule: SizingRule? = SizingRule.committed()): SizingReport? {
            val inputs = SizingRule.measureInputs()
            val base = rule?.derive(inputs) ?: WorkerLimits.fromOverrides(overrides)?.let { return SizingReport(null, inputs, it, overrides.keys) } ?: return null
            return SizingReport(rule, inputs, base.override(overrides), overrides.keys)
        }
    }
}

