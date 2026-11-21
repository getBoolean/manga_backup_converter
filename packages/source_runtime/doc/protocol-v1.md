# Source worker protocol, version 1 (minor 1.3)

This protocol connects the desktop supervisor (`WorkerSupervisor` in `package:source_runtime`) to a source worker process: the shared Tachi JVM worker (U3) or the Paperback Dart worker (U6). It implements KTD4 of the source runners plan. KTD20 adds the browser reverse requests.

**The Dart types are the source of truth.** Every shape below is a class in [`lib/src/backends/protocol_payloads.dart`](../lib/src/backends/protocol_payloads.dart), and framing is in [`lib/src/backends/protocol.dart`](../lib/src/backends/protocol.dart). If this document and the code disagree, the code wins; fix this document. `test/protocol_payloads_test.dart` round-trips every payload through real frame bytes. A Dart worker should use the same classes: each has `fromJson` and `toJson`.

## Versions

The protocol has a major and a minor version. The major version is the envelope's `v`, and is always `1`. Minor versions only add optional fields, so a frame from any 1.x peer parses, and `v` never changes for a minor bump.

- **Negotiation:** the supervisor's `handshake` request offers `protocolVersions: [1]` and `protocolMinor`, its highest minor (currently `3`). The worker replies with `protocolVersion: 1` and `protocolMinor`: the lower of the offer and its own highest minor. A worker that omits `protocolMinor` is a 1.0 worker; a request without it comes from a 1.0 supervisor. Either decodes as `0`.
- **Violations:** a reply with another major version, or with a `protocolMinor` above the offer, fails the session as `protocol-violation`.
- **Gating:** the supervisor sends a 1.1 feature only to a worker that negotiated 1.1. Against a 1.0 worker, string-set or source-scoped settings and `artifact.prepare` (which relies on `trustedSigners`) fail locally with `unsupported-api` before anything is sent.
- **Gating 1.2:** a reverse request introduced in 1.2 (`HostBrowserOperation.sinceMinor`) from a worker that negotiated less is answered `protocol-violation`, and the session continues. The supervisor puts the open reply's `capabilities` and the evaluate reply's `scriptError` only in replies to a 1.2 worker; a 1.1 worker gets the reply it always got (a throwing script reads as `result: "null"`). `ReverseRequest.protocolMinor` carries the negotiated minor to the handler.
- **Gating 1.3:** `host.browser.endInteraction` from a worker below 1.3 is answered `protocol-violation`. Only a 1.3 worker gets `package.load` `apiFamily`, the `host.browser.show` reply's `outcome`, and the `interaction.started` / `interaction.ended` events; an older worker gets exactly what it got before. The `trust` field on an `artifact-incompatible` error is sent to every peer: one that predates it ignores the unknown field and still reads `artifact-incompatible`.

| Minor | Adds |
|---|---|
| 1.0 | The protocol as first shipped. |
| 1.1 | Handshake `protocolMinor`, `limits` and `sizing`; `artifact.prepare` `trustedSigners`, and the explicit rule that it needs no loaded package; string-set setting values; source-scoped settings (`SettingsPayload.sources`); the browser message channel contract. |
| 1.2 | Browser capabilities on the `host.browser.open` reply; `scriptError` on the `host.browser.evaluate` reply; `host.browser.addPageStartScript`; request interception (`host.browser.setRequestInterception`, the `host.browser.request` event, `host.browser.respond`) with request bodies; `ipc` and every other identifier allowed as a channel name. |
| 1.3 | `package.load` `apiFamily`; `host.browser.show` completion rules and its reply's `outcome`; `host.browser.endInteraction`; the `interaction.started` and `interaction.ended` events; the evaluate promise rule; `trust` on `artifact-incompatible` errors. Also, without changing frames: the replace tier names the engine's own reason first, captures may keep allow-listed cookies and `cf-mitigated`, and `SettingsPayload.valuesFor` / `secretsFor`. |

## Transport

- **Pipes:** the supervisor writes frames to the worker's stdin. The worker writes frames to stdout and logs to stderr only. Any stdout line that is not a frame is a protocol violation.
- **Frame format:** each frame is one UTF-8 JSON object followed by `\n` (`\r\n` is accepted).
- **Size limit:** an encoded frame may be at most 16 MiB (16,777,216 bytes), not counting the newline. A larger frame fails visibly and is never truncated. The supervisor sends its limit in the handshake (`maxFrameBytes`).
- **Redaction:** the supervisor redacts stderr line by line before it reaches any log. It removes `Cookie`, `Set-Cookie` and `Authorization` values, credentials in URLs, and every secret it has sent to the worker (KTD9). A worker must still never write a secret to stdout or stderr on purpose.
- **Environment:** the supervisor gives the worker a scrubbed environment.

## Envelope

```json
{"v":1,"t":"req","id":"3-7","gen":3,"op":"search","pkg":"eu.kanade.x","payload":{}}
```

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Protocol major version; always `1` (minor versions are negotiated in the handshake). Any other value is a violation. |
| `t` | string | Frame type (table below). |
| `id` | string | Request ID. The supervisor writes `"<gen>-<n>"`; workers choose their own reverse request IDs. Treat IDs as opaque. |
| `gen` | int | Session generation. It increments on every worker (re)start; the handshake carries the new value. |
| `op` | string | Operation name (`req`, `rreq`, `event`). |
| `pkg` | string | Package ID for per-package operations. |
| `of` | string | On `rreq`: the `id` of the request that caused it. |
| `payload` | object | Request data (`req`, `rreq`, `event`). |
| `ok` | object | Success data (`res`, `rres`). Exactly one of `ok` and `err` is present. |
| `err` | object | Failure (`res`, `rres`): `{"code","message","operation"?,"trust"?}`. `operation` comes with `capability-unavailable`; `trust` (1.3) with `artifact-incompatible`. |

