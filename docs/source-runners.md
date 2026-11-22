# Source runners: compatibility inventory

What each source runner hosts, how, and where it stops. This file is updated by the unit that changes a
runner.

## Desktop Tachi worker (`tools/tachi-source-runner`, U3)

One Kotlin/JVM process per conversion hosts every selected Tachi extension package (KTD1). It speaks
protocol v1, minor 1.3, on stdio (`packages/source_runtime/doc/protocol-v1.md`), answering an older
supervisor with its lower minor; logs go to stderr only.

### Runtime

- Java: Amazon Corretto 21; the worker refuses to start below 21.0.13 (KTD1 security floor).
- Gradle 9.8.1 wrapper, version catalog `gradle/libs.versions.toml`, every configuration locked in
  `gradle.lockfile`. Licences: `tools/tachi-source-runner/THIRD_PARTY.md`.
- Limits come from the committed KTD25 sizing rule (see `docs/validation/source-runners/desktop/`), or
  from explicit `--limit NAME=VALUE` overrides. Without either the worker refuses to start.
- Handshake deadline: the one limit the worker cannot report, because the supervisor needs it before the
  worker has said anything. The benchmark measures JVM launch to handshake reply (cold and warm) and the
  rule derives `handshakeDeadlineMs = ceil(maxStartupToHandshakeMs × handshakeFactor)`. `installDist`
  writes it into the runtime manifest `tachi-runtime.json` at the install root (beside `lib/`), which
  `package:tachi_plugin_loader` reads; the handshake repeats it in `limits` and `sizing.derived` for
  receipts only (it is not an adoptable limit).

### Extension API

| API family | Status | How |
|---|---|---|
| `tachi-1.6` (extensions-lib 1.6, suspend API, `SMangaUpdate`) | hosted | Mihon `source-api` at `f64d82b9` |
| `tachi-1.5`, `tachi-1.4` (Rx `fetch*` and request/parse pairs) | hosted through Mihon's legacy bridge | same; covered by a fixture extension |
| other versions | `unsupported-api` at `package.load` | |

`AbiConformanceTest` checks that every member of the extensions-lib 1.6 ABI dump exists in the host, and
that every external class, method and field the six qualification artifacts reference links.

### Artifact paths (KTD5)

| Path | Steps | Result |
|---|---|---|
| Repository JAR | copy to private staging → SHA-256 check → JAR signature: every non-signature entry signed by exactly one signer whose certificate SHA-256 is trusted; duplicate ZIP entries rejected → stage | loads unmodified |
| APK | copy → SHA-256 check → apksig verification against the same trust identity → dex2jar 2.4.39 (own loader, insertion-ordered collections) → host bytecode fixes → JAR (sorted entries, fixed zone-free timestamps) with all resources | loads; byte-deterministic |

- **Patching.** Published keiyoushi JARs need no Android bytecode patching. APKs do: R8 removes trivial
  constructors when dexing (`new X; invoke S.<init>` and super calls that skip the direct superclass),
  which the JVM verifier rejects. `ConstructorElisionFix` restores those constructors before translation
  (it cannot occur in verified JAR class files), and `FrameComputer` recomputes stack map frames with the
  extension's own class hierarchy, because dex2jar's frame pass falls back to `Object`. dex2jar must also
  keep Kotlin's mangled names (`constructor-impl`). All of this is in the converter version
  `dex2jar-2.4.39+ctorfix.1+frames.1+ordered.1+casesafe.1`, which is part of the prepared artifact's cache identity
  (`converterVersion` in the `artifact.prepare` reply, with host compatibility `tachi-host.1`).
- **Case safety.** dex2jar writes classes to memory, never to a directory or `jdk.zipfs`, so R8 names that differ only by case (`a`/`A`) both survive on case-insensitive volumes; a JAR whose class count differs from the DEX headers' `class_defs_size` fails as `artifact-incompatible` (`CaseCollisionConversionTest`).
- **Determinism.** Preparing the same APK always gives the same bytes, so a resumed conversion on the
  APK path keeps its session identity (the prepared digest). dex2jar's IR passes kept working sets in
  `HashMap`/`HashSet` keyed by identity-hashed IR objects, so register assignment changed between
  conversions in one JVM. Each conversion now loads dex2jar in a fresh class loader that rewrites those
  instantiations (constructors, `::new` handles, subclasses) to `LinkedHashMap`/`LinkedHashSet`, so
  iteration follows insertion order; frames are recomputed in sorted class order; entries are sorted and
  stamped with a fixed DOS time that does not depend on the JVM's time zone. `DeterministicConversionTest`
  checks MangaDex, Weeb Central and MangaFire twice in one JVM (other thread, other order) and in two
  worker processes started with different time zones, collectors and heaps. Prepared digests (converter
  `+casesafe.1`, unchanged from `+ordered.1`, Corretto 21.0.13):
  - MangaDex `b7dda66c5c901aa23d172173d54c12f04d64bdc20bd0da58748ce7f095da28d0`
  - Weeb Central `546c4a615158c44bf656d9bb45f7555e9d31638a77d977d3f8a5a7e01dceb143`
  - MangaFire `19bd52b03b7dc17fa9aac1220ac729902d0d5ff03e536df6c1f73dcda8ec5630`

  The supervisor still re-hashes the staged output.
- **Trust identity.** keiyoushi's JAR and APK certificates both equal the published fingerprint
  `9add655a…4da2`, so they share one trust identity. The trusted signer reaches the worker only in
  the `trustedSigners` array of the `artifact.prepare` request (protocol 1.1): the certificate SHA-256
  fingerprints from the supervisor's stored trust anchor. A request without it is refused for kinds
  `jar` and `apk`; the worker has no command-line or file trust input.

### Class loading

Each package gets a child-first `PackageClassLoader`. Host-owned packages always resolve to the parent's
single copy: Kotlin, kotlinx, OkHttp/Okio, jsoup, RxJava, Injekt, `android.*`, `androidx.*`,
`eu.kanade.tachiyomi.{source,network,util}`, `eu.kanade.tachiyomi.AppInfo`. Identically named extension
classes in different packages do not collide, and unloading a package releases its loader
(`MultiPackageTest`).

### Host services

| Service | Implementation |
|---|---|
| `NetworkHelper` | per package; interceptor chain as Mihon (`UncaughtExceptionInterceptor`, `UserAgentInterceptor`, `CloudflareInterceptor`); per-package dispatcher; no disk cache |
| Cookies | per-package in-memory jar, shared with that package's `android.webkit.CookieManager` |
| `SharedPreferences` | `InMemorySharedPreferences` returned by the package's `Context`/`Application`; seeded from the settings snapshot, replaced by `settings.update`, discarded at unload; never written to disk (KTD9) |
| DI | Injekt (`com.github.mihonapp:injekt`); `Application`, `Context`, `NetworkHelper` resolve to the calling package (by the first stack frame from a package class loader, so OkHttp, coroutine and main-looper threads resolve correctly) |
| JSON | `Json { ignoreUnknownKeys = true; explicitNulls = false }` as Mihon |
| Main thread | worker-owned `android.os.Looper` main thread (`tachi-main`) and `Dispatchers.Main` over it |
| `AppInfo` | reports version 0.19.0 / code 19, chosen to match the Mihon source API the host implements (not an official Mihon release identity) |
| `JavaScriptEngine` | **unsupported**: fails with `capability-unavailable` (`host.api:eu.kanade.tachiyomi.network.JavaScriptEngine.evaluate`). None of the qualification extensions call it. |
| Cloudflare | challenge pages (a 403/429/503 with `cf-mitigated: challenge`, or a challenge marker and Cloudflare named) are detected. In interactive runs the worker gets `--interactive-challenges MS` (the flag the Android service also takes; the CLI passes it only when interactive) and installs a `CloudflareChallengeSolver` on the shared interceptor: on desktop `CloudflareSolver` opens a session for the operation's source with the request's user agent, pushes the package's cookies, loads the challenged URL and shows the helper's window (`host.browser.show`); a new `cf_clearance` in the session ends the show (`host.browser.endInteraction`), the session's cookies go into that package's own jar, the browser's `navigator.userAgent` is pinned for the host, and the request is retried once. Solves are single-flight per host. Without the flag, a window closed without a clearance, the interaction bound (or the flag's bound), and a retry that is still challenged are `interaction-required`; a cancelled operation is `cancelled`. The supervisor pauses its deadline for the show; the interceptor also pauses the operation's own platform deadline (`OperationContext.pauseDeadline`, a no-op except on iOS) while any solver runs (U8b) |

Settings: `SettingsPayload.values`/`secrets` seed every preference store the package opens.
`SettingsPayload.sources` (protocol 1.1) maps a `sourceId` to that source's own `values`/`secrets`, which
override the package-wide keys in the store the source opens (`source_<id>`). Keys are plain; no key
carries a store or source prefix. Values keep their JSON types (string, bool, int, and an array of
strings for a string set read through `getStringSet`).
Secret-like keys (L4): a key matching `pass|token|secret|cookie|auth` case-insensitively (`author`, `authors` and the like excepted; `authorization` included; a broad match such as `compassDirection` is accepted as the cost of the rule) is
treated as a secret even when placed under `values`. It is still delivered as a typed value, so the source reads
it unchanged, but its value never enters `SettingsSnapshot.revision` or `toJson` (only its name, with the secret
keys: the revision stays durable and is never an unsalted hash of a password), and its string forms are
registered for redaction. The CLI registers every secret of the settings file and `--setting` flags with the
session redactor before any worker, helper or plugin starts.

Unsupported Android APIs throw a named `UnsupportedHostApi`, reported as `capability-unavailable` with
`operation = host.api:<Class.member>`. A missing host class is `capability-unavailable` with
`operation = host.class:<name>`.

### Browser translation (KTD20)

`android.webkit.WebView`, `WebViewClient`, `WebChromeClient`, `WebSettings`, `CookieManager`,
`JavascriptInterface`, `WebResourceRequest`/`Response`/`Error` are shims over `host.browser.*` reverse
requests, sent for the package's in-flight operation and closed before it replies.

