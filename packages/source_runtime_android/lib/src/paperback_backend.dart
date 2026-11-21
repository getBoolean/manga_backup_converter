// Paperback on Android (KTD19, U12): the common Paperback host runs unchanged
// in an app-owned worker isolate (`isolatePaperbackLauncher` in
// paperback_plugin_loader, shared with U10 iOS), on the vendored QuickJS-ng
// that the quickjs build hook compiles for every advertised Android ABI
// (arm64-v8a, armeabi-v7a, x86_64). No Kotlin copy of the host, no desktop
// process launch, and no Tachi-service involvement.
//
// KTD16: this package must not depend on a concrete loader. The composition
// root builds the same `PaperbackSourceProvider` the desktop uses, with the
// in-app isolate launcher and limits from `planPaperbackIsolateWorker()`
// (the KTD25 rule measured on this device), and passes it in. This backend
// adds the Android admission check (QuickJS must load in this process before
// Paperback is offered, so a missing ABI build fails at registration, not at
// the first source call) and pairs the provider with the app-process
// `BrowserPort` that serves `executeInWebView` and the 0.8 Cloudflare bypass
// through `BrowserReverseBridge`.

import 'dart:ffi';

import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_android/src/aidoku_backend.dart' show NativeLibraryLoader;

/// The QuickJS-ng library the Paperback host loads, as packaged in
/// `lib/<abi>/` by the quickjs build hook.
const String paperbackNativeLibrary = 'libquickjs.so';

void _dlopen(String fileName) => DynamicLibrary.open(fileName);

/// The Paperback source backend registered on Android.
final class AndroidPaperbackBackend {
  AndroidPaperbackBackend._(this.provider, this.browser);

  /// Ecosystem name the injected provider must report.
  static const String ecosystem = 'paperback';

  /// The injected Paperback provider, unchanged: the desktop adapter over
  /// the in-app worker isolate.
  final SourceProvider provider;

  /// The app-process browser port behind `executeInWebView`, or `null` when
  /// the composition root runs without one (browser sources then fail with
  /// a named capability error).
  final BrowserPort? browser;

  /// Admits [paperback] after checking that [paperbackNativeLibrary] loads
  /// in this process. Fails with [RuntimeUnavailableFailure] naming the
  /// library, or when [paperback] is not a Paperback provider.
  static SourceOutcome<AndroidPaperbackBackend> register(
    SourceProvider paperback, {
    BrowserPort? browser,
    NativeLibraryLoader loadLibrary = _dlopen,
  }) {
    if (paperback.ecosystem != ecosystem) {
      return SourceFailed<AndroidPaperbackBackend>(
        RuntimeUnavailableFailure('Expected a "$ecosystem" provider, got "${paperback.ecosystem}"'),
      );
    }
    try {
      loadLibrary(paperbackNativeLibrary);
    } on Object catch (e) {
      return SourceFailed<AndroidPaperbackBackend>(
        RuntimeUnavailableFailure('Paperback runtime unavailable: $paperbackNativeLibrary did not load ($e)'),
      );
    }
    return SourceSuccess<AndroidPaperbackBackend>(AndroidPaperbackBackend._(paperback, browser));
  }
}
