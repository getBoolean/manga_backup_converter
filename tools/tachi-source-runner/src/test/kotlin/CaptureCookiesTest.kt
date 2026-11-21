package mangabackup.tachi

import mangabackup.tachi.extensions.Digests
import mangabackup.tachi.host.PackageCookieJar
import mangabackup.tachi.host.replay.CaptureFormat
import mangabackup.tachi.host.replay.CaptureFormat.CapturedCookie
import mangabackup.tachi.host.replay.CaptureFormat.CookieMode
import mangabackup.tachi.host.replay.ExchangeHandler
import mangabackup.tachi.host.replay.LoopbackTransport
import mangabackup.tachi.host.replay.ReplayLog
import mangabackup.tachi.host.replay.ReplayTransport
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/** Protocol 1.3 capture rules: allow-listed `Set-Cookie`s and `cf-mitigated`, matching the Dart capture format. */
class CaptureCookiesTest {
    private val loginBody = "{\"ok\":true}".toByteArray()
    private val challengeBody = "challenge".toByteArray()
    private val nextBody = "next".toByteArray()

    /** `capture.json` exactly as Dart's `CaptureManifest.encode` writes it (key order, omitted empties). */
    private fun dartCapture(): String {
        fun sha(b: ByteArray) = Digests.sha256(b)
        return """
            |{
            |  "format": 1,
            |  "ecosystem": "tachi",
            |  "source": "site.test",
            |  "recordedAt": "2026-11-20T12:00:00.123Z",
            |  "recordedBy": "tool/capture_source_fixtures.dart",
            |  "notes": "cookie case",
            |  "volatileQueryParameters": [],
            |  "setCookieAllowList": {
            |    "consent": "keep",
            |    "mhub_access": "redact"
            |  },
            |  "exchanges": [
            |    {
            |      "request": {
            |        "method": "GET",
            |        "url": "https://site.test/login",
            |        "bodySha256": null
            |      },
            |      "response": {
            |        "status": 200,
            |        "headers": {
            |          "content-type": "application/json"
            |        },
            |        "body": "bodies/${sha(loginBody)}.bin",
            |        "setCookies": [
            |          {
            |            "name": "mhub_access",
            |            "value": "redacted",
            |            "path": "/",
            |            "domain": "site.test",
            |            "redacted": true
            |          },
            |          {
            |            "name": "consent",
            |            "value": "yes"
            |          }
            |        ]
            |      },
            |      "artifact": {
            |        "sourceUrl": "https://site.test/login",
            |        "sha256": "${sha(loginBody)}",
            |        "size": ${loginBody.size},
            |        "licence": "test"
            |      }
            |    },
            |    {
            |      "request": {
            |        "method": "GET",
            |        "url": "https://site.test/challenge",
            |        "bodySha256": null
            |      },
            |      "response": {
            |        "status": 403,
            |        "headers": {
            |          "cf-mitigated": "challenge"
            |        },
            |        "body": "bodies/${sha(challengeBody)}.bin"
            |      },
            |      "artifact": {
            |        "sourceUrl": "https://site.test/challenge",
            |        "sha256": "${sha(challengeBody)}",
            |        "size": ${challengeBody.size},
            |        "licence": "test"
            |      }
            |    },
            |    {
            |      "request": {
            |        "method": "GET",
            |        "url": "https://site.test/next",
            |        "bodySha256": null
            |      },
            |      "response": {
            |        "status": 200,
            |        "headers": {
            |          "content-type": "text/plain"
            |        },
            |        "body": "bodies/${sha(nextBody)}.bin"
            |      },
            |      "artifact": {
            |        "sourceUrl": "https://site.test/next",
            |        "sha256": "${sha(nextBody)}",
            |        "size": ${nextBody.size},
            |        "licence": "test"
            |      }
            |    }
            |  ]
            |}
            |""".trimMargin()
    }

    private fun captureDir(json: String = dartCapture()): File {
        val dir = TestSupport.tempDir("capture")
        File(dir, CaptureFormat.BODIES).mkdirs()
        for (b in listOf(loginBody, challengeBody, nextBody)) File(dir, "${CaptureFormat.BODIES}/${Digests.sha256(b)}.bin").writeBytes(b)
        File(dir, CaptureFormat.MANIFEST).writeText(json)
        return dir
    }

