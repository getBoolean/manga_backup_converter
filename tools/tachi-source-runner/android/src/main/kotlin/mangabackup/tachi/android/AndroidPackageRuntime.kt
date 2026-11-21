package mangabackup.tachi.android

import android.content.Context
import android.os.Build
import android.os.Process
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.ArtifactVerifier
import mangabackup.tachi.extensions.ExtensionFactories
import mangabackup.tachi.extensions.ExtensionManifest
import mangabackup.tachi.extensions.ExtensionPackage
import mangabackup.tachi.extensions.SourceOperations
import mangabackup.tachi.host.HostSettings
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.host.PackageScope
import mangabackup.tachi.protocol.ArtifactBinding
import mangabackup.tachi.protocol.ArtifactRewrite
import mangabackup.tachi.protocol.Worker
import mangabackup.tachi.protocol.WorkerBrowser
import mangabackup.tachi.protocol.WorkerOptions
import mangabackup.tachi.protocol.NoOperationGuard
import mangabackup.tachi.protocol.OperationGuard
import mangabackup.tachi.protocol.PackageRuntime
import mangabackup.tachi.protocol.WorkerPlatform
import mangabackup.tachi.shim.HostFailures
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * The Android `:source_runtime` package runtime of the shared Tachi worker (U11;
 * KTD17): original APK DEX loaded on ART with the real Android framework, one
 * child-first class loader per package, all in this one service process.
 *
 * Admission: `artifact.prepare` verifies the APK signature against the
 * request's trust anchor with pinned apksig and only copies the verified
 * bytes; nothing is converted and nothing is executed to decide trust. An
 * ordinary JVM JAR is not DEX input and is refused (KTD17). `package.load`
 * never loads the path it is given (a cache file the app process owns and
 * may be writable): it copies it into private read-only staging, re-checks
 * the digest and the file mode there, and loads only that copy.
 */
class AndroidPackageRuntime(private val context: Context) : PackageRuntime {
    val staging = ArtifactStagingArea(context)
    val webViews = ServiceWebViews(context)
    private val staged = ConcurrentHashMap<PackageEnvironment, File>()

    /** Additive handshake fields set when the worker starts (debug network modes). */
    val notes = ConcurrentHashMap<String, String>()

    override val workerName: String = WORKER_NAME
    override val apiFamilies: Set<String> get() = ExtensionFactories.apiFamilies
    override val loadableKind: String = "apk"

    override fun runtimeIdentity(): Map<String, String> = mapOf(
        "sdkInt" to Build.VERSION.SDK_INT.toString(),
        "release" to Build.VERSION.RELEASE,
        "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
        "vm" to "${System.getProperty("java.vm.name")} ${System.getProperty("java.vm.version")}",
    ) + webViews.isolationReport() + notes

    override fun attach(worker: Worker): WorkerBrowser {
        PackageScope.stackResolver = AndroidPackageScope
        HostFailures.install { failure -> PackageScope.current()?.currentOperation?.recordHostFailure(failure) }
        return webViews
    }

    override fun prepare(kind: String, verifiedCopy: File, output: File, trusted: Set<String>): PackageRuntime.PreparedArtifact {
        if (kind != "apk") {
            throw ArtifactException("Android loads original APK DEX only; a '$kind' artifact is not DEX input (KTD17). Select the APK.")
        }
        ArtifactVerifier.verifyApk(verifiedCopy, trusted)
        verifiedCopy.copyTo(output, overwrite = true)
        return PackageRuntime.PreparedArtifact("apk", PRODUCER, CONVERTER_VERSION)
    }

    override fun environment(packageId: String, stateDir: File, options: WorkerOptions, settings: HostSettings): PackageEnvironment =
        PackageEnvironment(packageId, stateDir, options.transport, options.defaultUserAgent, settings) { env ->
            AndroidHostApplication(env, context)
        }

    override fun load(path: File, artifact: ArtifactBinding, environment: PackageEnvironment): ExtensionPackage {
        val apk = staging.stage(path, artifact.sha256)
        try {
            val manifest = ExtensionManifest.read(apk)
            val factories = ExtensionFactories.admit(manifest, path.name, environment)
            staging.requireLoadable(apk, artifact.sha256)
            val loader = AndroidPackageClassLoader(apk, AndroidPackageRuntime::class.java.classLoader!!, environment)
            AndroidPackageScope.register(loader)
            val pkg = try {
                ExtensionFactories.instantiate(manifest, factories, loader, environment)
            } catch (t: Throwable) {
                AndroidPackageScope.unregister(environment)
                throw t
            }
            staged[environment] = apk
            webViews.packageLoaded(environment, SourceOperations.referencesWebView(apk))
            return pkg
        } catch (t: Throwable) {
            staging.release(apk)
            throw t
        }
    }

    override fun packageClosed(environment: PackageEnvironment) {
        AndroidPackageScope.unregister(environment)
        staged.remove(environment)?.let(staging::release)
        webViews.packageClosed(environment)
    }

    companion object {
        const val WORKER_NAME = "tachi-android"
        const val PRODUCER = "tachi-android/apk-verify"
        const val CONVERTER_VERSION = "apk-verify.1"
    }
}

/**
 * The `:source_runtime` service process: its own process (the supervisor owns deadlines and can stop it),
 * with no platform deadline and no artifact rewrite (original DEX is loaded as verified).
 */
object AndroidHostPlatform : WorkerPlatform {
    override val name = "android"

    override fun pid(): Long = Process.myPid().toLong()

    override val artifactRewrite: ArtifactRewrite? = null

    override fun enterOperation(thread: Thread, onExpire: Runnable): OperationGuard = NoOperationGuard
}
