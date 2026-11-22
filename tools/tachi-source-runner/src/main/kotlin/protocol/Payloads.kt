package mangabackup.tachi.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.serializer
import mangabackup.tachi.host.HostSettings

// Typed payloads of worker protocol 1.3, mirroring packages/source_runtime/lib/src/backends/protocol_payloads.dart
// (the source of truth; the golden vectors in fixtures/wire_vectors/ check both). Decode with [Wire.decode]: a missing
// required field or a field of the wrong JSON type is a ProtocolViolation; unknown fields are ignored.

/** Operations the supervisor sends in `req` frames (Dart `WorkerOperation`). */
enum class WorkerOp(
    val wire: String,
    /** Whether the frame carries `pkg` and runs in that package's queue. */
    val perPackage: Boolean = true,
    /** Whether the package must already be loaded (everything but prepare, which makes the bytes, and load). */
    val requiresLoaded: Boolean = true,
) {
    HANDSHAKE("handshake", perPackage = false, requiresLoaded = false),
    ARTIFACT_PREPARE("artifact.prepare", requiresLoaded = false),
    PACKAGE_LOAD("package.load", requiresLoaded = false),
    PACKAGE_UNLOAD("package.unload"),
    SETTINGS_UPDATE("settings.update"),
    SEARCH("search"),
    DETAILS("details"),
    DISPOSE("dispose"),
    SHUTDOWN("shutdown", perPackage = false, requiresLoaded = false),
    ;

    companion object {
        fun fromWire(wire: String?): WorkerOp? = entries.firstOrNull { it.wire == wire }
    }
}

/** Reverse operations the worker sends in `rreq` frames (Dart `HostBrowserOperation`). */
enum class HostBrowserOp(
    val wire: String,
    /** The protocol minor that introduced it; a supervisor that negotiated less is never sent it. */
    val sinceMinor: Int = 0,
) {
    OPEN("host.browser.open"),
    LOAD("host.browser.load"),
    LOAD_DATA("host.browser.loadData"),
    EVALUATE("host.browser.evaluate"),
    SET_MESSAGE_HANDLER("host.browser.setMessageHandler"),
    GET_COOKIES("host.browser.getCookies"),
    SET_COOKIE("host.browser.setCookie"),
    SET_USER_AGENT("host.browser.setUserAgent"),
    SHOW("host.browser.show"),
    CLOSE("host.browser.close"),
    ADD_PAGE_START_SCRIPT("host.browser.addPageStartScript", sinceMinor = 2),
    SET_REQUEST_INTERCEPTION("host.browser.setRequestInterception", sinceMinor = 2),
    RESPOND("host.browser.respond", sinceMinor = 2),
    END_INTERACTION("host.browser.endInteraction", sinceMinor = 3),
    ;

    /** Whether a supervisor that negotiated protocol 1.[minor] may be sent this operation. */
    fun availableAt(minor: Long): Boolean = minor >= sinceMinor
}

/** Events the supervisor sends (`event` frames). Decoded leniently: a malformed one is dropped. */
object WorkerEvent {
    const val BROWSER_MESSAGE = "host.browser.message"
    const val BROWSER_REQUEST = "host.browser.request"
    const val INTERACTION_STARTED = "interaction.started"
    const val INTERACTION_ENDED = "interaction.ended"
}

// --- shared values -------------------------------------------------------------------------------

/** `ArtifactBinding`. */
@Serializable
data class ArtifactBinding(val sha256: String, val kind: String, val version: String)

/** `SourceIdentity`. */
@Serializable
data class SourceIdentity(val ecosystem: String, val packageId: String, val sourceId: String, val artifact: ArtifactBinding)

/** `NativeMangaRef`. */
@Serializable
data class NativeMangaRef(
    val source: SourceIdentity,
    val mangaId: String,
    val settingsRevision: String,
    val context: JsonObject = JsonObject(emptyMap()),
)

/**
 * `SettingsPayload`, including 1.1 string sets (string arrays) and per-source scopes (`sources`). Values keep
 * their JSON form here; [toHostSettings] applies the protocol's value rule ([settingsValue]).
 */
