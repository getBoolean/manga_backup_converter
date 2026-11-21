# R18: App Store compliance of the iOS source runtimes

Status: **final for M3's local checks (U15, 2026-11-21)**, started in U16 and
extended by U9, U10 and U18. Not legal advice, and Apple has reviewed nothing.
The app ships by sideloading and then TestFlight; App Store compliance is a
design constraint (Key Decisions, KTD11). Checked locally on unsigned builds
with `scripts/ios_package_check.sh`. App Store Connect validation of a
distribution-signed build is deferred to the TestFlight setup and is not
claimed here. Physical-iPhone execution under ordinary entitlements is still
open (see the end).

## What runs

| Sources | Interpreter | Bundled as |
| --- | --- | --- |
| Tachi (repository JARs, or APKs converted on the device by dex2jar) | OpenJDK mobile HotSpot **Zero** (bytecode interpreter; no JIT, no AOT) | `source_runtime_ios.framework` (static `libsourcejvm.a` + dispatcher) and the modular image under `flutter_assets/packages/source_runtime_ios/runtime/` |
| Paperback (JavaScript bundles) | **QuickJS-ng** (interpreter) | `quickjs.framework` |
| Aidoku (`.aix` WebAssembly) | **wasm3** (interpreter) | `wasm3.framework`; HTML via `SwiftSoupWrapper.framework` |
| Browser use by any source | **WKWebView** | system framework |

The app ships no extension and no repository. The user supplies repositories,
picks extensions, and enters settings; the app composition root
(`lib/src/features/conversion/application/conversion_composition.dart`)
has no default for any of them. The packaging check fails a build whose
payload holds an extension artifact or repository configuration.

## Guideline 2.5.2: self-contained, no downloaded executable code

