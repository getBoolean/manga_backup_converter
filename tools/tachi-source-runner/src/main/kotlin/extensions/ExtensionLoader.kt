package mangabackup.tachi.extensions

import mangabackup.tachi.host.PackageEnvironment
import java.io.File

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
     */
    fun load(stagedJar: File, environment: PackageEnvironment, parent: ClassLoader = ExtensionLoader::class.java.classLoader): ExtensionPackage {
        val manifest = ExtensionManifest.read(stagedJar)
        val factories = ExtensionFactories.admit(manifest, stagedJar.name, environment)
        return ExtensionFactories.instantiate(manifest, factories, PackageClassLoader(stagedJar, parent, environment), environment)
    }
}
