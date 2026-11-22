package mangabackup.tachi.protocol

import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.extensions.ExtensionFactories
import mangabackup.tachi.extensions.ExtensionPackage
import mangabackup.tachi.extensions.HostOwnership
import mangabackup.tachi.extensions.SourceOperations
import mangabackup.tachi.extensions.UnsupportedApiException
import mangabackup.tachi.host.HostInjekt
import mangabackup.tachi.host.HostOperationException
import mangabackup.tachi.host.OperationContext
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.host.PackageScope
import mangabackup.tachi.host.withHandshake
import mangabackup.tachi.shim.HostFailures
import java.io.BufferedReader
import java.io.File
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.ArrayDeque
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * The single Tachi worker (KTD1, KTD4): the desktop JVM process, the iOS
 * embedding (KTD11) and the Android `:source_runtime` service (KTD17), which
 * differ only in their [PackageRuntime] (how packages are prepared, loaded and
 * browsed) and [WorkerPlatform] (process identity, platform deadlines, artifact
 * rewrite). Reads protocol frames from [input], writes frames to [output] (and
 * nothing else), and hosts every loaded package in its own class loader.
 *
 * Concurrency: one operation at a time per package, enforced here even though
 * the supervisor already guarantees it; different packages run concurrently on
 * a fixed pool of [WorkerLimits.poolSize] threads (KTD25). Deadlines are the
 * supervisor's (plus iOS's native one); the worker answers `cancel` cooperatively by cancelling the
 * operation's coroutine, its package's HTTP calls and browser sessions, and
 * interrupting its thread.
 */
