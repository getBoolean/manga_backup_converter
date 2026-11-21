# U16 iOS runtime gate — evidence and decision (simulator stage)

Status: **simulator evidence only.** U16's verification needs physical-iPhone
receipts; nothing here passes the gate. The user chose simulator evidence now
and a physical iPhone later. Every receipt in this directory is labelled
`evidenceClass: simulator`.

## Decision record (input to U9/U10)

| Item | Decision / result |
| --- | --- |
| Runtime identity | OpenJDK mobile `ad8bb1b065bf230d193a1dfd0ebd39a8b1fedf53` (JDK 26, class-file 70), HotSpot Zero, static, `java.runtime.version` `26-internal-sourcerunner.r1`, patches 0001–0006 in `tools/tachi-source-runner/ios/patches/`, libffi 3.8.1 built from source. Hashes: `u16-runtime-build-outputs.json`. |
| Minimum iOS | **15.0**, the existing app target. Every object is built for 15.0 (checked with `vtool`) and runs on iOS 26.5 Simulator. The deployment target was not raised. Running on iOS 15 itself is unverified; it needs a device or simulator runtime with iOS 15–17. |
| Interruption mechanism | **Mechanism A: injected back-edge deadline checks** (`jdk.internal.misc.SourceRunnerDeadline.poll`, added by the build-time and on-device rewrite pass). It stopped every case, every time, in both poll configurations. **Keep patch 0004 (Zero back-edge safepoint poll) for GC and handshake liveness only.** Do not use JVMTI StopThread delivery (mechanism B) for deadlines. |
| WKWebView probe | **Pass** (simulator) for the fallback path: UA override, `loadData` with base URL, page-start interface shim, script-message-handler messaging, cookie in a non-persistent per-source store. Request observation (`sec-ch-ua*`) is unavailable on WKWebView for https. This is a capability gap; MangaFire only observes headers, so it is not a blocker. |
| Native boundary | Dart → FFIgen (`JNI_CreateJavaVM`/`JNI_GetCreatedJavaVMs`/`GetEnv` via `jni.h` bindings, plus the dispatcher C API) → owned pthreads → `NativeCallable.listener` completions. No platform channel. Dart threads are never attached (`GetEnv` returns `JNI_EDETACHED`). |

## Measurements (iPad Pro 13-inch (M5) Simulator, iOS 26.5, arm64; deadline 250 ms; 5 repetitions per case)

Stop latency is measured natively, from the watchdog firing to the Java call
returning to the dispatcher. The watchdog fires 5–10 ms after the 250 ms
deadline, so the end-to-end overshoot is under about 10 ms.

| Case | A, poll on (selected) | A, poll off | B (poll + StopThread) |
| --- | --- | --- | --- |
| Call-free extension loop | 5/5, max 0.05 ms | 5/5, max 0.04 ms | 5/5, max 0.04 ms |
| Loop inside host-library class | 5/5, max 0.03 ms | 5/5, max 0.02 ms | 5/5, max 0.04 ms |
| Catastrophic `java.util.regex` backtrack (`((x+)\2?)+y`, n=19) | 5/5, max 0.03 ms | 5/5, max 0.03 ms | 5/5, max 0.07 ms |
| Extension catches `Throwable` and continues | 5/5, max 0.02 ms | 5/5, max 0.02 ms | **0/5**: about 1,090 StopThread deliveries per call, then `BootstrapMethodError` |
| Blocked native wait (dispatcher latch) | 5/5, max 0.38 ms | 5/5, max 0.13 ms | 5/5, max 0.30 ms |
| Unrewritten call-free loop | not interrupted (expected) | not interrupted | stopped in 0.07 ms |
| `System.gc()` on another thread during an unrewritten call-free loop | 3.96 ms; with poll off (same run), 2,710 ms stall | (poll off) **2,473 ms stall** | 1.57 ms; with poll off, 2,642 ms stall |
| Baseline, no Java mechanism (Dart-style timeout) | loop ran to completion (1.4–1.5 s); a Dart timeout cannot pass the tests | same | same |

