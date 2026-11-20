package mangabackup.tachi.benchmark

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.host.SizingReport
import mangabackup.tachi.host.SizingRule
import mangabackup.tachi.host.replay.ReplayTransport
import mangabackup.tachi.protocol.ArtifactBinding
import mangabackup.tachi.protocol.WorkerClient
import mangabackup.tachi.protocol.WorkerOptions
import mangabackup.tachi.protocol.optStr
import java.io.File
import java.lang.management.ManagementFactory
import java.nio.file.Files
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlin.math.ceil

/**
 * KTD25 benchmark of the desktop Tachi worker, run against the committed
 * captures (no network):
 *
 *  1. per-operation latency (prepare, load, search, details) per qualification source;
 *  2. cooperative-cancel settle time;
 *  3. restart-and-rehydrate time (kill, new process, reload every package, details by durable ref);
 *  4. concurrent-package throughput by pool size, and heap per loaded package;
 *  5. graceful shutdown time.
 *
 * Writes results JSON + Markdown to docs/validation/source-runners/desktop/ and the derived
 * sizing rule to src/main/resources/tachi-worker-sizing.json.
 *
 *   ./gradlew benchmark                     # full run
 *   ./gradlew benchmark -PbenchmarkArgs="--quick"   # CI smoke: fewer iterations, no rule written
 */
const val KEIYOUSHI_SIGNER = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"

data class Q(val dir: String, val packageId: String, val jar: String, val version: String, val sourceId: String)

val QUALIFICATION = listOf(
    Q("all.mangadex", "eu.kanade.tachiyomi.extension.all.mangadex", "tachiyomi-all.mangadex-v1.6.4.jar", "1.6.4", "2499283573021220255"),
    Q("en.weebcentral", "eu.kanade.tachiyomi.extension.en.weebcentral", "tachiyomi-en.weebcentral-v1.6.27.jar", "1.6.27", "2131019126180322627"),
    Q("all.mangafire", "eu.kanade.tachiyomi.extension.all.mangafire", "tachiyomi-all.mangafire-v1.6.38.jar", "1.6.38", "6084907896154116083"),
)
const val QUERY = "Onimai"

/** Explicit limits for the benchmark itself, so the measurement never depends on the rule it produces. */
fun benchLimits(pool: Int) = mapOf(
    "poolSize" to pool.toLong(), "operationDeadlineMs" to 600_000L, "cancelGraceMs" to 30_000L,
    "interactionTimeoutMs" to 600_000L, "shutdownGraceMs" to 30_000L,
)

class Stats(values: List<Double>) {
    private val sorted = values.sorted()
    val n = sorted.size
    fun pct(p: Double): Double = if (sorted.isEmpty()) 0.0 else sorted[minOf(sorted.size - 1, ceil(p / 100.0 * sorted.size).toInt() - 1).coerceAtLeast(0)]
    val p50 get() = pct(50.0)
    val p95 get() = pct(95.0)
    val p99 get() = pct(99.0)
    val max get() = sorted.lastOrNull() ?: 0.0
    fun json() = buildJsonObject {
        put("n", n)
        put("p50Ms", round(p50))
        put("p95Ms", round(p95))
        put("p99Ms", round(p99))
        put("maxMs", round(max))
    }
}

fun round(d: Double) = Math.round(d * 10) / 10.0

fun ms(start: Long) = (System.nanoTime() - start) / 1e6

class Bench(private val repo: File, private val quick: Boolean) {
    private val fixtures = File(repo, "fixtures/source_captures/tachi")
    private val javaHome = File(System.getProperty("java.home"))
    private val classpath = System.getProperty("tachi.workerClasspath")
    private val fixtureJars = File(System.getProperty("tachi.fixtureJars"))
    private val iterations = if (quick) 3 else 20
    private val replayArgs = QUALIFICATION.flatMap { listOf("--replay", File(fixtures, it.dir).absolutePath) }

