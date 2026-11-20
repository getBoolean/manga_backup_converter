package mangabackup.tachi.extensions

import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.host.PackageScope
import java.io.File
import java.lang.reflect.InvocationTargetException

/** One package loaded into its own class loader, with the sources its factory enumerated. */
class ExtensionPackage(
    val manifest: ExtensionManifest,
    val loader: PackageClassLoader,
    val sources: List<Source>,
    val environment: PackageEnvironment,
) {
    val packageId: String get() = manifest.packageName

    fun source(id: String): Source? = sources.firstOrNull { it.id.toString() == id }

    /** Releases the class loader for unloading. The caller drops every reference to [sources]. */
    fun close() {
        environment.close()
        environment.classLoader = null
        loader.close()
    }
}

object ExtensionLoader {
    /** Extension API range hosted, the same one Mihon accepts. */
    const val LIB_VERSION_MIN = 1.4
    const val LIB_VERSION_MAX = 1.6

    val apiFamilies: Set<String> = setOf("tachi-1.4", "tachi-1.5", "tachi-1.6")

    fun apiFamily(libVersion: String): String = "tachi-$libVersion"

    /**
     * Loads [stagedJar] (already verified and staged) into a new child-first
     * class loader and instantiates the manifest's factory classes on the
     * calling thread, bound to [environment].
     */
    fun load(stagedJar: File, environment: PackageEnvironment, parent: ClassLoader = ExtensionLoader::class.java.classLoader): ExtensionPackage {
        val manifest = ExtensionManifest.read(stagedJar)
        if (!manifest.isTachiExtension) throw ArtifactException("${stagedJar.name} does not declare the tachiyomi.extension feature")
        val lib = manifest.libVersion.toDoubleOrNull()
            ?: throw UnsupportedApiException("Extension API version '${manifest.libVersion}' is not a version")
        if (lib < LIB_VERSION_MIN || lib > LIB_VERSION_MAX) {
            throw UnsupportedApiException("Extension API ${manifest.libVersion} is outside the hosted range $LIB_VERSION_MIN-$LIB_VERSION_MAX")
        }
        if (manifest.packageName != environment.packageId) {
            throw ArtifactException("Artifact package ${manifest.packageName} does not match requested package ${environment.packageId}")
        }
        val factories = manifest.factoryClasses
        if (factories.isEmpty()) throw ArtifactException("${manifest.packageName} declares no ${ExtensionManifest.META_CLASS}")
        val loader = PackageClassLoader(stagedJar, parent, environment)
        environment.classLoader = loader
        try {
            val sources = PackageScope.bind(environment) {
                factories.flatMap { className -> instantiate(loader, className) }
            }
            if (sources.isEmpty()) throw ArtifactException("${manifest.packageName} enumerated no sources")
            val duplicates = sources.groupBy { it.id }.filterValues { it.size > 1 }.keys
            if (duplicates.isNotEmpty()) throw ArtifactException("${manifest.packageName} has duplicate source IDs $duplicates")
            return ExtensionPackage(manifest, loader, sources, environment)
        } catch (e: Throwable) {
            environment.classLoader = null
            loader.close()
            throw e
        }
    }

    private fun instantiate(loader: ClassLoader, className: String): List<Source> {
        val instance = try {
            Class.forName(className, false, loader).getDeclaredConstructor().newInstance()
        } catch (e: ClassNotFoundException) {
            throw ArtifactException("Factory class $className is missing from the artifact", e)
        } catch (e: NoClassDefFoundError) {
            throw ArtifactException("Missing host class ${e.message?.replace('/', '.')} while loading $className", e)
        } catch (e: InvocationTargetException) {
            val cause = e.targetException
            if (cause is NoClassDefFoundError) {
                throw ArtifactException("Missing host class ${cause.message?.replace('/', '.')} while constructing $className", cause)
            }
            throw ArtifactException("Constructing $className failed: $cause", cause)
        }
        return when (instance) {
            is SourceFactory -> instance.createSources()
            is Source -> listOf(instance)
            else -> throw ArtifactException("$className is neither a Source nor a SourceFactory")
        }
    }
}
