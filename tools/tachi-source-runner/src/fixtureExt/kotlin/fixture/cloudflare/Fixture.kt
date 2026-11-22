package fixture.cloudflare

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
 * A source behind a (simulated) Cloudflare challenge, for the browser-join end-to-end test. Its base URL
 * is the `baseUrl` setting, so the test points it at a loopback server. Search lines are `url|title`.
 * It uses the regular `network.client`, so Cloudflare handling is entirely the host's interceptor.
 */
class Cloudflare : HttpSource() {
    override val id = 301L
    override val name = "Challenged"
    override val lang = "en"
    override val supportsLatest = false
    override val baseUrl: String
        get() = Injekt.get<Application>().getSharedPreferences("source_$id", 0).getString("baseUrl", null)
            ?: error("baseUrl setting missing")

    override suspend fun getPopularManga(page: Int) = getSearchManga(page, "", FilterList())

    override suspend fun getLatestUpdates(page: Int) = getSearchManga(page, "", FilterList())

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        val body = client.newCall(GET("$baseUrl/search?q=$query", headers)).awaitSuccess().use { it.body.string() }
        val mangas = body.lines().filter { it.isNotBlank() }.map { line ->
            val (url, title) = line.split('|')
            SManga.create().apply {
                this.url = url
                this.title = title
            }
        }
        return MangasPage(mangas, false)
    }

    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
        SMangaUpdate(SManga.create().apply { url = manga.url; title = manga.title }, emptyList())

    override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()

    override fun getMangaUrl(manga: SManga) = baseUrl + manga.url

    override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
}
