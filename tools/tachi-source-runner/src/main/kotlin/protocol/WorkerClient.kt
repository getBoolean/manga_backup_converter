package mangabackup.tachi.protocol

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.BufferedReader
import java.io.File
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * A minimal supervisor-side peer for the worker protocol, used by the JVM
 * tests, the capture tool and the benchmark. It is not the product
 * supervisor (that is `WorkerSupervisor` in package:source_runtime); it only
 * frames requests, correlates replies, serves reverse requests through
 * [reverseHandler], and keeps a transcript for conformance checks.
 */
class WorkerClient(
    private val toWorker: OutputStream,
    fromWorker: InputStream,
    val generation: Long = 1,
    @Volatile var reverseHandler: (Frame) -> JsonObject = { throw WorkerError(ErrorCode.CAPABILITY_UNAVAILABLE, "no browser port", it.op) },
    private val onExit: () -> Unit = {},
) : AutoCloseable {
    private val ids = AtomicLong()
    private val pending = ConcurrentHashMap<String, CompletableFuture<Frame>>()
    private val reverseExecutor = Executors.newCachedThreadPool { r -> Thread(r, "client-rreq").apply { isDaemon = true } }
    val transcript = CopyOnWriteArrayList<String>()
    val reverseRequests = CopyOnWriteArrayList<Frame>()
    private val closed = CompletableFuture<Unit>()

    private val readerThread = Thread({
        val reader = BufferedReader(InputStreamReader(fromWorker, StandardCharsets.UTF_8))
        try {
            while (true) {
                val line = reader.readLine() ?: break
                transcript += "<< $line"
                val frame = Frame.parse(line)
                when (frame.t) {
                    "res" -> pending.remove(frame.id)?.complete(frame)
                    "rreq" -> {
                        reverseRequests += frame
                        reverseExecutor.execute { serveReverse(frame) }
                    }
                }
            }
        } catch (e: Exception) {
            System.err.println("[client] reader stopped: $e")
        } finally {
            closed.complete(Unit)
            pending.values.forEach { it.completeExceptionally(WorkerError(ErrorCode.RUNTIME_UNAVAILABLE, "worker closed its output")) }
        }
    }, "client-reader").apply {
        isDaemon = true
        start()
    }

    private fun serveReverse(frame: Frame) {
        val reply = try {
            Frame(t = "rres", id = frame.id, gen = generation, ok = reverseHandler(frame))
        } catch (e: WorkerError) {
            Frame(t = "rres", id = frame.id, gen = generation, err = e.toJson())
        } catch (e: Exception) {
            Frame(t = "rres", id = frame.id, gen = generation, err = WorkerError(ErrorCode.SOURCE_ERROR, e.toString()).toJson())
        }
        write(reply)
    }

    fun write(frame: Frame) {
        val line = frame.encode()
        synchronized(toWorker) {
            transcript += ">> $line"
            toWorker.write(line.toByteArray(StandardCharsets.UTF_8))
            toWorker.write('\n'.code)
            toWorker.flush()
        }
    }

    fun nextId(): String = "$generation-${ids.incrementAndGet()}"

    fun send(op: String, pkg: String? = null, payload: JsonObject = JsonObject(emptyMap()), id: String = nextId()): Pair<String, CompletableFuture<Frame>> {
        val future = CompletableFuture<Frame>()
        pending[id] = future
        write(Frame(t = "req", id = id, gen = generation, op = op, pkg = pkg, payload = payload))
        return id to future
    }

    /** Sends a request and waits for its reply; returns `ok` or throws the `err` as [WorkerError]. */
    fun call(op: String, pkg: String? = null, payload: JsonObject = JsonObject(emptyMap()), timeoutMs: Long = 120_000): JsonObject {
        val frame = send(op, pkg, payload).second.get(timeoutMs, TimeUnit.MILLISECONDS)
        frame.err?.let { throw WorkerError.fromJson(it) }
        return frame.ok ?: throw WorkerError(ErrorCode.PROTOCOL_VIOLATION, "res without ok")
    }

    fun cancel(id: String) = write(Frame(t = "cancel", id = id, gen = generation))

    fun event(op: String, payload: JsonObject) = write(Frame(t = "event", id = "e${ids.incrementAndGet()}", gen = generation, op = op, payload = payload))

    fun handshake(): JsonObject = call("handshake", payload = buildJsonObject {
        put("protocolVersions", buildJsonArray { add(JsonPrimitive(1)) })
        put("maxFrameBytes", Wire.MAX_FRAME_BYTES)
    })

    fun awaitExit(timeoutMs: Long): Boolean = try {
        closed.get(timeoutMs, TimeUnit.MILLISECONDS)
        true
    } catch (_: Exception) {
        false
    }

    override fun close() {
        try {
            toWorker.close()
        } catch (_: Exception) {
        }
        awaitExit(5_000)
        reverseExecutor.shutdownNow()
        onExit()
    }

    companion object {
        /** Runs a [Worker] on a thread of this JVM, connected by pipes. */
        fun inProcess(options: WorkerOptions, generation: Long = 1): Pair<WorkerClient, Thread> {
            val down = QueuePipe()
            val up = QueuePipe()
            val toWorker = down.output
            val workerIn = down.input
            val fromWorker = up.input
            val workerOut = up.output
            val thread = Thread({
                try {
                    Worker(workerIn, workerOut, options).run()
                } finally {
                    workerOut.close()
                }
            }, "worker-main")
            thread.isDaemon = true
            thread.start()
            return WorkerClient(toWorker, fromWorker, generation) to thread
        }

        /** Starts the worker as a child process with [javaHome]'s `java`. */
        fun subprocess(javaHome: File, classpath: String, args: List<String>, generation: Long = 1, extraJvmArgs: List<String> = emptyList()): Pair<WorkerClient, Process> {
            val java = File(javaHome, "bin/java").absolutePath
            val command = listOf(java) + extraJvmArgs + listOf("-cp", classpath, "mangabackup.tachi.MainKt") + args
            val process = ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.INHERIT).start()
            val client = WorkerClient(process.outputStream, process.inputStream, generation, onExit = {
                if (!process.waitFor(5, TimeUnit.SECONDS)) process.destroyForcibly()
            })
            return client to process
        }
    }
}