    @Test
    fun `a Dart-written capture with cookies and cf-mitigated loads and encodes back unchanged`() {
        val dir = captureDir()
        try {
            val set = CaptureFormat.load(dir)
            assertEquals(mapOf("consent" to CookieMode.KEEP, "mhub_access" to CookieMode.REDACT), set.manifest.setCookieAllowList)
            val login = set.manifest.exchanges.first()
            assertEquals(
                listOf(CapturedCookie("mhub_access", "redacted", "/", "site.test", redacted = true), CapturedCookie("consent", "yes")),
                login.setCookies,
            )
            assertEquals("challenge", set.manifest.exchanges[1].headers["cf-mitigated"])
            // Kotlin writes its own recordedBy; everything else round-trips byte for byte.
            assertEquals(dartCapture(), set.manifest.copy(recordedBy = "tool/capture_source_fixtures.dart").encode())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `an unknown cookie mode is refused`() {
        val dir = captureDir(dartCapture().replace("\"consent\": \"keep\"", "\"consent\": \"store\""))
        try {
            val e = assertThrows<IllegalArgumentException> { CaptureFormat.load(dir) }
            assertEquals("Unknown cookie capture mode store (expected keep or redact)", e.message)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `live Set-Cookie headers are split, sanitised and redacted as the Dart recorder does`() {
        val parsed = CaptureFormat.parseSetCookieHeader(
            "consent=yes; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/, mhub_access=tok123; Domain=.site.test; HttpOnly; Secure, junk",
        )
        assertEquals(listOf(CapturedCookie("consent", "yes", "/"), CapturedCookie("mhub_access", "tok123", domain = ".site.test")), parsed)
        val recorded = CaptureFormat.recordedCookies(
            listOf("session=abc; Path=/", "mhub_access=tok123; Path=/; Max-Age=3600", "consent=yes"),
            mapOf("mhub_access" to CookieMode.REDACT, "consent" to CookieMode.KEEP),
        )
        assertEquals(listOf(CapturedCookie("mhub_access", "redacted", "/", redacted = true), CapturedCookie("consent", "yes")), recorded)
        assertEquals(emptyList<CapturedCookie>(), CaptureFormat.recordedCookies(listOf("mhub_access=tok"), emptyMap()))
        assertEquals("cf-mitigated" in CaptureFormat.RECORDED_RESPONSE_HEADERS, true)
    }

    @Test
    fun `replay serves allow-listed cookies into the package jar and the next request carries them`() {
        val dir = captureDir()
        val captures = listOf(CaptureFormat.load(dir))
        val log = ReplayLog()
        val cookiesSent = CopyOnWriteArrayList<String>()
        val transport = LoopbackTransport(ExchangeHandler { method, url, headers, body ->
            cookiesSent += "${url.encodedPath} ${headers["Cookie"].orEmpty()}"
            ReplayTransport.respond(captures, log, method, url, body)
        })
        val jar = PackageCookieJar()
        try {
            val client = OkHttpClient.Builder().cookieJar(jar).also(transport::configure).build()
            client.newCall(Request.Builder().url("https://site.test/login").build()).execute().use { assertEquals(200, it.code) }
            client.newCall(Request.Builder().url("https://site.test/challenge").build()).execute().use {
                assertEquals(403, it.code)
                assertEquals("challenge", it.header("cf-mitigated"))
            }
            client.newCall(Request.Builder().url("https://site.test/next").build()).execute().use { assertEquals(200, it.code) }
            assertEquals(setOf("mhub_access=redacted", "consent=yes"), jar.all().map { "${it.name}=${it.value}" }.toSet())
            val next = cookiesSent.last()
            assertEquals(true, next.startsWith("/next ") && "mhub_access=redacted" in next && "consent=yes" in next, next)
            assertEquals(emptyList<CaptureFormat.Key>(), log.misses)
        } finally {
            transport.close()
            dir.deleteRecursively()
        }
    }
}
