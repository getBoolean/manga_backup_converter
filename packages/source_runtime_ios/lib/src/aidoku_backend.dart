// Aidoku on iOS (KTD26): the existing Aidoku host runs unchanged in the app
// process. `AidokuPlugin` already executes each source in its own worker
// isolate (wasm3 interpreter, SwiftSoup HTML backend, GCD `WasmSemaphore`,
// postcard ABI), so this backend adds no second isolate and no iOS fork of
// WASM behaviour.
//
// KTD16: this package must not depend on a concrete loader. The composition
// root passes in the same `AidokuSourceProvider` the desktop and Android
// use. This backend adds two iOS concerns around it:
//
// * Admission: wasm3 and SwiftSoup are bundled as frameworks by their build
//   hooks. Both must load in this process, and export the symbol the host
//   calls first, before Aidoku is offered, so a missing slice fails at
//   registration rather than at the first source call. Only frameworks
//   inside the signed app bundle are opened; downloaded extensions stay
//   data for the wasm3 interpreter (R18).
// * Backgrounding (KTD12): while the app is in the background pending calls
//   answer with `CancelledFailure('app-backgrounded')`, new calls and
//   package opens are refused with the same failure, and sessions stay
//   open and usable again in the foreground. A cancelled plugin call
//   finishes in its worker isolate and the session's next call waits for it
//   (the desktop adapter's serialisation); iOS suspends that isolate with
//   the app, so nothing runs while backgrounded.
//
// Everything else passes through to the desktop sessions: identities,
// capabilities, settings revisions and refs are theirs.
//
// Browser imports: Aidoku's WebView imports stay named capability failures
// on iOS. No qualification source (MangaDex, Weeb Central, MangaFire) calls
// them, so nothing is routed to a `BrowserPort` (U13 and U18 receipts).

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:source_runtime/source_contracts.dart';

export 'package:source_runtime/source_contracts.dart' show appBackgroundedReason;

/// A native library of the Aidoku host: its framework in the app bundle and
/// the symbol the host resolves first.
typedef AidokuNativeLibrary = ({String framework, String symbol});

/// Frameworks the Aidoku host loads in the app process, as bundled in
/// `Runner.app/Frameworks/` by the wasm3 and swiftsoup build hooks.
const List<AidokuNativeLibrary> aidokuNativeLibraries = <AidokuNativeLibrary>[
  (framework: 'wasm3.framework/wasm3', symbol: 'm3_NewEnvironment'),
  (framework: 'SwiftSoupWrapper.framework/SwiftSoupWrapper', symbol: 'swiftsoup_init'),
];

/// Loads [library]; throws if the framework cannot be opened or does not
/// export the symbol.
typedef NativeLibraryLoader = void Function(AidokuNativeLibrary library);

/// The app bundle's `Frameworks/` directory.
String appFrameworksDirectory() => '${File(Platform.resolvedExecutable).parent.path}/Frameworks';

void _openFromBundle(AidokuNativeLibrary library) {
  final lib = DynamicLibrary.open('${appFrameworksDirectory()}/${library.framework}');
  if (!lib.providesSymbol(library.symbol)) {
    throw StateError('${library.framework} does not export ${library.symbol}');
  }
}

/// The Aidoku source backend registered on iOS.
final class IosAidokuBackend {
  IosAidokuBackend._(this.aidoku) {
    provider = _gate.provider(aidoku);
  }

  /// Ecosystem name the injected provider must report.
  static const String ecosystem = 'aidoku';

  /// The injected Aidoku provider, unchanged: the desktop adapter.
  final SourceProvider aidoku;

  /// The provider to offer: [aidoku] behind the backgrounding gate. Its
  /// packages and sessions delegate to [aidoku]'s.
  late final SourceProvider provider;

  /// The shared backgrounding gate (`source_runtime`).
  final BackgroundGate _gate = BackgroundGate();
  AppLifecycleListener? _lifecycle;

  /// Admits [aidoku] after checking that every library in
  /// [aidokuNativeLibraries] loads in this process.
  ///
  /// Fails with [RuntimeUnavailableFailure] naming the library that did not
  /// load, or when [aidoku] is not an Aidoku provider. [loadLibrary] is
  /// injectable for host tests; it defaults to opening the framework from
  /// the app bundle and resolving its symbol.
  static SourceOutcome<IosAidokuBackend> register(
    SourceProvider aidoku, {
    NativeLibraryLoader loadLibrary = _openFromBundle,
  }) {
    if (aidoku.ecosystem != ecosystem) {
      return SourceFailed<IosAidokuBackend>(
        RuntimeUnavailableFailure('Expected an "$ecosystem" provider, got "${aidoku.ecosystem}"'),
      );
    }
    for (final AidokuNativeLibrary library in aidokuNativeLibraries) {
      try {
        loadLibrary(library);
      } on Object catch (e) {
        return SourceFailed<IosAidokuBackend>(
          RuntimeUnavailableFailure('Aidoku runtime unavailable: ${library.framework} did not load ($e)'),
        );
      }
    }
    return SourceSuccess<IosAidokuBackend>(IosAidokuBackend._(aidoku));
  }

  /// Whether the app is treated as backgrounded.
  bool get isBackgrounded => _gate.isBackgrounded;

  /// Calls (and package opens) currently waiting on [aidoku].
  int get pendingCalls => _gate.pendingCalls;

  /// Enters or leaves the background. Entering cancels every pending call
  /// once; while backgrounded new calls are refused.
  void setBackgrounded(bool backgrounded) => _gate.setBackgrounded(backgrounded);

  /// Follows the Flutter app lifecycle: hidden or paused is backgrounded,
  /// resumed is foreground. Idempotent; undone by [dispose].
  void bindToAppLifecycle() {
    _lifecycle ??= AppLifecycleListener(
      onStateChange: (AppLifecycleState state) => switch (state) {
        AppLifecycleState.hidden || AppLifecycleState.paused => setBackgrounded(true),
        AppLifecycleState.resumed => setBackgrounded(false),
        AppLifecycleState.inactive || AppLifecycleState.detached => null,
      },
    );
  }

  /// Stops following the app lifecycle.
  void dispose() {
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
