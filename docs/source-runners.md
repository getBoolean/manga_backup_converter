# Source runners: compatibility inventory

What each source runner hosts, how, and where it stops. This file is updated by the unit that changes a
runner. Only the desktop Tachi worker (U3) is described so far.

## Desktop Tachi worker (`tools/tachi-source-runner`, U3)

One Kotlin/JVM process per conversion hosts every selected Tachi extension package (KTD1). It speaks
protocol v1, minor 1.2, on stdio (`packages/source_runtime/doc/protocol-v1.md`), answering an older
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
  `dex2jar-2.4.39+ctorfix.1+frames.1+ordered.1`, which is part of the prepared artifact's cache identity
  (`converterVersion` in the `artifact.prepare` reply, with host compatibility `tachi-host.1`).
- **Determinism.** Preparing the same APK always gives the same bytes, so a resumed conversion on the
  APK path keeps its session identity (the prepared digest). dex2jar's IR passes kept working sets in
  `HashMap`/`HashSet` keyed by identity-hashed IR objects, so register assignment changed between
  conversions in one JVM. Each conversion now loads dex2jar in a fresh class loader that rewrites those
  instantiations (constructors, `::new` handles, subclasses) to `LinkedHashMap`/`LinkedHashSet`, so
  iteration follows insertion order; frames are recomputed in sorted class order; entries are sorted and
  stamped with a fixed DOS time that does not depend on the JVM's time zone. `DeterministicConversionTest`
  checks MangaDex, Weeb Central and MangaFire twice in one JVM (other thread, other order) and in two
  worker processes started with different time zones, collectors and heaps. Prepared digests (converter
  `+ordered.1`, Corretto 21.0.13):
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
| Cloudflare | challenge pages are detected and reported `interaction-required` (`host.browser.show`); solving them through the browser port joins at U8 |

Settings: `SettingsPayload.values`/`secrets` seed every preference store the package opens.
`SettingsPayload.sources` (protocol 1.1) maps a `sourceId` to that source's own `values`/`secrets`, which
override the package-wide keys in the store the source opens (`source_<id>`). Keys are plain; no key
carries a store or source prefix. Values keep their JSON types (string, bool, int, and an array of
strings for a string set read through `getStringSet`).

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
- No CI job runs these JVM tests or the benchmark smoke yet.
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

## Desktop WebView capability matrix (`packages/desktop_webview`, U2)

One standalone helper (`desktop_webview_helper`, Rust over `wry` 0.57.3 / `tao` 0.37.3, pinned by
`helper/Cargo.lock`) per conversion, one WebView per source session. It is built by
`tool/build_helper.dart` (`cargo build --locked`) and located through `build/helper/runtime-artifacts.json`, which
records the SHA-256 the client verifies before launch. Protocol: `packages/desktop_webview/doc/helper-protocol.md`.

Status key: **pass** = ran and passed here; **compiled** = type-checks for the target, never run; **not run** =
neither built nor run. Windows cells come from the runs on 2026-11-20 (Windows 11, WebView2 157.0.4341.60,
`flutter test packages/desktop_webview/test --concurrency 1`: all passed, 0 skipped, against the protocol 1.2 contract
suite with no `knownFailures`). No macOS or Linux cell is an expected value.

