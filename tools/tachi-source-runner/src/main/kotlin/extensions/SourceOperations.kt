package mangabackup.tachi.extensions

import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import mangabackup.tachi.protocol.ArtifactBinding
import mangabackup.tachi.protocol.DetailsRequest
import mangabackup.tachi.protocol.DisposeRequest
import mangabackup.tachi.protocol.ErrorCode
import mangabackup.tachi.protocol.NativeMangaRef
import mangabackup.tachi.protocol.SearchRequest
import mangabackup.tachi.protocol.SourceIdentity
import mangabackup.tachi.protocol.Wire
import mangabackup.tachi.protocol.WorkerError
import java.io.File
import java.math.BigDecimal
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.ZipFile

/**
 * Search, details and dispose for one loaded package, mapping Tachi models to
 * protocol shapes. References are durable (KTD3): a hit's `ref.context` holds
 * every SManga field, so details can rehydrate the manga after a restart
 * without the live handle.
 */
class SourceOperations(private val pkg: ExtensionPackage, private val artifact: ArtifactBinding) {
    private class Handle(val sourceId: String, val manga: SManga)

    private val handles = ConcurrentHashMap<String, Handle>()
    private val handleIds = AtomicLong()

    fun handleCount(): Int = handles.size

    private fun resolveSource(identity: SourceIdentity, settingsRevision: String): Source {
        if (identity.packageId != pkg.packageId) throw WorkerError(ErrorCode.STALE_REFERENCE, "source belongs to ${identity.packageId}, not ${pkg.packageId}")
        if (identity.artifact != artifact) throw WorkerError(ErrorCode.STALE_REFERENCE, "source was bound to artifact ${identity.artifact.sha256}, loaded artifact is ${artifact.sha256}")
        if (settingsRevision != pkg.environment.settings.revision) {
            throw WorkerError(ErrorCode.STALE_REFERENCE, "settings revision $settingsRevision is not the package's current revision")
        }
        return pkg.source(identity.sourceId) ?: throw WorkerError(ErrorCode.STALE_REFERENCE, "package does not host source ${identity.sourceId}")
    }

    suspend fun search(request: SearchRequest): JsonObject {
        val identity = request.source
        val revision = request.settingsRevision
        val source = resolveSource(identity, revision) as? CatalogueSource
            ?: throw WorkerError(ErrorCode.UNSUPPORTED_API, "source ${identity.sourceId} is not a catalogue source")
        val query = request.query
        val page = request.cursor?.let { it.toIntOrNull() ?: throw WorkerError(ErrorCode.STALE_REFERENCE, "unknown cursor $it") } ?: 1
        val result = source.getSearchManga(page, query, source.getFilterList())
        return buildJsonObject {
            put("hits", buildJsonArray {
                for (manga in result.mangas) {
                    val handle = "h${handleIds.incrementAndGet()}"
                    handles[handle] = Handle(identity.sourceId, manga)
                    add(buildJsonObject {
                        put("ref", Wire.encode(NativeMangaRef(identity, manga.url, revision, mangaContext(manga))))
                        put("title", manga.safeTitle() ?: manga.url)
                        put("coverUrl", manga.thumbnail_url)
                        put("authors", strings(splitNames(manga.author)))
                        put("handle", handle)
                    })
                }
            })
            put("nextCursor", if (result.hasNextPage) (page + 1).toString() else null)
            put("warnings", strings(pkg.environment.currentOperation?.warnings.orEmpty()))
        }
    }

    suspend fun details(request: DetailsRequest): JsonObject {
        val identity = request.source
        val revision = request.settingsRevision
        val source = resolveSource(identity, revision)
        val ref = request.ref
        if (ref.settingsRevision != revision) throw WorkerError(ErrorCode.STALE_REFERENCE, "reference was confirmed under settings revision ${ref.settingsRevision}")
        if (ref.source != identity) throw WorkerError(ErrorCode.STALE_REFERENCE, "reference belongs to a different source identity")
        val handleId = request.handle
        val original = if (handleId != null) {
            val h = handles[handleId] ?: throw WorkerError(ErrorCode.STALE_REFERENCE, "handle $handleId was not issued by this worker")
            if (h.sourceId != identity.sourceId) throw WorkerError(ErrorCode.STALE_REFERENCE, "handle $handleId belongs to another source")
            h.manga
        } else {
            rehydrate(ref)
        }
        val update = source.getMangaUpdate(original.copy(), emptyList(), true, true)
        val manga = update.manga
        val http = source as? HttpSource
        val title = manga.safeTitle()?.takeIf { it.isNotBlank() } ?: original.safeTitle()
            ?: throw WorkerError(ErrorCode.SOURCE_ERROR, "source returned no title for ${ref.mangaId}")
        val chapters = update.chapters
        return buildJsonObject {
            put("metadata", buildJsonObject {
                put("title", title)
                put("altTitles", JsonArray(emptyList()))
                put("authors", strings(splitNames(manga.author ?: original.author)))
                put("artists", strings(splitNames(manga.artist ?: original.artist)))
                put("description", manga.description ?: original.description)
                put("tags", strings(manga.getGenres() ?: original.getGenres() ?: emptyList()))
                put("status", status(manga.status))
                put("contentRating", "unknown")
                put("url", http?.let { runCatching { it.getMangaUrl(manga.withUrl(original.url)) }.getOrNull() })
                put("coverUrl", manga.thumbnail_url ?: original.thumbnail_url)
            })
            put("chapters", buildJsonArray {
                chapters.forEachIndexed { index, chapter -> add(chapterJson(chapter, index, http)) }
            })
        }
    }