| `t` | Direction | Purpose |
|---|---|---|
| `req` | supervisor → worker | An operation. |
| `res` | worker → supervisor | Reply to the `req` with the same `id`. |
| `cancel` | supervisor → worker | Cancel the `req` with this `id` cooperatively. Has no payload. |
| `rreq` | worker → supervisor | A `host.browser.*` reverse request made while serving request `of`. |
| `rres` | supervisor → worker | Reply to the `rreq` with the same `id`. |
| `event` | supervisor → worker | A notification that needs no reply (`host.browser.message`, `host.browser.request`, `interaction.started`, `interaction.ended`). |

### Rules

- **Generations:** every frame the worker writes carries the current `gen`. A frame for any other generation fails the session.
- **Replies:** each `req` gets exactly one `res`. A `res` for an unknown `id` fails the session.
- **Payload shapes:** a `res` whose `ok` does not match the operation's reply shape (a missing required field, or a field of the wrong JSON type) fails the whole session, like a malformed frame. The worker's state can no longer be trusted; for example, it might hold a package the supervisor does not track. A malformed `rreq` payload is answered with `err.code = "protocol-violation"` and the session continues.
- **Reverse requests:** an `rreq` is valid only while its originating request (`of`) is in flight. An orphaned `rreq` fails the session. After a restart, the supervisor never delivers a late `rres` from an older generation.
- **Cancellation:** after a `cancel`, stop the operation and reply with `err.code = "cancelled"`. The supervisor discards that reply if the caller has already gone. If the operation does not settle within the cancel grace period, the supervisor kills and restarts the worker.
- **Concurrency:** the supervisor sends at most one per-package operation at a time for each package. Different packages may run concurrently, up to the pool size. `handshake` and `shutdown` are not package operations. Restart reloads also bypass the package queue.
- **Loaded packages:** `artifact.prepare` and `package.load` carry `pkg` but must not require the package to be loaded: `artifact.prepare` produces the bytes `package.load` will load. Every other per-package operation (`package.unload`, `settings.update`, `search`, `details`, `dispose`) needs a loaded package and answers `runtime-unavailable` without one. Dart workers use `WorkerRequest.admissionFailure` (backed by `WorkerOperation.requiresLoadedPackage`) for this check.
- **Deadlines:** each operation's deadline is measured from dispatch, so time spent waiting in the queue does not count. Time spent in `host.browser.show` is excluded from the deadline and bounded separately. A 1.3 worker is told when that exclusion starts and ends, and pauses its own engine deadlines to match (see [Interaction](#interaction-13)).
- **Restart:** a restart fences every older generation, starts a new process, completes the handshake, and reloads every loaded package from its re-verified artifact with its current settings. The operation that hit its deadline fails with `timeout`. Other interrupted operations are re-sent once; a second interruption fails them with `worker-restarted`.

### Errors

`err.code` is one of the following. Unknown codes are read as `source-error`.

| `code` | Meaning |
|---|---|
| `timeout` | Exceeded its deadline. |
| `cancelled` | Cancelled, superseded, or its generation was fenced. |
| `unsupported-api` | The source's API version or family is not supported. |
| `interaction-required` | Needs a visible user interaction, for example a challenge page. |
| `stale-reference` | A reference or handle no longer matches the running source or settings, or cannot be rehydrated. Never answer by guessing a replacement. |
| `artifact-incompatible` | The artifact failed integrity, trust or compatibility checks. A failed trust decision (1.3) adds `trust`: `first-seen` (no approved signer or key, and nothing approved it in this run), `changed` (it differs from the approved one) or `refused` (the user or a pinned policy refused it). Dart reads it as `TrustFailure`, a subtype of `ArtifactIncompatibleFailure`; the earlier `trust:` message prefix is retired. An unknown `trust` value reads as plain `artifact-incompatible`. |
| `worker-restarted` | Interrupted by a restart after its single re-send. |
| `source-error` | The source code itself failed. |
| `capability-unavailable` | A host capability is missing. `operation` names it, for example `host.browser.show`. |
| `protocol-violation` | The peer broke the protocol. |
| `runtime-unavailable` | The runtime could not start or is closed. |

## Shared shapes

These shapes appear inside several payloads.

