package mangabackup.tachi.host

/**
 * A package's settings snapshot as the supervisor sent it (SettingsPayload).
 *
 * Keys address extension SharedPreferences stores: a plain key seeds every
 * store the package opens; `storeName/key` (for example `source_123/lang`)
 * seeds only that store. Secrets are seeded the same way and live only in
 * memory (KTD9).
 */
data class HostSettings(
    val values: Map<String, Any>,
    val secrets: Map<String, String>,
    val revision: String,
) {
    /** Entries applying to [storeName], namespaced keys stripped. */
    fun seedFor(storeName: String): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        fun add(entries: Map<String, Any>) {
            for ((key, value) in entries) {
                val slash = key.indexOf('/')
                if (slash < 0) {
                    out.putIfAbsent(key, value)
                } else if (key.substring(0, slash) == storeName) {
                    out[key.substring(slash + 1)] = value
                }
            }
        }
        // Store-specific entries override plain ones regardless of order.
        val namespaced = (values + secrets).filterKeys { it.contains('/') }
        val plain = (values + secrets).filterKeys { !it.contains('/') }
        add(namespaced)
        add(plain)
        return out
    }

    companion object {
        val EMPTY = HostSettings(emptyMap(), emptyMap(), "")
    }
}