    private fun spawn(pool: Int, generation: Long = 1): Pair<WorkerClient, Process> {
        val args = benchLimits(pool).flatMap { (k, v) -> listOf("--limit", "$k=$v") } + listOf("--trusted-signer", KEIYOUSHI_SIGNER) + replayArgs
        return WorkerClient.subprocess(javaHome, classpath, args, generation, extraJvmArgs = listOf("-Xmx1g"))
    }

    private val settings = buildJsonObject {
        put("values", JsonObject(emptyMap()))
        put("secrets", JsonObject(emptyMap()))
        put("revision", "bench")
    }

    data class Staged(val q: Q, val binding: ArtifactBinding, val path: File)

    private fun identity(s: Staged) = buildJsonObject {
        put("ecosystem", "tachi")
        put("packageId", s.q.packageId)
        put("sourceId", s.q.sourceId)
        put("artifact", s.binding.toJson())
    }

    fun prepare(client: WorkerClient, q: Q): Staged {
        val jar = File(fixtures, "${q.dir}/${q.jar}")
        val out = Files.createTempFile("bench-staged-", ".jar").toFile()
        val ok = client.call("artifact.prepare", q.packageId, buildJsonObject {
            put("artifact", ArtifactBinding(Digests.sha256(jar), "jar", q.version).toJson())
            put("inputPath", jar.absolutePath)
            put("outputPath", out.absolutePath)
        })
        return Staged(q, ArtifactBinding.from(ok["artifact"]!!.jsonObject), out)
    }

    fun load(client: WorkerClient, s: Staged) = client.call("package.load", s.q.packageId, buildJsonObject {
        put("artifact", s.binding.toJson())
        put("path", s.path.absolutePath)
        put("settings", settings)
    })

    fun search(client: WorkerClient, s: Staged): JsonObject {
        val ok = client.call("search", s.q.packageId, buildJsonObject {
            put("source", identity(s))
            put("settingsRevision", "bench")
            put("query", QUERY)
        })
        val hits = (ok["hits"] as JsonArray).map { it.jsonObject }
        return hits.firstOrNull { it["title"]!!.jsonPrimitive.content.contains(QUERY, true) } ?: hits.first()
    }

    fun details(client: WorkerClient, s: Staged, hit: JsonObject, handle: Boolean) = client.call("details", s.q.packageId, buildJsonObject {
        put("source", identity(s))
        put("settingsRevision", "bench")
        put("ref", hit["ref"]!!)
        if (handle) put("handle", hit["handle"]!!)
    })

    /** CPU time the worker process used per wall-clock second while running operations (0..cores). */
    var cpuUtilisation = 0.0

    /** 1. Per-operation latency. */
    fun latency(): JsonObject {
        val (client, process) = spawn(1)
        var cpuNanos = 0L
        var wallNanos = 0L
        client.handshake()
        val out = buildJsonObject {
            for (q in QUALIFICATION) {
                val prep = ArrayList<Double>()
                val loadT = ArrayList<Double>()
                val searchT = ArrayList<Double>()
                val detailsT = ArrayList<Double>()
                var staged: Staged? = null
                repeat(if (quick) 2 else 5) {
                    var t = System.nanoTime()
                    staged = prepare(client, q)
                    prep += ms(t)
                    t = System.nanoTime()
                    load(client, staged!!)
                    loadT += ms(t)
                }
                val s = staged!!
                repeat(2) { details(client, s, search(client, s), true) } // warm-up
                val cpu0 = process.toHandle().info().totalCpuDuration().map { it.toNanos() }.orElse(0L)
                val wall0 = System.nanoTime()
                repeat(iterations) {
                    var t = System.nanoTime()
                    val hit = search(client, s)
                    searchT += ms(t)
                    t = System.nanoTime()
                    details(client, s, hit, true)
                    detailsT += ms(t)
                }
                cpuNanos += process.toHandle().info().totalCpuDuration().map { it.toNanos() }.orElse(0L) - cpu0
                wallNanos += System.nanoTime() - wall0
                put(q.dir, buildJsonObject {
                    put("prepare", Stats(prep).json())
                    put("load", Stats(loadT).json())
                    put("search", Stats(searchT).json())
                    put("details", Stats(detailsT).json())
                })
            }
        }
        cpuUtilisation = cpuNanos.toDouble() / wallNanos.coerceAtLeast(1)
        client.call("shutdown")
        client.close()
        return out
    }

