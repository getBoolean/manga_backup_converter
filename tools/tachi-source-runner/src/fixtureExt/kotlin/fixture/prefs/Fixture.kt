package fixture.prefs

import android.app.Application
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/** Two sources with fixed IDs whose search reports what their `source_<id>` store was seeded with. No network. */
class Factory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(Prefs(101, "One"), Prefs(102, "Two"))
}

class Prefs(override val id: Long, override val name: String) : HttpSource() {
    override val lang = "en"
    override val baseUrl = "https://prefs.test"
    override val supportsLatest = false

    override suspend fun getPopularManga(page: Int) = MangasPage(emptyList(), false)
    override suspend fun getLatestUpdates(page: Int) = MangasPage(emptyList(), false)

    /** Title: `lang=<lang>;tags=<a,b>;password=<set|unset>` from this source's preference store. */
    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        val prefs = Injekt.get<Application>().getSharedPreferences("source_$id", 0)
        val tags = prefs.getStringSet("tags", emptySet())!!.sorted().joinToString(",")
        val password = if (prefs.getString("password", null).isNullOrEmpty()) "unset" else "set"
        val title = "lang=${prefs.getString("lang", "-")};tags=$tags;password=$password"
        return MangasPage(listOf(SManga.create().apply { url = "/p/$id"; this.title = title }), false)
    }

    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
        SMangaUpdate(SManga.create().apply { url = manga.url; title = manga.title }, emptyList())

    override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()
    override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
    override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
}