Other results:
- VM creation takes 105–253 ms. The first call takes about 9 ms, and later
  round trips 0.01–0.04 ms (native-side timing).
- JNI global references return to baseline (3) after every case, and there
  are no owned job threads left behind.
- A Dart `Timer.periodic(16 ms)` kept a tick ratio of 0.99–1.0 during every
  loop, so the main run loop was never blocked.
- Mechanism A costs speed in tight loops: the rewritten host loop runs about
  3.5× slower (1,835 → 496–525 rounds/ms) and the rewritten counting loop
  about 3.3× slower.

### Why B is rejected

StopThread is one-shot and asynchronous. An extension that catches
`Throwable` inside its loop swallows each delivery, so the dispatcher must keep
re-issuing it. The re-issued exceptions then land wherever the thread happens
to be, including inside JDK code:

- In the first B run (`u16-simulator-stopthread-first-run.json`) one landed in
  `jdk.internal.vm.ContinuationSupport.<clinit>`. That class became
  permanently unusable for the whole VM: later `System.gc()` calls on other
  threads failed with `NoClassDefFoundError`.
- In the reordered run (`u16-simulator-stopthread.json`) every catch-all call
  ended with `BootstrapMethodError` after 1,082–1,104 deliveries, because an
  invokedynamic call site was poisoned.

This is the `Thread.stop` hazard, and no "within deadline" result can make up
for it. Mechanism A throws only at back-edges of code the rewrite pass chose,
and its mark is sticky, so catch-and-continue is stopped at the very next
back-edge without touching JDK internals.

### Consequences for U9 (rewrite pass scope)

- Rewrite extension JARs (both artifact paths) and parent-owned host
  libraries, and at image build time the class-library packages that
  extensions drive with site data: `java.util.regex` is proven here. Text,
  parsing and collection packages need to be chosen in U9.
- Never inject into `<clinit>`, and audit injection points inside
  lock-holding JDK code before widening the java.base set.
- Code that is not rewritten cannot be interrupted, but with patch 0004 it no
  longer stalls GC or handshakes. The operation-level backstop is the
  session/VM policy (KTD12), not a thread kill.
- Extension classes need `--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED`
  (or the poll class moved to an exported package) so they can call the poll.

## Receipts

- `u16-simulator-injected-poll-on.json`: selected configuration, all 14 tests passed.
- `u16-simulator-injected-poll-off.json`: A alone on upstream Zero semantics, all 14 passed.
- `u16-simulator-stopthread.json`: B; catch-and-continue failed (13 passed, 1 failed).
- `u16-simulator-stopthread-first-run.json`: B before the test reorder; shows the class-init poisoning.
- `u16-runtime-build-outputs.json`: runtime build identity and artifact hashes.
- `r18-app-store-guideline-mapping.md`: compliance note (started).

Reproduce: `tools/tachi-source-runner/ios/README.md`, "Running the gate".

## Still open: needs a physical iPhone

- Device run of the same gate (release profile, cold launch, no debugger).
  No-JIT enforcement is real only on a device: the simulator runs on macOS
  and does not enforce the iOS code-signing memory rules the same way. Patch
  0006 removes the runtime's only executable-memory commit, which is what
  makes it plausible on device, but this has not been checked on device yet.
- Re-measure deadline latency and loop overhead on device CPUs.
- WKWebView replay on device.
- Live MangaFire challenge behaviour with a Chrome UA and no client hints on
  WebKit: not testable without contacting the live site, which these tests
  must not do.

## Still open: needs Apple Developer / App Store Connect access

- A distribution-signed Release, validated by App Store Connect (validation
  upload only). It needs the team ID, an Apple Distribution certificate, an
  App Store provisioning profile for the bundle ID, and the user's explicit
  go-ahead to upload. Steps are in `tools/tachi-source-runner/ios/README.md`.
  The unsigned device Release build (`flutter build ios --release
  --no-codesign`) links and contains the runtime framework (7.2 MB, iOS 15.0,
  483 exported JNI natives, no JIT APIs imported).

## Known blocker outside U16