class Worker(
    input: InputStream,
    private val output: OutputStream,
    private val options: WorkerOptions,
    private val runtime: PackageRuntime,
) {
    private val reader = BufferedReader(InputStreamReader(input, StandardCharsets.UTF_8), 1 shl 16)
    private val writeLock = Any()

    @Volatile
    private var generation = -1L

    @Volatile
    private var maxFrameBytes = Wire.MAX_FRAME_BYTES

    /** The minor version agreed in the handshake; a reverse request newer than it is never sent ([reverseRequest]). */
    @Volatile
    var protocolMinor = 0L
        private set

    /** Whether the supervisor negotiated a protocol minor that has [op]. */
    fun supports(op: HostBrowserOp): Boolean = op.availableAt(protocolMinor)

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

    /** Browser hooks; set in init (the runtime may need this worker to build them). */
    val browser: WorkerBrowser

    /** A package loaded in this process. */
    class LoadedState(val pkg: ExtensionPackage, val artifact: ArtifactBinding, val ops: SourceOperations)

    private class PendingReverse(val of: String, val future: CompletableFuture<JsonObject>)

    inner class OpTask(val frame: Frame, val op: WorkerOp) : OperationContext {
        override val requestId: String get() = frame.id

        /** Peeked leniently for host diagnostics; the operation itself decodes its payload strictly. */
        override val sourceId: String? =
            ((frame.payload?.get("source") as? JsonObject)?.get("sourceId") as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        val packageId: String = frame.pkg!!

        @Volatile
        var thread: Thread? = null

        @Volatile
        var job: Job? = null

        /** The platform deadline of the running operation (KTD11; a no-op on desktop). */
        @Volatile
        var guard: OperationGuard? = null

        @Volatile
        override var isCancelled = false

        /** True between `interaction.started` and `interaction.ended` (protocol 1.3); guarded by [interactionLock]. */
        private var interacting = false

        /** Pauses held: the supervisor's interaction (at most one) plus host-driven ones ([pauseDeadline]). */
        private var pauses = 0
        private val interactionLock = Any()

        /**
         * `interaction.started`: pause the platform deadline. The supervisor sends one pair per operation
         * however many shows overlap, so a repeated start is ignored rather than counted.
         */
        fun interactionStarted(timeoutMs: Long): Unit = synchronized(interactionLock) {
            if (interacting || finished) return
            interacting = true
            hold(timeoutMs)
        }

        /** `interaction.ended`: resume the platform deadline. Never resumed on a show's `rres` alone. */
        fun interactionEnded(): Unit = synchronized(interactionLock) {
            if (!interacting) return
            interacting = false
            release()
        }

        override fun pauseDeadline(): Unit = synchronized(interactionLock) {
            if (!finished) hold(options.sizing.limits.interactionTimeoutMs)
        }

        override fun resumeDeadline(): Unit = synchronized(interactionLock) {
            release()
        }

        private fun hold(boundMs: Long) {
            if (pauses++ == 0) guard?.pause(boundMs)
        }

        private fun release() {
            if (pauses == 0) return
            if (--pauses == 0) guard?.resume()
        }

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
            guard?.expireNow()
            stopWork()
        }

        /** Stops the operation's host work cooperatively; also what a platform deadline calls. */
        fun stopWork() {
            job?.cancel()
            packages[packageId]?.pkg?.environment?.cancelActiveCalls()
            browser.cancelOperation(requestId)
            thread?.interrupt()
        }
    }

    init {
        HostInjekt.install()
        // Shims report host failures (unsupported API, browser capability) to the running operation.
        HostFailures.install { failure -> PackageScope.current()?.currentOperation?.recordHostFailure(failure) }
        browser = runtime.attach(this)
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
            FrameType.REQ -> {
                val op = WorkerOp.fromWire(frame.op)
                when {
                    frame.op == null -> replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "request has no op"))
                    op == WorkerOp.HANDSHAKE -> handshake(frame)
                    op == WorkerOp.SHUTDOWN -> {
                        shuttingDown = true
                        closeAll()
                        reply(frame, ok = JsonObject(emptyMap()))
                        output.flush()
                        return false
                    }
                    generation < 0 -> replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "handshake required first"))
                    op == null -> replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "unknown operation ${frame.op}"))
                    op.perPackage && frame.pkg == null -> replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "${op.wire} needs pkg"))
                    else -> enqueue(OpTask(frame, op))
                }
            }
            FrameType.CANCEL -> cancel(frame.id)
            FrameType.RRES -> {
                val pending = reverse.remove(frame.id) ?: return true
                when {
                    frame.err != null -> pending.future.completeExceptionally(WorkerError.fromJson(frame.err))
                    frame.ok != null -> pending.future.complete(frame.ok)
                    else -> pending.future.completeExceptionally(WorkerError(ErrorCode.PROTOCOL_VIOLATION, "rres without ok or err"))
                }
            }
            // Events are handled here, on the frame reader, never on a thread that waits for an rres:
            // a held request may be what keeps the worker's own reverse request from being answered.
            FrameType.EVENT -> {
                val p = frame.payload ?: return true
                when (frame.op) {
                    WorkerEvent.BROWSER_MESSAGE -> browser.onMessage(p)
                    WorkerEvent.BROWSER_REQUEST -> browser.onRequest(p)
                    WorkerEvent.INTERACTION_STARTED -> Wire.decodeOrNull<InteractionStarted>(p)?.let { e ->
                        interactionTask(e.of)?.interactionStarted(e.timeoutMs ?: 0L)
                    }
                    WorkerEvent.INTERACTION_ENDED -> Wire.decodeOrNull<InteractionEnded>(p)?.let { e -> interactionTask(e.of)?.interactionEnded() }
                }
            }
            FrameType.RES, FrameType.RREQ -> fatal("unexpected frame type ${frame.t} from supervisor")
        }
        return true
    }

    /**
     * The in-flight operation an `interaction.*` event (protocol 1.3) names. Decoded leniently, like the
     * other events: a malformed event, one for an operation no longer in flight, or one from a peer
     * that did not negotiate 1.3 is dropped. (Inbound events are gated here, not by [reverseRequest].)
     */
    private fun interactionTask(of: String): OpTask? = if (protocolMinor < 3) null else tasks[of]

    private fun handshake(frame: Frame) {
        val p = frame.payload ?: return replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "handshake needs a payload"))
        val (request, offeredMinor) = try {
            val request = Wire.decode<HandshakeRequest>(p, "handshake")
            request to request.offeredMinor()
        } catch (e: ProtocolViolation) {
            return replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, e.message ?: "bad handshake"))
        }
        if (Wire.VERSION.toLong() !in request.protocolVersions) {
            return replyError(frame, WorkerError(ErrorCode.PROTOCOL_VIOLATION, "supervisor offers ${request.protocolVersions}; worker speaks ${Wire.VERSION}"))
        }
        // 1.1: answer with the lower of the offered minor and ours.
        generation = frame.gen
        protocolMinor = minOf(offeredMinor, Wire.MINOR_VERSION.toLong())
        maxFrameBytes = request.maxFrameBytesOrNull()?.let { minOf(it, Wire.MAX_FRAME_BYTES.toLong()).toInt() } ?: Wire.MAX_FRAME_BYTES
        reply(
            frame,
            ok = buildJsonObject {
                put("protocolVersion", Wire.VERSION)
                put("protocolMinor", protocolMinor)
                put("worker", runtime.workerName)
                put("workerVersion", WorkerOptions.WORKER_VERSION)
                options.platform.pid()?.let { put("pid", it) }
                put("capabilities", buildJsonObject {
                    put("apiFamilies", buildJsonArray { runtime.apiFamilies.sorted().forEach { add(JsonPrimitive(it)) } })
                    put("browser", options.browser)
                })
                // KTD25 limits and sizing (1.1), then additive runtime identity fields readers ignore.
                put("limits", options.sizing.limits.toJson().withHandshake(options.sizing.rule))
                put("sizing", options.sizing.toJson())
                put("networkMode", options.networkMode)
                for ((key, value) in runtime.runtimeIdentity()) put(key, value)
                put("hostCompatibility", WorkerOptions.HOST_COMPATIBILITY)
                put("platform", options.platform.name)
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
        var failure: Throwable? = null
        val guard = options.platform.enterOperation(Thread.currentThread(), task::stopWork)
        task.guard = guard
        try {
            if (task.isCancelled) throw WorkerError(ErrorCode.CANCELLED, "cancelled")
            env?.currentOperation = task
            val job = Job()
            task.job = job
            ok = runBlocking(job) {
                if (env != null) PackageScope.bind(env) { runOp(task) } else runOp(task)
            }
        } catch (t: Throwable) {
            failure = t
        } finally {
            // End the platform deadline before anything else runs on this thread: after close() no deadline
            // check can fire here, so mapping the error and writing the reply cannot be interrupted.
            guard.close()
            task.guard = null
            env?.currentOperation = null
            Thread.interrupted()
        }
        if (failure != null) {
            // A show that ended in interaction-required is the operation's failure even when the source then
            // waited out the deadline (protocol 1.3: the interaction bound is interaction-required, not timeout).
            val interaction = task.hostFailures.firstOrNull { (it as? HostOperationException)?.code == ErrorCode.INTERACTION_REQUIRED }
            error = if (guard.expired && !task.isCancelled && interaction == null) {
                WorkerError(ErrorCode.TIMEOUT, "operation stopped by its deadline", cause = failure)
            } else {
                mapError(failure, task)
            }
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
        val state = if (task.op.requiresLoaded) requireLoaded(task.packageId) else null
        return when (task.op) {
            WorkerOp.ARTIFACT_PREPARE -> Wire.encode(prepare(Wire.decode(p, task.op.wire)))
            WorkerOp.PACKAGE_LOAD -> Wire.encode(load(task.packageId, Wire.decode(p, task.op.wire)))
            WorkerOp.PACKAGE_UNLOAD -> {
                packages.remove(task.packageId)?.let { closePackage(it.pkg) }
                JsonObject(emptyMap())
            }
            WorkerOp.SETTINGS_UPDATE -> {
                state!!.pkg.environment.replaceSettings(Wire.decode<SettingsUpdateRequest>(p, task.op.wire).settings.toHostSettings())
                JsonObject(emptyMap())
            }
            WorkerOp.SEARCH -> state!!.ops.search(Wire.decode(p, task.op.wire))
            WorkerOp.DETAILS -> state!!.ops.details(Wire.decode(p, task.op.wire))
            WorkerOp.DISPOSE -> {
                val request = Wire.decode<DisposeRequest>(p, task.op.wire)
                state!!.ops.dispose(request)
                // A dispose without handles closes the source's session (protocol › dispose).
                if (request.handles == null) browser.sourceSessionClosed(state.pkg.environment, request.source.sourceId)
                JsonObject(emptyMap())
            }
            WorkerOp.HANDSHAKE, WorkerOp.SHUTDOWN -> error("${task.op.wire} is answered on the frame reader")
        }
    }

    private fun requireLoaded(packageId: String): LoadedState =
        packages[packageId] ?: throw WorkerError(ErrorCode.RUNTIME_UNAVAILABLE, "package $packageId is not loaded")

    // --- operations --------------------------------------------------------------------------

    private fun prepare(request: ArtifactPrepareRequest): ArtifactPrepareResponse {
        val artifact = request.artifact
        val input = File(request.inputPath)
        val output = File(request.outputPath)
        // KTD5: the request's trust anchor is the only source of trusted signers. An absent or empty list (a 1.0
        // supervisor, or no stored anchor) is refused by the verifier as artifact-incompatible; nothing else is trusted.
        val trusted = request.trustedSigners.orEmpty().map { it.lowercase() }.toSet()
        if (trusted.isEmpty()) throw ArtifactException("artifact.prepare carries no trustedSigners; refusing to verify ${artifact.kind} without a stored trust anchor")
        try {
            output.parentFile?.mkdirs()
            val staging = Files.createTempDirectory(output.parentFile?.toPath() ?: File(".").toPath(), ".prepare-").toFile()
            try {
                // Verify a private copy so the bytes checked are the bytes converted or staged.
                val copy = File(staging, "input.bin")
                input.copyTo(copy, overwrite = true)
                Digests.requireSha256(copy, artifact.sha256, "Input artifact")
                // KTD5/KTD11: a platform rewrite pass applies identically to both artifact paths, after verification.
                val rewrite = options.platform.artifactRewrite
                val unrewritten = if (rewrite == null) output else File(staging, "prepared.bin")
                val prepared = runtime.prepare(artifact.kind, copy, unrewritten, trusted)
                if (rewrite != null) {
                    val rewritten = File(staging, "rewritten.bin")
                    rewrite.rewrite(unrewritten, rewritten)
                    // The staging directory sits beside the output, so this is a same-directory atomic replace.
                    Files.move(rewritten.toPath(), output.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
                }
                val digest = Digests.sha256(output)
                val versions = listOfNotNull(prepared.converterVersion, rewrite?.version, WorkerOptions.HOST_COMPATIBILITY)
                return ArtifactPrepareResponse(ArtifactBinding(digest, prepared.kind, artifact.version), prepared.producer, versions.joinToString("+"))
            } finally {
                staging.deleteRecursively()
            }
        } catch (t: Throwable) {
            output.delete()
            throw t
        }
    }

    private fun load(packageId: String, request: PackageLoadRequest): PackageLoadResponse {
        val artifact = request.artifact
        if (artifact.kind != runtime.loadableKind) {
            throw ArtifactException("package.load needs a prepared ${runtime.loadableKind}, got kind '${artifact.kind}'")
        }
        val path = File(request.path)
        val settings = Wire.decode<SettingsPayload>(request.settings, "package.load settings").toHostSettings()
        Digests.requireSha256(path, artifact.sha256, "Staged artifact")
        packages.remove(packageId)?.let { closePackage(it.pkg) }
        val stateDir = File(options.stateRoot, "pkg-${envIds.incrementAndGet()}")
        val env = runtime.environment(packageId, stateDir, options, settings)
        val pkg = try {
            PackageScope.bind(env) { runtime.load(path, artifact, env) }
        } catch (t: Throwable) {
            env.close()
            runtime.packageClosed(env)
            throw t
        }
        // Source IDs are unique across every package hosted in this worker (U11); report both identities.
        for (other in packages.values) {
            val clash = pkg.sources.map { it.id }.intersect(other.pkg.sources.map { it.id }.toSet())
            if (clash.isNotEmpty()) {
                closePackage(pkg)
                throw ArtifactException(
                    "source IDs ${clash.sorted()} of $packageId (${artifact.sha256}) are already hosted by " +
                        "${other.pkg.packageId} (${other.artifact.sha256})",
                )
            }
        }
        val state = LoadedState(pkg, artifact, SourceOperations(pkg, artifact))
        packages[packageId] = state
        val requiresBrowser = SourceOperations.referencesWebView(path)
        val family = ExtensionFactories.apiFamily(pkg.manifest.libVersion)
        return PackageLoadResponse(
            pkg.sources.map { source ->
                val ops = mutableListOf("search", "mangaDetails", "chapterList")
                if (source is eu.kanade.tachiyomi.source.ConfigurableSource) ops += "settings"
                LoadedSource(source.id.toString(), source.name, source.lang.ifEmpty { null }, SourceCapabilities(ops, listOf(family), requiresBrowser))
            },
        )
    }

    // --- reverse requests (KTD20) --------------------------------------------------------------

    /**
     * Sends a `host.browser.*` reverse request on behalf of the in-flight
     * operation [of]. Fails with `cancelled` if that operation has finished, so
     * no reverse request can ever follow its reply, and with
     * `capability-unavailable` if the supervisor negotiated a protocol minor
     * older than the operation ([HostBrowserOp.sinceMinor]).
     */
    fun reverseRequest(of: String, request: HostBrowserRequest): CompletableFuture<JsonObject> {
        val op = request.op
        val future = CompletableFuture<JsonObject>()
        if (!supports(op)) {
            future.completeExceptionally(
                WorkerError(ErrorCode.CAPABILITY_UNAVAILABLE, "${op.wire} needs protocol 1.${op.sinceMinor}; the supervisor speaks 1.$protocolMinor", op.wire),
            )
            return future
        }
        val id = "r${reverseIds.incrementAndGet()}"
        synchronized(writeLock) {
            val task = tasks[of]
            if (task == null || task.finished || task.isCancelled) {
                future.completeExceptionally(WorkerError(ErrorCode.CANCELLED, "originating operation $of is no longer in flight"))
                return future
            }
            reverse[id] = PendingReverse(of, future)
            writeFrame(Frame(t = FrameType.RREQ, id = id, gen = generation, op = op.wire, of = of, payload = request.toPayload()))
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
        val frame = Frame(t = FrameType.RES, id = request.id, gen = generation, ok = ok)
        synchronized(writeLock) {
            val encoded = frame.encode()
            val size = encoded.toByteArray(StandardCharsets.UTF_8).size
            if (size > maxFrameBytes) {
                writeRaw(Frame(t = FrameType.RES, id = request.id, gen = generation, err = WorkerError(ErrorCode.SOURCE_ERROR, "reply of $size bytes exceeds the $maxFrameBytes-byte frame limit").toJson()).encode())
            } else {
                writeRaw(encoded)
            }
        }
    }

    private fun replyError(request: Frame, error: WorkerError) {
        synchronized(writeLock) {
            writeRaw(Frame(t = FrameType.RES, id = request.id, gen = generation, err = error.toJson()).encode())
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

    private fun closePackage(pkg: ExtensionPackage) {
        try {
            pkg.close()
        } finally {
            runtime.packageClosed(pkg.environment)
        }
    }

    private fun closeAll() {
        for (state in packages.values) {
            try {
                closePackage(state.pkg)
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
            is mangabackup.tachi.shim.UnsupportedHostApi -> WorkerError(ErrorCode.CAPABILITY_UNAVAILABLE, t.message ?: "unsupported", "host.api:${t.api()}", t)
            is NoClassDefFoundError, is ClassNotFoundException -> {
                val name = (t.message ?: "").replace('/', '.').substringBefore(' ')
                if (HostOwnership.isHostOwned(name)) WorkerError(ErrorCode.CAPABILITY_UNAVAILABLE, "missing host class $name", "host.class:$name", t) else null
            }
            else -> null
        }
    }
}
