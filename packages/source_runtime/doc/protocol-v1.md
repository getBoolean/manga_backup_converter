# Source worker protocol, version 1

This protocol connects the desktop supervisor (`WorkerSupervisor` in `package:source_runtime`) to a source worker process: the shared Tachi JVM worker (U3) or the Paperback Dart worker (U6). It implements KTD4 of the source runners plan. KTD20 adds the browser reverse requests.

**The Dart types are the source of truth.** Every shape below is a class in [`lib/src/backends/protocol_payloads.dart`](../lib/src/backends/protocol_payloads.dart), and framing is in [`lib/src/backends/protocol.dart`](../lib/src/backends/protocol.dart). If this document and the code disagree, the code wins; fix this document. `test/protocol_payloads_test.dart` round-trips every payload through real frame bytes. A Dart worker should use the same classes: each has `fromJson` and `toJson`.

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
| `v` | int | Protocol version; always `1`. Any other value is a violation. |
| `t` | string | Frame type (table below). |
| `id` | string | Request ID. The supervisor writes `"<gen>-<n>"`; workers choose their own reverse request IDs. Treat IDs as opaque. |
| `gen` | int | Session generation. It increments on every worker (re)start; the handshake carries the new value. |
| `op` | string | Operation name (`req`, `rreq`, `event`). |
| `pkg` | string | Package ID for per-package operations. |
| `of` | string | On `rreq`: the `id` of the request that caused it. |
| `payload` | object | Request data (`req`, `rreq`, `event`). |
| `ok` | object | Success data (`res`, `rres`). Exactly one of `ok` and `err` is present. |
| `err` | object | Failure (`res`, `rres`): `{"code","message","operation"?}`. |

| `t` | Direction | Purpose |
|---|---|---|
| `req` | supervisor → worker | An operation. |
| `res` | worker → supervisor | Reply to the `req` with the same `id`. |
| `cancel` | supervisor → worker | Cancel the `req` with this `id` cooperatively. Has no payload. |
| `rreq` | worker → supervisor | A `host.browser.*` reverse request made while serving request `of`. |
| `rres` | supervisor → worker | Reply to the `rreq` with the same `id`. |
| `event` | supervisor → worker | A notification that needs no reply (`host.browser.message`). |

### Rules

- **Generations:** every frame the worker writes carries the current `gen`. A frame for any other generation fails the session.
- **Replies:** each `req` gets exactly one `res`. A `res` for an unknown `id` fails the session.
- **Payload shapes:** a `res` whose `ok` does not match the operation's reply shape (a missing required field, or a field of the wrong JSON type) fails the whole session, like a malformed frame. The worker's state can no longer be trusted; for example, it might hold a package the supervisor does not track. A malformed `rreq` payload is answered with `err.code = "protocol-violation"` and the session continues.
- **Reverse requests:** an `rreq` is valid only while its originating request (`of`) is in flight. An orphaned `rreq` fails the session. After a restart, the supervisor never delivers a late `rres` from an older generation.
- **Cancellation:** after a `cancel`, stop the operation and reply with `err.code = "cancelled"`. The supervisor discards that reply if the caller has already gone. If the operation does not settle within the cancel grace period, the supervisor kills and restarts the worker.
- **Concurrency:** the supervisor sends at most one per-package operation at a time for each package. Different packages may run concurrently, up to the pool size. `handshake` and `shutdown` are not package operations. Restart reloads also bypass the package queue.
- **Deadlines:** each operation's deadline is measured from dispatch, so time spent waiting in the queue does not count. Time spent in `host.browser.show` is excluded from the deadline and bounded separately.
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
| `artifact-incompatible` | The artifact failed integrity, trust or compatibility checks. |
| `worker-restarted` | Interrupted by a restart after its single re-send. |
| `source-error` | The source code itself failed. |
| `capability-unavailable` | A host capability is missing. `operation` names it, for example `host.browser.show`. |
| `protocol-violation` | The peer broke the protocol. |
| `runtime-unavailable` | The runtime could not start or is closed. |

## Shared shapes

These shapes appear inside several payloads.

