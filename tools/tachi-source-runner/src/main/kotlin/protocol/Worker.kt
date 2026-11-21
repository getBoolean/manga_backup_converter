package mangabackup.tachi.protocol

import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import mangabackup.tachi.extensions.ApkConverter
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.ArtifactVerifier
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.extensions.ExtensionLoader
import mangabackup.tachi.extensions.ExtensionPackage
import mangabackup.tachi.extensions.PackageClassLoader
import mangabackup.tachi.extensions.SourceOperations
import mangabackup.tachi.extensions.UnsupportedApiException
import mangabackup.tachi.host.HostInjekt
import mangabackup.tachi.host.HostOperationException
import mangabackup.tachi.host.OperationContext
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.host.PackageScope
import mangabackup.tachi.host.withHandshake
import mangabackup.tachi.shim.HostFailures
import mangabackup.tachi.shim.UnsupportedHostApi
import mangabackup.tachi.webkit.BrowserBridge
import java.io.BufferedReader
import java.io.File
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.util.ArrayDeque
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * The single desktop Tachi worker (KTD1, KTD4). Reads protocol frames from
 * [input], writes frames to [output] (and nothing else), and hosts every
 * loaded package in its own class loader.
 *
 * Concurrency: one operation at a time per package, enforced here even though
 * the supervisor already guarantees it; different packages run concurrently on
 * a fixed pool of [WorkerLimits.poolSize] threads (KTD25). Deadlines are the
 * supervisor's; the worker answers `cancel` cooperatively by cancelling the
 * operation's coroutine, its package's HTTP calls and browser sessions, and
 * interrupting its thread.
 */
class Worker(input: InputStream, private val output: OutputStream, private val options: WorkerOptions) {
    private val reader = BufferedReader(InputStreamReader(input, StandardCharsets.UTF_8), 1 shl 16)
    private val writeLock = Any()

    @Volatile
    private var generation = -1L

    @Volatile
    private var maxFrameBytes = Wire.MAX_FRAME_BYTES

    /** The minor version agreed in the handshake; 1.2 browser requests are sent only when it is at least 2. */
    @Volatile
    var protocolMinor = 0L
        private set

    @Volatile
    private var shuttingDown = false

    private val threadIds = AtomicInteger()
    private val pool = ThreadPoolExecutor(
        options.sizing.limits.poolSize, options.sizing.limits.poolSize, 0, TimeUnit.MILLISECONDS, LinkedBlockingQueue(),
    ) { r -> Thread(r, "tachi-op-${threadIds.incrementAndGet()}").apply { isDaemon = true } }

    private val packages = ConcurrentHashMap<String, LoadedState>()
    private val queues = HashMap<String, ArrayDeque<OpTask>>()
    private val runningPackages = HashSet<String>()
    private val tasks = ConcurrentHashMap<String, OpTask>()
    private val reverse = ConcurrentHashMap<String, PendingReverse>()
    private val reverseIds = AtomicLong()
    private val envIds = AtomicLong()

    val browser = BrowserBridge(this)

    /** A package loaded in this process. */
    class LoadedState(val pkg: ExtensionPackage, val artifact: ArtifactBinding, val ops: SourceOperations)

    private class PendingReverse(val of: String, val future: CompletableFuture<JsonObject>)

    inner class OpTask(val frame: Frame) : OperationContext {
        override val requestId: String get() = frame.id
        override val sourceId: String? = runCatching { frame.payload?.optObj("source")?.optStr("sourceId") }.getOrNull()
        val packageId: String = frame.pkg!!

        @Volatile
        var thread: Thread? = null

        @Volatile
        var job: Job? = null

        @Volatile
        override var isCancelled = false

        /** Set (under [writeLock]) once the reply is being written: no reverse request may follow it. */
        @Volatile
        var finished = false
        val hostFailures = java.util.concurrent.CopyOnWriteArrayList<Throwable>()
        private val warningSet = java.util.concurrent.CopyOnWriteArraySet<String>()

        override fun addWarning(warning: String) {
            warningSet += warning
        }

        override val warnings: List<String> get() = warningSet.toList()

        override fun recordHostFailure(failure: Throwable) {
            hostFailures += failure
        }

        fun cancel() {
            isCancelled = true
            job?.cancel()
            packages[packageId]?.pkg?.environment?.cancelActiveCalls()
            browser.cancelOperation(requestId)
            thread?.interrupt()
        }
    }

