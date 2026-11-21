package mangabackup.tachi.extensions

import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.host.PackageScope
import java.io.Closeable
import java.lang.reflect.InvocationTargetException

/**
 * One package loaded into its own class loader, with the sources its factory
 * enumerated. Shared by the desktop worker (JVM bytecode in a child-first
 * `PackageClassLoader`) and the Android service (original APK DEX).
 */
class ExtensionPackage(
    val manifest: ExtensionManifest,
    val loader: ClassLoader,
    val sources: List<Source>,
    val environment: PackageEnvironment,
) {
    val packageId: String get() = manifest.packageName

    fun source(id: String): Source? = sources.firstOrNull { it.id.toString() == id }

    /** Releases the class loader for unloading. The caller drops every reference to [sources]. */
    fun close() {
        environment.close()
        environment.classLoader = null
        (loader as? Closeable)?.close()
    }
}

/**
 * Platform-neutral half of package loading: API range and manifest checks
 * before any class loader exists, then factory instantiation inside one.
 */
object ExtensionFactories {
    /** Extension API range hosted, the same one Mihon accepts. */
    const val LIB_VERSION_MIN = 1.4
    const val LIB_VERSION_MAX = 1.6

    val apiFamilies: Set<String> = setOf("tachi-1.4", "tachi-1.5", "tachi-1.6")

    fun apiFamily(libVersion: String): String = "tachi-$libVersion"

    /** Checks [manifest] against the hosted API range and the requested package; returns the factory classes. */
    fun admit(manifest: ExtensionManifest, label: String, environment: PackageEnvironment): List<String> {
        if (!manifest.isTachiExtension) throw ArtifactException("$label does not declare the tachiyomi.extension feature")
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
        return factories
    }

    /**
     * Instantiates every factory class in [loader] bound to [environment] and
     * returns the package. On failure the loader is detached and closed.
     */
    fun instantiate(manifest: ExtensionManifest, factories: List<String>, loader: ClassLoader, environment: PackageEnvironment): ExtensionPackage {
        environment.classLoader = loader
        try {
            val sources = PackageScope.bind(environment) {
                factories.flatMap { className -> create(loader, className) }
            }
            if (sources.isEmpty()) throw ArtifactException("${manifest.packageName} enumerated no sources")
            val duplicates = sources.groupBy { it.id }.filterValues { it.size > 1 }.keys
            if (duplicates.isNotEmpty()) throw ArtifactException("${manifest.packageName} has duplicate source IDs $duplicates")
            return ExtensionPackage(manifest, loader, sources, environment)
        } catch (e: Throwable) {
            environment.classLoader = null
            (loader as? Closeable)?.close()
            throw e
        }
    }

    private fun create(loader: ClassLoader, className: String): List<Source> {
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

/**
 * Packages the host owns: every extension package links against the host's
 * single copy of these (source API, Android, Kotlin, OkHttp, jsoup and friends).
 * Extension packages (`eu.kanade.tachiyomi.extension.*`, R8-renamed
 * `eu.kanade.tachiyomi.a.*`) and their bundled helpers (`keiyoushi.*`) are not listed.
 */
object HostOwnership {
    val HOST_PREFIXES = listOf(
        "java.", "javax.", "jdk.", "sun.", "com.sun.", "org.w3c.", "org.xml.",
        "kotlin.", "kotlinx.", "okhttp3.", "okio.", "mockwebserver3.", "org.jsoup.", "org.jspecify.", "rx.",
        "uy.kohesive.", "dev.mihon.", "android.", "androidx.", "org.brotli.", "com.squareup.",
        "app.cash.quickjs.", "tachiyomi.core.", "mihon.core.", "mangabackup.tachi.",
        "eu.kanade.tachiyomi.source.", "eu.kanade.tachiyomi.network.", "eu.kanade.tachiyomi.util.",
    )
    private val HOST_CLASSES = setOf("eu.kanade.tachiyomi.AppInfo")

    fun isHostOwned(className: String): Boolean =
        className in HOST_CLASSES || HOST_PREFIXES.any { className.startsWith(it) }
}