@Serializable
data class SettingsPayload(
    val values: Map<String, JsonElement>,
    val secrets: Map<String, String>,
    val revision: String,
    val sources: Map<String, SourceScope>? = null,
) {
    @Serializable
    data class SourceScope(val values: Map<String, JsonElement>? = null, val secrets: Map<String, String>? = null)

    fun toHostSettings(): HostSettings = HostSettings(
        values(values, ""),
        secrets,
        revision,
        sources.orEmpty().mapValues { (id, scope) ->
            HostSettings.SourceScope(values(scope.values.orEmpty(), "sources.$id."), scope.secrets.orEmpty())
        },
    )

    private fun values(values: Map<String, JsonElement>, prefix: String): Map<String, Any> =
        values.mapValues { (k, v) -> v.settingsValue("$prefix$k") }
}

/** `SourceCapabilities`. */
@Serializable
data class SourceCapabilities(val operations: List<String>, val apiFamilies: List<String>, val requiresBrowser: Boolean)

// --- supervisor → worker requests and their replies ------------------------------------------------

/**
 * `handshake`. `protocolMinor` (1.1) must be a non-negative integer when present; an unusable
 * `maxFrameBytes` falls back to the worker's own limit, as the worker always has.
 */
@Serializable
data class HandshakeRequest(
    val protocolVersions: List<Long>,
    val protocolMinor: JsonElement? = null,
    val maxFrameBytes: JsonElement? = null,
) {
    /** The offered minor: absent (a 1.0 supervisor) is 0. */
    fun offeredMinor(): Long = when (protocolMinor) {
        null, JsonNull -> 0L
        else -> protocolMinor.safeIntegerOrNull()?.takeIf { it >= 0 }
            ?: throw ProtocolViolation("protocolMinor must be a non-negative integer")
    }

    fun maxFrameBytesOrNull(): Long? = maxFrameBytes?.safeIntegerOrNull()
}

/** `artifact.prepare`. An absent `trustedSigners` (a 1.0 supervisor) trusts nothing. */
@Serializable
data class ArtifactPrepareRequest(
    val artifact: ArtifactBinding,
    val inputPath: String,
    val outputPath: String,
    val trustedSigners: List<String>? = null,
)

@Serializable
data class ArtifactPrepareResponse(val artifact: ArtifactBinding, val producer: String, val converterVersion: String)

/**
 * `package.load`. [settings] stays raw so the artifact kind is checked before the settings are
 * decoded ([SettingsPayload]), as the worker always has.
 */
@Serializable
data class PackageLoadRequest(
    val artifact: ArtifactBinding,
    val path: String,
    val settings: JsonObject,
    val apiFamily: String? = null,
)

@Serializable
data class PackageLoadResponse(val sources: List<LoadedSource>)

@Serializable
data class LoadedSource(val sourceId: String, val name: String, val language: String? = null, val capabilities: SourceCapabilities)

@Serializable
data class SettingsUpdateRequest(val settings: SettingsPayload)

@Serializable
data class SearchRequest(val source: SourceIdentity, val settingsRevision: String, val query: String, val cursor: String? = null)

@Serializable
data class DetailsRequest(val source: SourceIdentity, val settingsRevision: String, val ref: NativeMangaRef, val handle: String? = null)

/** `dispose`. Without `handles` it closes the source's session (protocol › dispose). */
@Serializable
data class DisposeRequest(val source: SourceIdentity, val handles: List<String>? = null)

// --- events ----------------------------------------------------------------------------------------

@Serializable
data class HostBrowserMessage(val session: String, val name: String, val message: String)

/** `interaction.started` (1.3). */
@Serializable
data class InteractionStarted(val of: String, val timeoutMs: Long? = null)

/** `interaction.ended` (1.3). */
@Serializable
data class InteractionEnded(val of: String, val pausedMs: Long? = null)

// --- worker → supervisor reverse requests (`host.browser.*`, KTD20) --------------------------------

/** A `host.browser.*` reverse request payload; [op] is the frame's `op`, so the two cannot disagree. */
sealed interface HostBrowserRequest {
    val op: HostBrowserOp
}

