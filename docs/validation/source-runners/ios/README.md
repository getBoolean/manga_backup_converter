# iOS Tachi runtime — U16 gate and U9 implementation evidence (simulator stage)

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
- `app-store-compliance.md`: compliance note (started).

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


---

# U9: local iOS Tachi runtime (simulator stage)

Status: **simulator evidence only** (iPad Pro 13-inch (M5) Simulator, iOS
26.5, arm64, Xcode 27.2). Every U9 receipt is labelled `evidenceClass:
simulator`. U9's verification needs a signed physical-iPhone build; see the
list at the end. Branch `feat/source-runners-u9`.

## What runs where

| Layer | Implementation |
| --- | --- |
| VM | One process-lifetime Zero VM (`IosJvmRuntime`), started from Dart through FFIgen JNI invocation bindings with `BundledRuntime.productionOptions`: `-Xint`, the Tachi host class path, `-Djava.library.path=`, `--illegal-native-access=deny`. Never destroyed. |
| Worker | The desktop worker's own classes (`Worker`, class-file 65) run inside the VM via `mangabackup.tachi.ios.IosWorkerHost` on a dispatcher-owned thread, over a native byte channel (`srt_worker_*`). No helper process, no network RPC; output reaches Dart through one `NativeCallable.listener`. |
| Dart backend | `IosTachiBackend` (`packages/source_runtime_ios/lib/src/tachi_backend.dart`) implements `SourceProvider` over the unchanged `ConversionRuntimeScope`/`WorkerSupervisor`/`WorkerSourceSession`/`BrowserReverseBridge`, with `InVmWorkerProcess` as the injected launcher. `worker()` is also a `TachiWorkerAccess` for the common `TachiRuntime`. |
| Deadlines | Every operation arms a native deadline (`IosNatives.arm`) on the dispatcher's watchdog. When it fires the watchdog marks the thread for the rewritten back-edge polls (mechanism A), interrupts it, and runs the operation's cooperative stop (HTTP calls, browser reverse requests) on a Java helper thread. The reply is `timeout`. A supervisor restart ("kill") closes the channel and fires every deadline of that worker generation; the next generation is a new worker in the same VM. |
| Shared code | `WorkerPlatform` hook in the shared worker (`desktop` default is a no-op): native deadlines and the artifact rewrite. ApkConverter now writes dex2jar output to a temp directory (the image has no `jdk.zipfs`). Desktop worker tests: 52/52 on Temurin 21.0.13.1 before and after. |

## Decisions

