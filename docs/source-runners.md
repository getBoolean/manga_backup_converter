# Source runners: compatibility inventory

What each source runner hosts, how, and where it stops. This file is updated by the unit that changes a
runner. Only the desktop Tachi worker (U3) is described so far.

## Desktop Tachi worker (`tools/tachi-source-runner`, U3)

One Kotlin/JVM process per conversion hosts every selected Tachi extension package (KTD1). It speaks
protocol v1 on stdio (`packages/source_runtime/doc/protocol-v1.md`); logs go to stderr only.

### Runtime

- Java: Amazon Corretto 21; the worker refuses to start below 21.0.13 (KTD1 security floor).
- Gradle 9.8.1 wrapper, version catalog `gradle/libs.versions.toml`, every configuration locked in
  `gradle.lockfile`. Licences: `tools/tachi-source-runner/THIRD_PARTY.md`.
- Limits come from the committed KTD25 sizing rule (see `docs/validation/source-runners/desktop/`), or
  from explicit `--limit NAME=VALUE` overrides. Without either the worker refuses to start.

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
| APK | copy → SHA-256 check → apksig verification against the same trust identity → dex2jar 2.4.39 → host bytecode fixes → JAR (sorted entries, fixed timestamps) with all resources | loads |

- **Patching.** Published keiyoushi JARs need no Android bytecode patching. APKs do: R8 removes trivial
  constructors when dexing (`new X; invoke S.<init>` and super calls that skip the direct superclass),
  which the JVM verifier rejects. `ConstructorElisionFix` restores those constructors before translation
  (it cannot occur in verified JAR class files), and `FrameComputer` recomputes stack map frames with the
  extension's own class hierarchy, because dex2jar's frame pass falls back to `Object`. dex2jar must also
  keep Kotlin's mangled names (`constructor-impl`). All of this is in the converter version
  `dex2jar-2.4.39+ctorfix.1+frames.1`, which is part of the prepared artifact's cache identity
  (`converterVersion` in the `artifact.prepare` reply, with host compatibility `tachi-host.1`).
- **Determinism.** dex2jar's register allocation differs between conversions in one JVM (static state),
  so two conversions can differ in bytes but not in entries or behaviour. The supervisor re-hashes the
  staged output, so byte identity is not relied on.
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
- `addJavascriptInterface(obj, name)` registers message channel `name`; a page message invokes the
  object's `@JavascriptInterface` method `postMessage(String)` (or its only one-`String` method).
- Load, navigation and base URLs must be http(s) (`about:blank` for loads); anything else is
  `capability-unavailable` before any reverse request.
- Cookies are pushed to the session before each load and pulled into the package jar after it.
- Observe-only `shouldInterceptRequest` sees main-frame `loadUrl` navigations. Returning a replacement
  response, and synchronous `@JavascriptInterface` return values, are named capability errors.
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
`flutter test packages/desktop_webview/test --concurrency 1`: 77 passed, 0 skipped, against the protocol 1.2 contract
suite with no `knownFailures`). No macOS or Linux cell is an expected value.

