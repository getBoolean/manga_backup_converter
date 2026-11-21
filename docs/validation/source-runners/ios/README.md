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

## Results by scenario (22/22 passed, `integration_test/source_runners_ios_test.dart`)

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
