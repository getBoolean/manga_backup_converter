package mangabackup.tachi.extensions

import mangabackup.tachi.extensions.Digests.toHex
import mangabackup.tachi.host.PackageEnvironment
import java.io.File
import java.security.DigestInputStream
import java.security.MessageDigest

/** Desktop package loading: a verified, staged JVM JAR into a child-first [PackageClassLoader]. */
object ExtensionLoader {
    const val LIB_VERSION_MIN = ExtensionFactories.LIB_VERSION_MIN
    const val LIB_VERSION_MAX = ExtensionFactories.LIB_VERSION_MAX

    val apiFamilies: Set<String> get() = ExtensionFactories.apiFamilies

    fun apiFamily(libVersion: String): String = ExtensionFactories.apiFamily(libVersion)

    /**
     * Loads [stagedJar] (already verified and staged) into a new child-first
     * class loader and instantiates the manifest's factory classes on the
     * calling thread, bound to [environment].
     *
     * The JAR is first copied into the package's private state directory
     * while the copied bytes are hashed, and loading fails unless they hash
     * to [expectedSha256] (L5). Everything after that (manifest, classes,
     * resources) reads only that snapshot, so a staged file replaced after
     * the worker's digest check is never loaded.
     */
    fun load(
        stagedJar: File,
        environment: PackageEnvironment,
        expectedSha256: String,
        parent: ClassLoader = ExtensionLoader::class.java.classLoader,
    ): ExtensionPackage {
        val jar = snapshot(stagedJar, expectedSha256, environment)
        val manifest = ExtensionManifest.read(jar)
        val factories = ExtensionFactories.admit(manifest, stagedJar.name, environment)
        return ExtensionFactories.instantiate(manifest, factories, PackageClassLoader(jar, parent, environment), environment)
    }

    /** Copies [staged] into [environment]'s state directory, hashing what is copied; see [load]. */
    internal fun snapshot(staged: File, expectedSha256: String, environment: PackageEnvironment): File {
        val dir = File(environment.stateDir, "package").apply { mkdirs() }
        val copy = File.createTempFile("package-", ".jar", dir)
        val md = MessageDigest.getInstance("SHA-256")
        try {
            DigestInputStream(staged.inputStream(), md).use { input -> copy.outputStream().use { input.copyTo(it) } }
        } catch (t: Throwable) {
            copy.delete()
            throw t
        }
        val actual = md.digest().toHex()
        if (!actual.equals(expectedSha256, ignoreCase = true)) {
            copy.delete()
            throw ArtifactException("Staged artifact ${staged.name} changed after verification: expected $expectedSha256, loaded $actual")
        }
        return copy
    }
}
