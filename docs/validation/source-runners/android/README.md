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
| [`u11-tachi-emulator-api36-pixel9pro-x86_64.json`](u11-tachi-emulator-api36-pixel9pro-x86_64.json) | AVD `Pixel_9_Pro`, Android 16 (API 36), x86_64, WebView 134.0.6998.135, debug build | 20/20 in one run of the file: 8 U13 cases, 11 U11 scenarios, 1 benchmark |
| [`u11-benchmark-emulator-api36-pixel9pro-x86_64.json`](u11-benchmark-emulator-api36-pixel9pro-x86_64.json) | same AVD | KTD25 inputs of the provisional Android sizing rule |
| [`u11-release-keep-rules-check.txt`](u11-release-keep-rules-check.txt) | `flutter build apk --release` (R8) | 0 unresolved host references for the three pinned APKs (static resolution; the release APK was not run) |
| [`u11-dependency-closure-releaseRuntimeClasspath.txt`](u11-dependency-closure-releaseRuntimeClasspath.txt) | `:tachi_source_host:releaseRuntimeClasspath` | resolved host closure |

Command: `flutter test integration_test/source_runners_android_test.dart -d emulator-5554 --reporter expanded` (debug, android-x64, Flutter 3.50.0). Each U11 case prints a `U11_RECEIPT` JSON line; the receipt file collects them. Host contract test: `flutter test packages/source_runtime_android/test/tachi_backend_contract_test.dart`. Desktop worker suite after the shared refactor: `./gradlew test` in `tools/tachi-source-runner`, 71/71.

## How it runs

- **Shared worker, Binder stdio.** The desktop Tachi worker (`tools/tachi-source-runner`, protocol v1) runs unchanged inside `:source_runtime`. Package handling sits behind `PackageRuntime`: `JvmPackageRuntime` (dex2jar, child-first JVM loading, KTD20 webkit shim, `StackWalker`; desktop and iOS) and `AndroidPackageRuntime` (original APK DEX on ART, real `android.webkit`). The hosting process sits behind the shared `WorkerPlatform` (U9): `AndroidHostPlatform` reports `platform: android` and its pid, with no platform deadline and no artifact rewrite. The service compiles the shared `Wire` (protocol minor 3, the desktop worker's); the U11 emulator receipts below were recorded at minor 2, before the integration, and were not re-run after it. Frames travel one-way over Binder in both directions. A frame over 32 KiB travels as a read-only `SharedMemory` descriptor with its length and SHA-256, validated and closed on every path (`FrameTransport`). The 16 MiB logical frame limit still applies.
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
| Service WebViews and storage wipe | The fixture built a real WebView in the `:source_runtime` PID (JS returned `fixture:42`). Until A's session closed, source B saw A's cookie in the shared profile (no per-source isolation; see below). After A's session closed it saw none, and after a kill and restart it saw none (`startupWipe` removed `app_webview_source_runtime`). **Cookies verified only**: `WebStorage.deleteAllData()` runs in the same wipe, but no test checks web storage |
| Offline WebView proof | Debug builds point the process's WebViews at a loopback refuser through `ProxyController`, with no DIRECT fallback. A WebView page load ends in `net::ERR_PROXY_CONNECTION_FAILED`, with no DNS lookup and no network |
| AE11 (replayed) | A captcha 403 fired once, and MangaFire's `runWebViewBlocking` ran `solver.html` in a real WebView in the service process (the `app_webview_source_runtime` directory filled). Offline, its subresources fail, so the solver gives up. The search fails `source-error` with the extension's own "Failed to solve shape-selecting captcha" message, and no request reached a server |
| Production configuration | `AndroidTachiBackend()` with no arguments (live transport, no replay, no proxy override) starts, handshakes with the committed sizing rule (pool 2, operation deadline 133,260 ms, cancel and shutdown grace 2,075 ms) and shuts down. No package was loaded, so nothing reached a server |
| Challenge Activity | `https://…` was shown in `ChallengeActivity` in the worker's PID, then closed. A `file:` URL was refused as `capability-unavailable` |
| JNI references | Over 10 rounds of worker start and close, package and jni listener references returned to baseline (`PortProxyBuilder` −2). The only growth is `LoadedApk$ServiceDispatcher$InnerConnection` (+10), one per `bindService`, held by system_server until its own GC, as U17 recorded. The worker connection reaches its listener only through relays that are cleared at exit, so these do not pin the Dart proxy |

**Open decision — per-source browser isolation is not met.** The brief asks for per-source androidx.webkit profiles where supported, and the installed WebView supports multi-profile (`webViewMultiProfile: true`). The service does not apply them. A profile must be assigned with `WebViewCompat.setProfile` before first use, and the extension constructs and configures its own WebView; the claim that no host hook exists before that first use is reasoning, not a demonstrated probe. Options: a probe (setProfile right after construction vs after a load) and, if a hook exists, per-source profiles; bytecode rewriting of WebView construction; or accepting the shared profile with the wipe rule. The handshake reports `sourceBrowserIsolation: unavailable` with that reason, and the service applies KTD19's rule instead: it wipes the shared profile at a browser-using source's session close and at every service start, and fails the browser capability if it cannot confirm the wipe.

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
- **WebView cookies and OkHttp.** WebView-acquired cookies are not copied into the package's OkHttp jar. OkHttp keeps the per-package in-memory jar (KTD9), while WebView keeps the process profile. Mihon shares a single CookieManager-backed jar; a source that relies on that sharing after a solved challenge is unverified.
- **Cloudflare interaction.** The `CloudflareInterceptor` still fails with `interaction-required` (the desktop behaviour). It does not open `ChallengeActivity` yet; the Activity and its visible-only launcher exist and are tested directly.
- **Resources.** `Context.getString(resId)` resolves against the app's resources, not the extension's: the extension's resources are not merged. None of the qualification sources call it.
- **Not implemented:**
  - Pausing new work and fencing callbacks when the app is backgrounded (KTD18 lifecycle).
  - The app-scoped conversion job and its recovery from the KTD8 journal (the journal exists in `manga_backup_core` but is not exercised on Android).
  - Activity recreation was not run. The worker lives in a bound service; nothing in U11 ties it to an Activity, and `MainActivity` handles configuration changes itself.
- **U17 gate test.** `integration_test/android_runtime_gate_test.dart` passes 4/5 on this branch. Scenario 2 asserts `construction['ok'] == false` with `Stub!`; with the real host, MangaDex's sources now construct (`ok` true), so the case stops there, before its writable and tampered staged-file checks. The file is outside U11's ownership: it needs its construction assertion updated.
