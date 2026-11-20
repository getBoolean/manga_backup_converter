# Tachimanga released runtime evidence

Inspected 2026-11-19 through REA on the linked Mac. This is static evidence from the Mac-distributed iOS application, not a live iPhone qualification.

## Artifact identity

- App: Tachimanga 5.4, build 538, bundle `com.mangacrush.ios`, App Store item `6447486175`.
- Original app path on the Mac: `/Applications/Tachimanga.app`.
- Main executable SHA-256: `0d410b997282f9603cf19080bd87ef29cc4ae291fda23eb100bcae1bb9e52160`.
- Remote retained evidence: `/tmp/tachimanga-rea-9VbEUV/REPORT.md`, `sha256-manifest.txt`, `macho-cryptid.txt`, `rea-evidence-bundle.json`, native disassembly slices, and `javap` listings. These are machine-local temporary paths; preserve or export the bundle before relying on it in a later implementation session.
- Analysis thread: <t3-thread://v2/84eb2fa4-c5f5-4e48-a1f2-7d4def1c2222/mcp:launch:395df9004ebb8d50055a017c4878922c077c74c91633a3a9c70486be21092f0a>.

## Observations supporting the plan

The executable embeds OpenJ9 and JDK 17 class-library resources. The binary contains `_J9_CreateJavaVM` at `0x1002bf314`, an `OpenJ9_iOS_SDK` CocoaPod marker, OpenJ9 runtime module entry points, and a JDK `jre/lib/modules` image. Startup code supplies `-Xint` and `-Djava.compiler=NONE`. This establishes an interpreter-only startup configuration; it does not establish the active configuration of a running app.

The packaged Java code uses dex2jar to translate extension DEX into JVM bytecode, then invokes `BytecodeEditor.fixAndroidClasses`. Loading registers extension assets and instantiates classes through reflection using child-first or ordinary URL class loaders. The accepted extension-library range in these bytes is 1.3 through 1.6. Exact patcher transformations remain unresolved.

Native startup enters `+[JavaLauncher launchJVM:]` at `0x100027190`, then the VM creator and Java entry bridge at `0x10003016c` and `0x100030554`. It calls `suwayomi/tachidesk/MainKt.main`. The application embeds a modified Tachidesk server and has loopback endpoint strings for `127.0.0.1:4567`; that architecture is evidence of this reference app, not a requirement for the converter.

The native bridge supports calls into Java through `MainKt.javaChannel`, attaches/detaches threads, and uses JNI local frames. A returned duplicated string has caller-owned native storage. VM lifecycle code includes a guard against recreating the VM after destruction. Foreground/background paths coordinate request draining and socket shutdown/restart, rather than recreating the VM.

The host integrates native networking through NSURLSession, browser functionality through WKWebView, and a statically linked QuickJS JNI API. Java-side Android API shims and application-specific native glue support those paths. A native request waits for completion on a semaphore and cancels on timeout. This does not prove that arbitrary extension CPU loops are safely interruptible.

The main executable declares one encrypted 4 KiB range at file offset `0x2e000`, while the remaining inspected code is readable. The 50 inspected framework dylibs declare `cryptid=0`. Encryption must therefore be assessed per image and range, not assumed to cover every bundled framework.

## Evidence limits

No target or extension was launched. No decryption, resigning, instrumentation, or source-repository edit was performed. The original main executable hash was unchanged after analysis. REA supplied Mach-O and artifact inventories; additional native traces came from `otool` disassembly and a read-only symbol/selector resolver, and Java listings came from `javap`. No configured deep decompiler or complete disassembler callers graph was available, so those supplemental traces are attributed to the static analysis rather than presented as decompiler output. The raw exported evidence includes a failed symbol-scoped REA objdump request.

Absence of a `j9jit29` symbol supports, but does not by itself prove, that no JIT code is linked. The contents of the encrypted page, active downloaded server update, actual runtime timing, physical-iPhone behavior, and exact bytecode rewrites are unresolved. No applicable source license or reproducible build for Tachimanga's specific iOS OpenJ9 port has been established. Its readable proprietary glue is not a reusable implementation.