- **Rewrite pass** (`BackedgeRewriter`, version `ios-backedge.1`, part of
  every prepared artifact's converter version, so KTD5 cache identities
  change when it changes): never `<clinit>`; extension and host-library code
  calls a poll trampoline baked into exported `java.lang`
  (`SourceRunnerPoll`), so `jdk.internal.misc` is **not** exported to source
  code (U16's `--add-exports` is no longer needed for production).
- **java.base package set:** `java/util/regex/` and `java/text/` (53 classes,
  303 back-edges). Synchronized methods and monitor regions are skipped.
  Collections, I/O and concurrency are excluded (bounded by host data, and
  they run under locks shared across operations).
- **Host libraries rewritten at staging:** jsoup (298 back-edges),
  `kotlin.text` (240), kotlinx-serialization-json (87). Coroutines, OkHttp,
  Okio and the worker itself are not rewritten; their waits end through
  cancellation.
- **Baked, not patched in:** the rewritten java.base classes, the poll
  trampoline and the native-load guard are baked into `lib/modules` by
  `build_runtime.sh package` (`image_bake` in `u9-runtime-build-outputs.json`).
  No `--patch-module`. Gate fixtures are staged only with `--gate`, test data
  only with `--test`; the default (shipping) payload has neither, nor the
  replay server JARs.
- **R18 native code:** two layers. `--illegal-native-access=deny` refuses JNI
  and `java.lang.foreign` library loads from every unnamed module
  (`IllegalCallerException`). Behind it, the baked guard at
  `ClassLoader.loadLibrary(Class, String|File)` refuses any library load not
  requested by boot or platform classes (`UnsatisfiedLinkError`), including
  reflective calls. The guard-only diagnostic run shows the guard stops all
  JNI paths but not the foreign lookup, so `deny` is required.
- **Runtime patches added by U9** (both found by running the real worker; the
  U16 gate never reached these paths):
  - `0007-ios-libjava-builtin-library-lookup.patch`: libjava's
    `findBuiltinLib` searched only the main executable, so `jimage`, `net`,
    `nio` and `zip` could not load from the app framework.
  - `0008-ios-zero-signal-context-pc.patch`: on bsd_zero every signal
    HotSpot handles called `ucontext_get_pc` (ShouldNotCall) before the
    SIGPIPE/SIGXFSZ ignore branch, so a SIGPIPE from a closing socket aborted
    the app.
- **No built-in extensions or repositories:** the runtime image holds only
  the JDK class library and the baked additions; the shipping payload holds
  the image and the host class path (worker, libraries, iOS host), with no
  extension artifact, capture, gate fixture or repository reference
  (`stage_runtime.sh` fails a default payload that contains any). Product code
  in `source_runtime_ios` and `ios/host` names no extension or repository.
  The real keiyoushi artifacts and captures under `fixtures/source_captures/`
  are test-only (staged with `--test`) until a follow-up replaces them with
  mocked extensions; a release build refuses a `--gate`/`--test` payload at
  start (`BundledRuntime.prepare`; not yet exercised, since release builds
  cannot run on the simulator).
- **Limits:** no iOS sizing rule exists (KTD25 needs device benchmarks). The
  worker reports every limit as an explicit override (`rule: null`); the
  desktop rule is never applied. Heap is `-Xmx384m`, provisional.

## Measurements (simulator)

Interpreter-mode `artifact.prepare` (verification + conversion + rewrite),
first run in a fresh VM, from `u9-simulator-receipts.jsonl`:

| Source | JAR: verify + rewrite | APK: apksig + dex2jar + frames + rewrite | Search | Details + chapters |
| --- | --- | --- | --- | --- |
| MangaDex 1.6.4 (62 source IDs) | 1.57 s | **14.96 s** | 0.50 s / 0.19 s | 1.08 s (15 ch.) |
| WeebCentral 1.6.27 (1) | 0.56 s | **3.01 s** | 0.27 s / 0.18 s | 4.09 s (114 ch.) |
| MangaFire 1.6.38 (7) | 1.13 s | **11.90 s** | 0.25 s / 0.25 s | 1.05 s (86 ch.) |

JAR and converted-APK results were identical for all three (titles,
metadata, every chapter). Prepared artifacts are cached by KTD5 identity:
re-preparing the same JAR returned the same cache path every time.

Native deadlines (1,500 ms, 5 cases, one run each; full latency is from the
Dart call to the reply, so it includes the protocol round trip):

| Case | Elapsed | Overshoot |
| --- | --- | --- |
| Call-free CPU loop (`busy`) | 1,511 ms | 11 ms |
| Catch `Throwable` and loop again (`catch`) | 1,512 ms | 12 ms |
| Catastrophic regex in baked `java.util.regex` | 1,512 ms | 12 ms |
| Host HTTP call that never answers (`hang`) | 1,524 ms | 24 ms |
| Browser open that never completes | 1,512 ms | 12 ms |

The Dart supervisor deadline was 8 s and its generation never changed, so
every stop came from the native deadline. After each stop the fixture's
counter read the same value twice 500 ms apart: the loop had stopped, which
a Dart-only timeout cannot achieve.

Other: VM creation 80–94 ms; worker handshake under 1 s; JNI global
references 4 after start and 4 after every case, five package open/close
cycles and a second backend; 0 armed deadlines afterwards; 1 VM throughout;
loaded image count unchanged (927); no platform message from the app during
the whole run; no replay capture miss.

## Results by scenario (22/22 passed, `integration_test/source_runners_ios_test.dart`, renamed `source_runners_ios_tachi_test.dart` in U15)

| Scenario | Result |
| --- | --- |
| AE7: MangaDex, WeebCentral, MangaFire from the repository JAR and from the APK converted in the VM; exact int64 source IDs equal the index entry; search, details, chapters from fail-closed replay; rehydration from the durable reference | pass (6 cases) |
| Tampered JAR (modified class), JAR with an appended unsigned class, tampered APK, APK against another signer: refused before loading/conversion as `artifact-incompatible` | pass (4 cases) |
| Cached converted JAR modified on disk: refused by digest before loading | pass |
| AE8: CPU loop, catch-and-continue, regex, never-completing network wait, delayed browser callback stopped by the native deadline | pass (5 cases) |
| Browser port with `.androidCompatible` semantics: a throwing script reaches the source as `null` (test port; the WKWebView port is U10) | pass |
| R18: `System.loadLibrary`, `System.load`, reflective `System.load`, `SymbolLookup.libraryLookup` all refused; no image loaded | pass (+ guard-only diagnostic run) |
| Session/package/backend closure never destroys the VM; references back to baseline; a new backend runs in the same VM | pass |
| No platform channel used | pass |
| U16 gate on the rebuilt runtime and new rewriter (regression) | 14/14 pass (`u9-simulator-u16-gate-regression.json`) |
| Desktop worker tests (shared code) | 52/52 pass, Temurin 21.0.13.1 |

## Still open: needs a physical iPhone

- Everything above on a signed device build (release, cold launch, no
  debugger): no-JIT/no-executable-memory enforcement only exists on a device.
- APK conversion time on device CPUs (the simulator runs at Mac speed; 15 s
  for MangaDex here could be much longer on older iPhones), and whether a
  conversion fits the device's memory with `-Xmx384m`.
- KTD25 device benchmark to size the native deadline, pool size and heap.
- Deadline latency and back-edge overhead on device CPUs.
- Fixture staging: `--test` payloads bundle the data as assets, so the same
  test runs on a device; not yet tried.

## Remaining U9 work (not done here)

- Live networking on iOS: the production transport is OkHttp over JDK
  sockets/JSSE in the VM (`HostTransport.LIVE`). TLS with the bundled
  `cacerts` is untested (tests must not contact live sites); the plan's
  NSURLSession shim is not implemented.
- App backgrounding (KTD12): reject new work, fence late callbacks, resume
  after foregrounding. Not implemented.
- Per-session reference bound assertions for Objective-C wrappers: only JNI
  global references are counted (no Objective-C objects are created by the
  Tachi path yet; WKWebView is U10).
- Secret-in-preferences scenario (password never reaches app storage) is not
  yet a test case; worker state directories are deleted when each worker
  generation exits.
- Operations an extension moves to other threads (`Dispatchers.IO`) are not
  marked by the deadline; only the operation thread is. Their host waits are
  still cancelled.
- `docs/source-runners.md` platform section (outside this unit's owned
  paths).
- Protocol 1.2 features arrive with the U3b worker merge; this branch runs the
  1.1 worker.

---

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
| AE4/AE7 MangaDex: inkdex 0.9 JSON feed, 223 chapters; neihc1002 0.8 meets the recorded edge challenge and fails visibly | pass (before the U6d merge; see the note below the table) |
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

Note (integration of U6d and U10): U6d replaced the 0.8 MangaDex cell with
community `MangaDex` 3.0.6 and removed the neihc1002 fixtures, so the MangaDex
case now expects both bundles to complete the 223-chapter feed (the desktop
in-app contract test checks the same through a worker isolate). The simulator
receipt above predates that change; the iOS case has not been re-run.

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

---

# U18 Aidoku runner on iOS — simulator evidence

Status: **simulator evidence only** (`evidenceClass: simulator`). These results
do not satisfy R14. Receipt: `u18-simulator-receipt.json`.

## What runs

- The existing `aidoku_plugin_loader` host, unchanged. It runs one WASM worker
  isolate per source with the wasm3 interpreter, the SwiftSoup HTML backend
  (`parser_native.dart` already routes iOS to it), the GCD `WasmSemaphore`
  and the postcard ABI. U18 changes nothing in `aidoku_plugin_loader`. U13's
  isolate-death fix and its default WebView-style User-Agent were already on
  the base branch and are exercised here.
- `packages/source_runtime_ios/lib/src/aidoku_backend.dart`:
  `IosAidokuBackend.register(aidokuProvider)` takes the same
  `AidokuSourceProvider` that desktop and Android use (KTD16: no dependency
  on a concrete loader). It does two things:
  - **Admission.** It opens `wasm3.framework/wasm3` and
    `SwiftSoupWrapper.framework/SwiftSoupWrapper` from `Runner.app/Frameworks`
    and resolves `m3_NewEnvironment` and `swiftsoup_init`. A missing slice is
    a `RuntimeUnavailableFailure` at registration, not at the first source
    call. Only frameworks inside the app bundle are opened.
  - **Backgrounding (KTD12).** `provider` is the desktop adapter behind a
    lifecycle gate. On hidden or paused (`bindToAppLifecycle`, or
    `setBackgrounded`), pending calls answer once with
    `CancelledFailure('app-backgrounded')`. New calls and package opens are
    refused with the same failure, and late results are fenced. A package
    that opens after the transition is closed. Sessions are usable again after
    resume. Identities, capabilities, settings revisions and refs all pass
    through from the desktop session.
- Host contract test: `packages/source_runtime_ios/test/aidoku_backend_contract_test.dart`
  (12/12 on macOS).

## Results (iPad Pro 13-inch (M5) Simulator, iOS 26.5, arm64; Xcode 27.2, Flutter 3.50.0)

`flutter test integration_test/source_runners_ios_aidoku_test.dart -d <sim> --dart-define=SRT_MANUAL=true`:
**10 passed, 0 failed.** No request reached a server: the committed `.aix`
fixtures and captures come from U13's `aidoku_fixture_bundle.g.dart`, which
is in `integration_test/`, so it ships only in the test build. Every source
case asserts zero replay misses.

| Case | Result |
| --- | --- |
| 1. Registration | wasm3 and SwiftSoup open from the bundle and export their symbols |
| 2. multi.mangadex v12 | 2 hits, "Onii-chan wa Oshimai!", 223 chapters, 3 requests replayed, 0 misses, 0 host warnings |
| 2. en.weebcentral v6 | 1 hit, "ONIMAI - I'm Now Your Sister!", 114 chapters, 0 misses; SwiftSoup loaded in the WASM isolate |
| 2. multi.mangafire v8 | 50 hits, "Highschool ONIMAI", 86 chapters, 0 misses |
| 3. Cancel in flight | `cancelled` after 305 ms (response delayed 2 s); the next call returns 2 hits |
| 4. WASM trap | `source-error` twice (`unreachable`); the session survives |
| 5. Isolate death (trap in `start`) | `runtime-unavailable` twice in 3 ms; no `port.first` hang |
| 6. Headers and rate limit | `X-Probe` value-1…value-5 read by the plugin; the 2/1 s window gaps were 1004, 1007 and 1001 ms (same as desktop and Android) |
| 7. Background gate (programmatic) | in flight: `app-backgrounded` after 303 ms; new call and package open `cancelled`; after foreground, 2 hits |
| 8. Real backgrounding (manual) | agent-device `home` sent the app to the background and `open` brought it back. The held in-flight search answered `app-backgrounded` through `AppLifecycleListener`; the next search after resume returned 2 hits |

## Native libraries (R18, local checks)

| Slice | wasm3 | SwiftSoupWrapper |
| --- | --- | --- |
| iphoneos, `flutter build ios --release --no-codesign` | arm64, iOS 15.0, 145,536 B | arm64, iOS 15.0, 1,676,240 B |
| iphonesimulator (debug test build) | arm64, iOS Simulator 15.0, 153,104 B | arm64, iOS Simulator 15.0, 2,458,448 B |

Neither binary imports `mprotect`, `mmap`, `pthread_jit_write_protect_np`,
`sys_icache_invalidate`, `vm_protect` or `dlopen` in either slice. wasm3 is an
interpreter, so a downloaded `.aix` is data. Hashes are in the receipt.
Flutter refuses a release build for the simulator ("Release mode is not
supported for simulators"), so the release-profile check covers only the
device slice. The swiftsoup hook checks the built slice's platform and
architecture, and wasm3 is built per target by `native_toolchain_c`, so a
missing or wrong slice fails the build. The device release build now
succeeds with the committed swiftsoup hook, which resolves the Xcode 27
blocker noted under U16.

## Browser imports

None of the three qualification sources imports a `js` or `webview` function:
their WASM import sections contain only `env`, `std`, `net`, `html` and
`defaults`. Aidoku's WebView imports therefore stay named capability
failures on iOS, and nothing is routed to U10's `BrowserPort`. This matches
U13 on Android.

## Still open: needs a physical iPhone

- The same ten cases on a development-signed release-profile build after a
  cold launch, without a debugger. This is the R14 receipt: build, OS, device
  architecture, entitlements and native hashes. The simulator does not
  enforce iOS code-signing memory rules, so "no JIT" holds on the simulator
  only as a static import check.
- Real backgrounding on a device, where the OS suspends the process after
  about 5 s. Also check that a held host request does not keep the app awake.
- Timing on device CPUs (the WeebCentral search takes about 0.5 s on the
  simulator).
- An App Store Connect validation of a distribution-signed build remains
  deferred to the TestFlight setup.

---

# U15 — iOS conversion through the app composition root (simulator stage)

Status: **simulator evidence only** (`evidenceClass: simulator`). U15's
verification needs physical-iPhone receipts (R14, AE7 on a device); none of
the results below stands in for them. Device: iPad Pro 13-inch (M5)
Simulator, iOS 26.5 (23F77), arm64; Xcode 27.2; Flutter 3.50.0 / Dart 3.14.0.
Branch `feat/source-runners-u15`, rebased on `fa0b50a` (U11).
Receipts: `u15-simulator-receipts.jsonl`, `u15-package-iphoneos.json`,
`u15-package-iphonesimulator.json`.

## What runs

`lib/src/features/conversion/application/conversion_composition.dart`
(`IosSourceRuntimes`) registers the three local runtimes with
`ConversionService`, which runs the core `ConversionJob`:

| Runtime | Backend | Notes |
| --- | --- | --- |
| Aidoku | `IosAidokuBackend` over the desktop `AidokuSourceProvider` (U18) | framework admission at start; background gate |
| Paperback | worker isolate (`isolatePaperbackLauncher`, U10) under a per-conversion `ConversionRuntimeScope` | KTD25 plan measured on the device at start (`quickjs-sizing-v2`) |
| Tachi | `IosTachiBackend` in the process-lifetime JVM (U9), reached through the common `TachiRuntime` with `hostCompatibility: tachi-host.1+ios` | limits are explicit app config (no iOS rule yet) |

Both workers share one `WKWebViewBrowserPort`, each through its own reverse
bridge; a bridge resolves a browser source from the artifact its worker
currently hosts (`WorkerSupervisor.artifactOf`). Per-conversion scopes are
adopted by the job's `ConversionOwner`; the JVM is never destroyed. The
loaders are the CLI's, moved unchanged into `packages/source_loaders`.
Nothing is defaulted: repositories come in the request, extensions through
the `SelectionPort`, settings through `settingsFor`. Nothing starts at app
launch; `iosConversionServiceOverride` installs the composition for
Riverpod (the deferred conversion UI will call it).

## Results

`flutter test integration_test/source_runners_ios_test.dart -d <sim> --dart-define=SRT_REPO_ROOT=$PWD`
after `stage_runtime.sh iphonesimulator --test`: **12 passed, 2 skipped**
(the manual case and the built-app relaunch case, both run separately below).
Every job goes parse → local runtime fetches → reconcile → build/validate →
atomic publication inside the app container; every source request replays a
committed capture (0 replay misses).

| Case | Result |
| --- | --- |
| R5 Paperback → Aidoku, Mihon → Aidoku | pass; `en.weebcentral` (the `.aix` the runtime loaded), 114 chapters; emitted ID = runtime identity |
| R5 Aidoku → Paperback, Mihon → Paperback | pass; `WeebCentral` (inkdex 0.9 bundle, `paperback-bundle-0.9`), 114 chapters |
| R5 Aidoku → Mihon, Paperback → Mihon | pass; exact int64 `2131019126180322627` from the verified keiyoushi JAR, source URLs, partial page 4 kept unread (AE1/AE2), 10–13 s each (worker start + prepare) |
| Mihon inputs | partial by design (Aidoku/Paperback cannot hold a bookmark) and accepted, as in the desktop six-direction test |
| Resources after every job | 0 browser sessions, 0 pending Aidoku calls, 0 live VM workers, 0 armed deadlines, 1 VM, JNI global refs back to 4 |
| Main run loop | largest gap between 16 ms ticks during a job: 18–30 ms |
| Platform channels | none used by source work (KTD23) |
| AE8 backgrounding (programmatic) mid-search | held search answered once `cancelled: app-backgrounded`, new search refused while backgrounded, job completed in the foreground, exactly one output |
| AE8 real backgrounding (manual, `SRT_MANUAL=true`) | agent-device `home`, then `open`: events `[backgrounded, error:cancelled:app-backgrounded, foregrounded]`, one output |
| AE8 cancel an in-flight search | session usable at once (next result 16 ms after cancel), job completed |
| AE8 engine deadline (Tachi, native deadline 1.5 s, replay host never answers) | search failed `timeout` ("operation stopped by its deadline"), partial declined, nothing published, no worker or deadline left |
| AE8 repeated jobs (2 × Aidoku→Mihon, Mihon→Paperback, Paperback→Aidoku) | every job opened and closed its sessions/workers; references back to baseline |
| AE8 late WebView callbacks | after the AE11 job every browser session was closed; the next job on the same port succeeded |
| Kill and relaunch | built app (`--dart-define=SRT_PHASE=relaunch`), installed once; launch 1 SIGKILLed itself (FFI `raise`; `Process.killPid` on the own pid does nothing on iOS) at publication with the journal on disk and no output; launch 2 reused 1 journaled decision, asked nothing, made 0 site requests (snapshot reused), published exactly one `.aib`, cleared the journal. Re-run after the rebase: same result. `flutter test` reinstalls the app and wipes its container between runs, so this case cannot run under it |
| AE11 MangaFire (Paperback 0.9) inside a job | `executeInWebView` opened a WKWebView session inside the job; offline the page cannot load MangaFire's scripts, so the search failed with the named source error `VRF capture timed out`, the partial conversion was declined, nothing was published. **The live challenge path is not proven; M3 stays open on it.** The Tachi MangaFire 1.6.38 artifact computes its VRF without a WebView in the captured flow |

## Protocol 1.3 on the WKWebView port

`integration_test/source_runners_ios_paperback_browser_test.dart`:
**127 passed, 3 skipped** (benchmark, two manual U10 cases). The contract
suite (55 cases at 1.3) now runs twice, both 55/55:

- without interaction (the U10 harness, `allowInteraction: false`): the 1.3
  completion cases take the no-display path;
- with a presented sheet (`_WkHarness(interactive: true)`): page-signalled
  completion (`completedByPage`), user dismissal (`closedByUser`, through the
  sheet's dismissal handler), timeout → `interaction-required` after ≥ 250 ms
  with the session usable, cancel → `cancelled` with the session usable, and
  session close → `cancelled`. No port change was needed: the U10 port already
  hid the sheet on cancel and timeout and reported `BrowserCompleted` only
  for a user dismissal.
- Deadline pause: the Paperback worker isolate ran past its 300 ms engine
  deadline for 1,200 ms between `interaction.started` and
  `interaction.ended`, then timed out 305 ms after the resume. The Tachi
  worker's pause (`PausableDeadline` over the native watchdog) is in the
  shared worker; its iOS path was not driven by an interaction here.

## Regression runs on the rebased runtime (U11 `PackageRuntime` split)

- `source_runners_ios_tachi_test.dart` (U9): **22/22** on payload
  `cd474aced982` (worker from `fa0b50a`). The AE7 JAR and APK cases for
  MangaDex, WeebCentral and MangaFire go through `Worker.prepare` →
  `JvmPackageRuntime` prepare → iOS back-edge rewrite: each prepared JAR's
  digest differs from its input (e.g. WeebCentral JAR `8b287c95…` →
  `459c257d…`), and the native-deadline cases that only rewritten back-edges
  can stop (busy loop, catch-and-continue, regex) pass. No breakage.
- `source_runners_ios_aidoku_test.dart` (U18): 9 passed, 1 manual skip
  (before the rebase; the rebase did not touch Aidoku).
- `ios_runtime_gate_test.dart` (U16) was not re-run (needs a `--gate`
  payload; nothing it covers changed).

## Packaging (`scripts/ios_package_check.sh`)

| Build | Result |
| --- | --- |
| iPhoneOS, `flutter build ios --release --no-codesign`, shipping payload (`stage_runtime.sh iphoneos`) | **pass**. Every binary arm64, platform IOS, minos 15.0 (= project target and `MinimumOSVersion`, the U16 runtime minimum); unsigned/ad hoc (no distribution or development signature, no entitlements); links only `@rpath` and system libraries; no test file, capture, extension artifact or repository reference anywhere in the bundle or the AOT snapshot; layout kinds `home`, `classpath`, `stamp` only; GPL notices present; privacy manifest in `Runner.app` covers file timestamp, boot time and disk space. Hashes: `source_runtime_ios` `a928eb03…`, `quickjs` `12cef141…` (same as U10), `wasm3` `75184e9c…`, `SwiftSoupWrapper` `b7308e33…` (full digests in the receipt) |
| iPhoneSimulator, debug test build (`--allow-test-payload --debug-engine`) | pass; x86_64 + arm64; the test payload and the debug kernel name the fixture repositories, as expected for a test build |

The R18 audit of `source_runtime_ios`'s `dlopen`/`mmap`/`mprotect` (and the
`vm_remap`/`vm_protect` this check found) is in `app-store-compliance.md`:
libffi's trampoline code is linked but has no caller; no `PROT_EXEC` path is
reachable in a Zero/BSD build; library loads sit behind
`--illegal-native-access=deny`, the baked guard and iOS library validation.

## Still open: needs a physical iPhone

- Development-signed release-profile build on a device, cold launch, no
  debugger: the six directions, AE8 (iOS suspends the app ~5 s after
  backgrounding), kill-and-relaunch, AE11. Fixtures need a test-only delivery
  on device (this harness reads them from the host checkout via
  `SRT_REPO_ROOT`, which only a simulator can do).
- Receipts with build identity, OS, device architecture, entitlement profile,
  native runtime hashes of the signed build, and the KTD25 device benchmark
  (Paperback limits and an iOS Tachi rule).
- Live MangaFire challenge on WebKit (tests may not contact the site).
- Restore spot checks of iOS-built Paperback, Aidoku and Tachi backups.
- App Store Connect validation (TestFlight setup).

## Decisions

- The loaders moved to `packages/source_loaders` (shared by the CLI and the
  app) instead of the app depending on the CLI package.
- U9's suite was renamed `source_runners_ios_tachi_test.dart` so the plan's
  `source_runners_ios_test.dart` holds the U15 conversion suite.
- `r18-app-store-guideline-mapping.md` was renamed `app-store-compliance.md`
  (the plan's path).
- The composition is not started at app launch (it starts the JVM and
  measures the device); the conversion UI installs it.
- Tachi and Paperback calls have no background gate yet (only Aidoku and the
  browser port do); this is **open and untested**. iOS suspends their threads
  with the app; a result that arrives after resume belongs to the still-open
  job, and the job publishes only validated output once every decision is
  made, so nothing stale can publish, but a call may end as `timeout` after a
  long suspension.
