package mangabackup.tachi.protocol

import mangabackup.tachi.extensions.ApkConverter
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.ArtifactVerifier
import mangabackup.tachi.extensions.ExtensionFactories
import mangabackup.tachi.extensions.ExtensionLoader
import mangabackup.tachi.extensions.ExtensionPackage
import mangabackup.tachi.host.DesktopPackageScope
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.webkit.BrowserBridge
import mangabackup.tachi.webkit.WebkitHost
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/**
 * The JVM package runtime (U3) of the desktop worker and the iOS embedding: JAR verification or
 * APK → dex2jar, child-first JVM loading, KTD20 webkit shim.
 */
object JvmPackageRuntime : PackageRuntime {
    override val workerName: String get() = WorkerOptions.WORKER_NAME
    override val apiFamilies: Set<String> get() = ExtensionFactories.apiFamilies
    override val loadableKind: String = "jar"

    override fun runtimeIdentity(): Map<String, String> = mapOf(
        "javaVersion" to Runtime.version().toString(),
        "javaVendor" to System.getProperty("java.vendor").orEmpty(),
    )

    override fun attach(worker: Worker): WorkerBrowser {
        DesktopPackageScope.install()
        val bridge = BrowserBridge(worker)
        WebkitHost.install(bridge)
        return bridge
    }

    override fun prepare(kind: String, verifiedCopy: File, output: File, trusted: Set<String>): PackageRuntime.PreparedArtifact = when (kind) {
        "jar" -> {
            ArtifactVerifier.verifyJar(verifiedCopy, trusted)
            ApkConverter.writeAtomically(output.toPath(), verifiedCopy.readBytes())
            PackageRuntime.PreparedArtifact("jar", "tachi-jvm/jar-verify", "jar-verify.1")
        }
        "apk" -> {
            ArtifactVerifier.verifyApk(verifiedCopy, trusted)
            ApkConverter.convert(verifiedCopy, output)
            PackageRuntime.PreparedArtifact("jar", "tachi-jvm/apk-dex2jar", ApkConverter.CONVERTER_VERSION)
        }
        else -> throw ArtifactException("artifact kind '$kind' is not a Tachi artifact (jar or apk)")
    }

    override fun load(path: File, artifact: ArtifactBinding, environment: PackageEnvironment): ExtensionPackage =
        ExtensionLoader.load(path, environment, artifact.sha256)
}

/** The desktop worker process ([ProcessPlatform]; its pid is read when first used). */
val DesktopPlatform: WorkerPlatform by lazy { ProcessPlatform("desktop", ProcessHandle.current().pid()) }

/** A worker over [input]/[output] that runs packages on the JVM ([JvmPackageRuntime]). */
fun Worker(input: InputStream, output: OutputStream, options: WorkerOptions): Worker =
    Worker(input, output, options, JvmPackageRuntime)
