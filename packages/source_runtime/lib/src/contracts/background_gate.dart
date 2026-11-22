import 'dart:async';

import 'package:source_runtime/src/contracts/cancellation.dart';
import 'package:source_runtime/src/contracts/identity.dart';
import 'package:source_runtime/src/contracts/outcome.dart';
import 'package:source_runtime/src/contracts/source.dart';

/// Cancellation reason while the app is backgrounded (KTD12, KTD18).
const String appBackgroundedReason = 'app-backgrounded';

/// The app-lifecycle gate in front of source work (KTD12 on iOS, KTD18 on
/// Android).
///
/// While backgrounded:
/// - new gated work is refused with `CancelledFailure('app-backgrounded')`;
/// - work in flight that the gate may interrupt ([run] with
///   `interruptible: true`) answers once with the same failure at the moment
///   the app leaves the foreground, and a success that raced that
///   transition is fenced (turned into the failure), so no late result
///   reaches the conversion.
///
/// Returning to the foreground re-admits work; sessions behind the gate stay
/// open. The gate holds no platform signal itself: a host calls
/// [setBackgrounded] from its one lifecycle source.
final class BackgroundGate {
  final Set<CancellationSource> _pending = <CancellationSource>{};
  bool _backgrounded = false;

  /// Whether the app is treated as backgrounded.
  bool get isBackgrounded => _backgrounded;

  /// Interruptible calls currently in flight behind the gate.
  int get pendingCalls => _pending.length;

  /// Enters or leaves the background. Entering cancels every pending
  /// interruptible call once, synchronously; while backgrounded new calls
  /// are refused.
  void setBackgrounded(bool backgrounded) {
    if (_backgrounded == backgrounded) return;
    _backgrounded = backgrounded;
    if (!backgrounded) return;
    for (final CancellationSource pending in _pending.toList()) {
      pending.cancel(appBackgroundedReason);
    }
  }

  /// The refusal for new work while backgrounded, or `null` in the
  /// foreground.
  SourceFailed<T>? refusal<T>() =>
      _backgrounded ? SourceFailed<T>(const CancelledFailure(appBackgroundedReason)) : null;

  /// Runs [call] behind the gate.
  ///
  /// Refused while backgrounded or when [caller] is already cancelled. With
  /// [interruptible] (the default), [call] receives a token cancelled by
  /// [caller] or by backgrounding, and a success that arrives after that
  /// token was cancelled is answered as cancelled. Without it, [call] only
  /// sees [caller] and always runs to completion once admitted (for work
  /// whose interruption would leave the runtime holding state the host no
  /// longer tracks, such as a package load).
  ///
  /// [call] is invoked synchronously, so callers that order work on
  /// submission keep their order.
  Future<SourceOutcome<T>> run<T>(
    CancellationToken? caller,
    Future<SourceOutcome<T>> Function(CancellationToken cancel) call, {
    bool interruptible = true,
  }) async {
    final SourceFailed<T>? refused = refusal<T>();
    if (refused != null) return refused;
    if (caller?.isCancelled ?? false) return SourceFailed<T>(CancelledFailure(caller!.reason ?? 'cancelled'));
    if (!interruptible) return call(caller ?? CancellationToken.none);
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

  /// [inner] behind this gate: discovery, package opens and session calls
  /// are gated and interruptible; a package that opens after its call was
  /// cancelled is closed so nothing leaks. Identities, capabilities, settings
  /// revisions and refs are [inner]'s.
  SourceProvider provider(SourceProvider inner) => _GatedProvider(inner, this);
}

final class _GatedProvider implements SourceProvider {
  _GatedProvider(this._inner, this._gate);

  final SourceProvider _inner;
  final BackgroundGate _gate;

  @override
  String get ecosystem => _inner.ecosystem;

  @override
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async {
    final SourceOutcome<SourcePackage> opened = await _gate.run(cancel, (CancellationToken c) async {
      final SourceOutcome<SourcePackage> outcome = await _inner.openPackage(artifact, settings, cancel: c);
      // A package that opened after the caller was cancelled (or the app
      // was backgrounded) is fenced by the gate; close it so nothing leaks.
      if (c.isCancelled) await outcome.valueOrNull?.close();
      return outcome;
    });
    return opened.map<SourcePackage>((SourcePackage p) => _GatedPackage(p, _gate));
  }
}

final class _GatedPackage implements SourcePackage {
  _GatedPackage(this._inner, BackgroundGate gate)
    : sessions = List<SourceSession>.unmodifiable(<SourceSession>[
        for (final SourceSession s in _inner.sessions) _GatedSession(s, gate),
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
  _GatedSession(this._inner, this._gate);

  final SourceSession _inner;
  final BackgroundGate _gate;

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
      _gate.run(cancel, (CancellationToken c) => _inner.search(request, cancel: c));

  @override
  Future<SourceOutcome<MangaSnapshot>> fetchManga(NativeMangaRef ref, {CancellationToken? cancel}) =>
      _gate.run(cancel, (CancellationToken c) => _inner.fetchManga(ref, cancel: c));

  @override
  Future<void> close() => _inner.close();
}
