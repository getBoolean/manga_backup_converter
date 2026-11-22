package mangabackup.tachi.android

import android.content.Context
import android.system.Os
import android.system.OsConstants
import dalvik.system.BaseDexClassLoader
import mangabackup.tachi.extensions.ArtifactException
import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.extensions.HostOwnership
import mangabackup.tachi.host.HostApplication
import mangabackup.tachi.host.PackageEnvironment
import mangabackup.tachi.host.PackageOwned
import mangabackup.tachi.host.PackageScope
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong

/**
 * Child-first class loader over an extension APK's original DEX (KTD17), the
 * ART counterpart of the desktop `PackageClassLoader`. Host-owned API
 * packages always come from the parent (this service's class loader), so
 * every package links against one copy of the source API, Kotlin, OkHttp,
 * jsoup and the Android framework; everything else in the APK wins over the
 * parent, so two packages may carry the same class names (bundled
 * `keiyoushi.*` helpers) without seeing each other's.
 */
class AndroidPackageClassLoader(
    val stagedApk: File,
    parent: ClassLoader,
    override val environment: PackageEnvironment,
) : BaseDexClassLoader(stagedApk.absolutePath, null, null, parent), PackageOwned {

    override fun loadClass(name: String, resolve: Boolean): Class<*> {
        synchronized(this) {
            findLoadedClass(name)?.let { return it }
            if (HostOwnership.isHostOwned(name)) return parent.loadClass(name)
            return try {
                findClass(name)
            } catch (_: ClassNotFoundException) {
                parent.loadClass(name)
            }
        }
    }

    /** True if this loader defined [className] (it has been loaded from this APK). */
    fun defines(className: String): Boolean = findLoadedClass(className)?.classLoader === this
}

/**
 * [PackageScope.StackResolver] for ART, which has no `StackWalker`: the
 * nearest stack frame whose class one live package loader defined, and only
 * one, names the package. Frames of classes several packages define (shared
 * helper names) are skipped as ambiguous.
 */
object AndroidPackageScope : PackageScope.StackResolver {
    private val loaders = CopyOnWriteArrayList<AndroidPackageClassLoader>()

    fun register(loader: AndroidPackageClassLoader) {
        loaders += loader
    }

    fun unregister(environment: PackageEnvironment) {
        loaders.removeAll { it.environment === environment }
    }

    fun liveLoaders(): Int = loaders.size

    override fun fromStack(): PackageEnvironment? {
        if (loaders.isEmpty()) return null
        for (frame in Thread.currentThread().stackTrace) {
            val name = frame.className
            if (HostOwnership.isHostOwned(name) || name.startsWith("dalvik.") || name.startsWith("com.android.")) continue
            var match: AndroidPackageClassLoader? = null
            var ambiguous = false
            for (loader in loaders) {
                if (loader.defines(name)) {
                    if (match != null) ambiguous = true else match = loader
                }
            }
            if (match != null && !ambiguous) return match.environment
        }
        return null
    }
}

/**
 * The Application a package receives on Android: a real [android.content.ContextWrapper]
 * over the service context, so framework code (WebView, system services,
 * resources, the main looper) works, while preferences stay the package's
 * in-memory stores (KTD9: never the framework's file-backed SharedPreferences)
 * and caches and files stay in the package's private state directory.
 */
class AndroidHostApplication(environment: PackageEnvironment, base: Context) : HostApplication(environment) {
    init {
        attachBaseContext(base)
    }

    /** The app's real package name: framework code (WebView data directories, PreferenceManager) needs it. */
    override fun getPackageName(): String = baseContext.packageName
}

/**
 * Private, read-only staging for admitted APKs (Android 14 dynamic code
 * loading order): the file is created in no-backup storage and marked
 * read-only through its path before any byte is written; the bytes go
 * through the descriptor that was already open, are synced, and are digested
 * on the way. A staged artifact is never writable by path, on any API level.
 */
class ArtifactStagingArea(context: Context) {
    val directory: File = File(context.noBackupFilesDir, "source_runtime/staged").apply { mkdirs() }
    private val ids = AtomicLong()

    /** Removes everything staged by an earlier process (a killed service leaves its copies). */
    fun clear() {
        // Includes ART's oat/ directory for previously loaded secondary DEX.
        directory.listFiles()?.forEach { it.setWritable(true); it.deleteRecursively() }
    }

    /**
     * Copies [source] into staging as a new read-only file and returns it.
     * Fails (and removes the copy) unless its digest is [expectedSha256].
     */
    fun stage(source: File, expectedSha256: String): File {
        val target = File(directory, "${expectedSha256.take(16)}-${ids.incrementAndGet()}.apk")
        target.delete()
        val digest = MessageDigest.getInstance("SHA-256")
        try {
            FileOutputStream(target).use { out ->
                check(target.setReadOnly()) { "could not mark ${target.name} read-only" }
                FileInputStream(source).use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        digest.update(buffer, 0, n)
                        out.write(buffer, 0, n)
                    }
                }
                out.fd.sync()
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (actual != expectedSha256) throw ArtifactException("staged copy digest $actual does not match $expectedSha256")
            requireLoadable(target, expectedSha256)
            return target
        } catch (t: Throwable) {
            target.delete()
            throw t
        }
    }

    /**
     * Refuses a path outside private staging, a file with any write bit or
     * writable by this process, and a digest mismatch, before any class loader
     * exists (checked on every API level, not only where ART enforces it).
     */
    fun requireLoadable(file: File, expectedSha256: String) {
        if (file.canonicalFile.parentFile != directory.canonicalFile) throw ArtifactException("${file.name} is outside private staging")
        val mode = Os.stat(file.absolutePath).st_mode
        val writeBits = OsConstants.S_IWUSR or OsConstants.S_IWGRP or OsConstants.S_IWOTH
        if ((mode and writeBits) != 0 || file.canWrite()) throw ArtifactException("${file.name} is writable; refusing to load mutable code")
        Digests.requireSha256(file, expectedSha256, "Staged APK")
    }

    fun release(file: File) {
        file.delete()
    }
}