    init {
        HostInjekt.install()
        HostFailures.install { failure -> PackageScope.current()?.currentOperation?.recordHostFailure(failure) }
        mangabackup.tachi.webkit.WebkitHost.install(browser)
    }

    /** Runs until `shutdown` or end of input. Returns the process exit code. */
    fun run(): Int {
        try {
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isBlank()) continue
                if (line.toByteArray(StandardCharsets.UTF_8).size > maxFrameBytes) {
                    fatal("incoming frame exceeds the ${maxFrameBytes}-byte limit")
                    return 2
                }
                val frame = try {
                    Frame.parse(line)
                } catch (e: ProtocolViolation) {
                    fatal("malformed frame: ${e.message}")
                    return 2
                }
                if (generation >= 0 && frame.gen != generation) {
                    fatal("frame for generation ${frame.gen}, current generation is $generation")
                    return 2
                }
                if (!dispatch(frame)) return 0
            }
            return 0
        } finally {
            closeAll()
        }
    }

    private fun fatal(message: String) {
        System.err.println("[worker] protocol violation: $message")
    }

    /** Returns false when the worker should exit. */
    private fun dispatch(frame: Frame): Boolean {
        when (frame.t) {
            "req" -> when (frame.op) {
                "handshake" -> handshake(frame)
                "shutdown" -> {
                    shuttingDown = true
                    closeAll()
                    reply(frame, ok = JsonObject(emptyMap()))
                    output.flush()
                    return false
                }
                null -> replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "request has no op"))
                else -> {
                    if (generation < 0) {
                        replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "handshake required first"))
                    } else if (frame.pkg == null) {
                        replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "${frame.op} needs pkg"))
                    } else {
                        enqueue(OpTask(frame))
                    }
                }
            }
            "cancel" -> cancel(frame.id)
            "rres" -> {
                val pending = reverse.remove(frame.id) ?: return true
                when {
                    frame.err != null -> pending.future.completeExceptionally(WorkerError.fromJson(frame.err))
                    frame.ok != null -> pending.future.complete(frame.ok)
                    else -> pending.future.completeExceptionally(WorkerError(ErrorCode.PROTOCOL_VIOLATION, "rres without ok or err"))
                }
            }
            // Events are handled here, on the frame reader, never on a thread that waits for an rres:
            // a held request may be what keeps the worker's own reverse request from being answered.
            "event" -> when (frame.op) {
                "host.browser.message" -> frame.payload?.let(browser::onMessage)
                "host.browser.request" -> frame.payload?.let(browser::onRequest)
            }
            else -> fatal("unexpected frame type ${frame.t} from supervisor")
        }
        return true
    }

    private fun handshake(frame: Frame) {
        val p = frame.payload ?: return replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "handshake needs a payload"))
        val versions = try {
            p.arr("protocolVersions").map { (it as JsonPrimitive).content.toLong() }
        } catch (e: Exception) {
            return replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "bad protocolVersions"))
        }
        if (Wire.VERSION.toLong() !in versions) {
            return replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "supervisor offers $versions; worker speaks ${Wire.VERSION}"))
        }
        // 1.1: answer with the lower of the offered minor and ours; absent (a 1.0 supervisor) is 0.
        val offeredMinor = when (val m = p["protocolMinor"]) {
            null, kotlinx.serialization.json.JsonNull -> 0L
            else -> (m as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toLongOrNull()?.takeIf { it >= 0 }
                ?: return replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "protocolMinor must be a non-negative integer"))
        }
        generation = frame.gen
        protocolMinor = minOf(offeredMinor, Wire.MINOR_VERSION.toLong())
        maxFrameBytes = try {
            minOf(p.int("maxFrameBytes"), Wire.MAX_FRAME_BYTES.toLong()).toInt()
        } catch (_: ProtocolViolation) {
            Wire.MAX_FRAME_BYTES
        }
        reply(
            frame,
            ok = buildJsonObject {
                put("protocolVersion", Wire.VERSION)
                put("protocolMinor", protocolMinor)
                put("worker", WorkerOptions.WORKER_NAME)
                put("workerVersion", WorkerOptions.WORKER_VERSION)
                put("pid", ProcessHandle.current().pid())
                put("capabilities", buildJsonObject {
                    put("apiFamilies", buildJsonArray { ExtensionLoader.apiFamilies.sorted().forEach { add(JsonPrimitive(it)) } })
                    put("browser", options.browser)
                })
                // KTD25 limits and sizing (1.1), then additive runtime identity fields readers ignore.
                put("limits", options.sizing.limits.toJson().withHandshake(options.sizing.rule))
                put("sizing", options.sizing.toJson())
                put("networkMode", options.networkMode)
                put("javaVersion", Runtime.version().toString())
                put("javaVendor", System.getProperty("java.vendor").orEmpty())
                put("hostCompatibility", WorkerOptions.HOST_COMPATIBILITY)
            },
        )
    }

    // --- per-package queueing --------------------------------------------------------------

    private fun enqueue(task: OpTask) {
        tasks[task.frame.id] = task
        synchronized(queues) {
            queues.getOrPut(task.packageId) { ArrayDeque() }.addLast(task)
            pump(task.packageId)
        }
    }

    /** Starts the package's next queued operation if none is running. Caller holds [queues]. */
    private fun pump(packageId: String) {
        if (packageId in runningPackages) return
        val next = queues[packageId]?.pollFirst() ?: return
        runningPackages += packageId
        pool.execute { execute(next) }
    }

    private fun cancel(id: String) {
        val task = tasks[id] ?: return
        var dequeued = false
        synchronized(queues) {
            dequeued = queues[task.packageId]?.remove(task) == true
        }
        if (dequeued) {
            task.isCancelled = true
            tasks.remove(id)
            replyError(task.frame, WorkerError(ErrorCode.CANCELLED, "cancelled before it started"))
        } else {
            task.cancel()
        }
    }

    private fun execute(task: OpTask) {
        task.thread = Thread.currentThread()
        val state = packages[task.packageId]
        val env = state?.pkg?.environment
        var ok: JsonObject? = null
        var error: WorkerError? = null
        try {
            if (task.isCancelled) throw WorkerError(ErrorCode.CANCELLED, "cancelled")
            env?.currentOperation = task
            val job = Job()
            task.job = job
            ok = runBlocking(job) {
                if (env != null) PackageScope.bind(env) { runOp(task) } else runOp(task)
            }
        } catch (t: Throwable) {
            error = mapError(t, task)
        } finally {
            env?.currentOperation = null
            Thread.interrupted()
        }
        if (task.isCancelled) error = WorkerError(ErrorCode.CANCELLED, "cancelled")
        browser.closeSessionsOf(task.frame.id)
        synchronized(writeLock) {
            task.finished = true
            failReverseRequestsOf(task.frame.id)
        }
        browser.operationFinished(task.frame.id)
        tasks.remove(task.frame.id)
        if (error != null) replyError(task.frame, error) else reply(task.frame, ok = ok ?: JsonObject(emptyMap()))
        synchronized(queues) {
            runningPackages -= task.packageId
            pump(task.packageId)
        }
    }

    private suspend fun runOp(task: OpTask): JsonObject {
        val p = task.frame.payload ?: JsonObject(emptyMap())
        return when (task.frame.op) {
            "artifact.prepare" -> prepare(p)
            "package.load" -> load(task.packageId, p)
            "package.unload" -> {
                packages.remove(task.packageId)?.pkg?.close()
                    ?: throw WorkerError(ErrorCode.RUNTIME_UNAVAILABLE, "package ${task.packageId} is not loaded")
                JsonObject(emptyMap())
            }
            "settings.update" -> {
                val state = requireLoaded(task.packageId)
                state.pkg.environment.replaceSettings(SettingsCodec.from(p.obj("settings")))
                JsonObject(emptyMap())
            }
            "search" -> requireLoaded(task.packageId).ops.search(p, state = requireLoaded(task.packageId))
            "details" -> requireLoaded(task.packageId).ops.details(p, state = requireLoaded(task.packageId))
            "dispose" -> requireLoaded(task.packageId).ops.dispose(p)
            else -> throw WorkerError(ErrorCode.PROTOCOL_VIOLATION, "unknown operation ${task.frame.op}")
        }
    }

    private fun requireLoaded(packageId: String): LoadedState =
        packages[packageId] ?: throw WorkerError(ErrorCode.RUNTIME_UNAVAILABLE, "package $packageId is not loaded")

    // --- operations --------------------------------------------------------------------------

    private fun prepare(p: JsonObject): JsonObject {
        val artifact = ArtifactBinding.from(p.obj("artifact"))
        val input = File(p.str("inputPath"))
        val output = File(p.str("outputPath"))
        // KTD5: the request's trust anchor is the only source of trusted signers. An absent or empty list (a 1.0
        // supervisor, or no stored anchor) is refused by the verifier as artifact-incompatible; nothing else is trusted.
        val trusted = p.optArr("trustedSigners")?.map { it.asStringStrict("trustedSigners[]").lowercase() }?.toSet() ?: emptySet()
        if (trusted.isEmpty()) throw ArtifactException("artifact.prepare carries no trustedSigners; refusing to verify ${artifact.kind} without a stored trust anchor")
        try {
            output.parentFile?.mkdirs()
            val staging = Files.createTempDirectory(output.parentFile?.toPath() ?: File(".").toPath(), ".prepare-").toFile()
            try {
                // Verify a private copy so the bytes checked are the bytes converted or staged.
                val copy = File(staging, "input.bin")
                input.copyTo(copy, overwrite = true)
                Digests.requireSha256(copy, artifact.sha256, "Input artifact")
                val (producer, converter) = when (artifact.kind) {
                    "jar" -> {
                        ArtifactVerifier.verifyJar(copy, trusted)
                        ApkConverter.writeAtomically(output.toPath(), copy.readBytes())
                        "tachi-jvm/jar-verify" to "jar-verify.1"
                    }
                    "apk" -> {
                        ArtifactVerifier.verifyApk(copy, trusted)
                        ApkConverter.convert(copy, output)
                        "tachi-jvm/apk-dex2jar" to ApkConverter.CONVERTER_VERSION
                    }
                    else -> throw ArtifactException("artifact kind '${artifact.kind}' is not a Tachi artifact (jar or apk)")
                }
                val digest = Digests.sha256(output)
                return buildJsonObject {
                    put("artifact", ArtifactBinding(digest, "jar", artifact.version).toJson())
                    put("producer", producer)
                    put("converterVersion", "$converter+${WorkerOptions.HOST_COMPATIBILITY}")
                }
            } finally {
                staging.deleteRecursively()
            }
        } catch (t: Throwable) {
            output.delete()
            throw t
        }
    }

    private fun load(packageId: String, p: JsonObject): JsonObject {
        val artifact = ArtifactBinding.from(p.obj("artifact"))
        if (artifact.kind != "jar") throw ArtifactException("package.load needs a prepared jar, got kind '${artifact.kind}'")
        val path = File(p.str("path"))
        val settings = SettingsCodec.from(p.obj("settings"))
        Digests.requireSha256(path, artifact.sha256, "Staged artifact")
        packages.remove(packageId)?.pkg?.close()
        val stateDir = File(options.stateRoot, "pkg-${envIds.incrementAndGet()}")
        val env = PackageEnvironment(packageId, stateDir, options.transport, options.defaultUserAgent, settings)
        val pkg = try {
            PackageScope.bind(env) { ExtensionLoader.load(path, env) }
        } catch (t: Throwable) {
            env.close()
            throw t
        }
        val state = LoadedState(pkg, artifact, SourceOperations(pkg, artifact))
        packages[packageId] = state
        val requiresBrowser = SourceOperations.referencesWebView(path)
        val family = ExtensionLoader.apiFamily(pkg.manifest.libVersion)
        return buildJsonObject {
            put("sources", buildJsonArray {
                for (source in pkg.sources) {
                    add(buildJsonObject {
                        put("sourceId", source.id.toString())
                        put("name", source.name)
                        put("language", source.lang.ifEmpty { null })
                        val ops = mutableListOf("search", "mangaDetails", "chapterList")
                        if (source is eu.kanade.tachiyomi.source.ConfigurableSource) ops += "settings"
                        put("capabilities", capabilitiesJson(ops, listOf(family), requiresBrowser))
                    })
                }
            })
        }
    }

    // --- reverse requests (KTD20) --------------------------------------------------------------

    /**
     * Sends a `host.browser.*` reverse request on behalf of the in-flight
     * operation [of]. Fails with `cancelled` if that operation has finished, so
     * no reverse request can ever follow its reply.
     */
    fun reverseRequest(of: String, op: String, payload: JsonObject): CompletableFuture<JsonObject> {
        val future = CompletableFuture<JsonObject>()
        val id = "r${reverseIds.incrementAndGet()}"
        synchronized(writeLock) {
            val task = tasks[of]
            if (task == null || task.finished || task.isCancelled) {
                future.completeExceptionally(WorkerError(ErrorCode.CANCELLED, "originating operation $of is no longer in flight"))
                return future
            }
            reverse[id] = PendingReverse(of, future)
            writeFrame(Frame(t = "rreq", id = id, gen = generation, op = op, of = of, payload = payload))
        }
        return future
    }

    private fun failReverseRequestsOf(of: String) {
        val it = reverse.entries.iterator()
        while (it.hasNext()) {
            val (_, pending) = it.next()
            if (pending.of == of) {
                it.remove()
                pending.future.completeExceptionally(WorkerError(ErrorCode.CANCELLED, "originating operation finished"))
            }
        }
    }

    // --- replies ---------------------------------------------------------------------------------

    private fun reply(request: Frame, ok: JsonObject) {
        val frame = Frame(t = "res", id = request.id, gen = generation, ok = ok)
        synchronized(writeLock) {
            val encoded = frame.encode()
            val size = encoded.toByteArray(StandardCharsets.UTF_8).size
            if (size > maxFrameBytes) {
                writeRaw(Frame(t = "res", id = request.id, gen = generation, err = WorkerError(ErrorCode.SOURCE_ERROR, "reply of $size bytes exceeds the $maxFrameBytes-byte frame limit").toJson()).encode())
            } else {
                writeRaw(encoded)
            }
        }
    }

    private fun replyError(request: Frame, error: WorkerError) {
        synchronized(writeLock) {
            writeRaw(Frame(t = "res", id = request.id, gen = generation, err = error.toJson()).encode())
        }
    }

    private fun writeFrame(frame: Frame) = writeRaw(frame.encode())

    private fun writeRaw(line: String) {
        synchronized(writeLock) {
            output.write(line.toByteArray(StandardCharsets.UTF_8))
            output.write('\n'.code)
            output.flush()
        }
    }

    private fun closeAll() {
        for (state in packages.values) {
            try {
                state.pkg.close()
            } catch (e: Exception) {
                System.err.println("[worker] closing ${state.pkg.packageId}: $e")
            }
        }
        packages.clear()
        for (task in tasks.values) task.cancel()
        pool.shutdownNow()
    }

    companion object {
        /** Maps a failure to a protocol error (KTD4 error codes; distinct host errors per U3). */
        fun mapError(t: Throwable, task: OperationContext?): WorkerError {
            if (t is WorkerError) return t
            if (task?.isCancelled == true) return WorkerError(ErrorCode.CANCELLED, "cancelled")
            if (t is ArtifactException) return WorkerError(ErrorCode.ARTIFACT_INCOMPATIBLE, t.message ?: "artifact rejected", cause = t)
            if (t is UnsupportedApiException) return WorkerError(ErrorCode.UNSUPPORTED_API, t.message ?: "unsupported API", cause = t)
            if (t is ProtocolViolation) return WorkerError(ErrorCode.PROTOCOL_VIOLATION, t.message ?: "bad payload", cause = t)
            // A host failure recorded during the operation wins even if extension code wrapped it.
            val recorded = (task as? OpTask)?.hostFailures?.firstOrNull()
            for (candidate in listOfNotNull(recorded) + generateSequence(t) { it.cause }.take(16).toList()) {
                hostError(candidate)?.let { return it }
            }
            val root = generateSequence(t) { it.cause }.take(16).last()
            val message = if (root === t) "${t.javaClass.simpleName}: ${t.message}" else "${t.javaClass.simpleName}: ${t.message} (cause ${root.javaClass.simpleName}: ${root.message})"
            return WorkerError(ErrorCode.SOURCE_ERROR, message, cause = t)
        }

        private fun hostError(t: Throwable): WorkerError? = when (t) {
            is WorkerError -> t.takeIf { it.code != ErrorCode.CANCELLED }
            is HostOperationException -> WorkerError(t.code, t.message ?: t.code, t.operation, t)
            is UnsupportedHostApi -> WorkerError(ErrorCode.CAPABILITY_UNAVAILABLE, t.message ?: "unsupported", "host.api:${t.api()}", t)
            is NoClassDefFoundError, is ClassNotFoundException -> {
                val name = (t.message ?: "").replace('/', '.').substringBefore(' ')
                if (PackageClassLoader.isHostOwned(name)) WorkerError(ErrorCode.CAPABILITY_UNAVAILABLE, "missing host class $name", "host.class:$name", t) else null
            }
            else -> null
        }
    }
}
