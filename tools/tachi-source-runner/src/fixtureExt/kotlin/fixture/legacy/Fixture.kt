package fixture.legacy

import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import okhttp3.Request
import okhttp3.Response

/** extensions-lib 1.5 style: the deprecated request/parse pairs and Rx fetch path (legacy adapter). */
@Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
class LegacySource : HttpSource() {
    override val name = "Legacy"
    override val lang = "en"
    override val baseUrl = "https://legacy.test"
    override val supportsLatest = false

    override fun searchMangaRequest(page: Int, query: String, filters: FilterList): Request = GET("$baseUrl/search?q=$query", headers)

    override fun searchMangaParse(response: Response): MangasPage {
        val mangas = response.body.string().lines().filter { it.isNotBlank() }.map { line ->
            val (url, title) = line.split('|')
            SManga.create().apply {
                this.url = url
                this.title = title
            }
        }
        return MangasPage(mangas, false)
    }

    override fun mangaDetailsParse(response: Response): SManga = SManga.create().apply {
        title = response.body.string().trim()
        description = "legacy details"
    }

    override fun chapterListParse(response: Response): List<SChapter> = listOf(
        SChapter.create().apply {
            url = "/c/1"
            name = "Chapter 1"
            chapter_number = 1f
        },
    )

    override fun popularMangaRequest(page: Int): Request = throw UnsupportedOperationException()
    override fun popularMangaParse(response: Response): MangasPage = throw UnsupportedOperationException()
    override fun latestUpdatesRequest(page: Int): Request = throw UnsupportedOperationException()
    override fun latestUpdatesParse(response: Response): MangasPage = throw UnsupportedOperationException()
    override fun pageListParse(response: Response) = throw UnsupportedOperationException()
    override fun imageUrlParse(response: Response) = throw UnsupportedOperationException()
}
