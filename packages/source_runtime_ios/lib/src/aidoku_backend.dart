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

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:source_runtime/source_contracts.dart';

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

/// Cancellation reason while the app is backgrounded.
const String appBackgroundedReason = 'app-backgrounded';

/// The Aidoku source backend registered on iOS.
final class IosAidokuBackend {
  IosAidokuBackend._(this.aidoku) {
    provider = _GatedProvider(aidoku, this);
  }

  /// Ecosystem name the injected provider must report.
  static const String ecosystem = 'aidoku';

  /// The injected Aidoku provider, unchanged: the desktop adapter.
  final SourceProvider aidoku;

  /// The provider to offer: [aidoku] behind the backgrounding gate. Its
  /// packages and sessions delegate to [aidoku]'s.
  late final SourceProvider provider;

  final Set<CancellationSource> _pending = <CancellationSource>{};
  bool _backgrounded = false;
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
  bool get isBackgrounded => _backgrounded;

  /// Calls (and package opens) currently waiting on [aidoku].
  int get pendingCalls => _pending.length;

  /// Enters or leaves the background. Entering cancels every pending call
  /// once; while backgrounded new calls are refused.
  void setBackgrounded(bool backgrounded) {
    if (_backgrounded == backgrounded) return;
    _backgrounded = backgrounded;
    if (!backgrounded) return;
    for (final CancellationSource pending in _pending.toList()) {
      pending.cancel(appBackgroundedReason);
    }
  }

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

  /// Runs [call] with a token cancelled by [caller] or by backgrounding.
  Future<SourceOutcome<T>> _gate<T>(
    CancellationToken? caller,
    Future<SourceOutcome<T>> Function(CancellationToken cancel) call,
  ) async {
    if (_backgrounded) return SourceFailed<T>(const CancelledFailure(appBackgroundedReason));
    if (caller?.isCancelled ?? false) return SourceFailed<T>(CancelledFailure(caller!.reason ?? 'cancelled'));
    final linked = CancellationSource();
    _pending.add(linked);
    if (caller != null) unawaited(caller.whenCancelled.then((_) => linked.cancel(caller.reason ?? 'cancelled')));
    try {
      final SourceOutcome<T> outcome = await call(linked.token);
      // Fence a result that raced the background transition.
      if (linked.token.isCancelled && outcome.isSuccess) {
        return SourceFailed<T>(CancelledFailure(linked.token.reason ?? 'cancelled'));
      }
      return outcome;
    } finally {
      _pending.remove(linked);
    }
  }
}

final class _GatedProvider implements SourceProvider {
  _GatedProvider(this._inner, this._backend);

  final SourceProvider _inner;
  final IosAidokuBackend _backend;

  @override
  String get ecosystem => _inner.ecosystem;

  @override
  Future<SourceOutcome<List<PackageListing>>> discoverPackages(Uri repository, {CancellationToken? cancel}) =>
      _backend._gate(cancel, (CancellationToken c) => _inner.discoverPackages(repository, cancel: c));

  @override
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async {
    final SourceOutcome<SourcePackage> opened = await _backend._gate(cancel, (CancellationToken c) async {
      final SourceOutcome<SourcePackage> outcome = await _inner.openPackage(artifact, settings, cancel: c);
      // A package that opened after the caller was cancelled (or the app
      // was backgrounded) is fenced by the gate; close it so nothing leaks.
      if (c.isCancelled) await outcome.valueOrNull?.close();
      return outcome;
    });
    return opened.map<SourcePackage>((SourcePackage p) => _GatedPackage(p, _backend));
  }
}

final class _GatedPackage implements SourcePackage {
  _GatedPackage(this._inner, IosAidokuBackend backend)
    : sessions = List<SourceSession>.unmodifiable(<SourceSession>[
        for (final SourceSession s in _inner.sessions) _GatedSession(s, backend),
      ]);

  final SourcePackage _inner;

  @override
  final List<SourceSession> sessions;

  @override
  String get packageId => _inner.packageId;

  @override
  Future<void> close() => _inner.close();
}

final class _GatedSession implements SourceSession {
  _GatedSession(this._inner, this._backend);

  final SourceSession _inner;
  final IosAidokuBackend _backend;

  @override
  SourceIdentity get identity => _inner.identity;

  @override
  String get displayName => _inner.displayName;

  @override
  SourceCapabilities get capabilities => _inner.capabilities;

  @override
  String get settingsRevision => _inner.settingsRevision;

  @override
  Future<SourceOutcome<SearchPage>> search(SearchRequest request, {CancellationToken? cancel}) =>
      _backend._gate(cancel, (CancellationToken c) => _inner.search(request, cancel: c));

  @override
  Future<SourceOutcome<MangaSnapshot>> fetchManga(NativeMangaRef ref, {CancellationToken? cancel}) =>
      _backend._gate(cancel, (CancellationToken c) => _inner.fetchManga(ref, cancel: c));

  @override
  Future<void> close() => _inner.close();
}