The root app's iOS build fails in `packages/swiftsoup/hook/build.dart` with
Xcode 27. It builds Swift for `arm64-apple-ios13.0` (below Xcode 27's 15.0
minimum), it builds the device triple for simulator targets, and it rejects
x86_64 simulator builds. The gate runs here used a temporary local patch to
that hook (iOS 15.0, plus the simulator triple and SDK for simulator runs).
The patch was reverted and is not committed. The swiftsoup owner needs to fix
the hook properly: iOS 15.0, choose the triple and SDK from
`code.iOS.targetSdk`, and include the SDK in the cache key.

# U10 — local Paperback execution and the WKWebView BrowserPort (simulator stage)

Status: **simulator evidence only** (`evidenceClass: simulator`). U10's
verification needs a signed physical-iPhone run; nothing here passes R14.
Device: iPad Pro 13-inch (M5) Simulator, iOS 26.5, arm64; Xcode 27.2;
Flutter 3.50.0 (`flutter test` integration runs are debug builds: Dart JIT,
QuickJS native).

Run: `flutter test integration_test/source_runners_ios_paperback_browser_test.dart -d <udid> --dart-define=SRT_REPO_ROOT=$PWD`
(add `--dart-define=SRT_BENCH=true` for the benchmark). Result:
**64 passed, 3 skipped**: the benchmark (ran separately, passed) and the two manual AE8 cases (ran separately with device automation, passed).
Receipt: `u10-simulator-receipt.json`. The desktop VM runs the in-app worker
cases in `packages/paperback_plugin_loader/test/in_app_backend_contract_test.dart`
(7/7 on macOS).

## What runs where

| Piece | Implementation |
| --- | --- |
| Paperback host | `isolatePaperbackLauncher` (`packages/paperback_plugin_loader/lib/src/runtime/isolate_worker.dart`): the unchanged `PaperbackSourceWorker` (U5 promise bridge, U6 0.8/0.9 adapters, pinned Cheerio) in a Dart isolate of the app, speaking protocol v1 over isolate ports to the normal `WorkerSupervisor`. No Dart subprocess. |
| Termination | Engine deadline checked natively by the QuickJS interrupt handler (fires while the isolate is blocked in JS). Each runtime's interrupt token is published to the launching isolate and adopted there (native reference, handed over without a free window), so `WorkerProcess.kill` stops running JS before `Isolate.kill`. |
| QuickJS | `packages/quickjs` hook, unchanged: it built for the iOS Simulator and for iPhoneOS without any change (see below). |
| Browser | `WKWebViewBrowserPort` (`packages/source_runtime_ios/lib/src/wkwebview_browser_port.dart`), Dart over FFIgen WebKit/UIKit bindings; no platform channel, no hand-written Objective-C. Paperback `executeInWebView` and the Tachi `android.webkit` translation both reach it through `BrowserReverseBridge`. |
| Aidoku WebView imports | Unchanged: `webview_*` imports return `-1` (failure). No qualification source needs them. |

## QuickJS iOS build

- Built from the pinned submodule (`dce8c0bb…`) by the existing hook; no hook change was needed for iOS.
- Simulator slice: arm64, `IOSSIMULATOR`, minos 15.0, SDK 27.2, 1,121,456 bytes, SHA-256 `e3677a16b2f5ee0f8b4d5b53a147aa5aef65c0b62c9073b115fb1ace4843cac3`.
- Device slice (`flutter build ios --release --no-codesign`, unsigned): arm64, `IOS`, minos 15.0, 1,067,568 bytes, SHA-256 `12cef14164cfae439fe4fbe04b600a4b55533306c382baff1e1a683cfa009ec6`. The release app contains no capture, bundle or fixture file, and no Paperback host code (the root app depends on `paperback_plugin_loader` only as a dev dependency for the integration test). (`source_runtime_ios.framework` imports `dlopen`/`mmap`/`mprotect` only because this clone links U16's staged JVM archive; that is U9/U16's R18 item, unchanged by U10.)
- Linkage: only `libSystem`; no `mmap`/`mprotect`/JIT/`dlopen` imports (interpreter only, R18).
- Native stack: root isolate thread 8 MiB, worker isolate thread about 1.0 MiB (1,057,423 bytes).

