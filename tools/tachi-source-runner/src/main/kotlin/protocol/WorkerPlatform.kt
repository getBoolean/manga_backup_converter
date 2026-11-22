package mangabackup.tachi.protocol

import java.io.File

/**
 * What differs between the processes that host this worker (KTD11 "shared host
 * code"): handshake identity, operation deadlines and a prepared-JAR rewrite.
 * The desktop worker and the Android `:source_runtime` service are their own
 * processes and need nothing beyond their pid ([ProcessPlatform]). The iOS
 * embedding (`tools/tachi-source-runner/ios/host`) runs the same classes
 * inside the app's single VM and supplies native operation deadlines and its
 * artifact rewrite pass through this interface. How packages are prepared and
 * loaded is the separate [PackageRuntime].
 *
 * The shared code is compiled for class-file 65 (Java 21) and uses only APIs
 * present in both the desktop JRE 21 and the mobile JDK 26 class library.
 */
interface WorkerPlatform {
    /** Reported in the handshake as `platform`. */
    val name: String

    /** Process id for the handshake, or null where the worker is not its own process. */
    fun pid(): Long?

    /** Applied to the prepared JAR on both artifact paths (KTD5), or null for none. */
    val artifactRewrite: ArtifactRewrite?

    /**
     * Called on the operation thread just before an operation runs. [onExpire]
     * stops the operation's host work cooperatively (HTTP calls, browser waits,
     * interruption); the platform calls it when its own deadline fires.
     */
    fun enterOperation(thread: Thread, onExpire: Runnable): OperationGuard
}

/** A bytecode pass over a prepared JAR. Its [version] is part of the cache identity (KTD5). */
interface ArtifactRewrite {
    val version: String

    fun rewrite(input: File, output: File)
}

/** One running operation's platform deadline. */
interface OperationGuard : AutoCloseable {
    /** True once the platform's own deadline stopped the operation. */
    val expired: Boolean

    /** Stops the operation now, as for a supervisor `cancel`. */
    fun expireNow()

    /**
     * `interaction.started` (protocol 1.3): stop counting time against the deadline while the user
     * interacts. The pause itself is bounded: the deadline still fires [boundMs] after the time that
     * remained, so a lost `interaction.ended` cannot leave the operation without one.
     */
    fun pause(boundMs: Long)

    /**
     * While paused, bounds the pause by [boundMs] from when it began instead of the bound [pause] was
     * given: the supervisor's interaction timeout replaces the worker's own once it is known.
     */
    fun rebound(boundMs: Long)

    /** `interaction.ended` (protocol 1.3): count time again, from the budget that remained at [pause]. */
    fun resume()

    /** Ends the guard. After it returns the deadline can no longer fire on this thread. */
    override fun close()
}

/**
 * A worker that is its own process (the desktop worker, the Android `:source_runtime` service): the
 * supervisor owns its deadlines and can stop it, and prepared artifacts are loaded as verified. [pid]
 * comes from the caller, because how a process reads its own id differs by platform.
 */
class ProcessPlatform(override val name: String, private val pid: Long) : WorkerPlatform {
    override fun pid(): Long = pid

    override val artifactRewrite: ArtifactRewrite? = null

    override fun enterOperation(thread: Thread, onExpire: Runnable): OperationGuard = NoOperationGuard
}

/** The guard of a platform whose deadlines are the supervisor's alone (desktop, Android): nothing to stop. */
object NoOperationGuard : OperationGuard {
    override val expired = false

    override fun expireNow() {}

    override fun pause(boundMs: Long) {}

    override fun rebound(boundMs: Long) {}

    override fun resume() {}

    override fun close() {}
}

/**
 * A platform timer that can only be armed for a span and disarmed, such as the iOS dispatcher's
 * native watchdog. When an armed span passes, the platform stops the operation itself.
 */
interface DeadlineTimer {
    /** Arms the deadline [ms] from now, replacing nothing: the caller disarms first. */
    fun arm(ms: Long)

    /** Disarms the deadline. After it returns the timer no longer touches the operation. True if it fired. */
    fun disarm(): Boolean

    /** Fires the armed deadline now. */
    fun fireNow()
}

/**
 * Operation deadline accounting with interaction pauses (protocol 1.3), shared by every platform
 * whose timer can only be armed and disarmed ([DeadlineTimer]). The operation gets [budgetMs] of
 * running time; time between [pause] and [resume] is not counted.
 *
 * - A deadline that fired before a pause stays fired; pausing does not revive the operation. Because a
 *   disarm may clear the platform's stop mark (the iOS watchdog does), a fire found at a disarm is armed
 *   again at zero, so the operation stays stopped until [close].
 * - While paused the timer is armed for the remaining budget plus the pause's bound.
 * - [expireNow] fires whatever is armed, paused or not, so a `cancel` during an interaction still stops it.
 * - Nothing re-arms after [close]: the operation thread may already be running another operation.
 */
class PausableDeadline(
    private val budgetMs: Long,
    private val timer: DeadlineTimer,
    private val nanoTime: () -> Long = System::nanoTime,
) : OperationGuard {
    private var usedNanos = 0L
    private var runningSince = nanoTime()
    private var pausedSince = 0L
    private var paused = false
    private var closed = false

    @Volatile
    private var fired = false

    init {
        timer.arm(budgetMs)
    }

    override val expired: Boolean get() = fired

    /** The running budget left, in milliseconds (never negative). */
    @get:Synchronized
    val remainingMs: Long
        get() {
            val used = usedNanos + if (paused || closed) 0 else nanoTime() - runningSince
            return maxOf(0L, budgetMs - used / 1_000_000)
        }

    @Synchronized
    override fun pause(boundMs: Long) {
        if (closed || paused || fired) return
        val now = nanoTime()
        if (timer.disarm()) return refire()
        usedNanos += now - runningSince
        paused = true
        pausedSince = now
        timer.arm(remainingMs + maxOf(0L, boundMs))
    }

    @Synchronized
    override fun rebound(boundMs: Long) {
        if (closed || !paused || fired) return
        val pausedMs = (nanoTime() - pausedSince) / 1_000_000
        if (timer.disarm()) return refire()
        timer.arm(maxOf(0L, remainingMs + maxOf(0L, boundMs) - pausedMs))
    }

    @Synchronized
    override fun resume() {
        if (closed || !paused) return
        paused = false
        if (timer.disarm()) return refire()
        runningSince = nanoTime()
        timer.arm(remainingMs)
    }

    /** The deadline had fired: keep the operation stopped (the disarm may have cleared the platform's mark). */
    private fun refire() {
        fired = true
        timer.arm(0)
    }

    @Synchronized
    override fun expireNow() {
        if (!closed) timer.fireNow()
    }

    @Synchronized
    override fun close() {
        if (closed) return
        if (!paused) usedNanos += nanoTime() - runningSince
        closed = true
        if (timer.disarm()) fired = true
    }
}
