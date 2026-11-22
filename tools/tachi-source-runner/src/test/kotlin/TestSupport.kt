package mangabackup.tachi

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mangabackup.tachi.extensions.ApkConverter
import mangabackup.tachi.extensions.ArtifactVerifier
import mangabackup.tachi.host.HostInjekt
import mangabackup.tachi.host.HostSettings
import mangabackup.tachi.host.HostTransport
import mangabackup.tachi.host.PackageEnvironment
import java.io.File
import java.nio.file.Files

/** Paths and constants shared by the JVM tests. Tests never contact a server. */
object TestSupport {
    /** keiyoushi's published signingKeyFingerprint (repo.json), pinned by the qualification manifest. */
    const val KEIYOUSHI_SIGNER = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"

    val fixtures: File = File(System.getProperty("tachi.fixtures") ?: error("tachi.fixtures not set"))
    val fixtureJars: File = File(System.getProperty("tachi.fixtureJars") ?: error("tachi.fixtureJars not set"))

    data class Qualification(val dir: String, val packageId: String, val jar: String, val apk: String, val version: String)

    val MANGADEX = Qualification("all.mangadex", "eu.kanade.tachiyomi.extension.all.mangadex", "tachiyomi-all.mangadex-v1.6.4.jar", "tachiyomi-all.mangadex-v1.6.4.apk", "1.6.4")
    val WEEBCENTRAL = Qualification("en.weebcentral", "eu.kanade.tachiyomi.extension.en.weebcentral", "tachiyomi-en.weebcentral-v1.6.27.jar", "tachiyomi-en.weebcentral-v1.6.27.apk", "1.6.27")
    val MANGAFIRE = Qualification("all.mangafire", "eu.kanade.tachiyomi.extension.all.mangafire", "tachiyomi-all.mangafire-v1.6.38.jar", "tachiyomi-all.mangafire-v1.6.38.apk", "1.6.38")
    val ALL = listOf(MANGADEX, WEEBCENTRAL, MANGAFIRE)

    fun jar(q: Qualification) = File(fixtures, "${q.dir}/${q.jar}")
    fun apk(q: Qualification) = File(fixtures, "${q.dir}/${q.apk}")

    fun indexSources(q: Qualification): List<JsonObject> {
        val entry = Json.parseToJsonElement(File(fixtures, "${q.dir}/index-entry.json").readText()).jsonObject
        return entry["sources"]!!.jsonArray.map { it.jsonObject }
    }

    fun indexIds(q: Qualification): Set<String> = indexSources(q).map { it["id"]!!.jsonPrimitive.content }.toSet()

    fun tempDir(prefix: String): File = Files.createTempDirectory("tsr-$prefix").toFile()

    fun environment(packageId: String, transport: HostTransport = HostTransport.LIVE, settings: HostSettings = HostSettings.EMPTY): PackageEnvironment {
        HostInjekt.install()
        return PackageEnvironment(packageId, tempDir("state"), transport, "TestAgent/1.0", settings)
    }

    /** Verifies and stages the repository JAR the way artifact.prepare does. */
    fun stagedJar(q: Qualification): File {
        val out = File(tempDir("jar"), "staged.jar")
        jar(q).copyTo(out)
        ArtifactVerifier.verifyJar(out, setOf(KEIYOUSHI_SIGNER))
        return out
    }

    /** Verifies the APK and converts it through dex2jar the way artifact.prepare does. */
    fun convertedApk(q: Qualification): File {
        val src = File(tempDir("apk"), "input.apk")
        apk(q).copyTo(src)
        ArtifactVerifier.verifyApk(src, setOf(KEIYOUSHI_SIGNER))
        val out = File(src.parentFile, "converted.jar")
        ApkConverter.convert(src, out)
        return out
    }
}


/** A string field of a reply, or null when absent (test reading; the worker decodes with typed payloads). */
fun JsonObject.optStr(key: String): String? =
    (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content