- `WebView.getWebViewClassLoader()` sees no Chromium glue, so keiyoushi's `WebViewGlueBridge` reports
  every feature unsupported and the helper falls back to `addJavascriptInterface` (verified with the real
  MangaFire helper in `CapturedProofTest`).
- `addJavascriptInterface(obj, name)` registers message channel `name` (any JavaScript identifier,
  `ipc` included); a page message invokes the object's `@JavascriptInterface` method `postMessage(String)`.
- Load, navigation and base URLs must be http(s) (`about:blank` for loads); anything else is
  `capability-unavailable` before any reverse request.
- Cookies are pushed to the session before each load and pulled into the package jar after it.
- Protocol 1.2 features are used only when negotiated, and only as far as the session's reported
  `capabilities` allow (absent capabilities mean none):
  - `androidx.webkit.WebViewCompat.addDocumentStartJavaScript` (shimmed with `WebViewFeature` and
    `ScriptHandler`) becomes `host.browser.addPageStartScript`, replayed in registration order after the
    channel objects when the session opens. `allowedOriginRules` (androidx grammar: `*`;
    `http(s)://host[:port]`, where a leading `*.` matches subdomains but not the domain itself; IP
    literals; `scheme://` custom-scheme rules, valid but never matching because the port loads only
    http(s) documents) are enforced by a `location` check wrapped around the script; with `*` the script is sent unchanged, otherwise its
    top-level `let`/`const`/`class` are scoped to the wrapping block. Without `pageStartScripts` the call
    fails as `capability-unavailable` (operation `addPageStartScript`). `ScriptHandler.remove()` throws
    `UnsupportedOperationException` and adds an operation warning: the port cannot remove a script.
  - `shouldInterceptRequest` uses the replace tier when the session has `replaceRequests` (falling back
    to observe if the supervisor refuses it, for example with no replacement timeout), otherwise observe
    when it can see navigations. Held requests are answered with `host.browser.respond`: the replacement's
    status, reason, headers (plus `Content-Type` from the MIME type and encoding) and body, or `null`. A
    redirect or out-of-range status is refused by name (`android.webkit.shouldInterceptRequest.redirect`)
    and the request proceeds. On an observe-only session a non-null response is a named capability error
    (`android.webkit.shouldInterceptRequest.replace`). Without subresource observation the operation
    carries a `degraded: subresource observation unavailable` warning with the engine's reason.
  - `host.browser.request` events are decoded and routed on the frame reader thread; the extension's
    handler runs on a browser thread (as Android calls it off the main thread) and `respond` is sent
    without waiting for its `rres`. A held request is always answered, with `null` if the handler or
    the replacement fails. The thread that sent `host.browser.load` is blocked until the held
    request is answered, and the reader is the only thread that can read that `rres`, so neither may
    wait. `respond` is sent only while one of the package's operations is in flight.
  - `evaluate`'s `scriptError` is ignored, so a throwing script reads as `"null"` as on Android.
- With protocol 1.3 (see *Protocol 1.3* below) the shim also shows a session for interaction, reads the
  show's `outcome`, ends it with `host.browser.endInteraction`, and passes an awaited promise's settled
  value through `evaluate`.
- Against a 1.1 supervisor, or a session with no observe feature, `shouldInterceptRequest` sees
  main-frame `loadUrl` navigations only (called by the shim), and `addDocumentStartJavaScript` is
  `capability-unavailable`. Synchronous `@JavascriptInterface` return values are a named capability error.
- A capability or interaction failure from the port cancels the package's in-flight calls, so helpers
  that watch their call (`runWebViewBlocking`) fail at once with the recorded host error.

### Qualification evidence

| Source | Artifacts | Captured proof (replay, both paths) |
|---|---|---|
| MangaDex (`all.mangadex` 1.6.4) | JAR + APK, keiyoushi signer | search, details, 15 chapters (`Onimai` → *Petit Onimai Manga!*) |
| Weeb Central (`en.weebcentral` 1.6.27) | JAR + APK | search, details, 114 chapters |
| MangaFire (`all.mangafire` 1.6.38) | JAR + APK | search (VRF signing path), details, 86 chapters; no challenge fired at capture. The captcha path is exercised with a synthetic 403 and a fake port: it completes through the `addJavascriptInterface` fallback, and port failures map to `interaction-required` / `capability-unavailable`. |

Fixtures: `fixtures/source_captures/tachi/<source>/` (artifacts, `index-entry.json`, `desktop-artifacts.json`,
`capture.json` + `bodies/`). The MangaFire live browser path (AE11) runs at the U8 join with U2's helper.

### Known gaps

- Only the browser surface used by the keiyoushi helper and the qualification sources is translated.
- Heap and metaspace use per package are not reported to the supervisor.
- CI runs the JVM tests on Linux (`test` job) and the benchmark in quick mode on each desktop OS as a non-gating
  report (`benchmarks` job, U8).
- Live transcripts of the one-time captures: `docs/validation/source-runners/desktop/captures/`.

### Protocol 1.1 (resolved gaps)

The worker negotiates protocol minor 1.1 (`packages/source_runtime/doc/protocol-v1.md`), which closed
the gaps this inventory used to list:

1. **Trusted signer.** `artifact.prepare` carries `trustedSigners: [string]` (lowercase hex certificate
   SHA-256); it is the only trust input.
2. **String-set preferences.** A `SettingsPayload` value can be an array of strings (a set).
3. **Per-source settings.** `SettingsPayload.sources` addresses one source of a multi-source package.
4. **Handshake limits.** The worker's `limits` and `sizing` are decoded by the supervisor (KTD25).
5. **Page-to-host messages.** The browser message channel contract defines
   `window.<name>.postMessage(string)` for each enabled channel.

### Protocol 1.3

The worker negotiates minor 1.3 (`Wire.MINOR_VERSION`); against an older supervisor it keeps its 1.2 behaviour.

- **Deadline pause.** `interaction.started {of, timeoutMs}` pauses operation `of`'s platform deadline and
  `interaction.ended {of, pausedMs}` resumes it; the show's `rres` alone never resumes it. Handled on the
  frame reader, leniently: an event for an operation no longer in flight, a malformed one, a repeated start,
  an end without a start, or any event from a peer below 1.3 is dropped. Overlapping shows give one pair.
  The accounting (`PausableDeadline`) runs over any arm/disarm timer: while paused the timer is armed for
  the remaining budget plus `timeoutMs`, so a lost `interaction.ended` still ends the operation; a deadline
  that fired before the pause stays fired; a `cancel` during the pause still fires; nothing re-arms after the
  operation ends. A fire found when disarming is armed again at zero, because the iOS watchdog's disarm
  clears the thread's stop mark. The desktop worker has no deadline of its own (the supervisor's applies),
  so on desktop this changes nothing. The iOS embedding (`ios/host/.../IosPlatform.java`) pauses its native
  watchdog through it; that path is compile-checked only (`javac` against the worker classes), never run on
  a device or simulator. JVM tests cover the accounting with a scheduler-backed test platform.