## Consequences for independent implementation

Use an embedded interpreter-only JVM and a direct native operation bridge as the reference architecture. Prefer investigating an independently buildable OpenJ9/JDK 17 iOS port first, without importing Tachimanga's server or proprietary bridge. Establish mobile VM and class-library build provenance before promising engine-specific delivery. Maintain one VM for the app lifetime and reset logical source sessions/class loaders, not the VM itself.

Retain the dedicated desktop worker architecture. Reuse host code only where its bytecode/class-library level is compatible with the mobile engine. Implement independent native networking, browser, and QuickJS shims for required source APIs. Prove native interruption and physical-device source operations separately; neither follows from the static reference-app startup path.

## Analyst return

The complete analyst return is retained below for attribution. Abbreviated hashes and Evidence IDs in that return are display abbreviations only; the remote manifest and exported REA bundle contain their full identities.

Tachimanga does not interpret extension bytecode directly. It converts each extension's DEX into ordinary Java bytecode with dex2jar and runs that on an OpenJ9 (JDK 17) VM built into the main executable, in interpreter-only mode. That VM hosts an embedded, modified Suwayomi/Tachidesk server, and the Flutter UI talks to it over `127.0.0.1:4567`.

Everything here is static: the app was never launched, nothing was attached, and the bundle was not modified. The main executable hash was unchanged after analysis. No Ghidra, Hopper, IDA or Kuna is configured, so I didn't set one up. I disassembled with `otool -tV` plus a small read-only resolver for ObjC selectors and strings, and read the Java side with `javap`, which only parses class files and runs nothing. Unless marked (I) for inference, the findings below are read directly from the bytes.

**Evidence directory:** `/tmp/tachimanga-rea-9VbEUV/` (mode 700). It has `REPORT.md`, `sha256-manifest.txt` (all 389 files), `macho-cryptid.txt`, the REA bundle `rea-evidence-bundle.json` (7 records), symbol and disassembly dumps, annotated function slices, `javap` listings and the scripts. I deleted the temporary extraction of `res.zip`, so no proprietary class files are kept. My REA session is exported and closed.

## Installed release
- **Location:** `/Applications/Tachimanga.app`, a Mac App Store wrapper around the iOS app.
- **Identity:** `com.mangacrush.ios`, version 5.4, build 538, App Store item 6447486175, external version id 895131952, variant `1:MacFamily20,1:18`, marked as a purchased redownload.
- **Hashes:**
  - Main executable `Tachimanga`: `0d410b997282f9603cf19080bd87ef29cc4ae291fda23eb100bcae1bb9e52160` (UUID A90D22CF-…).
  - `MCHome.bundle/res.zip`: `3a3a94b9…1dc3f`.
  - `jre/lib/modules`: `55ce9d6e…edd2`.
- **Encryption, checked per image:**
  - The main executable has cryptid=1, but only one 4 KiB page is encrypted (offset 0x2E000, about VM 0x10002E000–0x10002F000). The rest of its code is readable.
  - All 50 framework dylibs have cryptid=0.

## What runs extension code
1. **VM:** OpenJ9 for JDK 17 (version strings: "JCL 5f899adef82 based on jdk-17.0.15+6"), statically linked into the main executable. Anchors:
   - `_J9_CreateJavaVM` at 0x1002bf314.
   - Built-in VM modules `J9VMDllMain_{j9gc29,jclse29,j9jvmti29,j9trc29,j9dmp29,j9vrb29}`.
   - CocoaPod marker `PodsDummy_OpenJ9_iOS_SDK`.
   - Build-path strings `…/openj9-ios/openj9-openjdk-jdk17/openj9/runtime/…`.
   - `<redacted function 11339>` at 0x1003c5898 is the JNI_CreateJavaVM entry from OpenJ9's `j9vm/jvm.c`.
   - The class library is a jimage at `jre/lib/modules` containing `openj9.*` modules.
