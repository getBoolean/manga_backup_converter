# source_runtime_ios

Embedded interpreter-only JVM (OpenJDK mobile, HotSpot Zero) and WKWebView
bindings for iOS source runners. This is the U16 feasibility-gate package
(KTD11, KTD13, KTD23).

- `lib/src/runtime_bindings.g.dart`: FFIgen bindings for the JNI invocation
  interface (`src/include/jni.h`) and the native dispatcher
  (`src/source_runtime_ios.h`).
- `lib/src/webkit_bindings.g.dart` and `src/webkit_bindings.g.m`: FFIgen
  bindings for the WebKit classes and protocols used by `WKWebViewReplay`.
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
