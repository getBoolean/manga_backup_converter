package mangabackup.tachi.extensions

import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.host.PackageOwned
import java.io.File
import java.net.URL
import java.net.URLClassLoader
import java.security.CodeSigner
import java.security.CodeSource
import java.security.ProtectionDomain
import java.util.Collections
import java.util.Enumeration
import java.util.jar.JarFile

/**
 * Child-first class loader for one extension package (KTD5). Classes and
 * resources in the staged JAR win, except host-owned API packages, which
 * always come from the parent so every package links against one copy of the
 * source API, Android shims, Kotlin, OkHttp, jsoup and friends.
 */
class PackageClassLoader(
    stagedJar: File,
    parent: ClassLoader,
    override val environment: PackageEnvironment,
) : URLClassLoader("tachi-pkg:${environment.packageId}", arrayOf(stagedJar.toURI().toURL()), parent), PackageOwned {

    private val jar = JarFile(stagedJar, false)

    /**
     * Extension classes are defined with a protection domain that holds no class
     * loader. On JDK 21 every new thread inherits the access-control context of
     * the stack that created it; when extension code triggers a long-lived
     * library thread (Okio's watchdog, OkHttp's task runner), a normal protection
     * domain would pin this loader until that thread exits, so unloading a
     * package would not free it.
     */
    private val domain = ProtectionDomain(CodeSource(stagedJar.toURI().toURL(), null as Array<CodeSigner>?), null, null, null)

    override fun findClass(name: String): Class<*> {
        val entry = jar.getJarEntry(name.replace('.', '/') + ".class") ?: throw ClassNotFoundException(name)
        val bytes = jar.getInputStream(entry).use { it.readBytes() }
        val pkg = name.substringBeforeLast('.', "")
        if (pkg.isNotEmpty() && getDefinedPackage(pkg) == null) {
            try {
                definePackage(pkg, null, null, null, null, null, null, null)
            } catch (_: IllegalArgumentException) {
                // Defined concurrently.
            }
        }
        return defineClass(name, bytes, 0, bytes.size, domain)
    }

    override fun close() {
        jar.close()
        super.close()
    }

    override fun loadClass(name: String, resolve: Boolean): Class<*> {
        synchronized(getClassLoadingLock(name)) {
            val loaded = findLoadedClass(name) ?: if (isHostOwned(name)) {
                parent.loadClass(name)
            } else {
                try {
                    findClass(name)
                } catch (_: ClassNotFoundException) {
                    parent.loadClass(name)
                }
            }
            if (resolve) resolveClass(loaded)
            return loaded
        }
    }

    override fun getResource(name: String): URL? {
        if (isHostOwnedResource(name)) return parent.getResource(name)
        return findResource(name) ?: parent.getResource(name)
    }

    override fun getResources(name: String): Enumeration<URL> {
        val own = Collections.list(findResources(name))
        val inherited = Collections.list(parent.getResources(name))
        return Collections.enumeration(if (isHostOwnedResource(name)) inherited else own + inherited)
    }

    companion object {
        /** Packages the host owns. Extension packages (`eu.kanade.tachiyomi.extension.*`, R8-renamed `eu.kanade.tachiyomi.a.*`) are not listed. */
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

        private fun isHostOwnedResource(resource: String): Boolean {
            if (!resource.endsWith(".class")) return false
            return isHostOwned(resource.removeSuffix(".class").replace('/', '.'))
        }
    }
}
