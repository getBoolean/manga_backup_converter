package eu.kanade.tachiyomi.network

import android.content.Context
import mangabackup.tachi.shim.UnsupportedHostApi

/**
 * extensions-lib `JavaScriptEngine`. Mihon backs it with QuickJS through an
 * Android-only JNI build; none of the qualification extensions call it, so the
 * desktop host fails every evaluation explicitly rather than pretending.
 */
@Suppress("unused", "UNUSED_PARAMETER")
class JavaScriptEngine(context: Context) {
    suspend fun <T> evaluate(script: String): T =
        throw UnsupportedHostApi("eu.kanade.tachiyomi.network.JavaScriptEngine.evaluate (no JS engine in the desktop host)")
}