    /** 2b. Cancel settle for real source operations, cancelled while in flight. */
    fun cancelSettleReal(): Stats {
        val (client, _) = spawn(1)
        client.handshake()
        val samples = ArrayList<Double>()
        for (q in QUALIFICATION) {
            val s = prepare(client, q)
            load(client, s)
            val hit = search(client, s)
            repeat(if (quick) 1 else 5) {
                val (id, future) = client.send("details", s.q.packageId, buildJsonObject {
                    put("source", identity(s))
                    put("settingsRevision", "bench")
                    put("ref", hit["ref"]!!)
                })
                Thread.sleep(200)
                val t = System.nanoTime()
                client.cancel(id)
                val reply = future.get(30, TimeUnit.SECONDS)
                if (reply.err?.optStr("code") == "cancelled") samples += ms(t)
            }
        }
        client.call("shutdown")
        client.close()
        return Stats(samples)
    }

    /** 2. Cooperative-cancel settle time (fixture source sleeping in a loop). */
    fun cancelSettle(): Stats {
        val (client, _) = spawn(1)
        client.handshake()
        val jar = File(fixtureJars, "fixture-busy.jar")
        val binding = ArtifactBinding(Digests.sha256(jar), "jar", "1")
        val ok = client.call("package.load", "fixture.busy", buildJsonObject {
            put("artifact", binding.toJson())
            put("path", jar.absolutePath)
            put("settings", settings)
        })
        val sourceId = (ok["sources"] as JsonArray)[0].jsonObject["sourceId"]!!.jsonPrimitive.content
        val samples = ArrayList<Double>()
        repeat(iterations) {
            val (id, future) = client.send("search", "fixture.busy", buildJsonObject {
                put("source", buildJsonObject {
                    put("ecosystem", "tachi")
                    put("packageId", "fixture.busy")
                    put("sourceId", sourceId)
                    put("artifact", binding.toJson())
                })
                put("settingsRevision", "bench")
                put("query", "slow")
            })
            Thread.sleep(150)
            val t = System.nanoTime()
            client.cancel(id)
            val reply = future.get(30, TimeUnit.SECONDS)
            check(reply.err?.optStr("code") == "cancelled")
            samples += ms(t)
        }
        client.call("shutdown")
        client.close()
        return Stats(samples)
    }

    /** 3. Restart-and-rehydrate and 5. shutdown. */
    fun restartAndShutdown(): Pair<Stats, Stats> {
        val (first, _) = spawn(2)
        first.handshake()
        val staged = QUALIFICATION.map { prepare(first, it) }
        staged.forEach { load(first, it) }
        val hits = staged.associateWith { search(first, it) }
        first.call("shutdown")
        first.close()
        val restart = ArrayList<Double>()
        val shutdown = ArrayList<Double>()
        repeat(if (quick) 2 else 8) { gen ->
            val t = System.nanoTime()
            val (client, process) = spawn(2, generation = gen + 2L)
            client.handshake()
            staged.forEach { load(client, it) }
            for (s in staged) details(client, s, hits.getValue(s), handle = false)
            restart += ms(t)
            val ts = System.nanoTime()
            client.call("shutdown")
            process.waitFor(30, TimeUnit.SECONDS)
            shutdown += ms(ts)
            client.close()
        }
        return Stats(restart) to Stats(shutdown)
    }