## QuickJS limits (KTD25), provisional

Derived on the simulator by `planPaperbackIsolateWorker` (device measured on a
worker-isolate thread, rule `quickjs-sizing-v2`, profile and policy unchanged
from U6):

| Limit | Value | From |
| --- | --- | --- |
| memory | 19,420,946 B | peak heap 9.71 MB × 2 (the RAM cap does not bind: the simulator reports the host Mac's 16 GiB) |
| stack | 433,936 B | U6 peak stack 216,968 B × 2; cap 0.5 × 1,057,423 B thread stack = 528,711 B |
| operation deadline | 188.3 s | 2.389 s × (29.7 ms / 122.2 ms) × 4 + 186 s host-wait allowance |
| job slice | 46.4 ms | CPU part ÷ 50 |
| supervisor headroom / cancel grace | 266.5 ms / 313.0 ms | deadline tail × max(1, speed) × 4 |

Benchmark (`packages/paperback_plugin_loader/benchmark/results/2026-11-21-ios-simulator-arm64-bundles-jit.json`,
3 runs per workload): calibration 30.2 ms (Windows reference 122.2 ms);
slowest operation numby-0.8/WeebCentral details, p95 270.6 ms; peak heap
9,710,458 B (same as Windows); minimal stack 48,848 B (Windows MSVC 216,968 B;
clang frames are smaller, about 1,010 B per JS frame); deadline overshoot at
most 39.3 ms. The rule keeps the Windows profile, so the iOS stack and
deadline are conservative. These numbers are a simulator on an Apple-silicon
Mac and say nothing about iPhone CPUs; they are recorded as provisional and
must be re-measured on physical iPhones of different capability.

## Test results by scenario

| Scenario | Result (simulator) |
| --- | --- |
| AE4/AE7 WeebCentral: inkdex 0.9, gabrielcwt 0.8, numby 0.8 search → details → 114 chapters (Cheerio, HTML) | pass |
| AE4/AE7 MangaDex: inkdex 0.9 JSON feed, 223 chapters; neihc1002 0.8 meets the recorded edge challenge and fails visibly | pass |
| QuickJS sync loop ends at the native deadline while the worker isolate cannot read the cancel frame | pass (`timeout` after 402 ms, deadline 400 ms) |
| QuickJS job loop | pass (cancelled at a job-slice boundary after 106 ms, or deadline) |
| Kill from the root isolate stops JS through the adopted token | pass (exit −9 immediately) |
| Never-completing host call bounded by the deadline | pass |
| AE8 creation on the platform thread, completion (status 200/404), navigation failure (closed port), offline block | pass |
| AE8 visible interaction: presented sheet, user dismissal → completed once (a second dismissal changes nothing), timeout → interaction-required, cancel → cancelled | pass. Automated run: `debugUserDismiss` (same handler as the sheet delegate). Manual case (`--dart-define=SRT_MANUAL=true`): a real swipe-down driven with the T3 device tools on the simulator settled `BrowserCompleted` through `presentationControllerDidDismiss:` |
| AE8 backgrounding: pending evaluation cancelled once, new work refused, late callback discarded, work resumes in the foreground | pass. Automated run: `setBackgrounded`. Manual case: real backgrounding (Settings opened, then the app reopened, via the device tools) through `bindToAppLifecycle`: the pending evaluation settled `BrowserCancelled(The app entered the background)` once and a load completed after returning |
| AE8 late callbacks after supersession, close and fencing | pass |
| Session disposal: pending load/evaluate cancelled, no message after close, `pendingOperations` 0 | pass |
| Cookies (server-set and port-set both ways, per source), UA (page and server agree, `setUserAgent`), language (`en-US` / `en-US,en;q=0.9`), binary (256-byte fetch), UTF-8 (title, body, evaluate, channel, loadData) | pass |
| Tachi `android.webkit` translation through the bridge: open with capabilities, `ipc` channel, page-start script, observe accepted, replace refused naming `replaceRequests`, `loadData` on `https://mangafire.to/`, throwing evaluate → `result: "null"` + `scriptError`, messages delivered | pass |
| AE11 MangaFire 0.9 on WKWebView, offline replay | recorded: `executeInWebView` ran on WKWebView with every network load blocked; the page's own scripts could not load, so the source reports `VRF capture timed out` for search and details (a named source error, not an empty result); all browser sessions closed. Same outcome as the desktop scripted port. **The live challenge path is not proven; M3 stays open on it.** |

## Contract suite (`runBrowserPortContractSuite`, 48 cases): all pass, no skips, no known failures

- Allowed schemes (13): http(s) page, about:blank, loadData with http(s) base; refuses `file:` ×2, `content:`, `app:`, `javascript:`, `data:`; refuses a redirect to `file:` (WebKit refuses it in the network layer, `NSURLErrorNoPermissionsToReadFile`, mapped to capability-unavailable); refuses loadData bases `file:`, `about:blank`, `app:`.
- Storage (4): nothing left after close; nothing after kill and restart; per-source scope (two sources); closed-session operations cancelled.
- Fencing and cancellation (3).
- Scripts, messages, interaction (15): evaluate JSON; channel delivery on a page and on loadData content; registration before load; removal; cross-origin frame drop; about:blank drop; six invalid names; interaction-required without interaction; `ipc` channel beside a second channel and evaluation, surviving navigation.
- Protocol 1.2 capabilities (2): every unavailable feature has a reason; throwing script → `BrowserScriptError` (and `androidCompatible` → `null`).
- Page-start scripts (3): document start in top and same-origin child frames; later documents incl. loadData, not the current one; cross-origin frame posts dropped.
- Request interception (7): degraded observe tier — main-frame navigation observed (no headers, reason given); POST subresource proceeds unobserved (reason given); removed observer; replace refused naming `replaceRequests`; redirect replacement case returns early (no replace tier); scheme policy not widened; replacer/observer exclusivity.
- Known-failure bookkeeping (1).

## Capability report (`wkWebViewCapabilities`)

| Feature | Status |
| --- | --- |
| pageStartScripts | available (`WKUserScript`, document start, all frames) |
| observeNavigations | available (main-frame `decidePolicyForNavigationAction`, redirects flagged) |
| scriptErrors | available (`callAsyncJavaScript` wrapper) |
| observeSubresources | unavailable: WKURLSchemeHandler may not claim http(s); no public API reports subresource or child-frame requests (degraded observe tier) |
| observeRequestHeaders | unavailable: only the navigation request's own headers are visible, not what the network process sends |
| observeClientHints | unavailable: WebKit sends no `sec-ch-ua*` |
| observeRequestBodies | unavailable |
| replaceRequests | unavailable: WKURLSchemeHandler cannot handle http(s) |

## Findings worth keeping

- A WKWebView outside any window is treated as hidden: timers are throttled and cross-origin frames can stall. Each session's web view is parked in the key window outside its visible bounds, and moved into a presented sheet for interaction.
- `UIViewController.setView:` throws for a WKWebView created outside a controller; the sheet hosts it as a subview.
- WebKit content-rule regular expressions have no `|`; the offline rule list uses one rule per scheme and host.
- FFIgen's generated listener blocks assert on nil object arguments in debug builds; `nullable_blocks.dart` builds the same listener with nullable arguments.
- dart:io `HttpServer` sends `X-Frame-Options: SAMEORIGIN` by default (test servers must clear it for cross-origin frames).

## Needs a physical iPhone

- R14: a signed device build running the same cases (fixtures need a test-only delivery on device: the simulator reads them from the host path; no capture or bundle is packaged into the app).
- KTD25: re-run the benchmark (release/profile build) on iPhones of different capability; replace the provisional profile.
- Backgrounding on a device, where iOS suspends the app and WebContent process (the simulator keeps running them), and a swipe-down by hand.
- WKWebView behaviour with an iPhone's memory pressure and web-process jetsam.
- The live MangaFire challenge on WebKit (no client hints, Chrome UA): out of scope for tests that may not contact a server.