/** This request as its frame `payload`, encoded by its own generated serializer. */
fun HostBrowserRequest.toPayload(): JsonObject = Wire.encode(serializer(this::class.java), this)

@Serializable
data class HostBrowserOpen(val sourceId: String, val userAgent: String? = null) : HostBrowserRequest {
    override val op get() = HostBrowserOp.OPEN
}

@Serializable
data class HostBrowserLoad(val session: String, val url: String, val headers: Map<String, String> = emptyMap()) : HostBrowserRequest {
    override val op get() = HostBrowserOp.LOAD
}

@Serializable
data class HostBrowserLoadData(val session: String, val html: String, val baseUrl: String) : HostBrowserRequest {
    override val op get() = HostBrowserOp.LOAD_DATA
}

@Serializable
data class HostBrowserEvaluate(val session: String, val script: String) : HostBrowserRequest {
    override val op get() = HostBrowserOp.EVALUATE
}

@Serializable
data class HostBrowserSetMessageHandler(val session: String, val name: String, val enabled: Boolean) : HostBrowserRequest {
    override val op get() = HostBrowserOp.SET_MESSAGE_HANDLER
}

@Serializable
data class HostBrowserGetCookies(val session: String, val url: String) : HostBrowserRequest {
    override val op get() = HostBrowserOp.GET_COOKIES
}

/** Dart `BrowserCookie`; `expires` is an ISO-8601 instant. */
@Serializable
data class BrowserCookieJson(
    val name: String,
    val value: String,
    val domain: String? = null,
    val path: String? = null,
    val expires: String? = null,
    val secure: Boolean = false,
    val httpOnly: Boolean = false,
)

@Serializable
data class HostBrowserSetCookie(val session: String, val url: String, val cookie: BrowserCookieJson) : HostBrowserRequest {
    override val op get() = HostBrowserOp.SET_COOKIE
}

@Serializable
data class HostBrowserSetUserAgent(val session: String, val userAgent: String) : HostBrowserRequest {
    override val op get() = HostBrowserOp.SET_USER_AGENT
}

@Serializable
data class HostBrowserShow(val session: String) : HostBrowserRequest {
    override val op get() = HostBrowserOp.SHOW
}

@Serializable
data class HostBrowserClose(val session: String) : HostBrowserRequest {
    override val op get() = HostBrowserOp.CLOSE
}

@Serializable
data class HostBrowserAddPageStartScript(val session: String, val script: String) : HostBrowserRequest {
    override val op get() = HostBrowserOp.ADD_PAGE_START_SCRIPT
}

/** `mode`: `none`, `observe` or `replace`. */
@Serializable
data class HostBrowserSetRequestInterception(val session: String, val mode: String) : HostBrowserRequest {
    override val op get() = HostBrowserOp.SET_REQUEST_INTERCEPTION
}

/** `response`: a `BrowserReplacement`, or `null` to let the held request proceed. */
@Serializable
data class HostBrowserRespond(val session: String, val requestId: String, val response: JsonObject? = null) : HostBrowserRequest {
    override val op get() = HostBrowserOp.RESPOND
}

@Serializable
data class HostBrowserEndInteraction(val session: String) : HostBrowserRequest {
    override val op get() = HostBrowserOp.END_INTERACTION
}

// --- their replies (only the fields the worker reads; absent optional fields decode as null) -------

@Serializable
data class HostBrowserOpened(val session: String? = null, val capabilities: JsonObject? = null)

@Serializable
data class HostBrowserPage(val finalUrl: String? = null, val status: Long? = null)

@Serializable
data class HostBrowserEvaluated(val result: String? = null, val scriptError: String? = null)

@Serializable
data class HostBrowserCookies(val cookies: List<BrowserCookieReply> = emptyList())

/** A cookie in a `host.browser.getCookies` reply; one without a name is skipped. */
@Serializable
data class BrowserCookieReply(
    val name: String? = null,
    val value: String? = null,
    val domain: String? = null,
    val path: String? = null,
    val expires: String? = null,
    val secure: Boolean = false,
    val httpOnly: Boolean = false,
)

/** `outcome` (1.3): `completed` or `closed`; absent from an older supervisor. */
@Serializable
data class HostBrowserShown(val outcome: String? = null)
