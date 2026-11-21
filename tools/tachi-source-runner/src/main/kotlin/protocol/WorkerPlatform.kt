package mangabackup.tachi.protocol

import java.io.File

/**
 * What differs between the hosts that run this worker (KTD11 "shared host
 * code"). The desktop worker is its own process and needs nothing here. The
 * iOS embedding (`tools/tachi-source-runner/ios/host`) runs the same classes
 * inside the app's single VM and supplies native operation deadlines and its
 * artifact rewrite pass through this interface.
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

    /** Ends the guard. After it returns the deadline can no longer fire on this thread. */
    override fun close()
}

/** The desktop worker: deadlines are the supervisor's, and prepared JARs are not rewritten. */
object DesktopPlatform : WorkerPlatform {
    override val name = "desktop"

    override fun pid(): Long = ProcessHandle.current().pid()

    override val artifactRewrite: ArtifactRewrite? = null

    override fun enterOperation(thread: Thread, onExpire: Runnable): OperationGuard = NoGuard

    private object NoGuard : OperationGuard {
        override val expired = false

        override fun expireNow() {}

        override fun close() {}
    }
}