- **`ArtifactBinding`** — `{"sha256": hex, "kind": "jar"|"apk"|"aix"|"paperback-bundle"|…, "version": string}`.
- **`SourceIdentity`** — `{"ecosystem", "packageId", "sourceId", "artifact": ArtifactBinding}`. `sourceId` is always a string. Tachi sends its int64 ID as a decimal string (for example `"9223372036854775807"`); a JSON number is rejected.
- **`SettingsPayload`** — `{"values": {key: string|bool|int}, "secrets": {key: string}, "revision": string}`. `values` keep their JSON types, and integers must stay within ±(2^53 − 1). `secrets` are session-only: never persist or log them. `revision` is a durable digest over the non-secret values and the secret key names (never the secret values), so it is safe to store.
- **`NativeMangaRef`** — `{"source": SourceIdentity, "mangaId": string, "settingsRevision": string, "context": object}`. `context` holds the source-returned fields that later calls need, such as Tachi's `SManga` fields or Paperback's context.
- **`SourceCapabilities`** — `{"operations": ["search"|"mangaDetails"|"chapterList"|"settings"|"browser"…], "apiFamilies": [string], "requiresBrowser": bool}`.
- **`MangaMetadata`** — `{"title", "altTitles", "authors", "artists", "description"?, "tags", "status": "unknown"|"ongoing"|"completed"|"cancelled"|"hiatus", "contentRating": "unknown"|"safe"|"suggestive"|"nsfw", "url"?, "coverUrl"?}`.
- **`NativeChapter`** — `{"chapterId", "sourceOrder": int, "context", "title"?, "chapterNumber"?: number, "volumeNumber"?: number, "scanlators": [string], "language"?, "dateUploaded"?: ISO-8601 UTC, "url"?}`.
- **`BrowserCookie`** — `{"name", "value", "domain"?, "path"?, "expires"?: ISO-8601 UTC, "secure": bool, "httpOnly": bool}`.

A field marked `?` may be omitted or `null`. Workers may add fields; readers ignore fields they do not know.

## Operations (supervisor → worker)

| `op` | `pkg` | Request `payload` (Dart class) | Reply `ok` (Dart class) |
|---|---|---|---|
| `handshake` | — | `protocolVersions: [int]`, `maxFrameBytes: int` (`HandshakeRequest`) | `protocolVersion: int`, `worker: string`, `workerVersion?`, `pid?: int`, `capabilities: {apiFamilies: [string], browser: bool}` (`HandshakeResponse`, `WorkerCapabilities`) |
| `artifact.prepare` | yes | `artifact: ArtifactBinding`, `inputPath`, `outputPath` (`ArtifactPrepareRequest`) | `artifact: ArtifactBinding` (of the output), `producer`, `converterVersion` (`ArtifactPrepareResponse`) |
| `package.load` | yes | `artifact: ArtifactBinding`, `path`, `settings: SettingsPayload` (`PackageLoadRequest`) | `sources: [{sourceId, name, language?, capabilities: SourceCapabilities}]` (`PackageLoadResponse`, `LoadedSource`) |
| `package.unload` | yes | `{}` (`PackageUnloadRequest`) | `{}` (`EmptyPayload`) |
| `settings.update` | yes | `settings: SettingsPayload` (`SettingsUpdateRequest`) | `{}` |
| `search` | yes | `source: SourceIdentity`, `settingsRevision`, `query`, `cursor?` (`WorkerSearchRequest`) | `hits: [SearchHit & {handle?}]`, `nextCursor?`, `warnings: [string]` (`WorkerSearchResponse`, `WorkerSearchHit`) |
| `details` | yes | `source`, `settingsRevision`, `ref: NativeMangaRef`, `handle?` (`WorkerDetailsRequest`) | `metadata: MangaMetadata`, `chapters: [NativeChapter]` (`WorkerDetailsResponse`) |
| `dispose` | yes | `source: SourceIdentity`, `handles?: [string]` (`DisposeRequest`) | `{}` |
| `shutdown` | — | `{}` (`ShutdownRequest`) | `{}`, then flush and exit |

### Notes

- **`handshake`:** reply with one of `protocolVersions`; this supervisor accepts only `1`. A reply in any other version, or one missing a required field, fails the session as `protocol-violation`. `capabilities.apiFamilies` lists the source API versions the worker can host, for example `tachi-1.5` or `paperback-0.8`. `capabilities.browser` says whether the worker may send `host.browser.*` requests.
- **`artifact.prepare`:** this operation turns a verified input artifact into the form the worker loads, for example APK → JAR through dex2jar, or JAR signature verification (KTD5).
  - **Input:** before reading `inputPath`, re-verify it against `artifact.sha256`. Reject a mismatch with `artifact-incompatible`.
  - **Output:** write only to `outputPath`, a private staging path the supervisor chose.
  - **After the reply:** whoever sends `artifact.prepare` (the Tachi provider in U3; `WorkerSupervisor` only provides `send`) must re-hash the output and admit it to the artifact cache under an `ArtifactProfile(producer, converterVersion, hostCompatibility)`. It must never trust the reported digest alone. No caller does this yet.
  - **Not yet in the plan:** the plan names this operation but not its fields. This shape is the minimum U3 needs; U3 may extend it.
