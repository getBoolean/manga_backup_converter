// Aidoku on Android (KTD22): the existing Aidoku host runs unchanged in the
// app process. `AidokuPlugin` already executes each source in its own worker
// isolate (wasm3 interpreter, Rust scraper HTML backend, POSIX
// `WasmSemaphore`, postcard ABI), so this backend adds no second isolate and
// no Android fork of WASM behaviour.
//
// KTD16: this package must not depend on a concrete loader. The composition
// root passes in the same `AidokuSourceProvider` the desktop uses, and this
// backend hands back that very instance, so Android sessions are desktop
// sessions. What it adds is the Android admission check: both native
// libraries must load in this process before Aidoku is offered, so a
// missing ABI build fails at registration rather than at the first source
// call.
//
// Browser imports: Aidoku's WebView imports stay named capability failures
// on Android. No qualification source (MangaDex, Weeb Central, MangaFire)
// calls them, so nothing is routed to a `BrowserPort` (U13 receipts).

import 'dart:ffi';

import 'package:source_runtime/source_contracts.dart';

/// Native libraries the Aidoku host loads in the app process, as packaged
/// in `lib/<abi>/` by the wasm3 and scraper build hooks.
const List<String> aidokuNativeLibraries = <String>['libwasm3.so', 'libscraper_bridge.so'];

/// Loads the native library [fileName]; throws if it cannot be loaded.
typedef NativeLibraryLoader = void Function(String fileName);

void _dlopen(String fileName) => DynamicLibrary.open(fileName);

/// The Aidoku source backend registered on Android.
final class AndroidAidokuBackend {
  AndroidAidokuBackend._(this.provider);

  /// Ecosystem name the injected provider must report.
  static const String ecosystem = 'aidoku';

  /// The injected Aidoku provider, unchanged: the desktop adapter.
  final SourceProvider provider;

  /// Admits [aidoku] after checking that every library in
  /// [aidokuNativeLibraries] loads in this process.
  ///
  /// Fails with [RuntimeUnavailableFailure] naming the library that did not
  /// load, or when [aidoku] is not an Aidoku provider. [loadLibrary] is
  /// injectable for host tests; it defaults to `DynamicLibrary.open`.
  static SourceOutcome<AndroidAidokuBackend> register(
    SourceProvider aidoku, {
    NativeLibraryLoader loadLibrary = _dlopen,
  }) {
    if (aidoku.ecosystem != ecosystem) {
      return SourceFailed<AndroidAidokuBackend>(
        RuntimeUnavailableFailure('Expected an "$ecosystem" provider, got "${aidoku.ecosystem}"'),
      );
    }
    for (final String library in aidokuNativeLibraries) {
      try {
        loadLibrary(library);
      } on Object catch (e) {
        return SourceFailed<AndroidAidokuBackend>(
          RuntimeUnavailableFailure('Aidoku runtime unavailable: $library did not load ($e)'),
        );
      }
    }
    return SourceSuccess<AndroidAidokuBackend>(AndroidAidokuBackend._(aidoku));
  }
}
