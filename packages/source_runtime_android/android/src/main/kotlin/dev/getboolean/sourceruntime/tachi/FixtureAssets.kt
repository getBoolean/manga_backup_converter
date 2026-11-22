package dev.getboolean.sourceruntime.tachi

import android.content.Context
import androidx.annotation.Keep
import java.io.File

/**
 * Copies an asset directory into the app's cache, for integration tests that
 * read committed fixtures (`fixtures/source_captures/tachi/<package>/`) from
 * the plugin's debug-only asset folder. Release builds carry no fixture
 * assets, so this finds nothing there.
 */
@Keep
object FixtureAssets {
    /** Copies the asset tree [assetDir] to `cacheDir/fixtures/<assetDir>` and returns that path. */
    fun copyDirectory(context: Context, assetDir: String): String {
        require(Regex("^[A-Za-z0-9._/-]+$").matches(assetDir) && !assetDir.contains("..")) { "bad asset path $assetDir" }
        val target = File(context.cacheDir, "fixtures/$assetDir")
        target.deleteRecursively()
        copy(context, assetDir, target)
        if (!target.exists()) throw IllegalStateException("no asset directory $assetDir (debug builds only)")
        return target.absolutePath
    }

    private fun copy(context: Context, path: String, target: File) {
        val children = context.assets.list(path).orEmpty()
        if (children.isEmpty()) {
            target.parentFile?.mkdirs()
            runCatching {
                context.assets.open(path).use { input -> target.outputStream().use { input.copyTo(it) } }
            }
            return
        }
        target.mkdirs()
        for (child in children) copy(context, "$path/$child", File(target, child))
    }
}
