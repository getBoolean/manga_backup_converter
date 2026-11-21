import 'package:source_runtime/source_contracts.dart' show TrustFailure, TrustFailureReason;

/// A request to trust a repository's signing identity: shown when the
/// fingerprint is first seen, or differs from the one previously trusted.
final class RepositoryTrustRequest {
  const RepositoryTrustRequest({
    required this.ecosystem,
    required this.repository,
    required this.fingerprint,
    this.previousFingerprint,
  });

  final String ecosystem;
  final Uri repository;

  /// Signing fingerprint the repository presents now.
  final String fingerprint;

  /// Fingerprint trusted before, when this is a change.
  final String? previousFingerprint;

  bool get isChange => previousFingerprint != null;
}

/// The user's answer to a [RepositoryTrustRequest].
enum TrustDecision {
  /// Trust this fingerprint for this run only.
  trustOnce,

  /// Trust and remember the fingerprint, so it is not asked again.
  trustAndRemember,

  /// Do not use the repository (the user, or a policy, said no).
  reject,

  /// Nobody could be asked (an unattended run without a pin): the
  /// fingerprint is not trusted. Reported as first-seen or changed, never as
  /// a refusal.
  unanswered,
}

/// Remembered repository fingerprints; persisted by a platform adapter.
abstract interface class TrustStore {
  Future<String?> fingerprintFor(String ecosystem, Uri repository);

  Future<void> remember(String ecosystem, Uri repository, String fingerprint);
}

/// A [TrustStore] held in memory.
final class InMemoryTrustStore implements TrustStore {
  InMemoryTrustStore([Map<String, String>? initial]) : _fingerprints = <String, String>{...?initial};

  final Map<String, String> _fingerprints;

  /// Remembered fingerprints keyed by `ecosystem|repository`.
  Map<String, String> get fingerprints => Map<String, String>.unmodifiable(_fingerprints);

  static String keyOf(String ecosystem, Uri repository) => '$ecosystem|$repository';

  @override
  Future<String?> fingerprintFor(String ecosystem, Uri repository) async => _fingerprints[keyOf(ecosystem, repository)];

  @override
  Future<void> remember(String ecosystem, Uri repository, String fingerprint) async =>
      _fingerprints[keyOf(ecosystem, repository)] = fingerprint;
}

/// Admits signed repositories: an unchanged remembered fingerprint passes
/// silently; a first-seen or changed fingerprint is decided by the user
/// through [decide] (the `SelectionPort`).
///
/// Loaders whose repositories carry a signing identity (Tachi, Paperback)
/// call [admit] before using a repository's listings; Aidoku repositories are
/// unsigned and never consult it.
final class RepositoryTrustGate {
  RepositoryTrustGate({required this.store, required this.decide});

  final TrustStore store;
  final Future<TrustDecision> Function(RepositoryTrustRequest request) decide;

  /// Fingerprints trusted once during this run.
  final Set<String> _session = <String>{};

  /// Decisions taken through [decide], for the conversion report.
  final List<String> decisions = <String>[];

  /// Whether [fingerprint] is admitted for [repository] (see [check]).
  Future<bool> admit(String ecosystem, Uri repository, String fingerprint) async =>
      await check(ecosystem, repository, fingerprint) == null;

  /// `null` when [fingerprint] is admitted for [repository]; otherwise the
  /// [TrustFailure] saying why not:
  /// - [TrustFailureReason.refused] when the user (or a policy) answered no;
  /// - [TrustFailureReason.changed] when nobody could be asked and a
  ///   different fingerprint was remembered;
  /// - [TrustFailureReason.firstSeen] when nobody could be asked and none
  ///   was remembered.
  Future<TrustFailure?> check(String ecosystem, Uri repository, String fingerprint) async {
    final key = '${InMemoryTrustStore.keyOf(ecosystem, repository)}|$fingerprint';
    if (_session.contains(key)) return null;
    final String? known = await store.fingerprintFor(ecosystem, repository);
    if (known == fingerprint) return null;
    final request = RepositoryTrustRequest(
      ecosystem: ecosystem,
      repository: repository,
      fingerprint: fingerprint,
      previousFingerprint: known,
    );
    final TrustDecision decision = await decide(request);
    decisions.add(
      '${request.isChange ? 'Changed' : 'First-seen'} signing fingerprint for $repository ($ecosystem): ${decision.name}',
    );
    final what = request.isChange
        ? 'The signing fingerprint of $repository ($ecosystem) changed to $fingerprint'
        : 'The signing fingerprint $fingerprint of $repository ($ecosystem) is first seen';
    switch (decision) {
      case TrustDecision.reject:
        return TrustFailure(TrustFailureReason.refused, '$what and was refused');
      case TrustDecision.unanswered:
        return TrustFailure(
          request.isChange ? TrustFailureReason.changed : TrustFailureReason.firstSeen,
          '$what and nobody could approve it in this run',
        );
      case TrustDecision.trustOnce:
        _session.add(key);
        return null;
      case TrustDecision.trustAndRemember:
        await store.remember(ecosystem, repository, fingerprint);
        return null;
    }
  }
}
