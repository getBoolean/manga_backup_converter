package fixture.multi

import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource

/** One factory, three sources sharing one package; one overrides Source.id with the int64 maximum. */
class Factory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(Multi("One", "en"), Multi("Two", "fr"), Overridden())
}

open class Multi(override val name: String, override val lang: String) : HttpSource() {
    override val baseUrl = "https://multi.test"
    override val supportsLatest = false

    override suspend fun getPopularManga(page: Int) = MangasPage(emptyList(), false)
    override suspend fun getLatestUpdates(page: Int) = MangasPage(emptyList(), false)
    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList) =
        MangasPage(listOf(SManga.create().apply { url = "/m/$name"; title = "$name:$query"; genre = "A, B" }), false)

    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
        SMangaUpdate(SManga.create().apply { url = manga.url; title = manga.title; description = "details of ${manga.url}" }, emptyList())

    override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()
    override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
    override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
}

class Overridden : Multi("Overridden", "ja") {
    override val id: Long = Long.MAX_VALUE
}

