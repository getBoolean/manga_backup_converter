package eu.kanade.tachiyomi

/**
 * Host identity reported to extensions (extensions-lib `AppInfo`). The desktop
 * host implements the Mihon source API it was extracted from, so it reports a
 * Mihon-compatible version; see THIRD_PARTY.md for the pinned Mihon commit.
 */
@Suppress("unused")
object AppInfo {
    fun getVersionCode(): Int = 19

    fun getVersionName(): String = "0.19.0"
}