| Behaviour | Windows (WebView2) | macOS (WKWebView) | Linux (WebKitGTK) |
|---|---|---|---|
| Build | pass (debug and `--release`; 739 KB standalone exe) | compiled (`cargo check --target aarch64-apple-darwin`, with `CC_aarch64_apple_darwin` set to LLVM clang for one objc2 build script), including the script message handler; x64 not checked | not run. `cargo check --target x86_64-unknown-linux-gnu` cannot run on the Windows host (the build scripts need the target's system libraries through pkg-config) |
| BrowserPort contract suite (protocol 1.2, `source_runtime_testing`) | pass, 48/48, no known failures | not run | not run |
| Reported protocol 1.2 capabilities (`ready` `capabilities.browser`) | all eight available: `pageStartScripts`, `observeNavigations`, `observeSubresources`, `observeRequestHeaders`, `observeClientHints`, `observeRequestBodies`, `replaceRequests`, `scriptErrors` | available: `pageStartScripts`. Unavailable with WKWebView reasons: request observation (not wired), subresources, client hints (WebKit sends none), bodies, replacement, and `scriptErrors` (implemented engine-independently but not yet run on a Mac) | as macOS, with WebKitGTK reasons (`resource-load-started` not wired) |
| Page bridge transport | pass: `window.chrome.webview.postMessage` with `WebMessageReceived`, captured at document start under a non-identifier property; no wry IPC, so `ipc`, `chrome` and `webkit` all work as channel names | compiled: WebKit script message handler `dwvHost` (`WKScriptMessage.frameInfo` gives the posting frame) | written: script message handler `dwvHost` via `UserContentManager` (no frame identity; the page script's `location.origin` is used) |
| Script errors (`BrowserScriptError`) | pass: only a thrown script or rejected promise is `script-error`; a missing page bridge and a navigation away are separate codes that complete `null` | not run (reported unavailable) | not run (reported unavailable) |
| Request bodies | pass: `Request.Content` up to 1 MiB, stream rewound (the upload is unchanged); larger bodies omitted whole; `bodyOmitted` without a stream only when a non-GET request declares a `Content-Type` | unavailable (no request observation) | unavailable (no request observation) |
| `mainFrame` | pass: a `document` request whose URL a top-level `NavigationStarting` announced (redirect hops included); a same-origin child frame loading the same URL is not | n/a | n/a |
| Failing a held request (invalid replacement, redirect status, throwing replacer) | pass: the helper rewrites the request to `http://127.0.0.1:1/…` (Chromium's restricted port), so the page gets a network error and the original request never reaches the server; a failed main-frame load settles as navigation-failed | n/a (no replace tier) | n/a (no replace tier) |
| Load page, evaluate (promises awaited), JSON results | pass | not run | not run |
| Message channel `window.<name>.postMessage(string)` | pass: document start of every later document, plus the current page on registration; non-strings dropped | not run | not run |
| Origin rule (cross-origin frame, `about:blank` dropped) | pass. The page script reports the frame's origin and `top.location.origin`, which a cross-origin frame cannot read; on WebView2 the engine's document URL must agree too. Same-origin direct child frames get the channel and are delivered (frame message events are forwarded); nested frames are not subscribed | not run (wry reports the posting frame's URL) | not run (posting frame's `location.origin` used) |
| Cookies read/write; domain and path derived from the URL | pass | not run | not run |
| Two sessions' cookie and web-storage isolation | pass (InPrivate profile per session) | not run (non-persistent `WKWebsiteDataStore` per WebView) | not run (ephemeral `WebContext` per WebView) |
| Non-persistent store / start-up wipe | pass. InPrivate; browsing data cleared and confirmed on close. A one-off probe hard-killed the helper mid-session: 0 rows in the profile's Cookies database (a script-set cookie and a server cookie with `Max-Age`), and no localStorage or IndexedDB on disk. A directory is renamed before deletion, so a directory still in use is left whole and reported by name. The helper runs in a kill-on-close job object: after a kill the crashpad, GPU and utility processes end at once, but the browser process stays in termination for 1-110 s (measured; longer while the parent starts other processes, not caused by the GPU or by inherited stdio pipes), holding the directory. `wipe` retries within the client's `DesktopWebViewConfig.wipeRetry` budget (no product default; KTD25). Tests: planted stale directory; a killed helper's directory removed by the next helper's start-up wipe once released (10/10 consecutive runs, below); a directory held open is reported and left whole, then removed by a later wipe | not run (non-persistent; no data directory) | not run (ephemeral; no data directory) |
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

**Start-up wipe flake (fixed).** `start-up wipe › the next helper removes a killed helper directory` failed about 2
of 3 runs: the test started the next helper at once and then looped on `wipeAllSourceData`, while the killed helper's
WebView2 browser process was still terminating and holding the directory. The test now waits (bound 240 s) until the
directory can be released, then checks that the next helper's start-up wipe removed it. 10 consecutive runs on
2026-11-20 all passed (40-143 s per run including the debug build check; the longest wait for release was about
105 s).

**Still needed before U8.** Build and run everything on a Mac (arm64 and x64) and on Linux with WebKitGTK 4.1: the
new script message handler transport (and an `ipc` channel), the bootstrap capture of the post function, and
thrown-script reporting (then report `scriptErrors` available); Linux has never been type-checked.
Enforce offline replay on WebKit: candidates are a blackhole proxy with a loopback exclusion, or WebKitGTK
`resource-load-started` plus a URI-scheme handler; none is decided. Detect failed navigations on WKWebView, which
needs a navigation-delegate hook wry does not expose. Re-check MangaFire on both WebKit engines. The WSL Ubuntu on
the Windows host has WSLg (`DISPLAY=:0`) but no `webkit2gtk-4.1`/`gtk+-3.0` development packages and no Rust;
nothing was installed.
