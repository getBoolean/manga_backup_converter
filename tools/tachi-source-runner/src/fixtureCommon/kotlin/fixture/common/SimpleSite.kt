package fixture.common

import android.app.Application
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/**
 * A 1.6-style source over a fake plain-text site. Search lines are
 * `url|title|author`; a details body is `title|author|status|chapterUrl;name;number,...`.
 * Query `setpref:<v>` stores `mark` in the source preferences; every request
 * carries the current `mark` and the class tag, so tests can see which
 * package's state and classes served it.
 */
class SimpleSite(override val name: String, override val baseUrl: String, private val tag: String) : HttpSource() {
    override val lang = "en"
    override val supportsLatest = false
    private val preferences by lazy { Injekt.get<Application>().getSharedPreferences("source_$id", 0) }

    override suspend fun getPopularManga(page: Int): MangasPage = getSearchManga(page, "", FilterList())

    override suspend fun getLatestUpdates(page: Int): MangasPage = getSearchManga(page, "", FilterList())

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        if (query.startsWith("setpref:")) preferences.edit().putString("mark", query.removePrefix("setpref:")).apply()
        val mark = preferences.getString("mark", "none")
        val body = client.newCall(GET("$baseUrl/search?q=$query&page=$page&mark=$mark&tag=$tag", headers)).awaitSuccess().use { it.body.string() }
        val mangas = body.lines().filter { it.isNotBlank() }.map { line ->
            val (url, title, author) = line.split('|')
            SManga.create().apply {
                this.url = url
                this.title = title
                this.author = author
            }
        }
        return MangasPage(mangas, page < 2 && mangas.isNotEmpty())
    }

    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean): SMangaUpdate {
        val body = client.newCall(GET(baseUrl + manga.url, headers)).awaitSuccess().use { it.body.string() }
        val (title, author, status, chapterList) = body.trim().split('|')
        val details = SManga.create().apply {
            url = manga.url
            this.title = title
            this.author = author
            this.status = status.toInt()
            initialized = true
        }
        val parsed = chapterList.split(',').filter { it.isNotBlank() }.map { item ->
            val (url, name, number) = item.split(';')
            SChapter.create().apply {
                this.url = url
                this.name = name
                chapter_number = number.toFloat()
                date_upload = 1_700_000_000_000L
                scanlator = "Group A, Group B"
            }
        }
        return SMangaUpdate(details, parsed)
    }

    override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()

    override fun getMangaUrl(manga: SManga): String = baseUrl + manga.url

    override fun getChapterUrl(chapter: SChapter): String = baseUrl + chapter.url
}