| Claim | Evidence |
| --- | --- |
| Downloaded extensions are data for the app's own interpreters. | Tachi bytecode runs in Zero, JS in QuickJS, WASM in wasm3. None of them produces machine code. Extension artifacts land in the app's data container, which iOS never lets an app map as code. |
| No downloaded native code can be loaded. | Four layers for the JVM, which is the only runtime that has a library-loading API: (1) `--illegal-native-access=deny` refuses JNI and `java.lang.foreign` library loads from every unnamed module; (2) the baked guard in `ClassLoader.loadLibrary` refuses any load not requested by boot or platform classes, reflective calls included (U9 tests: `System.loadLibrary`, `System.load`, reflective `System.load`, `SymbolLookup.libraryLookup` all refused, loaded image count unchanged); (3) JDK natives resolve from the app's own framework (`findBuiltinLib`, patches 0002 and 0007), not from files; (4) iOS library validation refuses any dylib not signed by Apple or the app's team. QuickJS has no `std`/`os` module (quickjs-libc is not compiled). wasm3 and QuickJS import no `dlopen`. |
| No JIT, no writable+executable memory. | See [Executable memory audit](#executable-memory-audit). No binary imports `pthread_jit_write_protect_np`, `mach_vm_protect` or `MAP_JIT` users; no JIT entitlement is requested. |
| Extensions do not change the app's purpose or create a storefront. | Extensions only search, fetch details and list chapters, to map the user's own library entries to destination identities. The app lists no extension catalog of its own. |

## Guideline 4.7: plug-ins in an interpreter

| 4.7 expectation | Design |
| --- | --- |
| Plug-ins run in an interpreter or WebKit, using embedded runtimes only. | Zero, QuickJS, wasm3, WKWebView (above). |
| The native features exposed to plug-ins are limited and listed. | **Network:** HTTP(S) through the host (OkHttp over JDK sockets in the VM for Tachi; `package:http` for Paperback and Aidoku). **Browser:** a WKWebView per source with a non-persistent `WKWebsiteDataStore`, deleted and verified on close; page loads, scripts, message channels, page-start scripts, main-frame navigation observation, cookies, user agent, and a visible interaction sheet the user can dismiss. **Storage:** per-source settings and cookies; Tachi's per-generation state directory inside the app container, deleted when the generation exits. **Nothing else:** no contacts, photos, location, camera, microphone, notifications, or files outside the source's own state. |
| Age rating of content from plug-ins rated above the app's rating. | `SourceRatingPolicy` (core) hides NSFW and unknown-rated extensions on every platform until the user enables an age-confirming setting; Tachi "mixed" content counts as suggestive and is shown (Key Decisions). The app's own rating stays moderate. The app UI that exposes the setting is part of the deferred conversion UI. |
| Precedent | Interpreted plug-ins under 4.7 (2024 revision). Exploded module directories reportedly failed App Store Connect validation (ios-tools#61), so the JVM image is modular (`lib/modules`) with the module-path fix (patch 0001). |

## Executable memory audit

`nm -u` on every bundled binary (simulator and device slices, recorded in the
U15 package receipts) shows these memory and loader imports. Each was traced
to its call sites at the runtime pin:

| Binary | Import | Call sites and why it cannot create executable memory or load downloaded code |
| --- | --- | --- |
| `source_runtime_ios.framework` | `vm_remap`, `vm_protect` | Only libffi's `closures.o` (`ffi_trampoline_table_alloc`, `FFI_EXEC_TRAMPOLINE_TABLE`). It remaps libffi's own signed trampoline page from `__TEXT` and, if needed, adds execute to that remapped signed page; it never writes code. It is also unreachable: no object in `libsourcejvm.a` calls `ffi_closure_alloc` or the raw/Java closure preparers (Zero calls only `ffi_call`), and the JDK fallback linker that would need upcall closures is not built in this static image. |
| `source_runtime_ios.framework` | `mprotect` | `os_bsd.o`: guard pages and uncommit (`PROT_NONE`), and `os::pd_commit_memory`, whose `exec` flag is forced off on iOS by patch 0006. The only `MEM_PROT_RWX` caller in HotSpot (`handle_assert_poison_fault`) is compiled only for Linux/Windows non-Zero builds. iOS refuses `PROT_EXEC` on anonymous memory without the JIT entitlement anyway. |
| `source_runtime_ios.framework` | `mmap` | Reserved heap/metaspace/code-cache ranges (`PROT_NONE`, then read/write; no `MAP_JIT` on iOS), CDS/zip/file I/O mappings (read or read/write). |
| `source_runtime_ios.framework` | `dlopen` | `os::dll_load` (behind layers 1–4 above), `print_dll_info` (diagnostics, the VM's own image), the Objective-C runtime lookup in `os::init` (system library), and `DefaultProxySelector` (fixed GNOME library names that do not exist on iOS). No path takes a file name from source code past the guards. |
| `Flutter.framework` | `mmap`, `mprotect`, `dlopen` | The Flutter engine. The debug (simulator) engine also imports `sys_icache_invalidate` for Dart JIT; the release engine is checked separately (see the receipt). |
| `sqlite3.framework`, `super_native_extensions.framework`, `Runner` | `mmap`/`dlopen` | Existing app plugins, not source runtimes; unchanged by this plan. |
| `quickjs.framework`, `wasm3.framework`, `SwiftSoupWrapper.framework` | none | — |

Re-run `scripts/ios_package_check.sh` whenever the runtime pin, patch set or a
plugin changes; it fails on a new JIT import or on a memory/loader import
outside this table.

## Privacy manifest

`ios/Runner/PrivacyInfo.xcprivacy` (bundled into `Runner.app` since U15)
declares the required-reason APIs the runtime imports: file timestamp
(`C617.1`), system boot time (`35F9.1`) and disk space (`E174.1`); no
tracking and no collected data. The package check derives the categories from
`nm -u` of every binary and fails when one is neither in the app manifest nor
in the importing framework's own manifest.

## Licensing (KTD11)

HotSpot is GPLv2 without the Classpath exception and is linked statically.
The runtime payload ships `legal/LICENSE`, `ASSEMBLY_EXCEPTION`,
`ADDITIONAL_LICENSE_INFO` and the per-module notices (the package check fails
without the first three). Since U15 the app registers those notices and a
**written offer of the corresponding source** (the pinned OpenJDK mobile
commit, libffi 3.8.1, `tools/tachi-source-runner/ios/` and the dispatcher
sources) in Flutter's `LicenseRegistry`, so they appear on the app's license
page (`registerSourceRuntimeLicenses` in `source_runtime_ios`).

## Deployment target

The project's `IPHONEOS_DEPLOYMENT_TARGET` and `MinimumOSVersion` are 15.0,
the runtime minimum U16 set; every bundled binary is built for minos ≤ 15.0
(sqlite3 is 14.0). The package check fails on any mismatch. Running on iOS
15–17 itself is unverified.

## Still open

- **Physical iPhone, ordinary entitlements, release profile, cold launch, no
  debugger** (R14): the simulator does not enforce iOS code-signing memory
  rules, so "no executable memory" holds here as a static import and
  call-site audit, not as a device observation.
- **App Store Connect validation** of a distribution-signed build: deferred to
  the TestFlight setup; needs the team ID, an Apple Distribution certificate,
  an App Store provisioning profile and the user's go-ahead to upload.
