package dev.getboolean.sourceruntime

import android.content.Context
import android.content.pm.PackageManager
import dalvik.system.PathClassLoader
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Loads an original Tachi extension APK's DEX in the service process (KTD17).
 *
 * Admission order: refuse a writable staged file, then a digest mismatch,
 * then parse the APK manifest, and only then create the class loader. The
 * loader's parent is this service's own class loader, which carries the
 * pinned source API, so `SourceFactory` and every other host type stay
 * parent-owned.
 */
internal class ExtensionLoader(private val context: Context) {
    fun load(path: String, expectedSha256: String): JSONObject {
        val file = File(path)
        val stagingRoot = File(ArtifactStaging.stagingDirectory(context)).canonicalFile
        if (file.canonicalFile.parentFile != stagingRoot) {
            throw SecurityException("artifact is outside private staging")
        }
        if (ArtifactStaging.isWritable(file)) {
            throw SecurityException("staged artifact is writable")
        }
        val actual = ArtifactStaging.sha256(file)
        if (actual != expectedSha256) {
            throw SecurityException("staged artifact digest $actual does not match $expectedSha256")
        }

        val result = JSONObject()
            .put("pid", android.os.Process.myPid())
            .put("processName", SourceRuntimeService.currentProcessName())
            .put("sha256", actual)

        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageArchiveInfo(path, PackageManager.GET_META_DATA)
            ?: throw IllegalStateException("not a parseable APK")
        val pkg = info.packageName
        val meta = info.applicationInfo?.metaData
            ?: throw IllegalStateException("APK has no application metadata")
        val declared = meta.getString(EXTENSION_CLASS)
            ?: throw IllegalStateException("APK does not declare $EXTENSION_CLASS")
        val factoryName = if (declared.startsWith(".")) pkg + declared else declared
        result.put("packageName", pkg)
            .put("versionName", info.versionName)
            .put("extensionLib", meta.get(EXTENSION_LIB)?.toString())
            .put("factoryClass", factoryName)

        val parent = ExtensionLoader::class.java.classLoader
        val loader = PathClassLoader(path, parent)
        // initialize = true forces linking and static initialisation.
        val factoryClass = Class.forName(factoryName, true, loader)
        result.put("factoryLoader", factoryClass.classLoader?.javaClass?.name)
            .put("factoryLinked", true)
            .put("factoryIsSourceFactory", SourceFactory::class.java.isAssignableFrom(factoryClass))
            .put(
                "sourceFactoryParentOwned",
                factoryClass.interfaces.any { it === SourceFactory::class.java } &&
                    SourceFactory::class.java.classLoader === parent,
            )

        result.put("construction", construct(factoryClass))
        return result
    }

    /**
     * Tries to construct the factory and its sources with only the pinned
     * source API on the parent class path. With the compile-time stub API the
     * source constructors throw; that outcome is recorded, not hidden.
     */
    private fun construct(factoryClass: Class<*>): JSONObject {
        val out = JSONObject()
        val sources = try {
            val factory = factoryClass.getDeclaredConstructor().newInstance() as SourceFactory
            factory.createSources()
        } catch (e: Throwable) {
            val root = generateSequence(e) { it.cause }.last()
            return out.put("ok", false)
                .put("error", e.javaClass.name)
                .put("rootCause", root.javaClass.name)
                .put("rootMessage", root.message ?: "")
                .put("rootFrame", root.stackTrace.firstOrNull()?.toString() ?: "")
        }
        val ids = JSONArray()
        sources.forEach { source: Source ->
            ids.put(JSONObject().put("id", source.id.toString()).put("name", source.name).put("lang", (source as? CatalogueSource)?.lang))
        }
        return out.put("ok", true).put("sources", ids)
    }

    companion object {
        const val EXTENSION_CLASS = "tachiyomi.extension.class"
        const val EXTENSION_LIB = "tachiyomix.extensionLib"
    }
}