    /** 4. Concurrent-package throughput by pool size. */
    fun throughput(): JsonObject {
        // Three distinct qualification packages exist, so concurrency is measured up to three;
        // the rule never claims a pool size beyond what was measured.
        val pools = listOf(1, 2, 3)
        val rounds = if (quick) 2 else 6
        return buildJsonObject {
            for (pool in pools) {
                val (client, _) = spawn(pool)
                client.handshake()
                val packages = QUALIFICATION
                val staged = packages.map { prepare(client, it) }
                staged.forEach { load(client, it) }
                val hits = staged.associateWith { search(client, it) }
                val start = System.nanoTime()
                var ops = 0
                repeat(rounds) {
                    val futures = staged.flatMap { s ->
                        listOf(client.send("details", s.q.packageId, buildJsonObject {
                            put("source", identity(s))
                            put("settingsRevision", "bench")
                            put("ref", hits.getValue(s)["ref"]!!)
                        }).second)
                    }
                    futures.forEach { it.get(120, TimeUnit.SECONDS); ops++ }
                }
                val seconds = ms(start) / 1000
                put("pool$pool", buildJsonObject {
                    put("poolSize", pool)
                    put("operations", ops)
                    put("opsPerSecond", round(ops / seconds))
                })
                client.call("shutdown")
                client.close()
            }
        }
    }

    /** Heap: worker baseline and per loaded package, measured in this JVM after full GCs. */
    fun heap(): Pair<Double, Double> {
        fun used(): Double {
            repeat(3) {
                System.gc()
                Thread.sleep(100)
            }
            val m = ManagementFactory.getMemoryMXBean().heapMemoryUsage
            return m.used / (1024.0 * 1024.0)
        }
        val before = used()
        val transport = ReplayTransport.start(QUALIFICATION.map { File(fixtures, it.dir) })
        val options = WorkerOptions(
            sizing = SizingReport.resolve(benchLimits(1), rule = null)!!,
            trustedSigners = setOf(KEIYOUSHI_SIGNER),
            transport = transport,
            networkMode = "replay",
            stateRoot = Files.createTempDirectory("bench-heap-").toFile(),
            browser = false,
        )
        val (client, _) = WorkerClient.inProcess(options)
        client.handshake()
        val base = used()
        val staged = QUALIFICATION.map { prepare(client, it) }
        staged.forEach { s ->
            load(client, s)
            details(client, s, search(client, s), true)
        }
        val loaded = used()
        client.call("shutdown")
        client.close()
        transport.close()
        return (base - before).coerceAtLeast(1.0) + JVM_BASELINE_MIB to (loaded - base) / QUALIFICATION.size
    }

    companion object {
        /** Floor for the worker's own heap besides what this measurement sees (JIT, class metadata are off-heap). */
        const val JVM_BASELINE_MIB = 64.0
    }
}

