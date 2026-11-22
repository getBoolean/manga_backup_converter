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

/**
 * `busy` spins without any cancellation point; `slow` sleeps, so interruption cancels it; `missing` links a class the host lacks.
 *
 * iOS deadline and R18 cases (U9): `count` reports the counter, so a caller can prove a stopped loop stays stopped;
 * `catch` swallows every Throwable inside its loop and loops again; `regex` backtracks catastrophically inside
 * java.util.regex; `hang` waits on a host HTTP call that never answers; `native` tries every way an extension could
 * load native code and reports what each attempt threw.
 */
class Busy : HttpSource() {
    override val name = "Busy"
    override val lang = "en"
    override val baseUrl = "https://busy.test"
    override val supportsLatest = false

    @Volatile
    var counter = 0L

    @Volatile
    var caught = 0L

    private fun attempt(block: () -> Unit): String = try {
        block()
        "loaded"
    } catch (t: Throwable) {
        val cause = if (t is java.lang.reflect.InvocationTargetException) t.cause ?: t else t
        cause.javaClass.simpleName
    }

    private fun nativeAttempts(): String {
        val loadLibrary = attempt { System.loadLibrary("z") }
        val load = attempt { System.load("/usr/lib/libz.1.dylib") }
        val reflective = attempt {
            System::class.java.getMethod("load", String::class.java).invoke(null, "/usr/lib/libz.1.dylib")
        }
        // java.lang.foreign is final from Java 22; reached reflectively so this fixture still compiles for Java 21.
        val foreign = attempt {
            val arena = Class.forName("java.lang.foreign.Arena").getMethod("global").invoke(null)
            Class.forName("java.lang.foreign.SymbolLookup")
                .getMethod("libraryLookup", String::class.java, Class.forName("java.lang.foreign.Arena"))
                .invoke(null, "/usr/lib/libz.1.dylib", arena)
        }
        return "loadLibrary=$loadLibrary;load=$load;reflective=$reflective;foreign=$foreign"
    }

    override suspend fun getPopularManga(page: Int) = MangasPage(emptyList(), false)
    override suspend fun getLatestUpdates(page: Int) = MangasPage(emptyList(), false)

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        when (query) {
            "busy" -> while (true) counter++
            "slow" -> repeat(100_000) { Thread.sleep(50) }
            "unsupported" -> android.content.Context().getCacheDir()
            "js" -> eu.kanade.tachiyomi.network.JavaScriptEngine(android.content.Context()).evaluate<String>("1+1")
            "count" -> return MangasPage(listOf(SManga.create().apply { url = "/count"; title = counter.toString() }), false)
            "catch" -> while (true) {
                try {
                    while (true) counter++
                } catch (_: Throwable) {
                    caught++
                }
            }
            "regex" -> {
                val matched = Regex("((x+)\\2?)+y").matches("x".repeat(40))
                return MangasPage(listOf(SManga.create().apply { url = "/regex"; title = "matched=$matched" }), false)
            }
            "hang" -> client.newCall(eu.kanade.tachiyomi.network.GET("https://hang.test/never")).execute().close()
            "native" -> return MangasPage(listOf(SManga.create().apply { url = "/native"; title = nativeAttempts() }), false)
        }
        return MangasPage(listOf(SManga.create().apply { url = "/q/$query"; title = query }), false)
    }

    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
        SMangaUpdate(manga, emptyList())

    override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()
    override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
    override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
}