- **Interaction.** `WebViewBackend.showForInteraction(completionChannels, onOutcome)` (reached through
  `WebView.hostBackend()`: no Android API makes a WebView visible here) sends `host.browser.show` without
  holding the WebView's request chain, so the extension's evaluate, cookie and close calls proceed during
  the interaction. The show completes when a page message arrives on one of `completionChannels`
  (`endInteraction` is sent from the frame reader before the extension's handler runs) or when code calls
  `endInteraction()` (sent from the calling thread without waiting, the same rule as `respond`). The reply's
  `outcome` (`completed`, or `closed` when the user closed the window; absent from a 1.2 supervisor and
  read as `closed`) reaches `onOutcome` after the session's cookies are pulled into the package jar. The
  interaction bound is `interaction-required`, including an older peer's `timeout`, and stays the operation's
  error even if the source then waits out the deadline. Against a 1.2 supervisor `endInteraction` cannot be
  sent; the operation carries a warning and the show ends at a close or its bound.
  The extension-facing `showForInteraction` still has no production caller (the qualification sources use
  headless WebViews); the Cloudflare path shows the window through `CloudflareSolver` instead (see the
  Cloudflare row above).
- **Evaluate.** The host awaits a returned promise; the shim passes the settled value through (a rejected
  promise reads as `"null"`, like a throw). Android would report `{}` for a promise, which no source can
  use, and Dart's `BrowserEvaluateCompat.androidCompatible` keeps the settled value too. Evaluations stay
  ordered on the WebView's chain, so a promise that never settles holds that WebView's later calls until the
  operation is cancelled or stopped by its deadline.
- **Captures.** `CaptureFormat` reads and writes `setCookieAllowList` and each exchange's `setCookies`
  (name, value, `Path`, `Domain`, `redacted`) in the Dart format's key order, and records `cf-mitigated`.
  Replay serves each allow-listed cookie as its own `Set-Cookie` header, so it lands in the package jar and
  goes out on the next request. The capture tool records cookies only for a `Target.setCookieAllowList`
  (empty for the current targets) and refuses a recording whose body contains a redacted cookie's value.
- Tests: `InteractionDeadlineTest`, `WebkitProtocol13Test` (fake 1.3 supervisor), `CaptureCookiesTest`.

## Desktop WebView capability matrix (`packages/desktop_webview`, U2)

One standalone helper (`desktop_webview_helper`, Rust over `wry` 0.57.3 / `tao` 0.37.3, pinned by
`helper/Cargo.lock`) per conversion, one WebView per source session. It is built by
`tool/build_helper.dart` (`cargo build --locked`) and located through `build/helper/runtime-artifacts.json`, which
records the SHA-256 the client verifies before launch. Protocol: `packages/desktop_webview/doc/helper-protocol.md`.

Status key: **pass** = ran and passed here; **compiled** = type-checks for the target, never run; **not run** =
neither built nor run. Windows cells come from the runs on 2026-11-20 (Windows 11, WebView2 157.0.4341.60,
`flutter test packages/desktop_webview/test --concurrency 1`: all passed, 0 skipped, against the protocol 1.2 contract
suite with no `knownFailures`) and from the integration run on 2026-11-21 against the protocol 1.3 contract suite
(no contract case failed, no `knownFailures`, no skips; see the contract row for which 1.3 cases ran a display path).
Outside the contract suite that run failed `request bodies reach the replacer, and capture replay matches on the body
hash` intermittently: WebView2's own `GET /favicon.ico` sometimes reaches the replay replacer after it is set and is a
second miss (the test counts every miss); the test passed alone twice and in one of two later file runs. A file rerun
also failed the start-up wipe test below. macOS cells come from runs on 2026-11-21 (macOS 27.0 build 26A428, Apple M1, WebKit
22625.1.29.11.27, arm64 helper, `flutter test packages/desktop_webview/test --concurrency 1`; receipts and counts in
`docs/validation/source-runners/desktop/README.md`). No Linux cell is an expected value.

| Behaviour | Windows (WebView2) | macOS (WKWebView) | Linux (WebKitGTK) |
|---|---|---|---|
| Build | pass (debug and `--release`; 739 KB standalone exe) | pass (2026-11-21, arm64: debug and `--release` with Apple clang from Xcode; no `CC` override needed). x64 not built | not run. `cargo check --target x86_64-unknown-linux-gnu` cannot run on the Windows host (the build scripts need the target's system libraries through pkg-config) |
| BrowserPort contract suite (protocol 1.3, `source_runtime_testing`) | pass (2026-11-21, U8): 54 passed, 1 skipped, no `knownFailures`. The desktop harness is interactive where a display exists, so the five 1.3 interaction-completion cases run on the helper with a visible window: the page signals completion through a message channel (`completedByPage`), the "user" closes the window with a native `WM_CLOSE` posted to its HWND (the helper's `debugRequestClose` test hook; it arrives as `CloseRequested`, `closedByUser`), the bound times out as `interaction-required`, a cancel ends it, and closing the session ends a shown interaction as cancelled. The skipped case is *showForInteraction reports interaction-required without a display*, which only runs where no display exists (headless Linux, or `DWV_NO_DISPLAY=1`); the display-only cases are marked skipped, not passed, in that environment | pass (2026-11-21, U8 macOS): 54 passed, 1 skipped, no `knownFailures`. Visible windows: the five 1.3 interaction cases ran on the helper, the "user" close goes through AppKit `performClose:` on the window (`debugRequestClose`), which tao turns into `CloseRequested` (`closedByUser`). The skipped case is the no-display one, as on Windows | not run |
| Reported protocol 1.2 capabilities (`ready` `capabilities.browser`) | all eight available: `pageStartScripts`, `observeNavigations`, `observeSubresources`, `observeRequestHeaders`, `observeClientHints`, `observeRequestBodies`, `replaceRequests`, `scriptErrors` | available: `pageStartScripts`, `scriptErrors`. Unavailable with WKWebView reasons: `observeNavigations` (the policy delegate sees navigation requests without the headers the engine sends; not reported), `observeSubresources` and `replaceRequests` (no URL scheme handler for http or https), `observeRequestHeaders`, `observeClientHints` (WebKit sends none), `observeRequestBodies` | as macOS, with WebKitGTK reasons (`resource-load-started` not wired) |
| Page bridge transport | pass: `window.chrome.webview.postMessage` with `WebMessageReceived`, captured at document start under a non-identifier property; no wry IPC, so `ipc`, `chrome` and `webkit` all work as channel names | pass: WebKit script message handler `dwvHost` (`WKScriptMessage.frameInfo` gives the posting frame); `ipc` and `chrome` work as channel names. `webkit` is refused with its reason: WKWebView defines `window.webkit` as a non-configurable, non-writable global (measured), so no channel can replace it | written: script message handler `dwvHost` via `UserContentManager` (no frame identity; the page script's `location.origin` is used) |
| Script errors (`BrowserScriptError`) | pass: only a thrown script or rejected promise is `script-error`; a missing page bridge and a navigation away are separate codes that complete `null` | pass: same rules as WebView2. JavaScriptCore's `stack` omits the message, so the error text is the thrown value's string form followed by its stack | not run (reported unavailable) |
| Request bodies | pass: `Request.Content` up to 1 MiB, stream rewound (the upload is unchanged); larger bodies omitted whole. Probed: string, JSON string, Blob (typed and untyped), FormData (with a file), URLSearchParams, Uint8Array and XHR bodies are all exposed; `Content` is absent only for bodiless requests (including a bodiless POST or PUT with a `Content-Type`), so no stream means no body and `bodyOmitted` is set only for an unreadable stream or the cap. MangaFire's `verify` sends a JSON string body. `redirect` is always `false` (not reported) | unavailable (no request observation) | unavailable (no request observation) |
| `mainFrame` | pass: a `document` request whose URL a top-level `NavigationStarting` announced (redirect hops included); a same-origin child frame loading the same URL is not | n/a | n/a |
| Failing a held request (invalid replacement, redirect status, throwing replacer) | pass: the helper rewrites the request to `http://127.0.0.1:1/…` (Chromium's restricted port), so the page gets a network error and the original request never reaches the server; a failed main-frame load settles as navigation-failed | n/a (no replace tier) | n/a (no replace tier) |
| Load page, evaluate (promises awaited), JSON results | pass | pass | not run |
| Message channel `window.<name>.postMessage(string)` | pass: document start of every later document, plus the current page on registration; non-strings dropped | pass | not run |
| Origin rule (cross-origin frame, `about:blank` dropped) | pass. The page script reports the frame's origin and `top.location.origin`, which a cross-origin frame cannot read; on WebView2 the engine's document URL must agree too. Same-origin direct child frames get the channel and are delivered (frame message events are forwarded); nested frames are not subscribed | pass (posting frame's request URL from `frameInfo` must agree) | not run (posting frame's `location.origin` used) |
| Cookies read/write; domain and path derived from the URL | pass | pass. wry's WKWebView `cookies_for_url` compares the cookie domain with the URL's DNS name only (an IP host never matched) and ignores the path; the helper filters the store by RFC 6265 domain and path instead. wry also wrote `HttpOnly=FALSE` for every pushed cookie, which Foundation reads as HttpOnly, hiding pushed cookies from `document.cookie`; the helper now sets `secure`/`httpOnly` only when true | not run |
| Two sessions' cookie and web-storage isolation | pass (InPrivate profile per session) | pass (non-persistent `WKWebsiteDataStore` per WebView) | not run (ephemeral `WebContext` per WebView) |
| Non-persistent store / start-up wipe | pass. InPrivate; browsing data cleared and confirmed on close. A one-off probe hard-killed the helper mid-session: 0 rows in the profile's Cookies database (a script-set cookie and a server cookie with `Max-Age`), and no localStorage or IndexedDB on disk. A directory is renamed before deletion, so a directory still in use is left whole and reported by name. The helper runs in a kill-on-close job object (its effect on the other WebView2 processes was not compared against a run without it). After a kill, the WebView2 browser process can stay in termination for 1-110 s (measured; cause not identified), holding the directory. `wipe` retries within the client's `DesktopWebViewConfig.wipeRetry` budget. The CLI sets 120 s (`CliBrowserPolicy.wipeRetry`, U8): the slowest measured release (110 s) with margin; the CLI never calls `wipeAllSourceData` on a conversion's path, and the helper's own start-up wipe is a single attempt, so a held directory never delays a conversion. Tests: planted stale directory; a killed helper's directory removed by the next helper's start-up wipe once released; a directory held open is reported and left whole; one wipe that keeps retrying until the directory is released | pass. Non-persistent store, no data directory: after the full suite, no cookie, local-storage or IndexedDB file for the helper exists under `~/Library` (WebKit's per-client sandbox directories in the user temp folder are empty; the GPU process keeps a Metal shader cache only). The helper's own `h-<pid>` directory holds just the offline rule store and is removed at exit or by the next start-up wipe. POSIX lets a directory in use be renamed, so the wipe skips and reports an `h-<pid>` whose process still runs (tested with a live and then killed owner); the WebView2 file-locking test is skipped on macOS | not run (ephemeral; no data directory) |
| Visible window, interaction timeout, user close | pass (window shown; timeout hides it; close completes; session close cancels) | pass (window shown; timeout hides it; `performClose:` completes it; session close cancels) | not run |
| Scheme policy in the helper (load, `loadData` base, cookies, redirects, new windows denied) | pass. A 302 to `file:` surfaces only as Chromium `REDIRECT_FAILED`, which the helper maps to the named policy failure (a redirect loop maps the same way) | pass. The helper's own navigation delegate decides every navigation in every frame; WebKit refuses a 302 to `file:` itself (NSURLErrorDomain -1102), which the helper maps to the named policy failure | not run (wry navigation handler) |
| User-agent override at runtime | pass | pass (`setCustomUserAgent`) | not run (`WebSettings`) |
| `loadData` with base URL (document URL and origin = base) | pass: navigate to the base URL and substitute the main-document response | pass (`loadHTMLString:baseURL:`) | not run (`load_html(html, base)`) |
| Page-start script injection | pass (`AddScriptToExecuteOnDocumentCreated`; runs at `readyState == "loading"`) | pass (`WKUserScript` at document start, all frames) | not run (`UserScript` at start) |
| Request observation with headers | pass: every request, with `mainFrame` and bodies; `sec-ch-ua*` visible in `WebResourceRequested` and at the server | unavailable (reported) | unavailable (reported; `resource-load-started` could add it) |
| Request replacement (KTD20 replace tier) | pass | capability-unavailable | capability-unavailable |
| Synchronous script-interface returns | unsupported | unsupported | unsupported |
| HTTP status code of a load | pass | pass: from the main frame's navigation response (`decidePolicyForNavigationResponse`); 404 and 200 checked | unavailable (`null`) |
| Failed-navigation detection | pass | pass: `didFail(Provisional)Navigation` settles the load as `navigation-failed` (a dropped connection checked); completions of a superseded navigation are dropped | `load-failed` wired, not run |
| Offline replay (helper blocks unanswered non-loopback requests) | pass: interception over all request source kinds (a cross-origin iframe request is seen and blocked). A `--host-resolver-rules` DNS backstop for traffic interception misses (WebSockets) is configured but not verified by a test | pass: a WebKit content rule list blocks every http(s) and ws(s) load whose host is not `127.0.0.1`, `localhost` or `[::1]` (every frame, every resource type). Shown without request observation on a host that would reach the fixture server (`[::ffff:127.0.0.1]`): a control session without `--offline` reaches it, the offline session's fetch, iframe and navigation do not. A rule list that fails to compile is fatal (`offline-unsupported`) | refuses to start with `--offline` (`offline-unsupported`) |
| Typed failures: missing WebView runtime, no display | pass via `--simulate-fatal`, mapped to capability-unavailable; a real missing runtime is not reproduced | pass via `--simulate-fatal`; a real missing runtime cannot happen (WKWebView is part of the OS) | `no-display` check written, not run |
| MangaFire browser-behaviour replay | pass (below), through `browserCaptureReplayReplacer` (method, URL and body hash); a desktop test serves a recorded POST body and answers a different body with 599 | pass on a loopback copy (below): WKWebView has no replace tier to answer `https://mangafire.to`, so the page's origin and OpenCV URL are rewritten to a loopback server serving the same fixture | not run |

**MangaFire replay (Windows).** `mangafire_solver_replay_test.dart` loads the real `assets/solver.html` from the
committed `all.mangafire` 1.6.38 JAR with base URL `https://mangafire.to/@waf/solver`. It does what keiyoushi's
fallback does: Android Chrome user agent, a cookie pushed before load, a page-start script, and channel `bridge`.
Site responses come from a synthetic fixture (`test/fixtures/mangafire_solver/`): a stub `opencv.js`, and a
`generate` response with three shapes that makes every solve throw. The page completes with
`bridge.postMessage("false")`. Relative `fetch("generate")` resolves against the base URL and is served offline;
the `generate` requests carry `sec-ch-ua*`. This exercises the browser path only. The captcha success path needs
real OpenCV and a live challenge, and is unverified. On WebView2 the user-agent override does not change
`sec-ch-ua*`: the brand stays "Microsoft Edge WebView2" and the platform stays "Windows" while the user agent says
Android Chrome. Whether MangaFire rejects that mismatch, or a Chrome user agent with no client hints on WebKit, is
unverified until a live capture.

**MangaFire replay (macOS, loopback copy).** WKWebView cannot answer requests for `https://mangafire.to` (no replace
tier), so on macOS the same test serves the same fixture from a loopback server and rewrites the page's base URL and
its `https://docs.opencv.org/` script URL to that server. The real solver page then runs on JavaScriptCore with the
Android Chrome user agent, a pushed cookie (visible to `document.cookie` only after the HttpOnly fix in the matrix),
a page-start script (`readyState == "loading"`) and channel `bridge`, and completes with `bridge.postMessage("false")`;
the server sees the `generate` requests with the overridden user agent. This shows the page's script path works on
WebKit; it does not show MangaFire accepting WebKit at its real origin (a Chrome user agent with no client hints),
which needs a live capture.

**Start-up wipe flake (U8: made load-robust).** The test now first waits until no running process names the killed
helper's data directory on its command line (WebView2 passes it as `--user-data-dir`), then until the directory can be
renamed, and only then starts the next helper: a directory can be renamed while a terminating browser process still
has it open with delete sharing, which is how the single start-up attempt could still fail. The favicon flake is fixed
too: the body-replay test counts only its own `/body-replay` misses (WebView2 requests `/favicon.ico` itself).
The earlier record follows. **Start-up wipe flake (bounded, cause unidentified).** `start-up wipe › the next helper removes a killed helper
directory` failed about 2 of 3 runs: the test started the next helper at once and then looped on `wipeAllSourceData`
for 20 s while the killed helper's WebView2 browser process was still terminating and holding the directory. The test
now waits until the directory can be released (bound 240 s), then checks that the next helper's start-up wipe removed
it. 10 consecutive runs on 2026-11-20 all passed (40-143 s per run including the debug build check; the longest
release wait was about 105 s). The test is bounded rather than deterministic: how long the OS takes to finish
terminating that process is outside the helper's control.

**Still needed.** macOS x64 (not built). Linux with WebKitGTK 4.1 has never been built or type-checked: the WebKitGTK
script message handler and the `javascriptcore-rs` dependency are written blind, and its offline replay is still
`offline-unsupported` (a content-filter equivalent is `WebKitUserContentFilterStore`, untested). Re-check MangaFire on
both WebKit engines with a live capture. The WSL Ubuntu on the Windows host has WSLg (`DISPLAY=:0`) but no
`webkit2gtk-4.1`/`gtk+-3.0` development packages and no Rust; nothing was installed. Done on macOS (U8 macOS lane):
the script message handler transport (and an `ipc` channel), the bootstrap capture of the post function, thrown-script
reporting (`scriptErrors` now reported available), offline replay (content rules) and failed-navigation detection
(the helper's own navigation delegate).

## Desktop browser join (U8)

The CLI composition registers one `DesktopBrowserPort` per conversion (`packages/mangabackupconverter_cli/lib/src/commands/desktop_runtime.dart`) and gives it to both workers:

- **Tachi:** `DesktopTachiRuntime(browserPort: ...)` passes it to the conversion's `ConversionRuntimeScope`, so the JVM worker's `host.browser.*` reverse requests (the `android.webkit` shim) are served by the helper. A package may open sessions only for the sources it enumerated (`TachiRuntime.browserIdentity`).
- **Paperback:** `desktopPaperbackLoader` now runs the worker in its own `ConversionRuntimeScope` (it used a bare supervisor with no reverse-request handler, so `executeInWebView` had no browser at all). A bundle may open sessions only for its own sources (`PaperbackSourceProvider.browserIdentity`).
- **Ownership:** the port is adopted into the conversion owner first, so it closes last: the workers and their bridges close (fencing every session), then the port disposes the helper. `test/integration/source_runner_conversion_test.dart` checks that no session and no helper process remain.
- **Where the helper comes from:** `--webview-helper <runtime-artifacts.json>`, else the packaged `runtime/desktop_webview/`, else the development build (`packages/desktop_webview/build/helper/`) of the development checkout. The client verifies the helper's SHA-256 before launch. Without a helper, every browser request fails as `capability-unavailable` and `--verbose` says why.
- **Development layouts (M1):** the development helper build and the Tachi `installDist` output are used only from a development checkout: the one named by `MANGA_BACKUP_CONVERTER_DEV_ROOT` (used as given), or, when the CLI runs from source (`Platform.script` ends in `.dart`), the nearest ancestor of the script holding the workspace `pubspec.yaml` and `packages/mangabackupconverter_cli/pubspec.yaml`. Nothing above that root is searched, and a compiled CLI searches nothing: a `tachi-runtime.json` or helper manifest planted in a parent folder by another local user would otherwise run its `java`/`classpath` or helper as the victim. Released Linux and macOS archives therefore ship the packaged bundle (with `runtime/`), like Windows.

**Tested and not tested.** The Paperback half reached the real helper through the composition (integration test). The Tachi half is wired the same way and its resolver is unit-tested (`tachi_runtime_test.dart`: a package's own source is accepted, another package's source, an unknown package and no package are refused; the shim sends the operation's `sourceId` and the supervisor fills the reverse request's `packageId` from the loaded package), but no Tachi qualification source drives the shim into the real helper: the replayed Tachi captures need no browser. U8b: `tachi_cloudflare_challenge_test.dart` (CLI) runs the real JVM worker with `--interactive-challenges` against the real helper and a loopback "challenge" site (a 403 page that sets `cf_clearance` only once its window is visible, the clearance bound to the user agent that first presents it): page-signalled completion with cookies and user agent reaching the worker's retry, the operation deadline paused for a 15 s solve against a 10 s deadline, a user close without clearance, the interaction bound, cancellation while shown, and an unattended run that opens no session. A live Cloudflare challenge was not available to test against. The desktop contract harness treats Windows as always having a display, so CI's Windows test job opens real (briefly visible) windows; set `DWV_NO_DISPLAY=1` if a runner has no interactive desktop.

**What triggers `showForInteraction`.** A source asks for a visible interaction (`host.browser.show`: Paperback's Cloudflare bypass after its 8 s headless wait; the Tachi worker's `CloudflareSolver` in interactive runs). Interactive runs (a terminal) create the port with visible windows allowed, so the helper's window opens for the user; it ends when the page signals completion, the user closes it, or after 5 minutes (`interaction-required`), and the engine deadline is paused meanwhile (protocol 1.3). Unattended runs never open a window: the show returns `interaction-required` at once, and the conversion reports it.

**Bounds** (`CliBrowserPolicy`; KTD25 policy values of the composition root, not engine measurements):

| Bound | Value | Why |
|---|---|---|
| Interaction | 5 min | a person solving a challenge needs minutes; the Paperback desktop worker already used it |
| Held-request replacement (`browserReplacementTimeout`) | 30 s | the hosts' own per-request network timeout: a held request never waits longer than the request itself could. The bridge asks the session's capabilities first, so an engine without the replace tier still names its own reason |
| Helper start-up / shutdown grace | 60 s / 10 s | the values the contract suite has run with |
| `wipeRetry` | 120 s | measured WebView2 releases after a kill took 1-110 s; see the matrix row |

**MangaFire (AE11), Windows (U8b).**

- **Browser capture.** The helper's `--record` mode (WebView2) reports every response with its request and decoded body; `BrowserCaptureRecorder` writes them in the capture format (allowed response headers and allow-listed cookies only). It records through the real browser rather than a fetching proxy, so a Cloudflare-fronted page sees the browser's own TLS, cookies and headers. `BrowserCaptureReplay` serves a capture set to every session of an offline port (the worker's interceptor first, captured redirects included, CORS synthesised at serve time) and fails a miss closed.
- **Paperback 0.9 (Inkdex MangaFire 1.0.0-alpha.24): passed.** One manual, rate-limited live run on 2026-11-21 (`capture_paperback_sources.dart mangafire --only=inkdex-0.9/MangaFire --out=<scratch> --browser`; worker requests at least 1.5 s apart, one page load per `executeInWebView`) recorded search (two pages, 30 hits each), details of "Highschool ONIMAI" and 86 chapters, and the same invocation replayed it offline with identical results. The browser capture keeps only `mangafire.to` and the site's asset host `s.mfcdn.nl`, never `/cdn-cgi/` (Cloudflare bot-management scripts and beacons whose URLs carry ray IDs and per-client tokens), then pruned to what the offline replay served: 5 exchanges (the site's four script and style assets and its logo) in `fixtures/source_captures/paperback/mangafire/browser/`. The documents the source itself generates for `loadData` are seen by the recorder but never requested in replay, so they are dropped. The Paperback suite and the CLI composition test replay search, details and chapters through the real helper offline; requests to the omitted hosts fail closed and the page still signs.
- **Tachi (all.mangafire 1.6.38): replay passed; browser path not exercised live.** A live run of the Tachi capture tool on 2026-11-21 (JAR path live, APK path replayed from it) returned 200 for all three requests, with no WAF challenge and no `cf-mitigated`: search (50 hits), details and 86 chapters, identical on both paths. The extension's WebView solver (`assets/solver.html`) runs only on a WAF challenge, so it stays proven only against the synthetic replay fixture (`mangafire_solver_replay_test.dart`). The new scratch capture was not committed; the committed one still replays.
- **Aidoku (multi.mangafire v8): no browser path.** Its compiled import list holds only `net`, `std`, `env`, `html` and `defaults` (no `js` or WebView module), and its HTTP-only replay test passes.

**MangaFire (AE11), macOS (U8 macOS lane).** The same: the Tachi MangaFire captures need no browser, and Paperback 0.9 MangaFire reaches the real WKWebView helper through the composition and fails inside the page with the same VRF capture timeout (`receipts/macos-paperback-executeinwebview-helper.json`). Two helper bugs surfaced on the way and are fixed: the captured `/home` page's meta refresh to a blocked URL cancelled the evaluation although the document never changed, and WebKit's hidden-page timer throttling stretched the page's 10 s timeout past the operation deadline. Without a replace tier, a WKWebView live recording would also need a proxy-based recorder, and the browser capture replay needs the replace tier too, so the committed Windows browser capture cannot be replayed there: the CLI test keeps the VRF-timeout expectation on WebKit. The cell stays **open** on macOS. Not run on Linux.

## Desktop packaging (U8)

`scripts/package_cli.dart` builds the package for the host it runs on; `scripts/smoke_packaged_cli.dart` checks it. Layout (`build/package/<os>-<arch>/`, installed unchanged by the Windows installer):

| Path | Contents |
|---|---|
| `bin/` | the CLI executable; it is also the Paperback worker (`__paperback-worker`) and the runtime self-check (`__runtime-check`) |
| `lib/` | native code assets from `dart build cli` (QuickJS-ng, wasm3, SQLite, and the jsoup backend: the Rust scraper on Windows and Linux, SwiftSoup with `objective_c` on macOS) |
| `runtime/tachi/` | the JVM worker (`installDist` `lib/`) and `tachi-runtime.json`, whose `java` is `../jre/bin/java` |
| `runtime/jre/` | Amazon Corretto 21.0.13.1.2 jlinked from the archive pinned in `tools/tachi-source-runner/runtime/jre-pins.json` (URL and SHA-256 per OS/arch; downloaded once into the git-ignored `build/runtime-cache/`; never committed). Modules: jdeps over the worker plus what extension code commonly reaches (charsets, locale data, EC TLS, zipfs, management, naming, sql, desktop) |
| `runtime/desktop_webview/` | the helper (`cargo build --locked --release`) and its `runtime-artifacts.json` |
| `runtime/runtime-manifest.json` | host commit, JRE pin and version, and every shipped file's SHA-256 |
| `licenses/` | the project licence, `NOTICE.md`, the worker's `THIRD_PARTY.md`, QuickJS-ng and wasm3 licences, the Paperback host library's licences, and, for the helper and (where bundled) the scraper bridge, every crate linked for the host with its declared licence (`<tree>-crates.txt`, from `cargo metadata --filter-platform`) and its licence texts under `rust/<tree>/<crate>-<version>/` (the crate's own files; canonical MIT/Apache-2.0/MPL-2.0 texts from `scripts/licenses/` for the few crates that publish none; this repository's licence for its own crates). The smoke check fails when a listed crate has no text. The JRE's own `legal/` stays inside `runtime/jre/` |

No extension, repository or source artifact is bundled; `package_cli.dart` fails if a fixture or `tachiyomi-*` artifact is found in the output.

**WebView prerequisites** (documented, not bundled): Windows needs the WebView2 Runtime (preinstalled on Windows 11; the Evergreen Bootstrapper installs it elsewhere); Linux needs WebKitGTK 4.1 (`libwebkit2gtk-4.1-0`) and a display; macOS uses the system WKWebView.

**Windows results (2026-11-21, Windows 11 Pro 26300, WebView2 157.0.4341.60).** Package 96 MB, 225 files. The smoke test passed every check: copied into a path with spaces; manifest hashes and licences; no fixture shipped; no `java`, `dart`, `flutter`, `gradle`, `cargo`, `rustc` or `node` on the scrubbed PATH (JAVA_HOME and TACHI_JAVA_HOME removed); `--help`; the bundled JRE reports 21.0.13.1; `__runtime-check` started the JVM worker (protocol 1.3, on the bundled JRE), the Paperback worker (protocol 1.3, QuickJS loaded) and the helper (offline session, local HTML evaluated); closing left none of the three processes; killing the CLI mid-session left none either (each exits when its stdin closes; no WebView2 child of the helper was still terminating). Receipt: `docs/validation/source-runners/desktop/receipts/windows-package-smoke.json`. The replayed Tachi loader suite and the CLI integration and six-direction tests also passed with `TACHI_JAVA_HOME` set to the jlinked JRE.

**JRE floor.** The worker refuses a JRE below 21.0.13.1 (exit code 3, `below the security floor` on stderr): the Kotlin unit test checks the comparison, and `packages/tachi_plugin_loader/test/jre_floor_test.dart` launches the installed worker with a real older JRE (`TACHI_BELOW_FLOOR_JAVA_HOME`, or `JAVA_HOME` when it is older; here Liberica 21.0.4) and then the same worker on the floor JRE.

**macOS results (2026-11-21, macOS 27.0 build 26A428, Apple M1, arm64).** Package 98 MB, 192 files, 38 Mach-O files. `package_cli.dart` changes for macOS: the pinned Corretto JDK is fetched first and builds the JVM worker when `TACHI_JAVA_HOME` is unset (this Mac had no JDK 21 at the floor; `JAVA_HOME` is no longer a fallback because it may be any version); every Mach-O file's signature is verified, and only a file that fails would be signed ad hoc (`codesign -s -`; none needed it: the CLI, dylibs and helper carry linker ad-hoc signatures, the JRE keeps Amazon's); quarantine attributes are removed (none were present: nothing is downloaded through a quarantining app); the licences of the libraries `dart build cli` bundles on macOS are shipped (SwiftSoup, swift-atomics, LRUCache from the swiftsoup hook's SPM checkouts; `objective_c` from its pub package), `NOTICE.md` lists only the libraries present, and a missing licence source now fails the build. No Developer ID signing or notarization: the package runs locally, and a quarantined copy (downloaded through a browser) would need `xattr -dr com.apple.quarantine` or signing and notarization, which belong to a distribution lane. The smoke test passed every check: path with spaces; manifest hashes and licences; every Mach-O signature valid and nothing quarantined; no `dart`, `flutter`, `gradle`, `cargo`, `rustc` or `node` on the scrubbed PATH, and `java` resolves only to macOS's `/usr/bin/java` launcher stub (an OS file, recorded as `osLauncherStubs`; the runtime check shows the JVM worker ran on `<package>/runtime/jre/bin/java`); `--help`; JRE 21.0.13.1; `__runtime-check` started the JVM worker (protocol 1.3), the Paperback worker (protocol 1.3) and the helper (WKWebView 22625.1.29.11.27, offline session, local HTML evaluated); closing left none of the three; killing the CLI mid-session left none, and the WebKit XPC process the helper started was gone too (WebKit's XPC services belong to launchd, so the check compares them before and during the run). Receipt: `docs/validation/source-runners/desktop/receipts/macos-package-smoke.json`.

**Not done:** Linux packages were never built or smoke-tested (the CI job is wired and non-gating); macOS x64 was not built; the installer was not compiled locally (Inno Setup is not installed here; CI compiles it); the Windows package is unsigned and the macOS package is only ad-hoc signed.

## Security hardening (M1 review)

Fixes from the M1 security review, with where each is tested:

- **Development layouts (M1).** See *Desktop browser join*: only a source run or `MANGA_BACKUP_CONVERTER_DEV_ROOT` uses `packages/desktop_webview/build/helper/` and the Tachi `installDist`, never above the checkout root (`test/commands/desktop_runtime_test.dart`, `desktop_worker_test.dart`, and the packaged smoke check *a development layout planted in a parent folder is not used*). Linux and macOS release archives are the packaged bundle; packaging and its smoke test gate tag builds. Those jobs have not yet passed in CI, so the next tag can fail there until they do.
- **Gradle (M2).** Both wrappers pin `distributionSha256Sum`; the worker build verifies every artifact against `tools/tachi-source-runner/gradle/verification-metadata.xml` (SHA-256; no PGP keyring yet). The Android app build has the wrapper checksum only (see the worker README for why).
- **Size bounds (L2), each derived from an existing limit:** worker/helper diagnostic lines (`RedactingLineSink`, the helper's stderr) are held up to the protocol frame cap (KTD4, 16 MiB: nothing larger is a valid record from the same peer); a longer line is cut back to its last whitespace and to before any partial registered secret, marked `[line truncated]`, and its rest dropped. `JsContext.toDart` spends a unit budget equal to the runtime's KTD25 memory limit (one unit per array element, object entry, string code unit or byte, per visit; an array's length is paid before reading), which no tree-shaped value the heap holds can exceed, so only sparse arrays and shared-node graphs fail (`JsConversionBudgetExceeded`). Paperback response bodies are streamed against the source's KTD25 memory limit (half of it for the runtime HTTP host, which materialises `body` and `text`); the largest committed capture body (~1 MiB) fits the benchmarked limits.
- **Offline and replay egress (L3).** An offline WebView2 helper adds `--no-proxy-server` (a loopback system proxy is excluded from the resolver rules and would otherwise fetch any host) and fails a held request whose replacement or block response cannot be set. A `--replay` JVM worker installs `ReplayEgressGuard` first: every non-loopback destination of `HttpURLConnection`, `java.net.http` and raw sockets goes to a loopback proxy that closes the connection, and `jdk.net.hosts.file` points at an empty file (`SecurityHardeningTest`).
- **Settings secrets (L4).** See the *Settings* paragraph above.
- **Artifacts, captures, helper environment, CI (L5).** The worker loads a private snapshot of the staged JAR whose copied bytes it hashed; `verifyApk` rejects duplicate entry names; captures may only name `bodies/<sha256>.bin` (Kotlin and Dart); the helper gets a scrubbed environment (workers' allowlist plus profile, display and session-bus variables; no `WEBVIEW2_*`, proxy or loader variables); every GitHub Action is pinned to a commit SHA and Dependabot updates them. The Corretto archive is still trusted on first download (SHA-256 pinned in `jre-pins.json`); verifying Amazon's GPG signature in `package_cli.dart` is a follow-up.
- **WebView channel key (L1).** The envelopes that carry the session key are built by a private quoting function (no `JSON.stringify`, nothing reachable through a prototype); WebKitGTK injects every start script into the top frame only (page-start scripts included); macOS checks the posting frame's `securityOrigin`. The desktop suite's sandboxed cross-origin frame read the key before the change. Linux and macOS helper changes are not compile-checked on the Windows host.

## Paperback host (`packages/paperback_plugin_loader`, U6)

The Paperback Dart worker hosts original Paperback bundles, one QuickJS runtime per bundle (KTD2), through two
explicit host adapters (KTD6): `paperback-0.8` and `paperback-0.9`. It speaks protocol 1.3 on stdio, answering an
older supervisor with its lower minor; the in-app worker isolate (iOS, Android) runs the same worker. The CLI runs
it as a hidden subcommand of its own executable (`__paperback-worker`); `bin/paperback_source_worker.dart` is the
standalone entry point.

### Repositories, entry points and qualification sources

Pinned under `fixtures/source_captures/paperback/<repo>/` (`versioning.json`, bundles, and `artifacts.json` with
source URL, SHA-256, size, retrieval time and licence). Retrieved 2026-11-21.

| Repository | Catalog | `builtWith.types` | API family | Licence |
|---|---|---|---|---|
| Inkdex `https://inkdex.github.io/extensions/0.9/stable/` | 68 sources | `1.0.0-alpha.94` | 0.9 | GPL-3.0 (source repos `inkdex/general-extensions`); the catalog repo declares none |
| GabrielCWT `https://gabrielcwt.github.io/gabe-extensions/0.8/` | 2 sources | `0.8.0-alpha.47` | 0.8 | none declared (flagged) |
| numby `https://g2asell2019.github.io/numby-extensions/0.8/` | 2 sources | `0.8.7` | 0.8 | GPL-3.0 |
| Netsky `https://thenetsky.github.io/netskys-extensions/0.8/` | 14 sources (catalog only) | `0.8.7` | 0.8 | see repository |
| Paperback default `https://paperback-ios.github.io/extensions-default/0.8/` | 1 source (catalog only) | `0.8.0-alpha.47` | 0.8 | see repository |
| Netsky community `https://thenetsky.github.io/community-extensions/0.8/` | 5 sources | `0.8.7` | 0.8 | GPL-3.0 |
| kittycatgit `https://paperback.samipmainali.dev/kitty-0.8/` (source repo `kittycatgit/kitty-extensions-0.8`) | 8 sources | `0.8.7` | 0.8 | no licence file; source headers say GPL-3.0-or-later |

- **API family** comes from `builtWith.types`: `0.8.x` is the 0.8 API, `1.0.0-alpha.x` is the app's 0.9 API.
  Any other version is refused as `unsupported-api`.
- **Installation entry points** were checked against repository trees, not assumed. 0.9 repositories publish
  `<repo>/<id>/index.js`, a rolldown bundle starting `var source=`. 0.8 toolchain `0.8.0-alpha.47` publishes
  byte-identical `<id>/source.js` and `<id>/index.js` (browserify UMD that sets `Sources`). Toolchain `0.8.7`
  publishes only `<id>/source.js` (esbuild, `this.Sources = ...`). The 0.8 host therefore installs `source.js`.
- **Cheerio:** 0.8.0-alpha.47 bundles expect the host to inject Cheerio (`new Sources[id](cheerio)`); 0.8.7 and
  0.9 bundles carry their own copy.

| Qualification source | `paperback-0.8` | `paperback-0.9` |
|---|---|---|
| MangaDex | Netsky community `MangaDex` 3.0.6 (GPL-3.0): search (2 hits, first the Onimai title), next page (empty), details, 223 chapters (replayed). Chapter IDs are identical to the 0.9 bundle's | Inkdex `MangaDex` 1.0.0-alpha.28: search, details, 223 chapters (replayed) |
| WeebCentral | GabrielCWT `WeebCentral` 1.1.1 (host-injected Cheerio) and numby `WeebCentral` 2.0.12 (bundled Cheerio): search, details, 114 chapters each (replayed) | Inkdex `WeebCentral` 1.0.0-alpha.25: search, details, 114 chapters (replayed) |
| MangaFire | **Substitute:** no surveyed 0.8 catalog lists MangaFire, so the cell is kittycatgit `Mangahub` 4.0.0, a Cloudflare-fronted site (`CLOUDFLARE_BYPASS_REQUIRED`). Search, details of the Onimai title, 176 chapters (replayed); Cloudflare did not challenge either capture session. The challenge and bypass paths are proven with synthetic challenge answers and a scripted `BrowserPort` (below) | Inkdex `MangaFire` 1.0.0-alpha.24 signs every API request through `executeInWebView` (a VRF capture in the page), so search and details need a browser. Without one they fail as `capability-unavailable(executeInWebView)`. Through a scripted `BrowserPort` over worker reverse requests the call completes and its result reaches the source. U8: through the CLI composition the call reaches the real desktop helper (a session for MangaFire's own identity, the page loaded with its base URL); offline replay blocks the page's site scripts, which no capture holds, so the VRF capture times out inside the page (`source-error`, not a missing capability). **Open:** completing it needs a live browser capture run (none recorded; see *Desktop browser join*) |

Chapter identities are the site's own and identical across families: WeebCentral's first chapter is
`01KWM07QYFJMAP46S1A3ZVDWYG` in all three bundles.

**MangaDex 0.8 cell.** The cell first used neihc1002 `Mangadex` 1.0.0, an unlicensed bundle configured for
Vietnamese that returned no search hit for Onimai. It was replaced on 2026-11-21 by Netsky community `MangaDex`
3.0.6, and the neihc1002 repository was removed from the fixtures (no test used it any more). The community bundle
sets only a `referer`, so the host sends `Paperback-iOS`; its single capture session was not challenged. The
first neihc1002 run had met MangaDex's edge challenge (`302` to `mangadex.org/edge/challenge`) while its
interceptor echoed `getDefaultUserAgent()`, a mobile Safari string; a re-run without that user agent was not
challenged. That is why the 0.8 adapter sends no user agent when a source echoes `getDefaultUserAgent()` (a
missing one becomes `Paperback-iOS`, a source-chosen one is sent unchanged). `getDefaultUserAgent()` still reports
the browser string in both families.

**Mangahub (0.8 Cloudflare substitute).** kittycatgit `Mangahub` 4.0.0 talks to `https://mangahub.io/graphql`.
Every query carries an access token twice, as the `mhub_access` cookie and the `x-mhub-access` header, and the API
rejects a request where they differ. The source mints a token until the site sets one, then uses the site's. Its
interceptor echoes `getDefaultUserAgent()`, throws `Error("CLOUDFLARE BYPASS ERROR: …")` on a challenge page
(`cf-mitigated: challenge`, or 403/503 with challenge markers), and reads `set-cookie` from `response.headers`.
The captures search `Oshimai`, a word of Mangahub's title "Onii-Chan wa Oshimai" (`Onimai` was not tried). The 11
hits start with another title (`oshimai`), so the Mangahub bundle names its hit (`PinnedBundle.targetMangaId`) and
the scenario fetches `onii-chan-wa-oshimai` by ID, not the first hit: "Onii-Chan wa Oshimai", Nekotoufu, ongoing,
176 chapters (chapters 1–117 and 59 fractional entries, a few titled `<deleted>`), the first being chapter
`117`. Both capture sessions (2026-11-21, 3 requests each, at least 1.5 s apart) were not challenged. Replay keys
ignore request headers and the committed capture holds no `Set-Cookie`, so in replay the source runs on its own
minted token. The Mangahub scenario now allow-lists `mhub_access` with `redact`
(`captureSetCookies` in `test/support/paperback_scenarios.dart`, passed to the worker as
`--record-cookie=mhub_access:redact`), so the next recording keeps that the site set it, with the value
`redacted`. The committed capture was not edited: it predates the allow-list, and which answer set the cookie was
never recorded, so the replay test still adds it to the first answer by hand.

Tests (`cloudflare08_test.dart` with handwritten bundles, and the Mangahub group in `source_execution_test.dart`
with the real bundle over the committed capture) show:

- a challenge without a browser fails as `interaction-required`, both when the bundle throws its Cloudflare error
  and when it just fails to parse the challenge page (the host flags the challenge for the operation);
- with the intent, a browser channel and `getCloudflareBypassRequestAsync()`, the host loads the bypass request in
  a browser session (headers kept, an echoed default user agent dropped so the browser keeps its own), seeds the
  cookies it holds for that domain, waits for the challenge to clear (8 s on its own, then `host.browser.show`),
  reads back the session's cookies and `navigator.userAgent`, closes the session, and retries the operation once.
  A scripted port that "solves" the challenge lets Mangahub's search, details and chapters complete against a
  synthetic gate that challenges until a request carries `cf_clearance` and the browser's user agent;
- the clearance stays for the runtime: later operations need no browser;
- an unsolved challenge, no display, or a retry challenged again ends as `interaction-required` with one browser
  session and at most one retry; without the intent the browser is never used;
- the same holds on the desktop path (provider, supervisor, worker reverse requests): a challenged search ends the
  scenario as `interaction-required`, and with a solving port the scenario completes, `show` being served under
  the supervisor's interaction timeout;
- with a `Set-Cookie: mhub_access=…` added to the first replayed answer, every request carries exactly one
  `mhub_access` cookie equal to its `x-mhub-access` header, and the site's token replaces the minted one; after a
  bypass whose browser also holds an `mhub_access`, the request's own token still wins.

`show` completes when the user closes the window (protocol 1.3); its bound fails as `interaction-required`. The
engine deadline is paused while `show` is pending: the worker pauses its QuickJS budget between the
supervisor's `interaction.started` and `interaction.ended` events (an older supervisor sends none, so the host
then pauses around its own `show`), and an in-process `InProcessBrowserChannel` pauses around its own
`showBrowserInteraction`. The operation keeps the budget it had left when the window opened. Tests: a user slower
than the deadline (worker events in `runtime/worker_test.dart` and in the worker isolate, in-process `show` in
`cloudflare08_test.dart`, the runtime in `runtime/deadline_pause_test.dart`), each with a control that times out
without the pause, and the remaining budget still running out after resume.

Not yet proven: a real challenge solved in a real browser (U8), and whether the site accepts the browser's user
agent when the engine's client hints disagree.

### Trust and admission (KTD6)

Paperback repositories are unsigned, so the trust decision binds a bundle's exact bytes and API family: the
fingerprint is `paperback-0.9:sha256:<hex>` under the per-bundle key `<repository>#<sourceId>`, so two bundles from
one repository never overwrite each other's decision. The CLI answers it with the core `RepositoryTrustGate`
(`admit('paperback', key, fingerprint)`); qualification runs use the pinned digests. Every check runs before any
JavaScript:

1. `PaperbackSourceProvider.admit` computes the digest, requires the bundle's shape to declare the catalog's
   family, asks for the trust decision, then stages the bytes in the `ArtifactCache` under a profile whose host
   compatibility is the family.
2. Cache hits re-hash and re-ask trust. This covers `cached` and the CLI's `CachingPluginLoader`, which re-enters
   `loadPluginFromBytes`. Changed cached bytes present a changed fingerprint (asked again, refusable) or are
   dropped.
3. The supervisor re-hashes the leased file before `package.load`, which carries the trusted family as
   `apiFamily` (protocol 1.3).
4. The worker re-reads and re-hashes the staged file, takes the family from `apiFamily` (from the artifact kind,
   `paperback-bundle-0.8` or `-0.9`, for an older supervisor; a kind naming another family is refused), checks the
   bundle shape, and only then installs host globals.

A failed trust decision is a `TrustFailure` (`artifact-incompatible` with `trust`, protocol 1.3): `changed` for
bytes that differ from the admitted digest (the worker's re-hash), `refused` when the trust decision answers no,
and `first-seen` for an artifact the provider never admitted in this run. The CLI answers through
`RepositoryTrustGate.check` (U8), which names the reason: `refused` when the user said no, and, when nobody could be
asked (`TrustDecision.unanswered`, an unattended run), `first-seen` or `changed` from the remembered fingerprint. A
host that passes only the yes/no `trust` callback still gets `refused`. Family and shape mismatches stay plain `artifact-incompatible`. Failures are rebuilt with
`SourceFailure.fromJson`, so the reason survives the worker, the supervisor and the bundle glue.

### Host adapters

Host behaviour is JavaScript in `assets/` (`prelude.js`, `api08.js`, `api09.js`, `ops.js`), compiled into the
worker by `tool/embed_js_assets.dart`. Only primitives cross into Dart: one HTTP exchange, a timer wake-up, a
browser call, and synchronous codecs (UTF-8, Latin-1, UTF-16, base64, MD5). Semantics follow each toolchain's
reference runtime, `@paperback/runtime-polyfills` 0.8.7 and 1.0.0-alpha.94 (MIT).

| Capability | 0.8 (`App`) | 0.9 (`Application`) |
|---|---|---|
| Requests | `createRequestManager().schedule`: `interceptRequest`, then `url + param`, then `interceptResponse` on the packed `Response` (`data` as UTF-8, `rawData` as bytes, `headers['set-cookie']` as an array, as axios reports it). A missing user agent becomes `Paperback-iOS`; an echoed `getDefaultUserAgent()` is not sent, except on a domain cleared through the browser, where a missing or echoed user agent becomes the browser's (the clearance is bound to it). Object bodies are form-encoded when the content type says so, otherwise JSON. A non-2xx status resolves, since sources check `status` | `scheduleRequest` returns `[Response, ArrayBuffer]`. Request interceptors run in registration order, each given the previous result; response interceptors run in reverse order. Object bodies are sent as multipart form data |
| Redirects | followed hop by hop (at most 5) | followed hop by hop through `setRedirectHandler`, which may replace or cancel the next hop |
| Cookies | one value per name: a browser clearance's cookies, then an in-memory manager cookie store (`cookieStore`, fed by every hop's `Set-Cookie`), then `request.cookies`, which win (a source that pairs a cookie with a header never sends a stale second copy) | `request.cookies` becomes one `Cookie` header; `Set-Cookie` becomes `response.cookies`; cookies set by a redirect hop travel with the next hop |
| Rate limits | `requestsPerSecond` spacing on JS timers | the bundles' own `BasicRateLimiter` over `Application.sleep` |
| Timers | `setTimeout`, `setInterval`, `clear*`, `queueMicrotask`. State lives in JS and the host call is a re-armable wake-up, so a sleep parked at the end of one operation settles in the next | same |
| State | `createSourceStateManager` (`store`, `retrieve`, `keychain`) | `get/setState`, `get/setSecureState`, `resetAllState` |
| Settings | protocol 1.1 settings seed state per source (`SettingsPayload.valuesFor` / `secretsFor`): string sets as arrays, source scopes override package values. Secrets seed only the keychain/secure state, in memory (KTD9) | same |
| Parser | pinned Cheerio 1.0.0-rc.12 injected (the toolchain's `^1.0.0-rc.12`), `entities` 4.5.0 | the bundles' own Cheerio; `decodeHTMLEntities` is `entities.decodeHTMLStrict` |
| Browser | Cloudflare only: a challenge (bundle error `CLOUDFLARE BYPASS ERROR…`, or a 403/503 challenge page or `cf-mitigated: challenge` seen by the operation) is `interaction-required`. With `SourceIntents.CLOUDFLARE_BYPASS_REQUIRED` and a browser channel, `getCloudflareBypassRequestAsync()` runs in a source-scoped session (host cookies seeded, cookies and `navigator.userAgent` read back, storage deleted), the clearance is kept for the runtime, and the operation is retried once | `executeInWebView`: open a source-scoped session, seed the context's cookies, `loadData(html, baseUrl)`, run `inject` as an async function, return its result and the session's cookies, close (storage deleted). A 1.3 `evaluate` awaits the injected promise and replies with the result; an older engine replies early, so the result is also posted on the 1.1 message channel, and the first to arrive wins. A throwing script (`scriptError`) rejects the call at once with its message |
| Other members | `create*` factories return their argument; `createDUI*` rows carry `type` | any other `Application` member exists but throws a named `capability-unavailable` |
| Not provided | Node `fs` and process, QuickJS `std`/`os` | same; WebCrypto (`crypto_digest` and friends) is a named capability failure |

The pinned host library (`assets/paperback_host_lib.js`, 336 KiB) is built from `tool/host_lib/` with esbuild 0.24.0;
the lockfile is committed. npm was used once, in a temporary directory, to produce it. Bundled licences: cheerio
1.0.0-rc.12, htmlparser2 8.0.2, parse5 7.3.0, parse5-htmlparser2-tree-adapter 7.1.0 and dom-serializer 2.0.0 (MIT);
cheerio-select 2.1.0, css-select 5.2.2, css-what 6.2.2, domelementtype 2.3.0, domhandler 5.0.3, domutils 3.2.2,
entities 4.5.0 and 6.0.1 (the copy parse5 nests) and nth-check 2.1.1 (BSD-2-Clause); boolbase 1.0.0 (ISC). Their
licence texts ship beside the bundle in `assets/paperback_host_lib.LICENSES.txt`.

Cheerio rc.12 does not resolve `prop("href")` against a `baseURI` (that arrived in 1.0.0); 0.8 sources build
absolute URLs themselves, and a test pins that behaviour.

### Captures

`fixtures/source_captures/paperback/{mangadex,weebcentral,mangafire,mangahub}/` were recorded on 2026-11-21 by
`tool/capture_paperback_sources.dart` through the worker's `--record` mode. One worker session per site ran every
pinned bundle of that site, from both families, for the fixed query `Onimai` (Mangahub: `Oshimai`, below), with requests at least 1.5 s apart.
`scenario.json` beside each capture records what each bundle returned. Bodies were sanitised
(`tool/sanitize_captures.dart`): MangaDex's challenge page embedded a token carrying the recording client's network
address, and Cloudflare snippets carried ray IDs. Tests and the e2e suite replay with `--replay`; a request without
a capture fails the operation loudly, even when the source catches the error.

`mangahub/` was first recorded on 2026-11-21 in one session (3 exchanges, JSON API responses) whose details and
chapters were those of the first hit, `oshimai`. After the scenario was changed to select `onii-chan-wa-oshimai`, a
second session (`--only=kittycatgit-0.8/Mangahub --out=<temp>`, then `--merge=<temp>`; 3 requests, no challenge)
re-recorded the search (an identical body) and added that title's details and chapters, and `--prune` deleted the 2
`oshimai` exchanges. The sanitiser found nothing to strip in either session, and no token, address or ray ID is in
the bodies. The sanitiser now also blanks Cloudflare interstitial
tokens (`cRay`, `__cf_chl_*`, and the opaque `_cf_chl_opt` values) in case a later session is challenged.

The MangaDex 0.8 cell's exchanges come from second sessions that ran one bundle each
(`capture_paperback_sources.dart mangadex --only=<repo>/<id> --out=<temp>`, then `--merge=<temp>`). The
community `MangaDex` 3.0.6 session (2026-11-21, 4 requests, no challenge) was merged in; it re-requested the
details exchange the Inkdex bundle shares, whose body was replaced (the Inkdex assertions still hold). The retired
neihc1002 bundle's run was then removed from `scenario.json` (`--drop`), and `--prune` replayed the remaining
bundles offline and deleted the 2 exchanges no bundle requests any more. `capture.json` notes each step.

### Limits (KTD25)

`benchmark/bundle_benchmark.dart` measures the pinned bundles on the replayed captures: each bundle's load, and
search and details for the four bundles whose captures complete them. It runs under `flutter test` and as an AOT
executable (`benchmark/bundle_benchmark_main.dart`), because the worker ships AOT. Rate-limiter sleeps are made
instant for CPU timing (they are host waits). Reference device: Windows 11 x64, MSVC `/O2` QuickJS-ng 0.18.0,
16 logical processors, 128 GiB. Results: `benchmark/results/2026-11-21-windows-x64-bundles-{aot,jit}.json`.
macOS arm64 (Apple M1, clang, loaded machine; U8 macOS lane): `benchmark/results/2026-11-21-macos-arm64-bundles-{aot,jit}.json`
and `2026-11-21-macos-arm64.json`, summarised in `benchmark/README.md`. Same heap needs, about 1 KB of native stack per JS
call (MSVC: 4.8 KB, so about 523 frames fit the AOT worker's half-stack ceiling instead of 108), and 2.6-5× faster. The
reference device stays the Windows machine: each device sizes itself at worker start-up, and the slower reference keeps the
deadline basis conservative.

| AOT workload | Median | p95 | Minimal heap | Minimal stack |
|---|---|---|---|---|
| MangaDex 0.9 load / search / details | 160 / 2.9 / 45 ms | 202 / 3.7 / 46 ms | 5.5 / 5.5 / 9.7 MB | 67 / 90 / 71 KB |
| WeebCentral 0.9 load / search / details | 119 / 29 / 1,143 ms | 134 / 39 / 1,701 ms | 4.6 / 4.6 / 6.5 MB | 67 / 212 / 212 KB |
| WeebCentral 0.8 (GabrielCWT) load / search / details | 90 / 52 / 1,205 ms | 112 / 79 / 2,389 ms | 3.7 / 3.8 / 5.8 MB | 133 / 212 / 212 KB |
| WeebCentral 0.8 (numby) load / search / details | 683 / 83 / 1,152 ms | 1,118 / 176 / 1,856 ms | 6.3 / 6.4 / 7.5 MB | 71 / 212 / 212 KB |
| MangaDex 0.8 load (the retired neihc1002 bundle; the workload now loads community 3.0.6, not yet re-run), MangaFire 0.9 load | 62, 89 ms | 143, 117 ms | 3.6, 3.6 MB | 122, 67 KB |

- **Profile** (`paperbackBundleProfile`, replacing U5's synthetic one): peak heap 9.71 MB (MangaDex details mapping
  a 1 MB chapter feed), peak stack 217 KB (Cheerio and parse5 over WeebCentral pages), slowest operation 2.39 s
  (WeebCentral 0.8 details, p95), reference calibration 122 ms.
- **Sizing rule** (`quickjs-sizing-v2`: U5's formulas, policy factors unchanged at heap 2x, stack 2x, deadline
  4x, memory share 0.25, stack share 0.5, 50 slices per deadline). Derived on the reference device for one
  runtime: memory 19.4 MB, stack 434 KB (below the 522 KB cap), engine deadline 9.56 s plus the host-wait
  allowance, job slice 191 ms. The host-wait allowance (186 s) is 6 requests per operation (the most one
  qualification operation made, rounded up) at the host's 30 s request timeout, plus 1 s of rate-limiter sleep per
  request. It is the supervisor's policy, not a QuickJS property.
- **Deadline race.** The worker used to report the engine deadline as `operationDeadlineMs`, so an adopting
  supervisor timed operations out at the same instant the engine did and could kill a worker that was already
  stopping. The longest a single operation ran past its engine deadline (deadlines placed at 20 to 105 % of the
  operation) was 64.2 ms (WeebCentral 0.8 details); encoding the largest reply frame (MangaDex details, 223
  chapters) takes 2.5 ms more. The worker now takes `--deadline-headroom-ms` (that 66.6 ms tail, scaled by the
  device calibration, times 4: 267 ms on the reference device) and reports `operationDeadlineMs` = engine deadline
  + headroom, with both parts in the limit fields. The CLI uses the same headroom as its cancel grace.
- **Recursion (Windows MSVC).** The AOT worker thread has 1,044,208 bytes of stack; QuickJS uses 4,834 bytes per
  JS frame, so the 50 % stack share allows 108 frames. The real bundles need at most 217 KB, about 45 frames; with
  the 2x stack headroom, about 90 frames. That fits, so the qualification bundles do not need a larger-stack native
  thread. The margin over the headroomed need is only 1.2x: deeper HTML could exceed it, and fails as a
  stack-limit source error rather than a crash. JIT (`flutter_tester`) shows the same ceiling (107 frames).
- **JIT outliers.** The JIT run had multi-second stalls that AOT did not reproduce (WeebCentral 0.9 details p95
  10.1 s, one 5.75 s deadline overshoot). Their cause is unexplained (machine contention is suspected). The AOT
  figures size the shipped worker.
- **Not measured:** Clang targets (Android, Apple, Linux), slower reference devices, worker start-up to handshake
  (the CLI allows 30 s, an unmeasured policy value), and concurrency above one runtime.

## Android app composition (U14)

`AndroidSourceRuntimes` (`lib/src/features/conversion/application/conversion_composition_android.dart`) is
the Android branch of the app's composition root. It shares `LocalSourceRuntimes` with the iOS branch.

| Ecosystem | Backend | Admission | Runs in |
|---|---|---|---|
| Aidoku | `AndroidAidokuBackend` over the desktop `AidokuSourceProvider` | `libwasm3.so` and `libscraper_bridge.so` load | app process, one WASM isolate per source |
| Paperback | `isolatePaperbackLauncher`, plan from `planPaperbackIsolateWorker()` | `AndroidPaperbackBackend.checkNativeLibrary` (`libquickjs.so`) | app process, one worker isolate per conversion; `executeInWebView` on `AndroidWebViewBrowserPort` |
| Tachi | `AndroidTachiBackend` (`TachiRuntime`, APK artifacts only) | handshake of the service worker | `:source_runtime`, one worker per conversion, ended with it |

- **Configuration.** `AndroidConversionConfig.interactive` is required. When true, the Tachi worker gets
  `--interactive-challenges <interactionTimeout ms>` and the browser port may show interactions. Unattended runs
  pass false. `tachiWorkerArguments` carries test-only worker arguments (`--replay`, `--offline-browser`,
  `--limit`, `--challenge-once`); release builds refuse the debug-only ones, so production passes none.
- **No defaults.** The composition contains no repository, extension or settings. Starting it binds no service
  and starts no worker or isolate. The app's `main` does not start it, and no screen creates it yet.
- **Degraded browser.** If the browser port cannot start, Paperback runs without `executeInWebView` and
  `browserUnavailable` names the reason; the Aidoku and Tachi runtimes are unaffected.
- **Replay fails closed.** Tests block WebView networking through `ProxyController`, which needs the WebView
  feature `PROXY_OVERRIDE`. Where it is missing (the API 28 emulator image's WebView 69), the browser port
  refuses replay mode and the Tachi worker refuses `--offline-browser`. Cases that load pages then skip with that
  reason. Before U14, the service's hook only reported the missing override and carried on, so on that image
  service WebViews reached the network (U14 receipts, "API 28 network contact").
- **Lifecycle (KTD18).** One signal, `AndroidAppForeground` over the Kotlin `AppForegroundMonitor` (the Activity
  tracker the browser port's host already used: background after 700 ms without a started Activity; a visible
  `:source_runtime` challenge Activity counts as foreground; on the emulator a bound worker alone does not keep the app in the foreground, and a challenge on screen is not yet exercised), feeds the shared `BackgroundGate`
  (`source_runtime`) first and the browser port second. The gate wraps the Aidoku provider and both worker scopes
  (`WorkerSupervisor.gate`). While backgrounded, new calls fail `cancelled: app-backgrounded`; searches and
  details in flight answer the same at once and their late replies are dropped; prepare, load and settings calls
  already sent finish (interrupting them would leave the worker holding untracked state); cleanup and restart
  rehydration are never gated; no new worker starts. Sessions stay open and work resumes in the foreground. A job
  whose calls failed this way publishes nothing partial unless the user accepts the partial result. iOS uses the
  same gate class for Aidoku only.
- **Activity recreation and process death: journal resume is enough.** A destroyed `MainActivity` destroys the
  Flutter engine and with it the conversion; the journal resumes it at the next launch. There is no cached engine
  and no foreground service: keeping a job alive across recreation would need one, and the journal already
  avoids asking the user again for decisions already made.
- **Packaging.** `scripts/android_package_check.py` records the APK identity, SDK levels, signing identity and
  native library hashes, and fails on missing notices, missing runtime ABIs or extension/repository payload.
  `android/app/gradle.lockfile` locks the app's Gradle closure, except Flutter's engine artifacts. The Android
  host libraries' notices ship in `packages/source_runtime_android/notices/`.

Receipts and open items: `docs/validation/source-runners/android/README.md` (U14 section).
