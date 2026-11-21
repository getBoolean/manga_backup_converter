package mangabackup.tachi.protocol

import kotlinx.serialization.json.JsonObject
import mangabackup.tachi.extensions.ExtensionPackage
import mangabackup.tachi.host.HostSettings
import mangabackup.tachi.host.PackageEnvironment
import java.io.File

/**
 * How [Worker] prepares and loads packages and drives browsers: the JVM
 * runtime ([JvmPackageRuntime]; U3: dex2jar, child-first JVM class loading,
 * the KTD20 webkit translation shim), used by the desktop worker and the iOS
 * embedding, or the Android `:source_runtime` service (U11: original APK DEX
 * on ART, real `android.webkit`). Everything else in the worker (framing,
 * per-package queues, settings, source operations, error mapping) is shared.
 * The hosting process's deadlines and identity are the separate [WorkerPlatform].
 */
interface PackageRuntime {
    /** `worker` in the handshake. */
    val workerName: String

    /** Source API families this runtime can load (handshake `capabilities.apiFamilies`). */
    val apiFamilies: Set<String>

    /** Additive handshake fields identifying the runtime (readers ignore them). */
    fun runtimeIdentity(): Map<String, String>

    /** Called once from the worker's constructor; returns the browser hooks the worker drives. */
    fun attach(worker: Worker): WorkerBrowser

    /**
     * Verifies [verifiedCopy] (a private copy whose digest already matched the
     * request) against [trusted] signer fingerprints and writes the loadable
     * form to [output]. Never executes the artifact.
     */
    fun prepare(kind: String, verifiedCopy: File, output: File, trusted: Set<String>): PreparedArtifact

    /** Artifact kind `package.load` accepts (the kind [prepare] produces). */
    val loadableKind: String

    /** Loads the staged artifact at [path] (digest already checked) into [environment]. */
    fun load(path: File, artifact: ArtifactBinding, environment: PackageEnvironment): ExtensionPackage

    /** Creates the environment a package runs in. */
    fun environment(packageId: String, stateDir: File, options: WorkerOptions, settings: HostSettings): PackageEnvironment =
        PackageEnvironment(packageId, stateDir, options.transport, options.defaultUserAgent, settings)

    /** Called after a package closed (unload, reload, shutdown). */
    fun packageClosed(environment: PackageEnvironment) {}

    data class PreparedArtifact(val kind: String, val producer: String, val converterVersion: String)
}

/** The worker's browser hooks: the desktop KTD20 reverse-request bridge, or the Android service's WebView lifecycle. */
interface WorkerBrowser {
    fun onMessage(payload: JsonObject) {}

    fun onRequest(payload: JsonObject) {}

    fun cancelOperation(operationId: String) {}

    fun closeSessionsOf(operationId: String) {}

    fun operationFinished(operationId: String) {}

    /** A source session closed (`dispose` without handles): drop its browser state. */
    fun sourceSessionClosed(environment: PackageEnvironment, sourceId: String) {}
}
