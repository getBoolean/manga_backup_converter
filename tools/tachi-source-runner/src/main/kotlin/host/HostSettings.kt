package mangabackup.tachi.host

/**
 * A package's settings snapshot as the supervisor sent it (SettingsPayload,
 * protocol 1.1).
 *
 * [values] and [secrets] apply to every source of the package and seed every
 * SharedPreferences store it opens. [sources] holds per-source overrides keyed
 * by source ID; they seed only that source's store, `source_<id>` by Tachi
 * convention, on top of the package-wide entries. Keys are plain preference
 * keys: no key carries a store or source prefix. Secrets live only in memory
 * (KTD9).
 */
data class HostSettings(
    val values: Map<String, Any>,
    val secrets: Map<String, String>,
    val revision: String,
    val sources: Map<String, SourceScope> = emptyMap(),
) {
    /** One source's own values and secrets. */
    data class SourceScope(val values: Map<String, Any> = emptyMap(), val secrets: Map<String, String> = emptyMap())

    /** The entries store [storeName] starts from: package-wide, overlaid with its source's scope. */
    fun seedFor(storeName: String): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        out += values
        out += secrets
        val scope = storeName.removePrefix(SOURCE_STORE_PREFIX).takeIf { storeName.startsWith(SOURCE_STORE_PREFIX) }?.let { sources[it] }
        if (scope != null) {
            out += scope.values
            out += scope.secrets
        }
        return out
    }

    companion object {
        /** Tachi's name for a source's preference store: `source_<id>` (ConfigurableSource.preferenceKey). */
        const val SOURCE_STORE_PREFIX = "source_"

        val EMPTY = HostSettings(emptyMap(), emptyMap(), "")
    }
}
