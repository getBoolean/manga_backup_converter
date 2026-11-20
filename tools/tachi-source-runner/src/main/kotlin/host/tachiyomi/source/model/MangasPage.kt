// Extracted from Mihon (https://github.com/mihonapp/mihon) at f64d82b94218b42410c36e6c85da818574865a28,
// Apache License 2.0. Copyright the Mihon Open Source Project and Tachiyomi contributors.
// Changes for the desktop Tachi host are marked "desktop host:"; see THIRD_PARTY.md.

package eu.kanade.tachiyomi.source.model

class MangasPage(val mangas: List<SManga>, val hasNextPage: Boolean) {

    @Deprecated("MangasPage is now a regular class")
    operator fun component1(): List<SManga> = mangas

    @Deprecated("MangasPage is now a regular class")
    operator fun component2(): Boolean = hasNextPage

    @Deprecated("MangasPage is now a regular class")
    fun copy(
        mangas: List<SManga> = this.mangas,
        hasNextPage: Boolean = this.hasNextPage,
    ): MangasPage = MangasPage(
        mangas = mangas,
        hasNextPage = hasNextPage,
    )
}
