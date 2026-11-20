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
