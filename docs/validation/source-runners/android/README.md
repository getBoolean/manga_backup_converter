# U17 Android runtime gate — receipts

Plan: `docs/plans/2026-11-19-0356-feat-paperback-tachi-source-runners-plan.md` (U17; KTD17, KTD18, KTD19, KTD23).

> **Emulator evidence only.** Every run below happened on x86_64 Android emulators through T3's device tools. Emulator runs do not satisfy R16. Physical ARM64 receipts are still required before M2 closes; see "Still needs a physical ARM64 device".

## Runs

| Receipt | Device | Result |
|---|---|---|
| [`emulator-api36-pixel9pro-x86_64.json`](emulator-api36-pixel9pro-x86_64.json) | AVD `Pixel_9_Pro`, Android 16 (API 36), x86_64, WebView 134.0.6998.135 | 5/5 scenarios pass |
| [`emulator-api26-x86_64.json`](emulator-api26-x86_64.json) | AVD `U17_API26_x86_64` (`system-images;android-26;google_apis;x86_64` r16, installed for this gate), Android 8.0 (API 26), image WebView Chrome 69.0.3497.100 | 5/5 pass; scenario 4 asserts the *shared* WebView directory (evidence for the decision, not a capability pass) |

Command: `flutter test integration_test/android_runtime_gate_test.dart -d <emulator> --reporter expanded`, with a debug build (android-x64, Flutter 3.50.0). Each scenario prints a `U17_RECEIPT` JSON line; the receipt files collect them verbatim. Host paths and the device staging path are omitted. The tests contact no server.

Supporting files:
- [`dependency-closure-debugRuntimeClasspath.txt`](dependency-closure-debugRuntimeClasspath.txt): resolved `:source_runtime_android:debugRuntimeClasspath`.
- [`mangadex-v1.6.4-dex-external-types.txt`](mangadex-v1.6.4-dex-external-types.txt): every type the fixture's `classes.dex` references but does not define (from `dexdump`). This is the host surface the parent class path must supply.

## Step results

### 1. JNIgen facade

- Package `packages/source_runtime_android/`: a Flutter FFI plugin (`ffiPlugin: true`, no plugin class, no channel) with `jni`, `tool/jnigen.dart`, committed bindings in `lib/src/bindings/source_runtime_bindings.g.dart`, and a manifest declaring `SourceRuntimeService` with `android:exported="false"` and `android:process=":source_runtime"`. The merged app manifest carries exactly that entry.
- `SourceRuntimeClient` (Kotlin) binds the service, dispatches one-way Binder transactions carrying a reply binder, and reports through `SourceRuntimeListener`. Dart implements that listener through JNIgen with every method as an async listener (`$async: true`). Binder threads only hand work to the client's own executor, so no Binder thread waits on Dart.
- Receipt `facade`: the app and the service run under different PIDs; the service process name is `dev.getboolean.mangabackupconverter:source_runtime`; an unknown op returns a typed failure.
- `test/no_platform_channel_test.dart` checks that no `MethodChannel`, `EventChannel`, `BasicMessageChannel`, `BinaryMessenger`, `FlutterPlugin` or Pigeon use exists in the package's Dart or Kotlin sources.
- jni/jnigen are pinned at 0.15.x because `packages/jsoup_jni` constrains the workspace to `jnigen ^0.15.0` and `jni ^0.15.2`. jnigen 0.15's summarizer reads Kotlin metadata only up to 2.1, so the facade module compiles with Kotlin `languageVersion`/`apiVersion` 2.1 (compiler 2.4.20).

### 2. Real DEX from read-only staging