fun main(args: Array<String>) {
    val quick = "--quick" in args
    val repo = File(".").absoluteFile
    val bench = Bench(repo, quick)
    val started = Instant.now()
    System.err.println("[bench] latency")
    val latency = bench.latency()
    System.err.println("[bench] cancel settle")
    val cancelFixture = bench.cancelSettle()
    val cancelReal = bench.cancelSettleReal()
    val cancel = Stats(listOf(cancelFixture.max, cancelReal.max))
    System.err.println("[bench] restart and shutdown")
    val (restart, shutdown) = bench.restartAndShutdown()
    System.err.println("[bench] throughput")
    val throughput = bench.throughput()
    System.err.println("[bench] heap")
    val (baseHeap, perPackage) = bench.heap()

    val cores = Runtime.getRuntime().availableProcessors()
    val opP99 = latency.values.flatMap { src -> listOf("search", "details").map { src.jsonObject[it]!!.jsonObject["p99Ms"]!!.jsonPrimitive.content.toDouble() } }.max()
    // Smallest pool reaching 90% of peak throughput, as a fraction of cores.
    val tp = throughput.values.map { it.jsonObject["poolSize"]!!.jsonPrimitive.content.toInt() to it.jsonObject["opsPerSecond"]!!.jsonPrimitive.content.toDouble() }
    val peak = tp.maxOf { it.second }
    val knee = tp.filter { it.second >= 0.9 * peak }.minOf { it.first }
    val rule = SizingRule(
        source = "docs/validation/source-runners/desktop/benchmark-${System.getProperty("os.name").lowercase().replace(' ', '-')}.json (${started})",
        coresFactor = round(1.0 / bench.cpuUtilisation.coerceAtLeast(0.01)),
        baseHeapMiB = ceil(baseHeap),
        perPackageHeapMiB = ceil(maxOf(perPackage, 1.0) * 2),
        p99OperationMs = round(opP99),
        deadlineFactor = DEADLINE_FACTOR,
        maxCancelSettleMs = round(cancel.max),
        maxShutdownMs = round(shutdown.max),
        graceFactor = GRACE_FACTOR,
        interactionTimeoutMs = INTERACTION_TIMEOUT_MS,
        maxPoolSize = tp.maxOf { it.first },
    )
    val inputs = SizingRule.measureInputs()
    val derived = rule.derive(inputs)
    val machine = buildJsonObject {
        put("os", "${System.getProperty("os.name")} ${System.getProperty("os.version")} ${System.getProperty("os.arch")}")
        put("cpu", System.getenv("PROCESSOR_IDENTIFIER") ?: "unknown")
        put("logicalCores", cores)
        put("benchmarkJvmMaxHeapMiB", inputs.maxHeapMiB)
        put("workerJvmMaxHeapMiB", 1024)
        put("java", "${System.getProperty("java.vendor")} ${Runtime.version()}")
    }
    val results = buildJsonObject {
        put("recordedAt", started.toString())
        put("quick", quick)
        put("machine", machine)
        put("network", "replay of committed captures (fixtures/source_captures/tachi); no network")
        put("latency", latency)
        put("cancelSettleFixture", cancelFixture.json())
        put("cancelSettleRealSources", cancelReal.json())
        put("cpuUtilisationPerRunningOperation", round(bench.cpuUtilisation * 1000) / 1000)
        put("throughputKneePoolSize", knee)
        put("restartAndRehydrate", restart.json())
        put("shutdown", shutdown.json())
        put("throughput", throughput)
        put("heap", buildJsonObject {
            put("baseHeapMiB", round(baseHeap))
            put("perPackageHeapMiB", round(perPackage))
        })
        put("rule", rule.toJson())
        put("derivedForThisMachine", buildJsonObject {
            put("inputs", buildJsonObject {
                put("cores", inputs.cores)
                put("maxHeapMiB", inputs.maxHeapMiB)
            })
            put("limits", derived.toJson())
        })
    }
    if (quick) {
        println(results)
        return
    }
    val outDir = File(repo, "docs/validation/source-runners/desktop").apply { mkdirs() }
    val tag = System.getProperty("os.name").lowercase().replace(' ', '-')
    val pretty = kotlinx.serialization.json.Json { prettyPrint = true }
    File(outDir, "benchmark-$tag.json").writeText(pretty.encodeToString(JsonObject.serializer(), results) + "\n")
    File(repo, "tools/tachi-source-runner/src/main/resources/tachi-worker-sizing.json").writeText(pretty.encodeToString(JsonObject.serializer(), rule.toJson()) + "\n")
    System.err.println(pretty.encodeToString(JsonObject.serializer(), results))
}

/**
 * Policy multipliers applied to measured values. Replay removes network latency, so
 * the deadline multiplier is large; U8's live gates recalibrate it from live receipts.
 */
const val DEADLINE_FACTOR = 50.0
const val GRACE_FACTOR = 3.0

/** A user-facing bound for a visible browser interaction, not a machine capability. */
const val INTERACTION_TIMEOUT_MS = 300_000L

@Suppress("unused")
private val unusedArray = buildJsonArray { add(JsonPrimitive(0)) }