2. **No JIT:** the launch options pass `-Xint` and `-Djava.compiler=NONE`, and there is no `j9jit29` module in the symbol table. (I) The JIT is not linked at all.
3. **Extensions are translated, not interpreted as DEX:**
   - `PackageTools.dex2jar` uses d2j `MultiDexFileReader` and `Dex2jar`, then `BytecodeEditor.fixAndroidClasses` patches the result.
   - `loadExtensionSources0` chooses a class loader by `-Dapp.tachimanga.childfirst`:
     - 1: `org.tachiyomi.ChildFirstClassLoader`
     - 2: `ChildFirstClassLoader2`
     - otherwise: a plain `URLClassLoader`
   - It then calls `AssetManager.registerExtension`, then `Class.forName(…).getDeclaredConstructor().newInstance()`.
   - Package metadata: `tachiyomi.extension.class` and `.factory`, with extension library version accepted only between 1.3 and 1.6.

## Native bridge (proprietary app glue)
- **Startup:** `+[JavaLauncher launchJVM:]` at 0x100027190, called from a background GCD block (`-[MCBackendPlugin launch:]` 0x10004a19c → block 0x10004a45c).
  - It sets `OPENJ9_JAVA_OPTIONS=-Dcom.ibm.tools.attach.enable=no`.
  - Class path is the downloaded server JAR if one is valid, otherwise `MCHome.bundle/res.zip`.
  - Heap is `-Xms128M` / `-Xmx256M` unless overridden in user defaults.
  - Other options: `-Xshareclasses:none`, `-XX:-UseCompressedClassPointers`, `-Xdump:heap:none`, `-Xdump:snap:none`, `java.home` set to the bundle's `jre`.
  - It adds ten `-Dapp.tachimanga.*` feature switches, mostly WebView behaviour (full list in `REPORT.md`), plus extra options from the `flutter.config.joptions` user default.
  - It then calls the VM creator `jl_createJavaVM` (0x10003016c, called at 0x100027b08), then `jl_callJava` (0x100030554) on `suwayomi/tachidesk/MainKt.main`.
- **Server control:** `startServer`, `stopServer`, `startSocket`, `stopSocket` and `waitRequestDone` each call the matching `MainKt` static method (0x100027e04–0x100027f58).
- **Synchronous call into Java:** `jl_java_channel` (0x100030b5c) calls `MainKt.javaChannel(String,String)`. It returns the result as a `strdup` string that the caller must free.
- **Calls from native code back into Java:**
  - WebView: `-[NativeWebView callJava:param:]` → background queue → 0x1000167f8 → `android.webkit.WebView.onNativeCall`.
  - Dialogs: `MCNativeDialog emit:which:` → `org.tachiyomi.NativeDialog.onNativeCall`.
  - Foreground changes: 0x10001a384 → `android.app.Application.onNativeForegroundChanged`.

## Lifecycle constraints
- **One VM per process:** strings say "jl_destroyJavaVM has been called, cannot re-create the Java VM", and a pthread rwlock guards the VM pointer.
- **Threads:** every call into Java attaches the current thread, pushes a local frame, sets the context class loader, calls the method, then detaches.
- **Background:** on entering background the app starts a background task, waits for in-flight requests, stops the socket, then ends the task. On returning to foreground it calls `startSocket`.
- **Health check:** it polls `http://127.0.0.1:4567/api/v1/settings/about` and, if needed, does a stop/start restart with up to three checks.
- **Native memory ownership (I):** Java holds a `long` handle. The `NativeRef` / `NativeObject` singletons map that handle to the ObjC object. Release removes the map entry, then tears down the WebView on the main thread.
- **Network blocking:** Java threads that go through `NativeNet` block on a dispatch semaphore until the native request finishes. On timeout the request is cancelled.

## Host API shims (native code in the main executable, Java stubs in `res.zip`)
- **Network:** OkHttp's `CallNativeNetInterceptor` routes requests through `NativeNet.call_utf8` (0x10005c7b8) to NSURLSession. There is also a custom cookie jar and cookie manager.
- **WebView:** `android.webkit.WebView` is a stub. Its natives create, invoke and release a native WebView (0x1000198a8 / 0x10001996c / 0x100019f6c), backed by `NativeWebView` on WKWebView:
  - Request interception uses a custom URL scheme handler and calls Java's `interceptResponseMetadata` and `finishInterceptTask`.
  - `addJavascriptInterface` uses a WKWebView script message handler, delivered as `onWebMessage`.
  - Glue scripts are injected per frame and per content world.
  - Native work runs on queues `org.tachimanga.webview.callback` and `org.tachimanga.webview.navigation`.
