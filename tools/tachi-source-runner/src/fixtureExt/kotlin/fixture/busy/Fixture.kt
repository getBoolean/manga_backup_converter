package fixture.busy

import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource

class Factory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(Busy())
}

/** `busy` spins without any cancellation point; `slow` sleeps, so interruption cancels it; `missing` links a class the host lacks. */
class Busy : HttpSource() {
    override val name = "Busy"
    override val lang = "en"
    override val baseUrl = "https://busy.test"
    override val supportsLatest = false

    @Volatile
    var counter = 0L

    override suspend fun getPopularManga(page: Int) = MangasPage(emptyList(), false)
    override suspend fun getLatestUpdates(page: Int) = MangasPage(emptyList(), false)

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        when (query) {
            "busy" -> while (true) counter++
            "slow" -> repeat(100_000) { Thread.sleep(50) }
            "unsupported" -> android.content.Context().getCacheDir()
            "js" -> eu.kanade.tachiyomi.network.JavaScriptEngine(android.content.Context()).evaluate<String>("1+1")
        }
        return MangasPage(listOf(SManga.create().apply { url = "/q/$query"; title = query }), false)
    }

    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
        SMangaUpdate(manga, emptyList())

    override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()
    override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
    override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
}

