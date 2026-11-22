// Extracted from Mihon (https://github.com/mihonapp/mihon) at f64d82b94218b42410c36e6c85da818574865a28,
// Apache License 2.0. Copyright the Mihon Open Source Project and Tachiyomi contributors.
// Changes for the desktop Tachi host are marked "desktop host:"; see THIRD_PARTY.md.

package eu.kanade.tachiyomi.source.model

/**
 * Define the update strategy for a single [SManga].
 * The strategy used will only take effect on the library update.
 *
 * @since extensions-lib 1.4
 */
@Suppress("UNUSED")
enum class UpdateStrategy {
    /**
     * Series marked as always update will be included in the library
     * update if they aren't excluded by additional restrictions.
     */
    ALWAYS_UPDATE,

    /**
     * Series marked as only fetch once will be automatically skipped
     * during library updates. Useful for cases where the series is previously
     * known to be finished and have only a single chapter, for example.
     */
    ONLY_FETCH_ONCE,
}