- **JavaScript:** QuickJS is statically linked, with JNI entry points for the `app.cash.quickjs` API (0x10005102c onward).
- **Other:** `NativeString.indexOf` speeds up jsoup. `android.graphics.Bitmap` and `StaticLayout` are drawn with CoreGraphics. SharedPreferences comes from androidcompat's `JavaSharedPreferences`. sqlite-jdbc (`JNI_OnLoad_sqlitejdbc` at 0x100004b7c) and zstd are also linked in.

## Verification and update format
- **Extensions:** both `.apk` and pre-built `.jar` are accepted (`prepareJarExtension`, `removeJarSignatures`). `getSignatureHash` (SHA-256 of the first signing certificate) exists, but a search of `res.zip` found nothing else that calls it. So I saw no check of who signed an extension.
- **Server JAR updates:** the JAR is downloaded from a stored URL into `Application Support/Tachidesk/jars/`. It is accepted only if `sha1HashOfFileAtPath:` matches the stored hash (block 0x10004c5d4), after which the app asks the user to restart.

## Reusable third-party vs proprietary
- **Reusable third-party:**
  - Runtime: OpenJ9 and the OpenJDK 17 class library.
  - Extension pipeline: dex2jar and ASM.
  - Android compatibility: Suwayomi's androidcompat layer and the `android.*` stubs.
  - Server stack: Javalin and Jetty.
  - Network and parsing: OkHttp, Okio and jsoup.
  - Script engine: QuickJS.
  - Storage: sqlite-jdbc.
- **Proprietary:**
  - `JavaLauncher` and the `jl_*` bridge.
  - `MCBackendPlugin`.
  - The `org.tachiyomi.Native*` shims.
  - `NativeWebView` and `MCCloudflareInterceptor`.
  - The child-first class loaders.
  - The changes to Tachidesk-Server v0.7.0 "Preview".

## Planning conclusions
- **Supported:**
  - Extensions can run on iOS by translating DEX to Java bytecode and interpreting it with an embedded JVM. No DEX interpreter is needed.
  - This works with the JIT off.
  - A single VM per process, attaching and detaching threads per call, is a workable model.
  - WebView, network and JS shims can be built natively on WKWebView, NSURLSession and QuickJS.
- **Conflict with your plan:** Tachimanga runs the whole Suwayomi server in-process. Your plan excludes that server, so its source-factory loading path (`PackageTools` plus the androidcompat layer) would have to be reimplemented or separately licensed. Nothing here shows that loading extensions works without that layer.
- **Unproven:**
  - Which server JAR is active at runtime (the bundled `res.zip` or a downloaded one, which I did not examine).
  - Actual thread counts and timing.
  - What the patcher (`BytecodeEditor.fixAndroidClasses`) rewrites.
  - Whether OpenJ9 on iOS works on hardware without the Mac's memory and code-signing allowances.
  - The contents of the encrypted page.

## Tooling limits
- REA has no deep decompiler on this host, so I have no decompiled pseudocode or callers/references graph from a disassembler database. Call relationships come from my own scan of the disassembly.
- REA's objdump wrapper failed on symbol-scoped disassembly; that failure is recorded as Evidence `ev_e51e9062…`.
- A few annotations in the slices are false positives where a JNI table offset happens to match a section address (for example `sel:…` lines inside JNI calls). The report says to ignore them.

**REA Evidence IDs:**
- `inspect_macho`: `ev_aa7c8e10…dbd6` (parent `ev_d361bd9f…e4f6`).
- `res.zip` inventory: `ev_44040ea0…b9e0` (parent `ev_98aec6f5…ceaec`, inventory `ev_df7db784…3dec`).