    fun dispose(request: DisposeRequest) {
        val sourceId = request.source.sourceId
        val listed = request.handles
        if (listed == null) {
            handles.entries.removeIf { it.value.sourceId == sourceId }
        } else {
            for (h in listed) if (handles[h]?.sourceId == sourceId) handles.remove(h)
        }
    }

    private fun SManga.withUrl(url: String): SManga = also { runCatching { this.url }.getOrNull() ?: run { this.url = url } }

    private fun chapterJson(chapter: SChapter, index: Int, http: HttpSource?) = buildJsonObject {
        put("chapterId", chapter.url)
        put("sourceOrder", index)
        put("context", buildJsonObject {
            put("url", chapter.url)
            put("name", chapter.name)
            put("date_upload", chapter.date_upload)
            put("chapter_number", decimal(chapter.chapter_number))
            put("scanlator", chapter.scanlator)
            put("memo", chapter.memo)
        })
        put("title", chapter.name)
        put("chapterNumber", chapter.chapter_number.takeIf { it >= 0f }?.let { decimal(it) } ?: JsonNull)
        put("volumeNumber", JsonNull)
        put("scanlators", strings(splitNames(chapter.scanlator)))
        put("language", JsonNull)
        put("dateUploaded", chapter.date_upload.takeIf { it > 0 }?.let { Instant.ofEpochMilli(it).toString() })
        put("url", http?.let { runCatching { it.getChapterUrl(chapter) }.getOrNull() })
    }

    companion object {
        /** Float → shortest decimal, so 1.1f crosses JSON as 1.1, not 1.100000023841858. */
        fun strings(values: Iterable<String>): JsonArray = JsonArray(values.map(::JsonPrimitive))

        fun decimal(f: Float): JsonPrimitive = JsonPrimitive(BigDecimal(f.toString()))

        fun splitNames(value: String?): List<String> =
            value?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() }?.distinct().orEmpty()

        fun status(s: Int): String = when (s) {
            SManga.ONGOING -> "ongoing"
            SManga.COMPLETED, SManga.PUBLISHING_FINISHED -> "completed"
            SManga.CANCELLED -> "cancelled"
            SManga.ON_HIATUS -> "hiatus"
            else -> "unknown"
        }

        fun SManga.safeTitle(): String? = try {
            title
        } catch (_: UninitializedPropertyAccessException) {
            null
        }

        fun mangaContext(m: SManga): JsonObject = buildJsonObject {
            put("url", m.url)
            put("title", m.safeTitle())
            put("artist", m.artist)
            put("author", m.author)
            put("description", m.description)
            put("genre", m.genre)
            put("status", m.status)
            put("thumbnail_url", m.thumbnail_url)
            put("update_strategy", m.update_strategy.name)
            put("initialized", m.initialized)
            put("memo", m.memo)
        }

        /** Rebuilds the source-returned SManga from a durable reference (KTD3). */
        fun rehydrate(ref: NativeMangaRef): SManga {
            val c = ref.context
            fun s(k: String) = (c[k] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            return SManga.create().apply {
                url = s("url") ?: ref.mangaId
                s("title")?.let { title = it }
                artist = s("artist")
                author = s("author")
                description = s("description")
                genre = s("genre")
                status = (c["status"] as? JsonPrimitive)?.intOrNull ?: SManga.UNKNOWN
                thumbnail_url = s("thumbnail_url")
                update_strategy = s("update_strategy")?.let { runCatching { UpdateStrategy.valueOf(it) }.getOrNull() } ?: UpdateStrategy.ALWAYS_UPDATE
                initialized = (c["initialized"] as? JsonPrimitive)?.booleanOrNull ?: false
                (c["memo"] as? JsonObject)?.let { memo = it }
            }
        }

        private val DEX_ENTRY = Regex("""^classes\d*\.dex$""")

        /**
         * Whether any class of the artifact (JVM classes, or the DEX files of an
         * original APK) references android.webkit.WebView: the source may need a browser.
         */
        fun referencesWebView(jar: File): Boolean {
            val needle = "android/webkit/WebView".toByteArray()
            ZipFile(jar).use { zip ->
                for (e in zip.entries()) {
                    if (!e.name.endsWith(".class") && !DEX_ENTRY.matches(e.name)) continue
                    val bytes = zip.getInputStream(e).use { it.readBytes() }
                    if (indexOf(bytes, needle) >= 0) return true
                }
            }
            return false
        }

        private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
            outer@ for (i in 0..haystack.size - needle.size) {
                for (j in needle.indices) if (haystack[i + j] != needle[j]) continue@outer
                return i
            }
            return -1
        }
    }
}