| Behaviour | Windows (WebView2) | macOS (WKWebView) | Linux (WebKitGTK) |
|---|---|---|---|
| Build | pass (debug and `--release`; 739 KB standalone exe) | compiled (`cargo check --target aarch64-apple-darwin`, with `CC_aarch64_apple_darwin` set to LLVM clang for one objc2 build script), including the script message handler; x64 not checked | not run. `cargo check --target x86_64-unknown-linux-gnu` cannot run on the Windows host (the build scripts need the target's system libraries through pkg-config) |
| BrowserPort contract suite (protocol 1.2, `source_runtime_testing`) | pass: all 47 contract cases plus the `knownFailures` check, no known failures, no skips | not run | not run |
| Reported protocol 1.2 capabilities (`ready` `capabilities.browser`) | all eight available: `pageStartScripts`, `observeNavigations`, `observeSubresources`, `observeRequestHeaders`, `observeClientHints`, `observeRequestBodies`, `replaceRequests`, `scriptErrors` | available: `pageStartScripts`. Unavailable with WKWebView reasons: request observation (not wired), subresources, client hints (WebKit sends none), bodies, replacement, and `scriptErrors` (implemented engine-independently but not yet run on a Mac) | as macOS, with WebKitGTK reasons (`resource-load-started` not wired) |
| Page bridge transport | pass: `window.chrome.webview.postMessage` with `WebMessageReceived`, captured at document start under a non-identifier property; no wry IPC, so `ipc`, `chrome` and `webkit` all work as channel names | compiled: WebKit script message handler `dwvHost` (`WKScriptMessage.frameInfo` gives the posting frame) | written: script message handler `dwvHost` via `UserContentManager` (no frame identity; the page script's `location.origin` is used) |
| Script errors (`BrowserScriptError`) | pass: only a thrown script or rejected promise is `script-error`; a missing page bridge and a navigation away are separate codes that complete `null` | not run (reported unavailable) | not run (reported unavailable) |
| Request bodies | pass: `Request.Content` up to 1 MiB, stream rewound (the upload is unchanged); larger bodies omitted whole. Probed: string, JSON string, Blob (typed and untyped), FormData (with a file), URLSearchParams, Uint8Array and XHR bodies are all exposed; `Content` is absent only for bodiless requests (including a bodiless POST or PUT with a `Content-Type`), so no stream means no body and `bodyOmitted` is set only for an unreadable stream or the cap. MangaFire's `verify` sends a JSON string body. `redirect` is always `false` (not reported) | unavailable (no request observation) | unavailable (no request observation) |
| `mainFrame` | pass: a `document` request whose URL a top-level `NavigationStarting` announced (redirect hops included); a same-origin child frame loading the same URL is not | n/a | n/a |
| Failing a held request (invalid replacement, redirect status, throwing replacer) | pass: the helper rewrites the request to `http://127.0.0.1:1/…` (Chromium's restricted port), so the page gets a network error and the original request never reaches the server; a failed main-frame load settles as navigation-failed | n/a (no replace tier) | n/a (no replace tier) |
| Load page, evaluate (promises awaited), JSON results | pass | not run | not run |
| Message channel `window.<name>.postMessage(string)` | pass: document start of every later document, plus the current page on registration; non-strings dropped | not run | not run |
| Origin rule (cross-origin frame, `about:blank` dropped) | pass. The page script reports the frame's origin and `top.location.origin`, which a cross-origin frame cannot read; on WebView2 the engine's document URL must agree too. Same-origin direct child frames get the channel and are delivered (frame message events are forwarded); nested frames are not subscribed | not run (wry reports the posting frame's URL) | not run (posting frame's `location.origin` used) |
| Cookies read/write; domain and path derived from the URL | pass | not run | not run |
| Two sessions' cookie and web-storage isolation | pass (InPrivate profile per session) | not run (non-persistent `WKWebsiteDataStore` per WebView) | not run (ephemeral `WebContext` per WebView) |
| Non-persistent store / start-up wipe | pass. InPrivate; browsing data cleared and confirmed on close. A one-off probe hard-killed the helper mid-session: 0 rows in the profile's Cookies database (a script-set cookie and a server cookie with `Max-Age`), and no localStorage or IndexedDB on disk. A directory is renamed before deletion, so a directory still in use is left whole and reported by name. The helper runs in a kill-on-close job object (its effect on the other WebView2 processes was not compared against a run without it). After a kill, the WebView2 browser process can stay in termination for 1-110 s (measured; cause not identified), holding the directory. `wipe` retries within the client's `DesktopWebViewConfig.wipeRetry` budget; with no budget (the product default until U8 sizes one under KTD25), `wipeAllSourceData` right after a helper crash returns capability-unavailable until that process has exited. Tests: planted stale directory; a killed helper's directory removed by the next helper's start-up wipe once released; a directory held open is reported and left whole; one wipe that keeps retrying until the directory is released | not run (non-persistent; no data directory) | not run (ephemeral; no data directory) |
| Visible window, interaction timeout, user close | pass (window shown; timeout hides it; close completes; session close cancels) | not run | not run |
| Scheme policy in the helper (load, `loadData` base, cookies, redirects, new windows denied) | pass. A 302 to `file:` surfaces only as Chromium `REDIRECT_FAILED`, which the helper maps to the named policy failure (a redirect loop maps the same way) | not run (wry navigation handler) | not run (wry navigation handler) |
| User-agent override at runtime | pass | not run (`setCustomUserAgent`) | not run (`WebSettings`) |
| `loadData` with base URL (document URL and origin = base) | pass: navigate to the base URL and substitute the main-document response | not run (`loadHTMLString:baseURL:`) | not run (`load_html(html, base)`) |
| Page-start script injection | pass (`AddScriptToExecuteOnDocumentCreated`; runs at `readyState == "loading"`) | not run (`WKUserScript` at document start) | not run (`UserScript` at start) |
| Request observation with headers | pass: every request, with `mainFrame` and bodies; `sec-ch-ua*` visible in `WebResourceRequested` and at the server | unavailable (reported) | unavailable (reported; `resource-load-started` could add it) |
| Request replacement (KTD20 replace tier) | pass | capability-unavailable | capability-unavailable |
| Synchronous script-interface returns | unsupported | unsupported | unsupported |
| HTTP status code of a load | pass | unavailable (`null`) | unavailable (`null`) |
| Failed-navigation detection | pass | gap: only scheme refusals end a load; other failures end only through cancellation | `load-failed` wired, not run |
| Offline replay (helper blocks unanswered non-loopback requests) | pass: interception over all request source kinds (a cross-origin iframe request is seen and blocked). A `--host-resolver-rules` DNS backstop for traffic interception misses (WebSockets) is configured but not verified by a test | refuses to start with `--offline` (`offline-unsupported`) | refuses to start with `--offline` (`offline-unsupported`) |
| Typed failures: missing WebView runtime, no display | pass via `--simulate-fatal`, mapped to capability-unavailable; a real missing runtime is not reproduced | not run | `no-display` check written, not run |
| MangaFire browser-behaviour replay | pass (below), through `browserCaptureReplayReplacer` (method, URL and body hash); a desktop test serves a recorded POST body and answers a different body with 599 | not run | not run |

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

**Start-up wipe flake (bounded, cause unidentified).** `start-up wipe › the next helper removes a killed helper
directory` failed about 2 of 3 runs: the test started the next helper at once and then looped on `wipeAllSourceData`
for 20 s while the killed helper's WebView2 browser process was still terminating and holding the directory. The test
now waits until the directory can be released (bound 240 s), then checks that the next helper's start-up wipe removed
it. 10 consecutive runs on 2026-11-20 all passed (40-143 s per run including the debug build check; the longest
release wait was about 105 s). The test is bounded rather than deterministic: how long the OS takes to finish
terminating that process is outside the helper's control.

**Still needed before U8.** Build and run everything on a Mac (arm64 and x64) and on Linux with WebKitGTK 4.1: the
new script message handler transport (and an `ipc` channel), the bootstrap capture of the post function, and
thrown-script reporting (then report `scriptErrors` available). Linux has never been type-checked (the WebKitGTK
script message handler and the `javascriptcore-rs` dependency are written blind).
Enforce offline replay on WebKit: candidates are a blackhole proxy with a loopback exclusion, or WebKitGTK
`resource-load-started` plus a URI-scheme handler; none is decided. Detect failed navigations on WKWebView, which
needs a navigation-delegate hook wry does not expose. Re-check MangaFire on both WebKit engines. The WSL Ubuntu on
the Windows host has WSLg (`DISPLAY=:0`) but no `webkit2gtk-4.1`/`gtk+-3.0` development packages and no Rust;
nothing was installed.

## Paperback host (`packages/paperback_plugin_loader`, U6)

The Paperback Dart worker hosts original Paperback bundles, one QuickJS runtime per bundle (KTD2), through two
explicit host adapters (KTD6): `paperback-0.8` and `paperback-0.9`. It speaks protocol 1.1 on stdio. The CLI runs
it as a hidden subcommand of its own executable (`__paperback-worker`); `bin/paperback_source_worker.dart` is the
standalone entry point.

### Repositories, entry points and qualification sources

Pinned under `fixtures/source_captures/paperback/<repo>/` (`versioning.json`, bundles, and `artifacts.json` with
source URL, SHA-256, size, retrieval time and licence). Retrieved 2026-11-21.

| Repository | Catalog | `builtWith.types` | API family | Licence |
|---|---|---|---|---|
| Inkdex `https://inkdex.github.io/extensions/0.9/stable/` | 68 sources | `1.0.0-alpha.94` | 0.9 | GPL-3.0 (source repos `inkdex/general-extensions`); the catalog repo declares none |
| neihc1002 `https://neihc1002.github.io/paperback/0.8/` | 8 sources | `0.8.0-alpha.47` | 0.8 | none declared (flagged) |
| GabrielCWT `https://gabrielcwt.github.io/gabe-extensions/0.8/` | 2 sources | `0.8.0-alpha.47` | 0.8 | none declared (flagged) |
| numby `https://g2asell2019.github.io/numby-extensions/0.8/` | 2 sources | `0.8.7` | 0.8 | GPL-3.0 |
| Netsky `https://thenetsky.github.io/netskys-extensions/0.8/` | 14 sources (catalog only) | `0.8.7` | 0.8 | see repository |
| Paperback default `https://paperback-ios.github.io/extensions-default/0.8/` | 1 source (catalog only) | `0.8.0-alpha.47` | 0.8 | see repository |

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
| MangaDex | neihc1002 `Mangadex` 1.0.0 (third-party, configured for Vietnamese, unlicensed). Search and details ran, but MangaDex answered both with its edge browser challenge (`302` to `mangadex.org/edge/challenge`, POWBlock proof of work), and the source fails on the HTML. **Open cell** (below) | Inkdex `MangaDex` 1.0.0-alpha.28: search, details, 223 chapters (replayed) |
| WeebCentral | GabrielCWT `WeebCentral` 1.1.1 (host-injected Cheerio) and numby `WeebCentral` 2.0.12 (bundled Cheerio): search, details, 114 chapters each (replayed) | Inkdex `WeebCentral` 1.0.0-alpha.25: search, details, 114 chapters (replayed) |
| MangaFire | **Missing cell.** No surveyed 0.8 catalog lists MangaFire: Paperback default 0.8, Netsky 0.8, neihc1002 0.8, GabrielCWT 0.8 and numby 0.8 (SHA-256 in each `artifacts.json`). Not substituted; it needs an explicit coverage revision | Inkdex `MangaFire` 1.0.0-alpha.24 signs every API request through `executeInWebView` (a VRF capture in the page), so search and details need a browser. Without one they fail as `capability-unavailable(executeInWebView)`. Through a scripted `BrowserPort` over worker reverse requests the call completes and its result reaches the source. **Open until U8** (real desktop helper) |

Chapter identities are the site's own and identical across families: WeebCentral's first chapter is
`01KWM07QYFJMAP46S1A3ZVDWYG` in all three bundles.

**MangaDex 0.8 cell.** The 0.8 bundle sets `user-agent` to the host's `getDefaultUserAgent()` (a mobile Safari
string) and `referer: https://mangadex.org`. The 0.9 bundle also sends a `referer` but no user agent (so the
HTTP client's default), and was not challenged in the same
capture session. The likely trigger is a browser user agent on a client that runs no JavaScript; this is not
verified, because one capture run per source was authorised. Re-capture with a different `getDefaultUserAgent()`
once a second run is approved, or treat MangaDex's challenge as `interaction-required` at the U8 browser join.

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
3. The supervisor re-hashes the leased file before `package.load`.
4. The worker re-reads and re-hashes the staged file, checks the artifact kind (`paperback-bundle-0.8` or
   `-0.9`) and the bundle shape, and only then installs host globals.

### Host adapters

Host behaviour is JavaScript in `assets/` (`prelude.js`, `api08.js`, `api09.js`, `ops.js`), compiled into the
worker by `tool/embed_js_assets.dart`. Only primitives cross into Dart: one HTTP exchange, a timer wake-up, a
browser call, and synchronous codecs (UTF-8, Latin-1, UTF-16, base64, MD5). Semantics follow each toolchain's
reference runtime, `@paperback/runtime-polyfills` 0.8.7 and 1.0.0-alpha.94 (MIT).

| Capability | 0.8 (`App`) | 0.9 (`Application`) |
|---|---|---|
| Requests | `createRequestManager().schedule`: `interceptRequest`, then `url + param`, then `interceptResponse` on the packed `Response` (`data` as UTF-8, `rawData` as bytes). Object bodies are form-encoded when the content type says so, otherwise JSON. A non-2xx status resolves, since sources check `status` | `scheduleRequest` returns `[Response, ArrayBuffer]`. Request interceptors run in registration order, each given the previous result; response interceptors run in reverse order. Object bodies are sent as multipart form data |
| Redirects | followed hop by hop (at most 5) | followed hop by hop through `setRedirectHandler`, which may replace or cancel the next hop |
| Cookies | `request.cookies` plus an in-memory manager cookie store (`cookieStore`), fed by every hop's `Set-Cookie` | `request.cookies` becomes one `Cookie` header; `Set-Cookie` becomes `response.cookies`; cookies set by a redirect hop travel with the next hop |
| Rate limits | `requestsPerSecond` spacing on JS timers | the bundles' own `BasicRateLimiter` over `Application.sleep` |
| Timers | `setTimeout`, `setInterval`, `clear*`, `queueMicrotask`. State lives in JS and the host call is a re-armable wake-up, so a sleep parked at the end of one operation settles in the next | same |
| State | `createSourceStateManager` (`store`, `retrieve`, `keychain`) | `get/setState`, `get/setSecureState`, `resetAllState` |
| Settings | protocol 1.1 settings seed state per source: string sets as arrays, source scopes override package values. Secrets seed only the keychain/secure state, in memory (KTD9) | same |
| Parser | pinned Cheerio 1.0.0-rc.12 injected (the toolchain's `^1.0.0-rc.12`), `entities` 4.5.0 | the bundles' own Cheerio; `decodeHTMLEntities` is `entities.decodeHTMLStrict` |
| Browser | not part of the 0.8 API | `executeInWebView`: open a source-scoped session, seed the context's cookies, `loadData(html, baseUrl)`, run `inject` as an async function, return its result and the session's cookies, close (storage deleted). The result travels back on the 1.1 message channel, because `BrowserPort.evaluate` does not promise to await a promise |
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

`fixtures/source_captures/paperback/{mangadex,weebcentral,mangafire}/` were recorded on 2026-11-21 by
`tool/capture_paperback_sources.dart` through the worker's `--record` mode. One worker session per site ran every
pinned bundle of that site, from both families, for the fixed query `Onimai`, with requests at least 1.5 s apart.
`scenario.json` beside each capture records what each bundle returned. Bodies were sanitised
(`tool/sanitize_captures.dart`): MangaDex's challenge page embedded a token carrying the recording client's network
address, and Cloudflare snippets carried ray IDs. Tests and the e2e suite replay with `--replay`; a request without
a capture fails the operation loudly, even when the source catches the error.

### Limits (KTD25)

`benchmark/bundle_benchmark.dart` measures the pinned bundles on the replayed captures: each bundle's load, and
search and details for the four bundles whose captures complete them. It runs under `flutter test` and as an AOT
executable (`benchmark/bundle_benchmark_main.dart`), because the worker ships AOT. Rate-limiter sleeps are made
instant for CPU timing (they are host waits). Reference device: Windows 11 x64, MSVC `/O2` QuickJS-ng 0.18.0,
16 logical processors, 128 GiB. Results: `benchmark/results/2026-11-21-windows-x64-bundles-{aot,jit}.json`.

| AOT workload | Median | p95 | Minimal heap | Minimal stack |
|---|---|---|---|---|
| MangaDex 0.9 load / search / details | 160 / 2.9 / 45 ms | 202 / 3.7 / 46 ms | 5.5 / 5.5 / 9.7 MB | 67 / 90 / 71 KB |
| WeebCentral 0.9 load / search / details | 119 / 29 / 1,143 ms | 134 / 39 / 1,701 ms | 4.6 / 4.6 / 6.5 MB | 67 / 212 / 212 KB |
| WeebCentral 0.8 (GabrielCWT) load / search / details | 90 / 52 / 1,205 ms | 112 / 79 / 2,389 ms | 3.7 / 3.8 / 5.8 MB | 133 / 212 / 212 KB |
| WeebCentral 0.8 (numby) load / search / details | 683 / 83 / 1,152 ms | 1,118 / 176 / 1,856 ms | 6.3 / 6.4 / 7.5 MB | 71 / 212 / 212 KB |
| MangaDex 0.8 load, MangaFire 0.9 load | 62, 89 ms | 143, 117 ms | 3.6, 3.6 MB | 122, 67 KB |

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