- **`package.load`:**
  - **Artifact:** `path` is a privately staged artifact that the supervisor re-verified just before sending. Load it into its own child-first class loader (Tachi) or runtime (Paperback).
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
| `host.browser.open` | `sourceId`, `userAgent?` (`HostBrowserOpen`) | `session` (`HostBrowserOpened`) |
| `host.browser.load` | `session`, `url`, `headers?: {string: string}` (`HostBrowserLoad`) | `finalUrl`, `status?: int` (`HostBrowserPage`) |
| `host.browser.loadData` | `session`, `html`, `baseUrl` (`HostBrowserLoadData`) | `finalUrl`, `status?` (`HostBrowserPage`) |
| `host.browser.evaluate` | `session`, `script` (`HostBrowserEvaluate`) | `result`: the value as JSON text (`HostBrowserEvaluated`) |
| `host.browser.setMessageHandler` | `session`, `name`, `enabled: bool` (`HostBrowserSetMessageHandler`) | `{}` |
| `host.browser.getCookies` | `session`, `url` (`HostBrowserGetCookies`) | `cookies: [BrowserCookie]` (`HostBrowserCookies`) |
| `host.browser.setCookie` | `session`, `url`, `cookie: BrowserCookie` (`HostBrowserSetCookie`) | `{}` |
| `host.browser.setUserAgent` | `session`, `userAgent` (`HostBrowserSetUserAgent`) | `{}` |
| `host.browser.show` | `session` (`HostBrowserShow`) | `{}` |
| `host.browser.close` | `session` (`HostBrowserClose`) | `{}` |

| Event `op` (supervisor → worker) | `payload` (Dart class) |
|---|---|
| `host.browser.message` | `session`, `name`, `message` (`HostBrowserMessage`) |

### Notes

- **Scope:** a session belongs to the package of the originating request and to the generation that opened it. The supervisor resolves the `SourceIdentity` for `sourceId` and refuses a source the package does not host (`capability-unavailable`). A request for an unknown session, another package's session, or another generation's session is answered `cancelled`.
- **Allowed schemes:** `load`, navigations, redirects and `baseUrl` must be http or https. `about:blank` is also allowed, and `loadData` content is allowed when its base URL is http(s). Anything else, including `file:`, is refused as `capability-unavailable`.
- **Lifetime:** when a generation is fenced (by restart, session failure, or worker close), the supervisor closes every browser session that generation opened and deletes the sessions' storage.
  - **Late opens:** a session whose open completes after its generation was fenced is closed at once.
  - **Unconfirmed deletion:** when a close that the supervisor started on its own does not complete (for example, the platform cannot confirm that storage was deleted), the failure is written to the redacted log. There is no worker left to answer.
  - **After the conversion:** when the conversion scope closes, every remaining session closes, and later requests are refused.
  - **Requests in flight:** reverse requests from a fenced generation are cancelled, and their replies are never delivered.
- **Interaction:** while a `host.browser.show` request is open, the originating operation's deadline is paused. The interaction has its own bound; when it expires, the operation escalates like a deadline.
- **Failure codes:** platform failures map to `cancelled`, `interaction-required`, `capability-unavailable` (with the named operation), or `source-error` (navigation failures). A malformed reverse payload is answered `protocol-violation`.
- **Messages:** page messages arrive as `host.browser.message` events only while the handler is enabled and the session's generation is current.

## Example exchange

```text
→ {"v":1,"t":"req","id":"1-1","gen":1,"op":"handshake","payload":{"protocolVersions":[1],"maxFrameBytes":16777216}}
← {"v":1,"t":"res","id":"1-1","gen":1,"ok":{"protocolVersion":1,"worker":"tachi-jvm","workerVersion":"0.1.0","pid":4242,"capabilities":{"apiFamilies":["tachi-1.5"],"browser":true}}}
→ {"v":1,"t":"req","id":"1-2","gen":1,"op":"package.load","pkg":"eu.kanade.x","payload":{"artifact":{"sha256":"ab12…","kind":"jar","version":"1.4.2"},"path":"/…/ab12….bin","settings":{"values":{"lang":"en","nsfw":false},"secrets":{},"revision":"9f…"}}}
← {"v":1,"t":"res","id":"1-2","gen":1,"ok":{"sources":[{"sourceId":"9223372036854775807","name":"X (EN)","language":"en","capabilities":{"operations":["search","mangaDetails","chapterList"],"apiFamilies":["tachi-1.5"],"requiresBrowser":true}}]}}
→ {"v":1,"t":"req","id":"1-3","gen":1,"op":"search","pkg":"eu.kanade.x","payload":{"source":{…},"settingsRevision":"9f…","query":"onimai","cursor":null}}
← {"v":1,"t":"rreq","id":"r1","gen":1,"op":"host.browser.open","of":"1-3","payload":{"sourceId":"9223372036854775807"}}
→ {"v":1,"t":"rres","id":"r1","gen":1,"ok":{"session":"s-1"}}
← {"v":1,"t":"res","id":"1-3","gen":1,"ok":{"hits":[{"ref":{…},"title":"Onimai","coverUrl":null,"authors":[],"handle":"h-1"}],"nextCursor":null,"warnings":[]}}
→ {"v":1,"t":"req","id":"1-4","gen":1,"op":"shutdown","payload":{}}
← {"v":1,"t":"res","id":"1-4","gen":1,"ok":{}}
```