- Fixture: `fixtures/source_captures/tachi/all.mangadex/tachiyomi-all.mangadex-v1.6.4.apk`, SHA-256 `611bd20d91cdd4152b6d976081cc0cd4651208f7a153ddbef133f4ebba1688c3`. Its manifest (`artifact.json`) records the source URL, digest, signer (certificate SHA-256 equals keiyoushi's published `signingKey` `9add655a…4da2`, verified with `apksigner`), and the Apache-2.0 licence. It was downloaded once; it reaches the device only through the plugin's **debug** asset set, so release builds never carry it.
- `ArtifactStaging` creates the file in no-backup storage, calls `setReadOnly()` on the path before writing any byte (through the descriptor already open), and checks the digest. Receipt: staged mode `r--------` on both API levels.
- Before creating a class loader, the service rejects any file outside private staging, any file with a write bit or that is writable, and any digest mismatch. This happens on every API level, not only on API 34+. Receipts: a writable copy, a read-only copy with one byte flipped, and staging with the wrong digest are all rejected.
- The service reads `tachiyomi.extension.class` (`keiyoushi.source.Generated`) with `getPackageArchiveInfo`, then loads the original APK with `PathClassLoader(apk, parent = service class loader)` and links the factory with `Class.forName(name, initialize = true, loader)`. Receipt: `factoryLinked`, and `sourceFactoryParentOwned` is true, meaning the factory's `SourceFactory` interface is the same `Class` object the parent loader owns.
- **Pinned source API:** `com.github.mihonapp:extensions-lib:1.6.0` (JitPack, Apache-2.0), the API matching the extension's `extensionLib 1.6`. It is a **compile-time stub library**: its method bodies throw `Stub!`.
- **Source construction does not succeed with only the pinned source API.** `createSources()` fails in `eu.kanade.tachiyomi.source.online.HttpSource.<init>(HttpSource.kt:25)` with `java.lang.Exception: Stub!` on both API levels. Source IDs were therefore not enumerated here. U11 compares them with the repository index (`index-entry.json` beside the fixture) using its real host. Because the API is a stub, this failure says nothing against feasibility.
- **Stub packaging:** the stub AAR also contains stub `androidx.preference.*` and `android.content.*` classes. They collide with the real `androidx.preference:preference:1.2.1` the app already ships (via `shared_preferences_android`): `checkDebugDuplicateClasses` fails. The plugin therefore repackages only `eu/kanade/tachiyomi/**` from the AAR (Gradle `sourceApiJar` task) and declares the POM's runtime closure explicitly. A real host module (U11) must avoid the same collision.

### 3. Termination

Five rounds per device. In each round: dispatch the fixture `cpuLoop` (call-free, ignores interruption); confirm the service still answers `ping` while looping; kill the service by the PID it reported at bind time (`Process.killProcess`, same-UID); await the binder death notification for that generation; check that the pending loop call fails with `SourceRuntimeDiedException`; then rebind explicitly. The client unbinds the dead connection first, so the framework never restarts the service behind the caller.

| Device | kill → death (ms) | death → rebound (ms) | max Dart tick gap (ms, 16 ms timer) |
|---|---|---|---|
| API 36 | 15–33 | 475–556 | ≤ 35 |
| API 26 | 30–76 | 39–72 | ≤ 42 |

Every round produced a new PID and a higher generation, and the app process PID never changed. These timings are emulator values and are not deadlines; KTD25 sizes deadlines from physical-device benchmarks in U11.

### 4. Multi-process WebView

- **API 36:** `SourceRuntimeService.onCreate` calls `WebView.setDataDirectorySuffix("source_runtime")` before anything touches WebView. With an app-process WebView alive, the service creates its own WebView. Both load local `data:` content and return `"gate:42"` from `evaluateJavascript`, and the app WebView answers again while both are alive (`liveWebViews` 2). Data directories: `app_webview` (app) and `app_webview_source_runtime` (service).
- **API 26:** the suffix API does not exist. Both processes created WebViews and returned the JS result, but both used the single `app_webview` directory. No error was raised because Android before API 28 does not enforce one process per data directory. That is absence of enforcement, not evidence of safety.

### 5. Dependency minimum SDK

| Component (resolved) | Declared minSdk | Source |
|---|---|---|
| Pinned source API `com.github.mihonapp:extensions-lib:1.6.0` (AAR) | 21 | AAR manifest |
| OkHttp `com.squareup.okhttp3:okhttp-android:5.4.0` (AAR, selected for Android) | 21 | AAR manifest |
| `io.reactivex:rxandroid:1.2.1` (AAR) | 9 | AAR manifest |
| `androidx.preference:preference:1.2.1` (AAR) | 14 | AAR manifest |
| Kotlin `kotlin-stdlib:2.4.20`, `okio-jvm:3.17.0`, `rxjava:1.3.8`, `jsoup:1.22.2`, `kotlinx-serialization-json:1.7.3`, `injekt-core:1.16.1` (JARs) | none declared | JARs carry no Android minSdk |
| **Extension** `tachiyomi-all.mangadex-v1.6.4.apk` | **26** | APK manifest (`aapt2 dump badging`); its DEX also references `java.time.*` (API 26) |

The closure's declared floor is 21, below the app's 24. The binding constraint is the extension itself (26), not the host libraries. The closure was dexed for minSdk 24 without errors and loads on API 26. Library code paths (OkHttp etc.) were not exercised beyond class loading, because source construction stops at the stub.

## Decision: below API 28 → raise minSdk to 28

U17 decides, under KTD19 and the plan's Key Decision, between single-process WebView confinement and raising minSdk to 28. **Decision: raise minSdk to 28.** U11 implements it; the host app stays at minSdk 24 in this branch.

Basis:
1. **24/25 cannot be kept either way.** The pinned keiyoushi extension declares minSdk 26 and references `java.time` in its DEX, so the realistic alternative was "raise to 26 and confine on 26/27". Choosing 28 costs only API 26 and 27 beyond that. (This is static evidence from one APK: nothing ran on 24/25, and MangaFire's APK was not inspected.)
2. **One shared profile on 26/27.** On API 26 both processes used the same `app_webview` directory. KTD19's cleanup rule (at session close or service restart, delete all service-process WebView data when multi-profile is unavailable) would then also wipe the app process's WebView data.
3. **Confinement would need a second browser path.** It requires the app process to stay WebView-free during a conversion. The merged manifest already contains url_launcher's `WebViewActivity` in the app process, and KTD19 puts Paperback's `executeInWebView` there. Confinement would mean routing app-process WebView use into the service process on two API levels only.
4. **API 28+ gives enforced, separate directories.** Proven on API 36 with both WebViews live (step 4).

Limits:
- **Levels run:** 26 and 36. API 28 itself was not run: no API 28 image was installed, which was outside this gate's install authority. Proving on API 28 is the first follow-up.
- **WebView versions:** the API 26 image's Chrome 69 is a fact about that emulator image only. No claim about WebView versions on real API 26/27 devices is part of the basis.
- **Scope:** the change narrows advertised devices for the whole app, including the Aidoku and Paperback runners. The parent should confirm that before U11 lands it. Until then the app still installs on API 24–27 with a shared WebView directory.

## JNI reference counts

Method: ART's JNI global reference table, printed by `Debug.dumpReferenceTables()` (reached reflectively; it is `@hide`) and read back from the app's own logcat. Each sample is taken after forced Dart GCs (so `package:jni`'s finalizer-owned references are deleted) and Java GC in both processes. Each round creates a fresh `AndroidSourceRuntime`, binds it, pings, unbinds and disposes it, and also unbinds and rebinds the shared runtime: two binds per round. There are 30 rounds after one warm-up round.

| Device | total before → after | package/jni-owned before → after | binder-held before → after | total minus binder-held delta |
|---|---|---|---|---|
| API 36 | 650 → 710 | 9 → 9 | 18 → 78 | 0 |
| API 26 | 684 → 742 | 7 → 7 | 12 → 72 | −2 |

- References owned by this package and the jni listener glue return to baseline: no per-round growth. The test asserts both that owned delta ≤ 2 and that the total delta minus the binder-held delta is ≤ 2.
- **The total did not return to baseline within the run.** All of the growth is `android.app.LoadedApk$ServiceDispatcher$InnerConnection`, one per `bindService`. system_server holds it as a remote Binder reference until system_server's own GC. In an earlier API 26 run the binder-held count fell from 57 to 28 mid-run as system_server collected. Reply binders were released once the service process ran GC.
- jni 0.15's generated listener glue does not release each callback's argument array (`Object[]` of 3 or 4 elements); `package:jni` frees them through `NativeFinalizer` at Dart GC. They do not accumulate across GC, but between GCs they are bounded only by allocation pressure. A newer jnigen may release them eagerly; it is blocked by the `jsoup_jni` pin.
- All counts are far below the 50,000 global-reference limit.

## Still needs a physical ARM64 device

- All five scenarios on a physical ARM64 device, release profile (R16, AE9, AE10), including kill/rebind timing and WebView coexistence on a real WebView provider.
- API 28 exactly (the lowest level after the decision), emulator or device.
- Source construction and ID comparison with a real host (U11).

## Host app effects

These come from the plugin's build script and the root dependency; `android/` is untouched and the app's minSdk is still 24.
- JitPack (`https://jitpack.io`, limited to group `com.github.mihonapp`) is added to every Gradle project's repositories. The commit-hash `injekt:91edab2317` artifact is built on demand there.
- The repackaged stub source API plus OkHttp 5.4.0, RxJava 1.3.8, rxandroid 1.2.1, jsoup 1.22.2, injekt and kotlinx-serialization 1.7.3 now ship in every app variant.
- Debug builds bundle everything under `fixtures/source_captures/tachi/` as assets, including captures other units add there later. Release builds carry none: `flutter build apk --release` succeeds and the release APK has no `assets/all.mangadex/` entry, while the debug APK has three.
- `jni` is now registered as a Windows and Linux plugin of the host app. `flutter build windows --debug` succeeds and bundles `dartjni.dll`. Linux was not built.
- R8 keeps only `dev.getboolean.sourceruntime.**` and `eu.kanade.tachiyomi.**` (`consumer-rules.pro`). Release builds still rename or strip the rest of the surface extension DEX needs (OkHttp, Okio, Kotlin, kotlinx, jsoup, injekt, androidx.preference). The gate ran only on debug builds; U11 needs keep rules for that surface.

## Not done here

- KTD23's melos regeneration script and CI drift check for the generated bindings are outside this unit's ownership. `tool/jnigen.dart` regenerates and formats the bindings, but needs a prior app build so the compiled Kotlin classes exist.
- The minSdk raise itself (U11).

---

# U13 Aidoku runner on Android — receipts

Plan: U13 (KTD22; R15, R16). **Emulator evidence only.** These runs do not satisfy R16. See "U13: still needs a physical ARM64 device" below.

| Receipt | Device or build | Result |
|---|---|---|
| [`u13-aidoku-emulator-api36-pixel9pro-x86_64.json`](u13-aidoku-emulator-api36-pixel9pro-x86_64.json) | AVD `Pixel_9_Pro`, Android 16 (API 36), x86_64, debug build | 8/8 cases pass |
| [`u13-release-apk-native-libraries.json`](u13-release-apk-native-libraries.json) | `flutter build apk --release` | wasm3 and scraper packaged for arm64-v8a, armeabi-v7a and x86_64 (inspection only) |

Command: `flutter test integration_test/source_runners_android_test.dart -d <emulator> --reporter expanded`. Every case prints a `U13_RECEIPT` JSON line; the receipt file collects them, minus PIDs.

## How it runs

- **Runtime.** The existing Aidoku host runs unchanged in the app process. `AidokuPlugin` already runs each source in its own worker isolate, using the wasm3 interpreter, the Rust scraper HTML backend, the POSIX `WasmSemaphore` backend and the postcard ABI. Neither the host imports, the WASM isolate nor the ABI was forked for Android.
- **Registration.** `packages/source_runtime_android/lib/src/aidoku_backend.dart` (`AndroidAidokuBackend.register`). The composition root injects the desktop `AidokuSourceProvider`, and the backend hands back that same instance once `libwasm3.so` and `libscraper_bridge.so` load in the app process. If either library fails to load, registration fails with `RuntimeUnavailableFailure` naming that library, before any source call. Per KTD16, the package does not depend on `aidoku_plugin_loader`.
- **No network.** Replay data is embedded by `tool/generate_android_aidoku_fixtures.dart`, which writes `integration_test/aidoku_fixture_bundle.g.dart`; `--check` verifies the bundle against the committed fixtures. The bundle holds the three pinned `.aix` files plus the capture exchanges the cases replay. Each source case asserts zero replay misses.

## Results (emulator)

| Case | Result |
|---|---|
| Native libraries | `libwasm3.so` and `libscraper_bridge.so` load through `DynamicLibrary.open` on `android_x64` |
| MangaDex `multi.mangadex` v12 | search "Onimai" 2 hits; details and 223 chapters; 3 replayed requests, 0 misses, 0 host warnings |
| Weeb Central `en.weebcentral` v6 | 1 hit; details and 114 chapters, parsed from HTML by the scraper backend; 0 misses, no "HTML parser unavailable" log |
| MangaFire `multi.mangafire` v8 | 50 hits; details and 86 chapters (VRF computed in WASM, `html::parse_fragment` through scraper); 0 misses |
| Cancel in flight (responses delayed 2 s) | `cancelled` answered after 328 ms; the next call on the same session returns hits |
| WASM trap in `get_search_manga_list` | `source-error` (message names `unreachable`) twice; the session survives |
| Isolate death (trap in `start` kills the isolate) | `runtime-unavailable` twice, within 21 ms; no `port.first` hang |
| Response headers and rate limiting (synthetic probe) | `net::get_header("x-probe")` reads `X-Probe` values 1–5 through the native shared-state header slots; with `set_rate_limit(2, 1 s)`, the sliding-window gaps were 1009/1052/1002 ms. The desktop test asserts the same |

**Browser imports.** None of the three qualification sources imports `js::webview_*`. MangaDex uses `net`/`defaults`/`std`/`env`; Weeb Central adds `html`; MangaFire adds `html::parse_fragment`. The imports therefore stay named failure stubs and nothing is routed to a `BrowserPort`.

## Host fixes this unit needed (desktop and Android)

- **Isolate death hung callers.** `Isolate.spawn` had no exit or error listener, so every `port.first` (and the handshake) waited forever once the WASM isolate died. One example: an uncaught trap in `start`, which `wasm_isolate.dart` does not guard. Every reply wait now races the isolate's exit, and a dead isolate raises `AidokuIsolateExitedException`, which the adapter maps to `RuntimeUnavailableFailure`. Calls after `dispose` fail at once. Against the old code, the new desktop tests time out.
- **Missing User-Agent.** Aidoku's own host adds its WebView user agent when a source sets none (`WasmNet.swift`, `AidokuRunner.swift`). Our host sent Dart's `Dart/<version> (dart:io)`, and Weeb Central answered 403. The HTTP dispatch now supplies a WebKit UA.
- **Weeb Central captures.** Recorded once (3 exchanges, 2026-11-20) with `tool/capture_source_fixtures.dart aidoku en.weebcentral`. The provenance of the committed `.aix` is in `fixtures/source_captures/aidoku/en.weebcentral/artifact.json`; it was not re-downloaded.

## U13: still needs a physical ARM64 device

- The eight cases on a physical ARM64 device, in a release-profile build (R16). The arm64-v8a and armeabi-v7a libraries were packaged but never loaded. These runs were debug builds; `flutter test integration_test` does not run release builds.
- **"A missing ABI fails at build time" is not tested.** A failed code-asset hook does fail the build, but no build was forced to drop an ABI, which would need an `android/` abiFilters change outside this unit.
- Live-site behaviour is re-checked only by rerunning the capture tool.

---

# U11 Tachi APK sources on Android — receipts

Plan: U11 (KTD17, KTD18, KTD19, KTD9, KTD23, KTD25; R15, R16, R17; AE10, AE11). **Emulator evidence only.** These runs do not satisfy R16. See "U11: still needs a physical ARM64 device".

| Receipt | Device or build | Result |
|---|---|---|
| [`u11-tachi-emulator-api36-pixel9pro-x86_64.json`](u11-tachi-emulator-api36-pixel9pro-x86_64.json) | AVD `Pixel_9_Pro`, Android 16 (API 36), x86_64, WebView 134.0.6998.135, debug build | originally 20/20 (8 U13 cases, 11 U11 scenarios, 1 benchmark); refreshed by U12 on `feat/source-runners` 28b44470, where the file (U13, U11 and U12 cases) passed 96 with 2 skips |
| [`u11-benchmark-emulator-api36-pixel9pro-x86_64.json`](u11-benchmark-emulator-api36-pixel9pro-x86_64.json) | same AVD | KTD25 inputs of the provisional Android sizing rule |
| [`u11-release-keep-rules-check.txt`](u11-release-keep-rules-check.txt) | `flutter build apk --release` (R8) | 0 unresolved host references for the three pinned APKs (static resolution; the release APK was not run) |
| [`u11-dependency-closure-releaseRuntimeClasspath.txt`](u11-dependency-closure-releaseRuntimeClasspath.txt) | `:tachi_source_host:releaseRuntimeClasspath` | resolved host closure |

Command: `flutter test integration_test/source_runners_android_test.dart -d emulator-5554 --reporter expanded` (debug, android-x64, Flutter 3.50.0). Each U11 case prints a `U11_RECEIPT` JSON line; the receipt file collects them. Host contract test: `flutter test packages/source_runtime_android/test/tachi_backend_contract_test.dart`. Desktop worker suite after the shared refactor: `./gradlew test` in `tools/tachi-source-runner`, 71/71.

## How it runs

- **Shared worker, Binder stdio.** The desktop Tachi worker (`tools/tachi-source-runner`, protocol v1) runs unchanged inside `:source_runtime`. Package handling sits behind `PackageRuntime`: `JvmPackageRuntime` (dex2jar, child-first JVM loading, KTD20 webkit shim, `StackWalker`; desktop and iOS) and `AndroidPackageRuntime` (original APK DEX on ART, real `android.webkit`). The hosting process sits behind the shared `WorkerPlatform` (U9): `AndroidHostPlatform` reports `platform: android` and its pid, with no platform deadline and no artifact rewrite. The service compiles the shared `Wire` (protocol minor 3, the desktop worker's). The U11 receipts were first recorded at minor 2; U12 re-ran them after the 1.3 merge (see the U12 section), and the receipt file now holds that run. Frames travel one-way over Binder in both directions. A frame over 32 KiB travels as a read-only `SharedMemory` descriptor with its length and SHA-256, validated and closed on every path (`FrameTransport`). The 16 MiB logical frame limit still applies.
- **Dart side.** `lib/src/tachi_backend.dart` presents one service worker lifetime as the `WorkerProcess` the desktop `WorkerSupervisor` drives. Deadlines, cooperative cancel, kill by PID, restart, reload of hosted packages and generation fencing are therefore the supervisor's existing behaviour. The composition root builds `TachiRuntime` (tachi_plugin_loader: catalog, trust gate, artifact cache) over it, with the artifact policy forced to APK. KTD16: the package imports `source_runtime` only. `TachiWorkerConnection` and `TachiWorkerListener` are bound through JNIgen (`tool/jnigen.dart`). Every listener method is async, and Binder threads only hand work to the connection's executor. No platform channel exists (`test/no_platform_channel_test.dart`).
- **Host module.** `tools/tachi-source-runner/android` (`:tachi_source_host`, included by `android/settings.gradle.kts`) compiles the shared sources by an explicit include list. Excluded are the desktop `android.*`/`androidx.*` stubs, the webkit shim, `root/` launch code, dex2jar and its fixes, the JVM class loader and `ios/`. The replay transport is compiled into debug builds only. The real Mihon source API replaces U17's stub `extensions-lib`, so source construction succeeds.
- **Admission.** `artifact.prepare` verifies the APK with pinned apksig against the request's `trustedSigners` and only copies the bytes; nothing executes. A JAR is refused (KTD17). `package.load` never loads the path it gets, because that is an app cache file that may be writable. It copies the file into `noBackupFilesDir/source_runtime/staged/`, marks it read-only before writing through the open descriptor, re-checks the digest, the mode and the parent directory, and only then creates the class loader.
- **Loading.** There is one child-first `BaseDexClassLoader` per package, with host-owned prefixes delegated to the parent. Package scope on ART comes from the nearest stack frame that exactly one live package loader defines, with the thread-bound package as fallback. Extensions get `AndroidHostApplication`, a real `ContextWrapper` over the service context. Its `getSharedPreferences` returns the package's in-memory stores, seeded from the protocol 1.1 settings snapshot (values, string sets, per-source scopes). `getPackageName` returns the app's real name, which WebView needs.
- **Process lifetime.** There is one worker per service process. `shutdown` or the last unbind ends the process, so the app always sees the end as a binder death. `WORKER_OPEN` is one-way; its outcome arrives as `WORKER_STARTED`, and the Dart start is bounded by the handshake deadline. WebView is only ever initialized on the service's main looper.
- **WebView.** `setDataDirectorySuffix("source_runtime")` is applied in `onCreate`, after deleting the WebView data a previous (possibly killed) instance left (`app_webview_source_runtime`, the WebView cache). Extension-created `android.webkit.WebView`s run unmodified on the service main looper. `ChallengeActivity` (`android:process=":source_runtime"`, not exported, http/https only) shows visible challenges and returns `interaction-required` while no app Activity is visible.

## Results (emulator)

| Scenario | Result |
|---|---|
| Pinned real APKs, one service | MangaDex 1.6.4: 62 sources, IDs equal the index; search "Onimai" returned 2 hits, details returned 15 chapters. WeebCentral 1.6.27: 1 source, 1 hit, 114 chapters. MangaFire 1.6.38: 7 sources, 50 hits, 86 chapters. 3 live loaders in one PID, 0 replay misses. The handshake reports `tachi-android` with a PID other than the app's |
| Two repositories, distinct loaders, duplicates | keiyoushi WeebCentral, plus fixture `busy` and `dup` from a second repository, ran in one service as 3 loaders; `busy` and `dup` both define `fixture.android.FixtureSource`. Loading `dup2`, which shares a source ID with `dup`, fails `artifact-incompatible` and names both packages and both digests. No loader was left behind |
| Read-only staging | Every staged APK is `r--------` and not writable by the process (receipt `two-repositories-duplicates-staging`). Mutable-path rejection holds **by construction**: `package.load` never loads the path it is given; it loads its own staged copy only after `requireLoadable` (parent directory, mode, digest). No passing test feeds it a writable or outside path, because the protocol cannot reach that check with one, and the U17 gate case that covered writable and tampered staged files now stops earlier at its obsolete `Stub!` assertion (see notes) |
| Tamper, re-sign, wrong anchor | One flipped byte of WeebCentral fails with a CHUNKED_SHA256 mismatch. The `busy` fixture re-signed with a throwaway key generated per build (signer `a72f0e12…`) fails as an untrusted certificate under the fixture repository's anchor. WeebCentral under the wrong anchor fails the same way. 0 loaders and 0 staged files followed. All are refused in `artifact.prepare`, before any loader |
| Descriptor transport | 20,000 chapters (about 10.7 MB of chapter JSON) arrived intact through a descriptor frame. The service closed every descriptor it sent or received |
| AE10 | The fixture's call-free CPU loop hit `operationDeadlineMs=4000`, cooperative cancel did not settle within `cancelGraceMs=500`, and the supervisor killed the PID. Death was observed, the service rebound with a new PID, and both packages reloaded (`reloadFailures` empty). The looping search failed `timeout` and was not re-sent (`requeued` empty). With `poolSize=1`, a request queued behind the loop succeeded after the restart. The largest Dart 16 ms tick gap was 60 ms |
| Password never on disk | A seeded `password` secret, and a token the fixture writes beside it, appear in no file under the app's data directory after the session runs and closes. The only `shared_prefs` file is WebView's own `WebViewChromiumPrefs.xml` |
| Service WebViews and storage wipe | The fixture built a real WebView in the `:source_runtime` PID (JS returned `fixture:42`). Until A's session closed, source B saw A's cookie in the shared profile (no per-source isolation; see below). After A's session closed it saw none, and after a kill and restart it saw none (`startupWipe` removed `app_webview_source_runtime`). U12 added web storage to this case: `localStorage` read `"kept"` before close, `null` after the session closed and `null` after the restart |
| Offline WebView proof | Debug builds point the process's WebViews at a loopback refuser through `ProxyController`, with no DIRECT fallback. A WebView page load ends in `net::ERR_PROXY_CONNECTION_FAILED`, with no DNS lookup and no network |
| AE11 (replayed) | A captcha 403 fired once, and MangaFire's `runWebViewBlocking` ran `solver.html` in a real WebView in the service process (the `app_webview_source_runtime` directory filled). Offline, its subresources fail, so the solver gives up. The search fails `source-error` with the extension's own "Failed to solve shape-selecting captcha" message, and no request reached a server |
| Production configuration | `AndroidTachiBackend()` with no arguments (live transport, no replay, no proxy override) starts, handshakes with the committed sizing rule (pool 2, operation deadline 133,260 ms, cancel and shutdown grace 2,075 ms) and shuts down. No package was loaded, so nothing reached a server |
| Challenge Activity | `https://…` was shown in `ChallengeActivity` in the worker's PID, then closed. A `file:` URL was refused as `capability-unavailable` |
| JNI references | Over 10 rounds of worker start and close, package and jni listener references returned to baseline (`PortProxyBuilder` −2). The only growth is `LoadedApk$ServiceDispatcher$InnerConnection` (+10), one per `bindService`, held by system_server until its own GC, as U17 recorded. The worker connection reaches its listener only through relays that are cleared at exit, so these do not pin the Dart proxy |

**Open decision — per-source browser isolation is not met.** (U12 probed it; see "Isolation probe" in the U12 section: it stays unavailable in the service.) The brief asks for per-source androidx.webkit profiles where supported, and the installed WebView supports multi-profile (`webViewMultiProfile: true`). The service does not apply them. A profile must be assigned with `WebViewCompat.setProfile` before first use, and the extension constructs and configures its own WebView; the claim that no host hook exists before that first use is reasoning, not a demonstrated probe. Options: a probe (setProfile right after construction vs after a load) and, if a hook exists, per-source profiles; bytecode rewriting of WebView construction; or accepting the shared profile with the wipe rule. The handshake reports `sourceBrowserIsolation: unavailable` with that reason, and the service applies KTD19's rule instead: it wipes the shared profile at a browser-using source's session close and at every service start, and fails the browser capability if it cannot confirm the wipe.

Wiping the shared profile at one source's session close also wipes it under any other browser-using source in flight in the same service.

## KTD25 sizing (provisional, emulator)

Benchmark (3 rounds): handshake p99 2772 ms (bind, process start and handshake); dispatch round trip p50 10 / p99 36 ms; qualification search or details p99 4442 ms (replay); cancel settle ≤ 7 ms; kill → rebind p99 3386 ms; kill → all packages rehydrated p99 4353 ms; shutdown p99 415 ms.

These give the rule in `tools/tachi-source-runner/android/src/main/resources/tachi-worker-sizing.json`:
- operation deadline: 4442 × 30 = 133,260 ms
- cancel and shutdown grace: 415 × 5 = 2,075 ms
- handshake deadline: 2772 × 5 = 13,860 ms (`androidTachiHandshakeDeadline`)

Pool size (`0.5 × cores`, at most 2) and the per-package heap bound were **not** benchmarked, and the factors (30×, 5×, 5×) were chosen, not measured; they are provisional bounds. The benchmark ran with WebView already initialized by `--offline-browser`; in production the wipe at package unload or shutdown may cold-start WebView inside the 2,075 ms grace (unverified). A rerun in the final pass measured handshake p99 3276 ms and rehydration p99 5069 ms, both inside the derived bounds. Replay latency excludes real network time, so the operation deadline must be re-derived from physical-device live runs.

## SDK and dependency minimums

- App: minSdk **28** (`android/app/build.gradle.kts`; KTD19, user decision). targetSdk and compileSdk are 36 (Flutter 3.50 defaults). Verified in the release APK with `aapt2 dump badging`.
- Host closure declared floors: okhttp-android 5.4.0, zstd-kmp(-okio)-android 0.4.0, androidx.webkit 1.14.0 and androidx.startup 1.2.0 declare 21; androidx.preference 1.2.1, appcompat 1.1.0 and core 1.8.0 declare 14; the JARs (Kotlin 2.4.20, kotlinx coroutines/serialization 1.11.0, okio 3.17.0, jsoup 1.22.2, rxjava 1.3.8, injekt, apksig 9.5.1) declare none. The closure floor is **21**. The pinned extensions declare **26** (MangaDex, WeebCentral and MangaFire all report `minSdkVersion:'26'`). The fixtures are built for 28.
- `zstd-kmp-android` adds `libzstd-kmp.so` for 4 ABIs. Extensions reference `okhttp3.zstd.Zstd`, so it is part of the app-provided surface.

## Release keep rules

`tools/tachi-source-runner/android/consumer-rules.pro` keeps the extension surface: `eu.kanade.tachiyomi.**`, `tachiyomi.**`, `mihon.**`, `dev.mihon.**`, Kotlin and kotlinx, OkHttp/Okio, jsoup, RxJava, Injekt, androidx.preference, androidx.webkit, brotli and zstd. It also keeps `mangabackup.tachi.**`, plus signatures, annotations and inner classes. The plugin's own rules keep the JNIgen facade types.

Verification (static; the release APK was not run): `tools/tachi-source-runner/android/tool/check_keep_rules.py` dexdumps each pinned APK and lists every class, method and field it references but does not define, outside the Android framework. It then resolves each one by its original name and signature through the superclass and interface chain in the release APK's DEX. Results for the R8 release APK: MangaDex 348, WeebCentral 230 and MangaFire 362 host member references, all resolved. The release APK's own code is obfuscated (R8 ran); it keeps the JNIgen facade's public members by name and packages `tachi-worker-sizing.json` and the coroutines `MainDispatcherFactory` service entry; and it contains no fixture assets, no replay transport, no MockWebServer and no debug hooks.

## Fixtures

- The pinned keiyoushi APKs and captures (`fixtures/source_captures/tachi/`) reach the device only through the plugin's debug asset folder.
- The synthetic U11 fixture extensions (`fixtures/source_captures/tachi-android/android-fixtures/`) are built by `tools/tachi-source-runner/android/fixtures/build_fixtures.sh`:
  - sources in `android/fixtures/kotlin`
  - d8, aapt2 and apksigner from build-tools 36.0.0
  - a test-only key, committed with its password in the script (`android/fixtures/test-signing.p12`, signer `a4ae79f5…7f8c`); the re-signing case uses a second throwaway key generated per build and never committed
- The fixtures are `busy`, `prefs`, `big`, `dup`, `dup2` and `cookies`, plus `busy` re-signed with the throwaway key. They make no network requests and also reach the device through the debug asset folder only.

## U11: still needs a physical ARM64 device

- Every scenario above on a physical ARM64 device, release profile (R16, AE10, AE11), with the three qualification sources run live as well as replayed.
- The KTD25 benchmark on devices of different capability: live operation latency for the operation deadline, plus pool size and heap per package.
- MangaFire's challenge **success** path. It needs real OpenCV and a live challenge; offline replay only exercises the WebView path. A MangaFire challenge failure keeps M2 open.
- API 28 itself (emulator or device), with MangaFire's service-process WebView alongside an app-process WebView.
- Whether `androidx.startup`, which okhttp-android pulls in, initializes anything unwanted in `:source_runtime` on real devices.

## U11 notes and gaps

- **Network contact in development runs.** Before the proxy's DIRECT fallback was removed, the AE11 case ran four times on the emulator (one of those runs succeeded through the solver), and the two runs of the proxy check before the fix let Chromium resolve `proxy-check.invalid` itself (DNS lookups). Chromium falls back to DIRECT when the proxy refuses a tunnel, so in those runs WebView subresource requests (MangaFire's solver page) may have reached the real network. Every receipt above comes from runs after the fix, which fail closed.
- **WebView cookies and OkHttp.** (Addressed in U12; see "Carried from U11".) WebView-acquired cookies are not copied into the package's OkHttp jar. OkHttp keeps the per-package in-memory jar (KTD9), while WebView keeps the process profile. Mihon shares a single CookieManager-backed jar; a source that relies on that sharing after a solved challenge is unverified.
- **Cloudflare interaction.** (Addressed in U12 for interactive runs; see "Carried from U11".) The `CloudflareInterceptor` still fails with `interaction-required` (the desktop behaviour). It does not open `ChallengeActivity` yet; the Activity and its visible-only launcher exist and are tested directly.
- **Resources.** `Context.getString(resId)` resolves against the app's resources, not the extension's: the extension's resources are not merged. None of the qualification sources call it.
- **Not implemented:**
  - Pausing new work and fencing callbacks when the app is backgrounded (KTD18 lifecycle). (Addressed by the background gate; see "Android background gate" at the end.)
  - The app-scoped conversion job and its recovery from the KTD8 journal (the journal exists in `manga_backup_core` but is not exercised on Android).
  - Activity recreation was not run. The worker lives in a bound service; nothing in U11 ties it to an Activity, and `MainActivity` handles configuration changes itself.
- **U17 gate test.** `integration_test/android_runtime_gate_test.dart` passes 4/5 on this branch. Scenario 2 asserts `construction['ok'] == false` with `Stub!`; with the real host, MangaDex's sources now construct (`ok` true), so the case stops there, before its writable and tampered staged-file checks. The file is outside U11's ownership: it needs its construction assertion updated.

# U12 Paperback and the app-process BrowserPort on Android — receipts

Plan: U12 (KTD19, KTD20, KTD23, KTD25; AE4, AE9, AE11). **Emulator evidence only** (AVD `Pixel_9_Pro`, Android 16 / API 36, x86_64, WebView 134.0.6998.135, debug build). It does not satisfy R16; every physical ARM64 cell stays open.

| Receipt | Content |
|---|---|
| [`u12-paperback-browser-emulator-api36-pixel9pro-x86_64.json`](u12-paperback-browser-emulator-api36-pixel9pro-x86_64.json) | `U12_RECEIPT` lines: Paperback in the worker isolate, and every app-process BrowserPort case |
| [`2026-11-21-android-emulator-x64-bundles-jit.json`](../../../../packages/paperback_plugin_loader/benchmark/results/2026-11-21-android-emulator-x64-bundles-jit.json) | KTD25 real-bundle benchmark on the emulator (provisional) |
| refreshed `u11-tachi-…`, `u13-aidoku-…` and `emulator-api36-pixel9pro-x86_64.json` (U17 gate) | U11, U13 and U17 re-run on this branch after the protocol 1.3 merge |

Final run, on `feat/source-runners` 28b44470 (branch head `5b584a5b`): `flutter test integration_test/source_runners_android_test.dart -d emulator-5554 --reporter expanded` passed 96 with 2 skips (the opt-in benchmark, and the contract case that applies only without a display). The benchmark ran earlier with `--dart-define=SRT_BENCH=true`. Commands: (U13, U11 and U12 cases; the U12 cases live in `integration_test/android_u12_cases.dart`) and `flutter test integration_test/android_runtime_gate_test.dart -d emulator-5554`. Host: `flutter test packages/source_runtime_android/test` (`browser_port_contract_test.dart`, `paperback_backend_contract_test.dart`) and `packages/paperback_plugin_loader/test/in_app_backend_contract_test.dart` (shared with U10).

## How it runs

- **Paperback.** The common host runs unchanged in an app-owned worker isolate through `isolatePaperbackLauncher` (the U10 design), on the QuickJS-ng the quickjs hook builds for each advertised ABI (`libquickjs.so` in `lib/{arm64-v8a,armeabi-v7a,x86_64}`). Limits come from `planPaperbackIsolateWorker()` measured on the device (KTD25 rule `quickjs-sizing-v2`); the site cases ran with those limits, not test constants. `AndroidPaperbackBackend.register` admits the injected desktop provider only after `libquickjs.so` loads. Fixtures reach the device through a debug-only Gradle task (`paperbackFixtureAssets`, assets under `source_captures/paperback/`); release variants never get them.
- **BrowserPort.** `AndroidWebViewBrowserPort` (`lib/src/browser_port.dart`) drives the Kotlin facade `browser/AppBrowserHost` through JNIgen (`AppBrowserHost` and `AppBrowserListener`, with `@Keep` and consumer rules). Every facade call only posts to the main looper and returns, and every listener method is asynchronous. No Dart isolate waits on the main thread and no main-thread code waits on Dart. No platform channel exists.
  - **Messages:** one private `WebViewCompat.addWebMessageListener` bridge per session, registered before the first load, reports the engine-attested frame origin; Dart applies the KTD20 origin rule. Channel objects and page-start scripts are `addDocumentStartJavaScript` scripts, channels first. The port refuses to start without `WEB_MESSAGE_LISTENER` and `DOCUMENT_START_SCRIPT`. WebView reports a loadData document's URL as `about:blank`, so the session uses its loadData base URL as the document for the origin rule.
  - **Evaluate (protocol 1.3):** values and thrown errors come back through `evaluateJavascript`; a returned thenable posts its settled value on the bridge (`scriptErrors` is available). A page CSP without `unsafe-eval` falls back to the unwrapped script, without promise awaiting. An evaluation still running when its WebView is destroyed settles as cancelled.
  - **Show (protocol 1.3):** `BrowserInteractionActivity` (app process, not exported) hosts the session's WebView, which lives on a `MutableContextWrapper` and outlives the Activity. The close button, back or task removal ends it as `closed`; timeout, cancel and session close hide it. A configuration change recreates the Activity, and the new instance re-attaches the same WebView.
  - **Backgrounding:** when no Activity of the process has been started for 700 ms (the `ProcessLifecycleOwner` delay, so recreation gaps do not count), pending loads and evaluations end as interaction-required, and new work and shows are refused the same way. `setBackgroundedOverride` is the test seam. (Since the background gate, the tracker lives in `AppForegroundMonitor` and the app composition passes the port the shared `AndroidAppForeground` signal; see "Android background gate".)
  - **Cookies, UA, redirects, binary data:** a cookie is set with one `Set-Cookie` line (injection refused) and read back as name and value, which is what `CookieManager` reports. A redirect to `file:` is refused as capability-unavailable; `file:` and `content:` access are off, and non-web subresources get a blocked response. Status codes are reported for HTTP errors only: WebView exposes no status for a successful main-frame load, so 200 reads as `null`. `replaceRequests` and `observeRequestBodies` are named unavailable.
  - **Replay mode** (`AndroidBrowserConfig.offline`, tests only): `ProxyController` points every WebView request of the process at a loopback refuser with no DIRECT fallback; loopback hosts keep Chromium's implicit bypass. The port refuses to start if the override is not confirmed. Debug builds allow cleartext to `127.0.0.1` only (`android/app/src/debug/res/xml/srt_debug_network_security.xml`); release keeps the platform default.

## Isolation probe

`ProfileProbe` (receipt `isolation-probe`) tried `WebViewCompat.setProfile` at five points, in both the app process and `:source_runtime`. Both gave the same result:

| After | setProfile |
|---|---|
| construction | ok |
| a settings change | ok |
| `addJavascriptInterface` | ok |
| the first load | `IllegalStateException: Cannot set new profile on a WebView that has been previously navigated.` |
| `evaluateJavascript` | `IllegalStateException: Cannot set new profile after call to evaluateJavascript` |

- **App process (Paperback, Aidoku):** isolation is **available** where the WebView supports multi-profile: each session gets its own profile right after construction. Two sources' cookies and web storage stayed apart (contract case `scopes cookies and web storage to the source`). Without multi-profile the port reports isolation unavailable and refuses a second concurrently open source by name (receipt `isolation-unavailable`, forced with `disableProfiles`).
- **Service process (Tachi):** a profile could be assigned to an extension-created WebView only by code that holds the reference between construction and first load. No host code does: the extension constructs, configures and loads its own `android.webkit.WebView` in one main-looper task. Without rewriting extension bytecode, service isolation stays **unavailable**, and the service's reason now cites this probe. The side effect is unchanged from U11: wiping the shared profile at one source's session close also wipes it under any other browser-using source in flight in the same service.
- **Profile deletion:** Chromium refuses `ProfileStore.deleteProfile` ("Cannot delete in-use profile") for at least 2 s after the profile's last WebView is destroyed. A closed session's profile is therefore emptied (cookies, web storage, HTTP cache) and kept in a process-wide pool (`ProfilePool`). It is deleted when Chromium allows it, or handed to the next session. The start-up wipe empties every port-owned profile that no live session uses.

## Results (emulator)

| Scenario | Result |
|---|---|
| QuickJS on x86_64 | loads on the root and a worker isolate; worker thread stack 1,062,887 B |
| KTD25 sizing on the device | memory 19,420,946 B, stack 433,936 B, operation deadline 196.6 s, job slice 212 ms, deadline headroom 295 ms (4 cores, 3.8 GiB) |
| AE4 WeebCentral (0.9 and two 0.8 bundles) | search, details and 114 chapters each; 0 replay misses |
| AE4 MangaDex (0.9 and 0.8 community) | 223 chapters each; 0 misses |
| AE4 Mangahub (0.8, Cloudflare-fronted) | 11 hits, details and chapters; 0 misses |
| AE11 MangaFire 0.9 `executeInWebView` | ran on the app-process WebView. Offline, the VRF capture times out with a named source error. Its subresources reached only the refuser (`CONNECT mangafire.to:443`, fonts, CDN); 0 sessions left open |
| Native limits while the isolate is blocked | sync loop `timeout` in 417 ms; promise-job loop `cancelled` in 150 ms; memory exhaustion stopped at the 16 MiB limit in 82 ms; kill through the interrupt token in 10 ms; a never-completing host call times out, and interaction events pause the deadline |
| BrowserPort contract suite (protocol 1.3) | **every applicable case passes** (one display-less case is skipped), including two-source isolation, storage gone after close and after abandon and restart, user close, page-signalled completion, timeout, cancel, and session close during a show |
| Replay fails closed | a load of `https://example.com/` fails, and so does a page fetch of `u12-replay-check.invalid`. Both appear only as `CONNECT` lines at the refuser, so the engine did no DNS lookup |
| Request observation | main frame and subresources, with headers including `sec-ch-ua*`, so `observeClientHints` is available |
| Interaction and Activity recreation | a held script in the shown session survived two recreations; user close gave completed, a 2 s timeout interaction-required, cancel cancelled |
| `executeInWebView` | cookies round-trip. An execution in flight while the interaction Activity was recreated completed. Backgrounded, it fails `interaction-required`. After a fence it fails `cancelled`, with 0 pending operations, and late results are discarded |
| 0.8 Cloudflare bypass | interactive: shown in `BrowserInteractionActivity`, and the user's `cf_clearance` returned to the host (the 0.8 clearance jar). Unattended: interaction-required |
| JNI references | over 10 open and close rounds, references held for this package's classes went from 6 to 3, but the process total grew from 802 to 909. That growth is **unattributed** (not broken down by class); it is not shown to return to baseline |

## Carried from U11

- **Service web storage:** the U11 cookie-wipe case now also stores `localStorage` in the service WebView (`ServiceDiagnostics` `webStorage`). It read `"kept"` before close, `null` after the session closed, and `null` after a kill and restart.
- **WebView cookies into the package jar:** packages whose code uses WebView read the service WebView store on each request and copy its cookies into their own in-memory jar (`PackageCookieJar.browserCookies`). JVM-tested (`BrowserCookiesAndChallengeTest`); no device fixture exercises it.
- **Cloudflare to the challenge Activity:** with `--interactive-challenges MS`, `CloudflareInterceptor` shows the challenge in the service's `ChallengeActivity` with the request's user agent, and retries once when the user closes it. Without the flag (unattended), or while the app is not visible, it stays interaction-required. JVM-tested only. The supervisor's operation deadline is **not** paused during such an in-service challenge. U8b moved the hook to a shared `CloudflareChallengeSolver` (it also receives the request and the package environment, and the desktop worker installs its own solver behind the same flag); the service's solver keeps its behaviour. The interceptor now pauses the operation's platform deadline while a solver runs, but the Android platform guard is a no-op, so this changes nothing here: pausing the supervisor's deadline for an in-service challenge still needs a worker-to-supervisor notice that protocol 1.3 does not have.

## U12: still open

- Every case on a physical ARM64 device, release profile (R16, AE4, AE11). Only x86_64 ran; the arm64-v8a and armeabi-v7a QuickJS builds are verified only by their presence in the release APK.
- Physical-device KTD25 benchmarks. The emulator run measured a deadline overshoot of 924 ms (`maxDeadlineOvershootMicros`), well above the 295 to 349 ms headroom the rule derived on the same device across runs. The rule's headroom must be revisited with physical-device data.
- MangaFire's success path, which needs a live challenge. A MangaFire failure keeps M2 open.
- Real backgrounding and a real tap on the close button went through test seams (`setBackgroundedOverride`, and `debugCloseInteractionAsUser`, which runs the close button's own handler), not through device automation.
- In the app process, web storage deletion is confirmed by the contract cases (localStorage reads back `null`), not by `WebStorage.getOrigins`. On WebView 134 it reports no origin even while `localStorage` holds data (service receipt `webStorage.stored.storageOrigins: []`). So `close` reports completed when cookies are confirmed gone and `deleteAllData` ran, without confirming web storage itself; KTD9 asks for a failure when deletion cannot be confirmed.
- The Tachi WebView-cookie copy and the interactive Cloudflare path have JVM evidence only; `AndroidSourceRuntimes` passes `--interactive-challenges` when `interactive` is set (U14), but no device job has run with it yet, and the desktop CLI passes it in interactive runs since U8b.
- The cookie copy reads the service's one shared `CookieManager`, so a cookie one WebView-using package's WebView acquired for a URL also reaches another WebView-using package's requests to that URL. This weakens KTD9's per-package cookie separation for those packages.
- `getCookies` returns name and value only (what `CookieManager.getCookie` reports), although `GET_COOKIE_INFO` is available; a clearance cookie set for a parent domain is returned without its domain.
- Only the interaction Activity was recreated. The main `FlutterActivity` was never recreated during `executeInWebView`: it owns the Flutter engine, and recreating it would end the test. No real app-process kill ran either; the kill-and-restart case abandons the port in process and starts a new one.
- Fixed bounds that are not KTD25-derived: the 700 ms background delay, the 2 s service cookie read and the 250 ms of profile-delete retries.
- The release APK was built and inspected, not run.
- Root `dart analyze --fatal-infos .` reports one pre-existing warning (`unnecessary_dev_dependency` on `tachi_plugin_loader` in `pubspec.yaml`, which U12 does not touch).

## U12 notes

- **DNS lookup in a development run.** The first version of `BrowserCookiesAndChallengeTest` put its fake site behind an OkHttp network interceptor, so OkHttp tried to resolve `site.test` before reaching it (`UnknownHostException`). No connection was made. The committed test uses an application interceptor and touches no network.

---

# U14 Android on-device conversion and packaging — receipts

Plan: U14 (R5, R9-R12, R15-R17; AE9-AE11). **Emulator evidence only.** Nothing here satisfies R16 or AE9: every physical ARM64 release-profile cell stays open (see "U14: still open").

| Receipt | Device or build | Result |
|---|---|---|
| [`u14-conversion-emulator-api36-pixel9pro-x86_64.json`](u14-conversion-emulator-api36-pixel9pro-x86_64.json) | AVD `Pixel_9_Pro`, Android 16 (API 36), x86_64, WebView 134.0.6998.135, debug build | final whole-file run (U11-U14): 105 pass, 3 skip, 0 fail; manual backgrounding 1/1; kill-and-relaunch and Activity recreation pass |
| [`u14-conversion-emulator-api28-x86_64.json`](u14-conversion-emulator-api28-x86_64.json) | AVD `U14_API28_x86_64` (`system-images;android-28;google_apis;x86_64` r11, installed for this unit), Android 9 (API 28) | final whole-file run: 35 pass, 7 skip, 67 fail; every failure is a U12 browser-port case failing closed (no `PROXY_OVERRIDE`); see "Minimum SDK (API 28)" |
| [`u14-release-apk-check.json`](u14-release-apk-check.json) | `flutter build apk --release` | package check passes on the final build (native libraries identical to the earlier build, which was installed and launched on the API 36 AVD) |
| [`u14-mihon-restore-emulator-api36-pixel9pro-x86_64.json`](u14-mihon-restore-emulator-api36-pixel9pro-x86_64.json) | Mihon 0.21.3 (official x86_64 release APK) on the API 36 AVD | restore ok; with the pinned WeebCentral APK installed, refresh kept 114 chapters (no duplicates) and the read/partial state, and Step 2 opened at page 5 |

Commands:
- `flutter test integration_test/source_runners_android_test.dart -d <emulator> --name U14 --reporter expanded` runs the U14 cases; without `--name` the file also runs U11, U12 and U13.
- Real backgrounding: add `--name "U14 background" --dart-define=SRT_MANUAL=true` and drive the device with the T3 device tools (`agent-device home` at `U14_HOLDING`, `agent-device open <package>` at `U14_BACKGROUNDED`).
- Built-app phases: `flutter build apk --debug -t integration_test/source_runners_android_test.dart --dart-define=SRT_PHASE=relaunch` (or `recreate`), `adb install -r`, then launches through `agent-device open`. The steps are in `registerU14PhaseCases` in `integration_test/android_u14_cases.dart`.

## How it runs

- **Composition.** `AndroidSourceRuntimes.start(AndroidConversionConfig)` (`lib/src/features/conversion/application/conversion_composition_android.dart`) registers three runtimes:
  - U13 Aidoku (`AndroidAidokuBackend`: wasm3 and the scraper must load).
  - U12 Paperback: the worker isolate with the KTD25 plan measured on the device. `AndroidPaperbackBackend.checkNativeLibrary` admits it only when `libquickjs.so` loads.
  - U11 Tachi (`AndroidTachiBackend`): one `:source_runtime` worker per conversion, APK artifacts only.

  Paperback's `executeInWebView` uses the app-process `AndroidWebViewBrowserPort`. If the port cannot start, Paperback still runs without it and `browserUnavailable` names the reason. iOS and Android share `LocalSourceRuntimes`: the registry, per-conversion scopes adopted by the job's `ConversionOwner`, the Paperback worker isolate and secret registration. `androidConversionServiceOverride` installs it for Riverpod.
- **User-supplied only.** The composition has no default repository, extension or settings. The app passes repositories per request, picks through its `SelectionPort`, and passes settings through `convert(settingsFor:)`. Debug-only worker arguments (`--replay`, `--offline-browser`, `--limit`, `--challenge-once`) come only from `tachiWorkerArguments`, which production leaves empty.
- **Interactive challenges.** `AndroidConversionConfig.interactive` is required. When true, the Tachi worker gets `--interactive-challenges <interactionTimeout ms>` and the browser port may show its interaction Activity. The harness runs with `false` (unattended). The supervisor's operation deadline is not paused during an in-service challenge (U12), so the interaction timeout (30 s in the harness) must stay below the adopted operation deadline (133,260 ms from the committed sizing rule). Nothing enforces that yet.
- **Nothing starts at launch.** The app's `main` creates no runtime. The installed release APK, launched through `agent-device open`, ran as one process with no `:source_runtime` (checked with `ps`). Starting the runtimes binds no service either: the R5 group asserts that `start` adds no `:source_runtime` process and that none of the conversions' service processes outlives its job (the worker ends with the conversion). In whole-file runs an earlier U11/U12 diagnostics binding can leave its own service process alive; it is recorded as foreign and excluded.
- **Harness.** Two files:
  - `integration_test/support/conversion_harness.dart`, shared with iOS: scripted selection, sanitized input, replayed catalogs, the job, and the checks on the published backup.
  - `support/android_conversion_harness.dart`: fixtures from the debug asset folders and the embedded Aidoku bundle, with the browser port in replay mode.

  Every job publishes with `AppFileConversionOutput` inside the app's data directory.

## Results (API 36 emulator)

| Case | Result |
|---|---|
| R5, six directions | All six complete through `ConversionService`: parse, local runtime fetches, reconcile, build/validate, publish. Emitted source IDs equal the runtime's: `en.weebcentral` (Aidoku), `WeebCentral` (Paperback 0.9 bundle `bd62583e…`) and `2131019126180322627` (Tachi APK `7a53282b…`), with 114 chapters each. Read and partial state transferred (Mihon targets: partial at page index 4). 0 replay misses. No browser session, worker scope or service process was left after any job. The largest main-loop gap was 639 ms, in the first job of a run (debug JIT); the assertion bound is 1 s |
| AE10 | One job (Aidoku → Mihon) picked keiyoushi WeebCentral and the U11 `busy` fixture from a second repository, with `operationDeadlineMs=4000` (now 15000: see the API 28 section on AE10). While `busy` looped, the app SIGKILLed the service: generation 2 (`exited unexpectedly with code 137`). The supervisor **re-sent** the in-flight `busy` search (`requeued: [fixture.android.busy]`), which looped into the deadline (generation 3). A second `busy` search hit the deadline again (generation 4). No reload failures. The job then searched WeebCentral in the rehydrated worker and published one complete, validated backup (main-loop gap 52 ms). WeebCentral's replay has no capture for "busy", so those two searches fail closed with a named capture miss, as expected |
| Kill and relaunch | Built debug APK, Aidoku → Mihon with the journal. Launch 1 held at publication with the journal on disk: decisions and snapshot were journaled and the service had already ended. The host killed the app process with `run-as … kill -9` (logcat: `exited due to signal 9`). Launch 2 (via `agent-device open`) resumed: 1 journaled decision reused, 0 manga asked again, journal cleared, exactly one output. The case asserts the reused decision; it does not assert that the journaled snapshot was used without a new details fetch |
| Activity recreation | "Don't keep activities" was switched on in Settings through agent-device. While launch 1 held at publication: Home, then reopen. The process survived (same PID). `MainActivity` was destroyed and **FlutterActivity destroyed its engine**, so the first Dart isolate (and the job) ended without publishing. The new engine re-ran `main`, resumed from the journal and published exactly one output. The setting was switched off afterwards |
| AE11 Paperback | MangaFire 0.9 inside an Aidoku → Paperback job opened one session on the app-process WebView. Offline, the VRF capture times out (`source-error`, "VRF capture timed out matching /api/titles?"). Nothing was published and 0 sessions were left; the next job on the same port succeeded |
| AE11 Tachi | MangaFire inside an Aidoku → Mihon job with `--challenge-once /api/titles`. The captcha 403 reached the extension, which reports its own named error (`source-error`, "Shape-selecting captcha detected…"). Nothing was published |
| Real backgrounding (manual) | Mihon → Aidoku with an Aidoku search held, then `agent-device home`. The port saw the background through the real process lifecycle, and `openSession` answered `BrowserInteractionRequired`. The Aidoku call stayed in flight, because Android has no Aidoku or Tachi background gate. It ended at the Aidoku host's 30 s request timeout as an **empty page with no named error**. After `agent-device open`, a fresh search found the match and the job published one result |

## Minimum SDK (API 28)

AVD `U14_API28_x86_64`, Android 9, image WebView 69.0.3497.100. The full file (U11, U12, U13 and U14 cases) ran on the final tree (`df1bf2c4`): **35 pass, 7 skip, 67 fail**. An earlier run on `5a2c5218` gave 33/7/68 (the extra failure was AE10, below).

- **U13 Aidoku and U11 Tachi** (APK loading, exact source IDs, two repositories, tamper/re-sign rejection, descriptor transport, AE10 kill and rehydrate, password not persisted, JNI references, production configuration) pass on API 28.
- **U14 R5**: all six directions pass with the same emitted IDs as on API 36. The browser port is absent there, and Paperback ran without it.
- **Fail closed, exercised.** The case `U14 the Tachi worker refuses --offline-browser…` started a worker with `--offline-browser` on this WebView: the start failed in 678 ms with `runtime-unavailable` naming "--offline-browser cannot block WebView network: unavailable: WebView lacks PROXY_OVERRIDE".
- **Tachi without a WebView block.** Where the probe reports no `PROXY_OVERRIDE`, Tachi runs without `--offline-browser`. Safety then rests on the loaded extensions (WeebCentral, MangaDex, MangaFire without a challenge, the U11 fixtures) not creating a WebView outside the skipped cases; nothing asserts that.
- **U14 AE10** failed once in the full run and passed on a rerun with the same restart sequence. The cause was found later on API 36, where it reproduced in 2 of 3 runs: the test's `operationDeadlineMs=4000` also applies to WeebCentral's details call, which replays near U11's measured qualification p99 (4442 ms). So the details call sometimes timed out, and the job correctly declined to publish a partial backup (`details 2131019126180322627 timeout`). The test now uses 15 s; the API 36 receipt rows below were recorded with 4 s.
- **WebView cases.** The image's WebView 69 has no `PROXY_OVERRIDE`, so replay mode cannot keep WebViews off the network:
  - the app-process port refuses to start, and the 67 U12 browser-port cases (66 contract/scenario cases and U12's MangaFire case) fail closed with "Replay mode needs PROXY_OVERRIDE";
  - the five service-WebView and U14 AE11 cases skip with that reason.

  Browser behaviour at the minimum SDK is therefore **not qualified** on this image. It needs an API 28 device or image with a WebView that has `PROXY_OVERRIDE` (newer than 69), which this image cannot update without Play.
- **Kill/relaunch, recreation and backgrounding** were not repeated on API 28.

**API 28 network contact.** The first API 28 run, before the fix, did not fail closed in the service process. The Tachi worker's `--offline-browser` hook only noted the missing override, so service WebViews used the emulator's real network:
- the U11 storage-wipe case and the challenge-Activity case looked up `proxy-check.invalid` (DNS);
- the U11 MangaFire solver page ran unblocked, and its subresources may have reached the live site.

The app-process port did refuse, and no U14 browser case ran in that run. Commit `cf40a5af` makes the worker refuse `--offline-browser` unless the override is confirmed, and the harness now probes the capability and skips WebView cases. The incident is recorded in the API 28 receipt.

## Build records

- **SDK levels** (`aapt2 dump badging` on the release APK): minSdk 28, targetSdk 36, compileSdk 36; package `dev.getboolean.mangabackupconverter` 0.1.0 (1); NDK 28.2.13676358; Flutter 3.50.0 / Dart 3.14.
- **Signing**: the release build is signed with the local Android debug key (`CN=Android Debug, O=Android, C=US`, certificate SHA-256 `38f73b527d22675ccad2379bda776416b27429ab026f93984676aaacd88d1892`), APK Signature Scheme v2. No store or distribution key exists. Distribution is by sideloading only, with no claim of store approval.
- **Native libraries**: the release APK has 30 (arm64-v8a, armeabi-v7a, x86_64). The record lists each one's size, SHA-256 and ELF machine. All 30 equal AGP's stripped outputs (`--build-dir`). The unstripped build-hook outputs are recorded beside them; AGP strips symbols, so those hashes differ.
- **Gradle dependency locks**: `android/app/gradle.lockfile` pins every resolved configuration of `:app`, including the transitive artifacts of the plugin projects it packages. Flutter's engine artifacts (`io.flutter:*`) are excluded: the Flutter tool resolves only the ABIs of each build, so a lock of every ABI made a single-ABI `flutter test` build fail. Regenerate with `cd android && ./gradlew :app:dependencies --write-locks`.
- **Package check**: `python3 -I scripts/android_package_check.py <apk> <out.json> [--build-dir build] [--expect earlier.json] [--allow-test-payload]`. The release APK passes. The U14 test APK, checked without `--allow-test-payload`, fails with 98 problems (the extension JAR/APKs, captures, catalog manifests and fixture asset folders). This shows that the payload check catches test payload.

## Notices

Two gaps existed before this unit:
- Flutter's `NOTICES.Z` covered the Dart packages but not QuickJS-ng, Wasm3 or the scraper's Rust crates: those path packages carry no LICENSE.
- Nothing in the APK carried the notices of the Kotlin/Java host libraries; they were only in `tools/tachi-source-runner/THIRD_PARTY.md`.

U14 shipped a hand-written host notices file. Since the licensing follow-up it is generated:
`scripts/generate_notices.dart android` writes `packages/source_runtime_android/notices/third_party_notices.json`
(a package asset), and `registerSourceRuntimeLicenses` registers each component on the licence page with its full
licence texts. It covers:
- every artifact of the release runtime classpath, as Gradle resolves it (`scripts/licenses/license-inputs.gradle`):
  the licence and notice files inside the JAR/AAR, else the canonical text of a POM-declared licence that names no
  holder (Apache-2.0), else a committed upstream LICENSE with its real copyright line (Brotli, Injekt and
  the repackaged protobuf in datastore), recorded with URL and SHA-256 in `scripts/licenses/components.json`;
- every Rust crate of the scraper bridge, `super_native_extensions` and `irondash_engine_context` for the three ABIs
  (the U8b mechanism, now shared: `scripts/licenses/notices.dart`);
- QuickJS-ng, Wasm3, Zstandard (statically linked in `libzstd-kmp.so`) and the extracted Mihon source API.

The generator fails when any component has no text. `scripts/android_package_check.py` derives the expected set from
what ships, not from the asset: the lockfile's `releaseRuntimeClasspath` (without platform BOMs and the Flutter engine),
`cargo metadata` for each Rust library's ABIs in the APK, and a rule per native library; it fails on any shipped library
without an entry carrying a full text (200+ characters), and on a native library without a rule. CI runs
`generate_notices.dart android --check` before the package check. `u14-release-apk-check.json` is now the
refreshed release record (304 expected components, 307 with a full text, none missing).

## U14: still open

- **Physical ARM64, release profile (R16, AE9).** All six directions, AE10, AE11, kill-and-relaunch, recreation and backgrounding still need a physical ARM64 device with a release-profile build. Only x86_64 debug builds ran these cases; the release APK was only launched.
- **MangaFire success path** (AE11) needs a live challenge. Offline it fails with named errors in both ecosystems, which keeps M2 open.
- **Backgrounding gate.** Decided and done: Android gates Aidoku, Paperback and Tachi (see "Android background gate" at the end).
- **Activity recreation ends the job.** `MainActivity` is a plain `FlutterActivity` that owns its engine, so destroying the Activity destroys the Dart isolate and the conversion; the journal makes the next launch resume. Decision: journal resume is enough; there is no cached engine and no foreground service (see "Android background gate").
- **Requeue after service death.** The supervisor re-sends a call that was in flight when the service died (AE10 receipt). If that call itself killed the service (for example, a native crash), it gets one more attempt before it fails. The deadline path does not re-send.
- **Restore.** Restoring Android-built Paperback and Aidoku backups is iOS-device work under U8's restore prerequisites. The Mihon check refreshed through Mihon's own live traffic (outside the test suite, as authorised).
- **Host notices.** Closed by the licensing follow-up: every crate, artifact and vendored library now has its full text (see Notices).
- **Not wired into the UI.** No app screen creates `AndroidSourceRuntimes` yet (the iOS branch is in the same state); the harness is the only caller.
- **Device actions outside agent-device.** Taps, Home, reopen, Settings and the Mihon UI went through agent-device. These went through adb instead: `run-as … kill -9` (the real process kill), `am force-stop` (once, which interrupted the first API 28 run), copying the backup into `/sdcard` and a media-scan broadcast, `settings get` (read-only checks), installs and logcat.
- **`--interactive-challenges` ran only in a host test** (`test/features/conversion/android_conversion_config_test.dart`); no device job ran with `interactive: true`.
- **The CI package-check step was not run in CI**; the same command passed locally on the release APK.
- **Platforms built.** Android debug and release, and Windows debug (the licence registration now imports `source_runtime_android` on every native platform). iOS, macOS and Linux were not built.
- **iOS not re-run.** The iOS branch moved onto `LocalSourceRuntimes`, and the iOS harness onto the shared harness. Both analyze clean, but no iOS suite ran (no Mac here).

# Android background gate — receipts

## Decision

- **Gate:** Android gets a background gate like iOS (parent decision). Aidoku (U13), Paperback (U12 isolate) and Tachi (U11 service) calls go through it.
- **Activity recreation → journal resume is enough.** A destroyed `MainActivity` ends the job with its engine, and the next launch resumes from the journal. There is no cached engine and no foreground service.

## How it works

- **One signal.** The Activity tracker moved out of `AppBrowserHost` into `browser/AppForeground.kt`. `AppForegroundMonitor` and `AppForegroundListener` are a JNIgen facade, with `@Keep` and consumer rules. The Dart side, `AndroidAppForeground`, notifies its listeners in order. `AndroidSourceRuntimes.start` adds the gate first and passes the same object to the browser port. Given that object, the port ignores its host's own foreground events. The gate therefore answers `cancelled: app-backgrounded` before the port reacts. The test seam is `AndroidAppForeground.setBackgroundedOverride`.
- **Challenge Activity.** Tachi's `ChallengeActivity` runs in `:source_runtime`. While this process has no started Activity, the tracker treats another process of the app (same UID) at importance `VISIBLE` or better as foreground. It re-checks every 700 ms, so an interactive Cloudflare challenge is not cancelled as backgrounding.
  - **Checked on the emulator:** a bound Tachi worker does not keep the app in the foreground after Home. In "BG real tachi" the app was reported backgrounded about 2.8 s after agent-device `home` returned (5.3 s after the case asked for it). That is a few re-checks beyond the 700 ms delay: the service's inherited importance drops shortly after the app's. So the rule did not need changing.
  - **Not checked:** the positive half, that a challenge on screen keeps the app in the foreground. The harness runs `interactive: false`, so no `ChallengeActivity` is shown during a job.
- **Gate** (`BackgroundGate`, `source_runtime`):
  - The Aidoku provider is wrapped by `gate.provider`, the shared form of the former iOS gate.
  - The workers go through `WorkerSupervisor.gate`, via `ConversionRuntimeScope(gate:)`.
  - `search` and `details` are refused when new, and interrupted in flight: they answer at once, a cooperative cancel is sent, and the late reply is dropped.
  - `artifact.prepare`, `package.load` and `settings.update` are refused when new but finish once sent. Interrupting them would leave the worker holding state the supervisor does not track.
  - `dispose`, `package.unload`, restart rehydration, handshake and shutdown are never gated.
  - A scope does not start a new worker while backgrounded.
- **iOS** uses the same `BackgroundGate` class inside `IosAidokuBackend`, with an unchanged API. iOS still gates Aidoku only: Paperback and Tachi were never gated there (`workerGate` is `null`).

## Results

API 36 emulator (AVD `Pixel_9_Pro`, Android 16, x86_64, debug build). The AVD normally lives on B:, which was full, so it ran from a temporary copy on C: with a cold boot (`-no-snapshot`); the copy was deleted afterwards.

| Suite | Result |
|---|---|
| "BG real tachi", the first case run, driven by agent-device `home`/`open` | pass: held `busy` search `cancelled: app-backgrounded`, two new searches refused, retry after reopen hit `2131019126180322627`, one validated output, no service or scope left |
| "BG real" (Aidoku, Paperback, Tachi), driven by agent-device | 3/3 pass; each held call answered `cancelled: app-backgrounded` once (0-9 ms after detection), new calls were refused, the retry after reopen hit (`en.weebcentral`, `WeebCentral`, `2131019126180322627`), and each job published one output |
| "BG programmatic" (declined and resume, three ecosystems) | 6/6 pass; declined jobs threw `PartialConversionDeclined` and published nothing, then the same runtimes published the next job; resumed jobs published exactly one output |
| Whole file `source_runners_android_test.dart` (U11-U14 + BG) | 110 pass, 7 skip, 1 fail. The failure is U11 "extension WebViews run in the service; cookies and web storage are wiped…" (`webview=timeout`, the first service WebView after a cold boot). It passed when re-run alone (1/1). That case runs only in `:source_runtime` and touches neither the tracker nor the gate |
| `packages/source_runtime` host (incl. `background_gate_test.dart`, 10 new) | 221 pass |
| `packages/source_runtime_ios` host | 12 pass (iOS device suites not run: no Mac) |
| `packages/source_runtime_android` host (incl. the shared-signal port case) | 31 pass |
| `test/features/conversion` | 7 pass |
| JNIgen bindings regenerated twice | no diff on the second run |
| Debug APK, release APK | built |
| `scripts/android_package_check.py` on the release APK (`--build-dir build`) | PASS; R8 kept `AppForegroundMonitor`, `AppForegroundListener` and `onForegroundChanged` |
| `dart analyze --fatal-infos` (three packages, `lib`, `integration_test`, `test`), format | clean |

- **Device actions.** Home and reopen went through agent-device. Once agent-device `open` reported "could not launch the application" while the app still came back to the foreground (the case recorded `foregrounded`). A System UI "isn't responding" dialog after the cold boot was dismissed with agent-device `alert dismiss`. That disturbed the first try of "BG real tachi", whose held call had already reached its deadline before Home; the receipt row above is from a clean run.
- **Detection times** (`detected-after-ask-ms` in the events) include agent-device and log-flush latency. They are upper bounds, not the tracker's own delay.