- **`ArtifactBinding`** — `{"sha256": hex, "kind": "jar"|"apk"|"aix"|"paperback-bundle"|…, "version": string}`.
- **`SourceIdentity`** — `{"ecosystem", "packageId", "sourceId", "artifact": ArtifactBinding}`. `sourceId` is always a string. Tachi sends its int64 ID as a decimal string (for example `"9223372036854775807"`); a JSON number is rejected.
- **`SettingsPayload`** — `{"values": {key: string|bool|int|[string]}, "secrets": {key: string}, "sources"?: {sourceId: {"values"?: {…}, "secrets"?: {…}}}, "revision": string}`.
  - **Types:** `values` keep their JSON types, and integers must stay within ±(2^53 − 1).
  - **String sets (1.1):** an array value holds only strings and is a set: it backs `SharedPreferences.getStringSet` and multi-select settings. The supervisor sends it sorted and deduplicated, so equal sets always produce the same `revision`. Any other array content is rejected.
  - **Secrets:** `secrets` are session-only: never persist or log them.
  - **Source scopes (1.1):** see [Addressing one source](#addressing-one-source-of-a-multi-source-package).
  - **Revision:** `revision` is a durable digest over the non-secret values and the secret key names (never the secret values), for the package and every source scope, so it is safe to store. Settings without string sets or scopes keep the digest they had in 1.0.
- **`NativeMangaRef`** — `{"source": SourceIdentity, "mangaId": string, "settingsRevision": string, "context": object}`. `context` holds the source-returned fields that later calls need, such as Tachi's `SManga` fields or Paperback's context.
- **`SourceCapabilities`** — `{"operations": ["search"|"mangaDetails"|"chapterList"|"settings"|"browser"…], "apiFamilies": [string], "requiresBrowser": bool}`.
- **`MangaMetadata`** — `{"title", "altTitles", "authors", "artists", "description"?, "tags", "status": "unknown"|"ongoing"|"completed"|"cancelled"|"hiatus", "contentRating": "unknown"|"safe"|"suggestive"|"nsfw", "url"?, "coverUrl"?}`.
- **`NativeChapter`** — `{"chapterId", "sourceOrder": int, "context", "title"?, "chapterNumber"?: number, "volumeNumber"?: number, "scanlators": [string], "language"?, "dateUploaded"?: ISO-8601 UTC, "url"?}`.
- **`BrowserCookie`** — `{"name", "value", "domain"?, "path"?, "expires"?: ISO-8601 UTC, "secure": bool, "httpOnly": bool}`.
- **`BrowserCapabilities`** (1.2) — `{"available": [feature], "unavailable": {feature: reason}}`. Features: `pageStartScripts`, `observeNavigations`, `observeSubresources`, `observeRequestHeaders`, `observeClientHints`, `observeRequestBodies`, `replaceRequests`, `scriptErrors` (`BrowserFeature`). A feature in neither list is unavailable with the reason "Not reported by the browser implementation", and a peer that sends no capabilities has none, so nothing is ever assumed. Unknown feature names are ignored.
- **`BrowserReplacement`** (1.2) — `{"status": int, "reason"?: string, "headers"?: {string: string}, "bodyBase64"?: string}`. `status` is 100–599 and not 300–399; `reason` defaults to `OK` and is one non-empty line. Anything else is malformed.
- **`WorkerReportedLimits`** (1.1) — `{"poolSize"?: int, "operationDeadlineMs"?: int, "cancelGraceMs"?: int, "interactionTimeoutMs"?: int, "shutdownGraceMs"?: int, …}`. These names are the limits a supervisor can adopt; each is a positive integer when present. Runtime-specific limits (Paperback's QuickJS `memoryLimitBytes`, `maxStackBytes`, `operationDeadlineMicros`, `jobSliceMicros`) travel in the same object and are kept as reported, without interpretation.
- **`WorkerSizing`** (1.1) — `{"rule"?: object|null, "inputs"?: object, "derived"?: WorkerReportedLimits, "overridden"?: [string], …}`. The KTD25 sizing rule (its coefficients and the benchmark it came from; `null` when explicit overrides cover every limit), the measured device inputs (for example `cores`, `maxHeapMiB`), the limits the rule derived, and the names of limits set by explicit overrides.

A field marked `?` may be omitted or `null`. Workers may add fields; readers ignore fields they do not know.

### Addressing one source of a multi-source package

A package can host many sources (a Tachi factory). Package operations carry the package in `pkg`; a source within it is always addressed by its `sourceId`, the string `package.load` returned:

- **Operations:** `search`, `details` and `dispose` name their source in `source.sourceId` (a full `SourceIdentity`), and `host.browser.open` in `sourceId`. A worker must reject a `sourceId` the package does not host.
- **Settings (1.1):** `SettingsPayload.values` and `secrets` apply to every source of the package. `SettingsPayload.sources` maps a `sourceId` to that source's own `values` and `secrets`, which override the package-wide entries with the same key. The effective settings of source `S` are therefore `values` overlaid with `sources[S].values`, and likewise for secrets. Keys are plain setting keys; no key carries a source or store prefix. Dart workers resolve them with `SettingsPayload.valuesFor(S)` and `secretsFor(S)`, the same rule `SettingsSnapshot` uses (`ScopedSettingsView`); do not keep a copy of the overlay logic.
- **Tachi mapping:** a Tachi worker seeds the `SharedPreferences` store a source opens (by Tachi convention `source_<id>`) from that source's effective settings, and plain package-wide keys seed every store. The 1.0 convention of `storeName/key` keys is replaced by `sources`; a 1.1 supervisor never sends `/`-prefixed keys for scoping.

```json
{"values": {"lang": "en", "blockedGenres": ["action", "romance"]},
 "secrets": {},
 "sources": {"9223372036854775807": {"values": {"lang": "ja"}, "secrets": {"password": "…"}}},
 "revision": "9f…"}
```

## Operations (supervisor → worker)

| `op` | `pkg` | Request `payload` (Dart class) | Reply `ok` (Dart class) |
|---|---|---|---|
| `handshake` | — | `protocolVersions: [int]`, `protocolMinor?: int`, `maxFrameBytes: int` (`HandshakeRequest`) | `protocolVersion: int`, `protocolMinor?: int`, `worker: string`, `workerVersion?`, `pid?: int`, `capabilities: {apiFamilies: [string], browser: bool}`, `limits?: WorkerReportedLimits`, `sizing?: WorkerSizing` (`HandshakeResponse`, `WorkerCapabilities`, `WorkerReportedLimits`, `WorkerSizing`) |
| `artifact.prepare` | yes (need not be loaded) | `artifact: ArtifactBinding`, `inputPath`, `outputPath`, `trustedSigners: [string]` (`ArtifactPrepareRequest`) | `artifact: ArtifactBinding` (of the output), `producer`, `converterVersion` (`ArtifactPrepareResponse`) |
| `package.load` | yes | `artifact: ArtifactBinding`, `path`, `settings: SettingsPayload`, `apiFamily?: string` (1.3) (`PackageLoadRequest`) | `sources: [{sourceId, name, language?, capabilities: SourceCapabilities}]` (`PackageLoadResponse`, `LoadedSource`) |
| `package.unload` | yes | `{}` (`PackageUnloadRequest`) | `{}` (`EmptyPayload`) |
| `settings.update` | yes | `settings: SettingsPayload` (`SettingsUpdateRequest`) | `{}` |
| `search` | yes | `source: SourceIdentity`, `settingsRevision`, `query`, `cursor?` (`WorkerSearchRequest`) | `hits: [SearchHit & {handle?}]`, `nextCursor?`, `warnings: [string]` (`WorkerSearchResponse`, `WorkerSearchHit`) |
| `details` | yes | `source`, `settingsRevision`, `ref: NativeMangaRef`, `handle?` (`WorkerDetailsRequest`) | `metadata: MangaMetadata`, `chapters: [NativeChapter]` (`WorkerDetailsResponse`) |
| `dispose` | yes | `source: SourceIdentity`, `handles?: [string]` (`DisposeRequest`) | `{}` |
| `shutdown` | — | `{}` (`ShutdownRequest`) | `{}`, then flush and exit |

### Notes

- **`handshake`:** reply with one of `protocolVersions` (this supervisor accepts only `1`) and the negotiated `protocolMinor` (see [Versions](#versions)). A reply in any other version, above the offered minor, or missing a required field fails the session as `protocol-violation`. `capabilities.apiFamilies` lists the source API versions the worker can host, for example `tachi-1.5` or `paperback-0.8`. `capabilities.browser` says whether the worker may send `host.browser.*` requests.
  - **Limits and sizing (1.1, KTD25):** a worker reports the limits it runs with in `limits` and how it derived them in `sizing`. Report what the benchmarked rule produced on this device; never report a value without evidence. The supervisor exposes both on the typed reply.
  - **Adoption:** a supervisor built with `AdoptWorkerLimits` takes `poolSize` (as its package concurrency), `operationDeadlineMs`, `cancelGraceMs`, `interactionTimeoutMs` and `shutdownGraceMs` from `limits`. Every limit the caller supplies takes precedence; a limit neither supplies fails the start with `runtime-unavailable`, because no default is invented. The caller always supplies the handshake's own deadline. Limits are re-resolved after every restart. A supervisor built with fixed `SupervisorLimits` records the reported values but does not use them.
- **`artifact.prepare`:** this operation turns a verified input artifact into the form the worker loads, for example APK → JAR through dex2jar, or JAR signature verification (KTD5).
  - **Loaded package:** not required. The package is normally not loaded yet, because this operation produces the bytes `package.load` loads.
  - **Input:** before reading `inputPath`, re-verify it against `artifact.sha256`. Reject a mismatch with `artifact-incompatible`.
  - **Trust (1.1, KTD5):** `trustedSigners` lists certificate SHA-256 fingerprints (64 lowercase hex digits, sorted) taken from the stored trust anchor: the fingerprint the user approved for the repository, or one a qualification manifest pins. Verify the JAR or APK signature against them and reject any other signer with `artifact-incompatible`. A fingerprint read beside the artifact proves consistency, not provenance, so it never substitutes for this list. A request without `trustedSigners` (a 1.0 supervisor) decodes as an empty list; refuse anything that needs a signer rather than trust another source. A signer outside the list is a failed trust decision (1.3): answer `artifact-incompatible` with `trust: "refused"` (an unapproved signer) or `"changed"` (the repository's approved signer differs), not a message prefix. The supervisor itself refuses an empty anchor before sending, as `trust: "first-seen"`.
  - **Output:** write only to `outputPath`, a private staging path the supervisor chose.
  - **After the reply:** the sender re-hashes the output and admits it to the artifact cache under an `ArtifactProfile(producer, converterVersion, hostCompatibility)`, never trusting the reported digest alone. `WorkerSupervisor.prepareArtifact` does all of this: it refuses an empty trust anchor and a 1.0 worker before sending, stages the output in a private directory under the cache root, fails a digest mismatch as `artifact-incompatible`, and deletes the staging directory afterwards.
- **`package.load`:**
  - **Artifact:** `path` is a privately staged artifact that the supervisor re-verified just before sending. Load it into its own child-first class loader (Tachi) or runtime (Paperback).
  - **API family (1.3, KTD6):** `apiFamily` is the source API family the trust decision bound to the artifact, for example `paperback-0.9` or `tachi-1.5`, carried on `WorkerPackage.apiFamily` so restart reloads send it too. Host the package as that family; reply `unsupported-api` for a family the worker cannot host. It is absent from a pre-1.3 supervisor and for packages without a family; a worker then keeps its earlier behaviour (Paperback reads the family from `ArtifactBinding.kind`, for example `paperback-bundle-0.9`). Once a worker requires 1.3 it should stop reading the family from the kind.
  - **Sources:** enumerate the package's sources. A Tachi factory returns every source; Aidoku-style packages return one.
  - **Failures:** reply `artifact-incompatible` or `unsupported-api` on failure.
  - **Restarts:** after every restart the supervisor resends `package.load` for each loaded package with its current settings, and drops a package whose reload fails.
- **`package.unload`:** release the package's sources, live handles and class loader. Once the supervisor sees a successful reply, it no longer reloads the package after restarts. Answer later operations for the package with an error.
- **`settings.update`:** this replaces the whole settings snapshot; it is not a patch.
  - **On success:** later operations carry the new `settingsRevision`, the supervisor reloads the package with these settings after any restart, and references confirmed under the old revision are stale (KTD3).
  - **On failure:** the previous settings stay in effect.
  - **Secrets:** before sending, the supervisor registers the new secrets with its redactor.
- **`search` and `details`:** check `settingsRevision` against the package's current settings. Reply `stale-reference` on a mismatch.
  - **Search replies:** `hits` may be empty; that is a successful empty result. Each hit's `ref` must be durable, carrying everything `details` needs to rehydrate after a restart. `handle` optionally names a live object the worker cached for that hit.
  - **Handles:** the supervisor sends a `details` `handle` only within the generation that issued it. A worker must still reject a handle it did not issue with `stale-reference`.
  - **Missing data:** missing details are an `err`, never an empty `ok`.
- **`dispose`:** drop the live objects behind the listed handles, or behind every handle issued for `source` when `handles` is absent or `null`. Durable references stay valid. The supervisor sends this when a source session closes. The plan names this operation without fields; this shape is the minimum.
- **`shutdown`:** reply, flush stdout, and exit. The supervisor kills the process if it has not exited within the shutdown grace.

## Reverse requests (worker → supervisor, KTD20)

The worker sends an `rreq` frame while serving the request named in `of`. The frame carries the current `gen`. The supervisor serves it from the platform `BrowserPort` and answers with an `rres` frame that has the same `id`.

| `op` | Request `payload` (Dart class) | Reply `ok` (Dart class) |
|---|---|---|
| `host.browser.open` | `sourceId`, `userAgent?` (`HostBrowserOpen`) | `session`, `capabilities?: BrowserCapabilities` (1.2) (`HostBrowserOpened`) |
| `host.browser.load` | `session`, `url`, `headers?: {string: string}` (`HostBrowserLoad`) | `finalUrl`, `status?: int` (`HostBrowserPage`) |
| `host.browser.loadData` | `session`, `html`, `baseUrl` (`HostBrowserLoadData`) | `finalUrl`, `status?` (`HostBrowserPage`) |
| `host.browser.evaluate` | `session`, `script` (`HostBrowserEvaluate`) | `result`: the value as JSON text; `scriptError?: string` (1.2) (`HostBrowserEvaluated`) |
| `host.browser.setMessageHandler` | `session`, `name`, `enabled: bool` (`HostBrowserSetMessageHandler`) | `{}` |
| `host.browser.getCookies` | `session`, `url` (`HostBrowserGetCookies`) | `cookies: [BrowserCookie]` (`HostBrowserCookies`) |
| `host.browser.setCookie` | `session`, `url`, `cookie: BrowserCookie` (`HostBrowserSetCookie`) | `{}` |
| `host.browser.setUserAgent` | `session`, `userAgent` (`HostBrowserSetUserAgent`) | `{}` |
| `host.browser.show` | `session` (`HostBrowserShow`) | `outcome?`: `closed` or `completed` (1.3) (`HostBrowserShown`) |
| `host.browser.close` | `session` (`HostBrowserClose`) | `{}` |
| `host.browser.addPageStartScript` (1.2) | `session`, `script` (`HostBrowserAddPageStartScript`) | `{}` |
| `host.browser.setRequestInterception` (1.2) | `session`, `mode`: `none`, `observe` or `replace` (`HostBrowserSetRequestInterception`) | `{}` |
| `host.browser.respond` (1.2) | `session`, `requestId`, `response?: BrowserReplacement` (`HostBrowserRespond`) | `{}` |
| `host.browser.endInteraction` (1.3) | `session` (`HostBrowserEndInteraction`) | `{}` |

| Event `op` (supervisor → worker) | `payload` (Dart class) |
|---|---|
| `host.browser.message` | `session`, `name`, `message` (`HostBrowserMessage`) |
| `host.browser.request` (1.2) | `session`, `requestId?`, `method`, `url`, `headers`, `bodyBase64?`, `bodyOmitted`, `mainFrame`, `redirect`, `context` (`HostBrowserRequestEvent`) |
| `interaction.started` (1.3) | `of`, `timeoutMs: int` (`WorkerInteractionStarted`) |
| `interaction.ended` (1.3) | `of`, `pausedMs: int` (`WorkerInteractionEnded`) |

### Notes

- **Scope:** a session belongs to the package of the originating request and to the generation that opened it. The supervisor resolves the `SourceIdentity` for `sourceId` and refuses a source the package does not host (`capability-unavailable`). A request for an unknown session, another package's session, or another generation's session is answered `cancelled`.
- **Allowed schemes:** `load`, navigations, redirects and `baseUrl` must be http or https. `about:blank` is also allowed, and `loadData` content is allowed when its base URL is http(s). Anything else, including `file:`, is refused as `capability-unavailable`.
- **Lifetime:** when a generation is fenced (by restart, session failure, or worker close), the supervisor closes every browser session that generation opened and deletes the sessions' storage.
  - **Late opens:** a session whose open completes after its generation was fenced is closed at once.
  - **Unconfirmed deletion:** when a close that the supervisor started on its own does not complete (for example, the platform cannot confirm that storage was deleted), the failure is written to the redacted log. There is no worker left to answer.
  - **After the conversion:** when the conversion scope closes, every remaining session closes, and later requests are refused.
  - **Requests in flight:** reverse requests from a fenced generation are cancelled, and their replies are never delivered.
- **Interaction:** see [Interaction (1.3)](#interaction-13).
- **Failure codes:** platform failures map to `cancelled`, `interaction-required`, `capability-unavailable` (with the named operation), or `source-error` (navigation failures). A malformed reverse payload, or a 1.2 operation from a worker that did not negotiate 1.2, is answered `protocol-violation`.
- **Messages:** page messages arrive as `host.browser.message` events only while the handler is enabled and the session's generation is current.

### Interaction (1.3)

`host.browser.show` shows the session's window so the user can solve a challenge or log in. Every implementation follows `showBrowserInteraction` in `lib/src/contracts/browser_port.dart`; the desktop bridge and in-app adapters call it rather than `BrowserSession.showForInteraction` directly.

**Completion.** The show ends at the first of these, and the session stays open in every case:

| Ends when | Reply to a 1.3 worker | Reply to an older worker |
|---|---|---|
| The user closes the window. | `ok` `{"outcome": "closed"}` | `ok` `{}` |
| The page signals completion: the worker sends `host.browser.endInteraction` for the session. The window is hidden. | `ok` `{"outcome": "completed"}` | (cannot send it) |
| The interaction bound (`interactionTimeoutMs`) elapses. The window is hidden. | `err` `interaction-required`, message naming the bound | the same |
| The originating operation is cancelled or hits its backstop, or the session closes or is fenced. | `err` `cancelled` | the same |
| No display exists. | `err` `interaction-required` at once | the same |

- **Page signals:** the page has no special API. The worker decides what counts as completion: a message on a channel it installed, an observed navigation, or a cookie it polls with `getCookies`. It then sends `host.browser.endInteraction`. Because its `host.browser.show` is still pending, it sends this from another thread, the same rule as `host.browser.respond`. With no show pending in the session the request is answered `cancelled`.
- **Port obligations:** `BrowserSession.showForInteraction` returns `BrowserCompleted` only when the user closed the window. When its cancel token fires it hides the window and returns `BrowserCancelled`, keeping the session usable; `showBrowserInteraction` maps that to `completed` when it fired the token for a page signal. At its timeout it hides the window and returns `BrowserInteractionRequired`. The helper enforces the bound itself as well, so a port that overruns cannot stretch it.
- **Bound ownership:** the interaction bound produces `interaction-required`; the operation continues and the worker decides what to do with it. The supervisor keeps a backstop at the bound plus `cancelGraceMs`. Only a show that overruns its bound by that much escalates like a deadline: a cooperative cancel, then a restart.

**Deadline pause.** While any `host.browser.show` of an operation is pending, the supervisor pauses that operation's deadline. A 1.3 worker is told, so it can pause its own engine deadlines (Paperback's QuickJS interrupt budget, any JVM watchdog) for the same span:

- **`interaction.started`:** `{"of": "<request id>", "timeoutMs": <bound>}`. Sent when the first show of operation `of` begins, before the platform shows anything. Overlapping shows of one operation produce one event.
- **`interaction.ended`:** `{"of": "<request id>", "pausedMs": <ms>}`. Sent when the last overlapping show of `of` ends. It is written before that show's `rres`, so the worker always sees it before the reply.
- **Worker obligation:** between the two events, do not count time against operation `of`'s engine deadline. Never resume on the `rres` alone: wait for `interaction.ended`. A fenced generation ends every interaction without an `interaction.ended`, because no worker of that generation remains.
- **Without a supervisor:** an in-app adapter (the Paperback isolate, iOS, Android) has no events. It pauses its engine deadline around its own `showBrowserInteraction` call.

```text
← {"v":1,"t":"rreq","id":"r7","gen":1,"op":"host.browser.show","of":"1-3","payload":{"session":"s-1"}}
→ {"v":1,"t":"event","id":"e1-12","gen":1,"op":"interaction.started","payload":{"of":"1-3","timeoutMs":300000}}
→ {"v":1,"t":"event","id":"e1-13","gen":1,"op":"host.browser.message","payload":{"session":"s-1","name":"solved","message":"ok"}}
← {"v":1,"t":"rreq","id":"r8","gen":1,"op":"host.browser.endInteraction","of":"1-3","payload":{"session":"s-1"}}
→ {"v":1,"t":"rres","id":"r8","gen":1,"ok":{}}
→ {"v":1,"t":"event","id":"e1-14","gen":1,"op":"interaction.ended","payload":{"of":"1-3","pausedMs":8123}}
→ {"v":1,"t":"rres","id":"r7","gen":1,"ok":{"outcome":"completed"}}
```

### Evaluate and promises (1.3)

`host.browser.evaluate` **awaits** a returned promise (`BrowserSession.evaluate`):

- **Resolved:** a script whose completion value is a promise, or any thenable, replies with the JSON of the settled value.
- **Rejected:** a rejected promise is a throwing script: `scriptError` with `scriptErrors`, otherwise `result: "null"`.
- **No value:** `undefined`, and values JSON cannot encode, read as `null`.
- **Never settles:** the reply waits until the operation is cancelled, the session closes, or a fence. The operation deadline bounds it.

This is what the desktop helper's eval wrapper and WKWebView's `callAsyncJavaScript` already do. Android's `evaluateJavascript` would report `{}`, so an Android port wraps the script to await it, as it already must to detect throws. `BrowserEvaluateCompat.androidCompatible` still maps a script error to `null`, but a promise result keeps its settled value. The contract suite checks both rules with real JavaScript (`BrowserContractScripts.resolvedPromise`, `delayedPromise` and `rejectedPromise`).

### Browser message channel (1.1)

`host.browser.setMessageHandler` with `name` and `enabled: true` installs a page-side channel that every `BrowserPort` implementation provides identically (`BrowserMessageChannel` in `lib/src/contracts/browser_port.dart`):

- **Page API:** every frame sees a global object `window.<name>` with one method, `postMessage(message)`, where `message` is a string. This is the shape of an Android `JavascriptInterface` object with `void postMessage(String)`, so the Tachi shim's `addJavascriptInterface` fallback and the desktop helper's injected script use it unchanged. `postMessage` returns `undefined`; synchronous return values are not emulated.
- **Channel names:** `name` must be a plain JavaScript identifier (`[A-Za-z_$][A-Za-z0-9_$]*`). Anything else is refused as `capability-unavailable`. No identifier is reserved (1.2), so `ipc` is valid: a Tachi extension's `addJavascriptInterface(obj, name)` may use any name. An implementation must not occupy a `window.<identifier>` global with its own transport. wry's IPC handler defines `window.ipc` with `Object.defineProperty(window, 'ipc', {value: Object.freeze(…)})`, a non-writable, non-configurable property (verified in wry 0.57.3 for WebView2, WKWebView and WebKitGTK), after which no channel named `ipc` can be installed. wry injects it only when its IPC handler is set, so a wry-based helper leaves that handler off and registers its own engine message handler: WebView2 `WebMessageReceived` through `window.chrome.webview.postMessage`, or a WebKit script message handler under a private name.
- **Availability:** the object exists in the current page as soon as the handler is enabled, and is injected at document start into every later page, until the handler is disabled. Channel objects are installed before any page-start script runs, whatever the registration order.
- **Origin rule:** a message is delivered only when the frame that posted it has the same origin (scheme, host, port) as the session's current top-level document, and that document came from http(s): a `load` after redirects, or `loadData` with its http(s) base URL. Messages from cross-origin frames, and from `about:blank` or other opaque-origin documents, are dropped silently.
- **Payload:** a non-string argument is dropped. Messages from one frame arrive in posting order.
- **Conformance:** `runBrowserPortContractSuite` in `package:source_runtime_testing` checks delivery (on a loaded page and on `loadData` content with an http(s) base URL), registration before a load, removal, the cross-origin and `about:blank` drops, name validation, and (1.2) an `ipc` channel alongside evaluation and a second channel. Every platform implementation must pass it.

### Browser capabilities (1.2)

The `host.browser.open` reply carries the session's `BrowserCapabilities` (`BrowserSession.capabilities` in Dart). They are fixed for the session, and tell the worker which tier and features it has before it relies on them:

Expected values come from KTD20 where it states them; every other cell is unmeasured. The U2 and U16 measurements are authoritative, and each implementation reports what it measures rather than copying this table.

| Feature | Meaning | Expected per engine |
|---|---|---|
| `pageStartScripts` | `addPageStartScript` works. | WebView2, WKWebView, WebKitGTK: U2's helper already injects document-start scripts. Android: unmeasured. |
| `observeNavigations` | Top-level document requests reach the observer. | WebView2: yes (KTD20). WKWebView, WebKitGTK: main-frame navigations the shim can see (KTD20). Android: unmeasured. |
| `observeSubresources` | Subresource and child-frame requests reach the observer. | WebView2: yes (KTD20). WKWebView, WebKitGTK: no; they cannot observe http(s) subresource requests (KTD20, degraded observe tier). Android: unmeasured. |
| `observeRequestHeaders` | Observed requests carry their headers. | Unmeasured. |
| `observeClientHints` | Observed headers include `sec-ch-ua*`. | WebView2: yes. WebKit engines: no; they never send client hints (KTD20). Android: unmeasured. |
| `observeRequestBodies` | Observed requests carry their body. | Unmeasured. U2's helper does not forward bodies yet. |
| `replaceRequests` | Replace tier. | WebView2: yes. WKWebView, WebKitGTK: no (KTD20). Android: unmeasured. |
| `scriptErrors` | `evaluate` reports a throwing script. | WebView2, WKWebView, WebKitGTK: U2's eval wrapper already detects throws. Android: unmeasured. |

`interceptionTier` (Dart) summarises them: `replace` with `replaceRequests`, `observe` with either observe feature, `none` otherwise. Every missing feature carries a reason that names it. The contract suite accepts either "works" or "unavailable with a reason" for each feature; it never accepts an empty answer.

### Script errors (1.2)

A script that throws is reported as `{"result": "null", "scriptError": "<thrown value>"}` when the engine has `scriptErrors` (`BrowserScriptError` in Dart). `result` stays `null`, so a worker that ignores `scriptError` (or a 1.1 worker, which never receives it) sees Android's `evaluateJavascript` semantics. The Tachi shim keeps that behaviour by ignoring the field (Dart callers use `BrowserEvaluateCompat.androidCompatible`). Paperback's `executeInWebView` should reject its promise with the message. An engine without `scriptErrors` answers a throwing script with plain `result: "null"`.

### Page-start scripts (1.2)

`host.browser.addPageStartScript` registers `script` to run at document start in every frame (child frames of any origin included) of every document the session loads afterwards, until the session closes (`BrowserSession.addPageStartScript`; Android's `addDocumentStartJavaScript`).

- **Order:** channel objects first, then page-start scripts in registration order, then the page's scripts.
- **Current document:** not affected. Evaluate the script as well if it must run there.
- **Origins:** the script runs in documents of every origin. For Android's `allowedOriginRules`, the Tachi shim wraps the script in its own `location.origin` check. Messages it posts follow the origin rule, so a post from a cross-origin frame is still dropped.
- **Removal:** there is none; scripts last until the session closes. The Tachi shim's `ScriptHandler.remove()` must say it cannot remove a script, not pretend it did.
- **Unavailable:** `capability-unavailable` with operation `addPageStartScript` and a reason naming `pageStartScripts`.

### Request interception (1.2)

`host.browser.setRequestInterception` selects at most one interceptor per session (`BrowserSession.setRequestObserver` and `setRequestReplacer`). Setting one mode replaces the other; `none` removes it. Only http(s) requests are reported or held.

- **`observe`:** each request the engine can see is sent as a `host.browser.request` event without `requestId`, and proceeds unchanged. Which requests are reported depends on `observeNavigations` and `observeSubresources`. Where subresources cannot be observed, the worker records the degraded capability (KTD20) and the request still proceeds. Refused as `capability-unavailable` only when neither observe feature exists.
- **`replace`:** each request is held and sent as a `host.browser.request` event with a `requestId`. The worker answers with `host.browser.respond`: a `response` is served instead of the network response, and `null` lets the request proceed.
  - **Unavailable:** refused as `capability-unavailable` (operation `setRequestReplacer`, reason naming `replaceRequests`) without the feature. It is also refused when the supervisor has no replacement timeout configured (`BrowserReverseBridge.replacementTimeout`); no default is invented. The engine is asked first (1.3): on an engine without the feature, the refusal carries the engine's own `replaceRequests` reason, and the missing timeout is named only for an engine that has the feature. Asking never installs a replacer, so an observer the worker set keeps running.
  - **Timeout:** a held request with no answer within the replacement timeout proceeds unchanged, and the redacted log records its method and URL without the query.
  - **Late answers:** a `respond` for a request that is no longer held (answered, timed out, or its session closed or fenced) is answered `cancelled`.
  - **Closing:** held requests of a closed or fenced session proceed unchanged and get no event.
  - **Invalid replacements:** a replacement with a redirect status or a status outside 100–599 is malformed (`protocol-violation`). At the port, an invalid replacement, or a replacer that throws, fails the request: the page sees a network error. A replacement can never substitute a redirect, so it cannot steer a load around the scheme policy.
  - **Concurrency:** a held main-frame request means the worker's own `host.browser.load` does not get its `rres` until the worker answers, and likewise an `evaluate` that triggers a fetch. A worker must therefore handle `host.browser.request` events and send `respond` while its own reverse request is pending (the Tachi shim: on its frame reader thread, not the thread blocked on the `rres`). Otherwise every held request waits out the full replacement timeout.
  - **No operation in flight:** `respond` is an `rreq`, so the orphan rule applies. A worker answers only while one of the package's operations is in flight. With none in flight it does not answer, and the request proceeds after the timeout.
- **Event fields:** `method` (uppercase), `url`, `headers` (as the engine sends them; may include `Cookie` and `Authorization`, so never log them), `mainFrame` (Android's `isForMainFrame`), `redirect`, `context` (`document`, `script`, `fetch`, `xhr`, `image`, `stylesheet`, `other`; unknown values read as `other`), and the body.
- **Request bodies:** `bodyBase64` carries the body when the engine exposes it (`observeRequestBodies`). `bodyOmitted: true` means the request had a body that the event does not carry: the engine could not read it, or it was larger than 1 MiB (`hostBrowserMaxForwardedBodyBytes`), so one upload can never push a frame past the 16 MiB limit. A body is omitted whole, never truncated.
- **Captured headers and cookies (1.3):** a capture records only `content-type`, `location`, `retry-after` and `cf-mitigated` (Cloudflare's header-based challenge signal). `Set-Cookie` is recorded only for the cookie names in the capture's `setCookieAllowList`, which is empty unless the scenario in `tool/capture_source_fixtures.dart` names a cookie. Each such cookie is sanitised to name, value, `Path` and `Domain`. A `redact` entry's value is written as `redacted`, so replay shows that a site issued a token, such as Mangahub's `mhub_access`, without committing it. `ReplayHttpClient` serves them as one `set-cookie` header, comma-joined as `package:http` does, and `FakeBrowserPort.replay` stores them in the session's cookie jar.
- **Offline replay:** captures match on method, canonical URL and body SHA-256 (`CaptureKey`). `browserCaptureReplayReplacer` serves a capture set as a replace-tier handler, so a POST such as MangaFire's `verify` matches only its recorded body. A request with `bodyOmitted` is a recorded miss, never a match against a bodiless capture. `FakeBrowserPort.replay` applies the same rules to requests made from the page.
- **Conformance:** the contract suite checks main-frame observation with headers and client hints, a POST subresource with its body, observer removal, observation stopping at close, replacement and pass-through, refusal of a redirect replacement, and interceptor exclusivity. On an engine without a feature, each case instead checks the named `capability-unavailable` reason or the documented degradation.

## Example exchange

```text
→ {"v":1,"t":"req","id":"1-1","gen":1,"op":"handshake","payload":{"protocolVersions":[1],"protocolMinor":3,"maxFrameBytes":16777216}}
← {"v":1,"t":"res","id":"1-1","gen":1,"ok":{"protocolVersion":1,"protocolMinor":3,"worker":"tachi-jvm","workerVersion":"0.1.0","pid":4242,"capabilities":{"apiFamilies":["tachi-1.5"],"browser":true},"limits":{"poolSize":2,"operationDeadlineMs":6000,"cancelGraceMs":1800,"interactionTimeoutMs":300000,"shutdownGraceMs":1800},"sizing":{"rule":{"source":"docs/validation/source-runners/desktop/…"},"inputs":{"cores":8,"maxHeapMiB":512},"derived":{"poolSize":2},"overridden":[]}}}
→ {"v":1,"t":"req","id":"1-2","gen":1,"op":"package.load","pkg":"eu.kanade.x","payload":{"artifact":{"sha256":"ab12…","kind":"jar","version":"1.4.2"},"path":"/…/ab12….bin","settings":{"values":{"lang":"en","nsfw":false},"secrets":{},"revision":"9f…"},"apiFamily":"tachi-1.5"}}
← {"v":1,"t":"res","id":"1-2","gen":1,"ok":{"sources":[{"sourceId":"9223372036854775807","name":"X (EN)","language":"en","capabilities":{"operations":["search","mangaDetails","chapterList"],"apiFamilies":["tachi-1.5"],"requiresBrowser":true}}]}}
→ {"v":1,"t":"req","id":"1-3","gen":1,"op":"search","pkg":"eu.kanade.x","payload":{"source":{…},"settingsRevision":"9f…","query":"onimai","cursor":null}}
← {"v":1,"t":"rreq","id":"r1","gen":1,"op":"host.browser.open","of":"1-3","payload":{"sourceId":"9223372036854775807"}}
→ {"v":1,"t":"rres","id":"r1","gen":1,"ok":{"session":"s-1","capabilities":{"available":["pageStartScripts","observeNavigations","observeRequestHeaders","scriptErrors"],"unavailable":{"observeSubresources":"WebKit cannot observe http(s) subresource requests","observeClientHints":"WebKit engines do not send Chromium client hints","observeRequestBodies":"The engine does not expose request bodies","replaceRequests":"The engine cannot substitute http(s) responses"}}}}
← {"v":1,"t":"rreq","id":"r2","gen":1,"op":"host.browser.setRequestInterception","of":"1-3","payload":{"session":"s-1","mode":"observe"}}
→ {"v":1,"t":"rres","id":"r2","gen":1,"ok":{}}
→ {"v":1,"t":"event","id":"e1-9","gen":1,"op":"host.browser.request","payload":{"session":"s-1","requestId":null,"method":"GET","url":"https://x.example/","headers":{"User-Agent":"…"},"bodyBase64":null,"bodyOmitted":false,"mainFrame":true,"redirect":false,"context":"document"}}
← {"v":1,"t":"res","id":"1-3","gen":1,"ok":{"hits":[{"ref":{…},"title":"Onimai","coverUrl":null,"authors":[],"handle":"h-1"}],"nextCursor":null,"warnings":[]}}
→ {"v":1,"t":"req","id":"1-4","gen":1,"op":"shutdown","payload":{}}
← {"v":1,"t":"res","id":"1-4","gen":1,"ok":{}}
```
