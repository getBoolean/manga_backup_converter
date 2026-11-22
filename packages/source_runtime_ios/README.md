# source_runtime_ios

Embedded interpreter-only JVM (OpenJDK mobile, HotSpot Zero) and WKWebView
bindings for iOS source runners. This is the U16 feasibility-gate package
(KTD11, KTD13, KTD23).

- `lib/src/runtime_bindings.g.dart`: FFIgen bindings for the JNI invocation
  interface (`src/include/jni.h`) and the native dispatcher
  (`src/source_runtime_ios.h`).
- `lib/src/webkit_bindings.g.dart` and `src/webkit_bindings.g.m`: FFIgen
  bindings for the WebKit and UIKit classes and protocols used by
  `WKWebViewReplay` (U16) and `WKWebViewBrowserPort` (U10).
- `lib/src/wkwebview_browser_port.dart`: `WKWebViewBrowserPort`, the
  `BrowserPort` (KTD13, KTD20) over WKWebView, written in Dart over the FFIgen
  bindings: a non-persistent `WKWebsiteDataStore` per session (sources never
  share one; close deletes and verifies), WebKit calls on the platform thread
  through `runOnPlatformThread` (the root isolate is on that thread in Flutter
  3.50), Dart-implemented navigation, script-message and sheet-dismissal
  delegates (`implementAsListener`), the protocol 1.1/1.2 message channel and
  page-start scripts as document-start `WKUserScript`s in every frame, script
  errors as `BrowserScriptError`, http(s)-only navigation enforced at the port
  and in the navigation delegate, visible interaction as a presented sheet,
  backgrounding (KTD12), and an offline content rule list for tests. Paperback
  `executeInWebView` and U9's Tachi `android.webkit` translation both reach it
  through `BrowserReverseBridge`. Capability report: `wkWebViewCapabilities`.
- `lib/src/webkit/nullable_blocks.dart`: listener blocks for completion
  handlers whose object arguments may be nil (FFIgen's generated ones assert).
- `lib/src/ios_jvm_runtime.dart`: `IosJvmRuntime` (one VM per process;
  operations run on dispatcher-owned threads and complete through
  `NativeCallable.listener`) and `BundledRuntime` (recreates `java.home`
  from the staged package assets).
- `hook/build.dart`: links the dispatcher, the ObjC trampolines and, when it
  is built, `tools/tachi-source-runner/ios/build/out/<sdk>/lib/libsourcejvm.a`
  into one framework for iOS. There are no assets for other OSes.

Regenerate bindings: `dart run tool/ffigen.dart`. Build and stage the
runtime: `tools/tachi-source-runner/ios/README.md`. There are no platform
channels.

## Local Tachi backend (U9)

`IosTachiBackend` (`lib/src/tachi_backend.dart`) runs the shared Tachi worker
inside the embedded VM (`InVmWorkerProcess`, a native byte channel instead of
a process) and implements `SourceProvider` over the shared supervisor, session
and browser-bridge code. Every operation has a native deadline enforced by the
dispatcher's watchdog. Stage the payload with
`tools/tachi-source-runner/ios/scripts/stage_runtime.sh <sdk> [--gate] [--test]`;
evidence and decisions are in `docs/validation/source-runners/ios/README.md`.
