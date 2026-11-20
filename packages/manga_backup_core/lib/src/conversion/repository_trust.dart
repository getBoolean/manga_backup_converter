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

  /// Do not use the repository.
  reject,
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

  Future<bool> admit(String ecosystem, Uri repository, String fingerprint) async {
    final key = '${InMemoryTrustStore.keyOf(ecosystem, repository)}|$fingerprint';
    if (_session.contains(key)) return true;
    final String? known = await store.fingerprintFor(ecosystem, repository);
    if (known == fingerprint) return true;
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
    switch (decision) {
      case TrustDecision.reject:
        return false;
      case TrustDecision.trustOnce:
        _session.add(key);
        return true;
      case TrustDecision.trustAndRemember:
        await store.remember(ecosystem, repository, fingerprint);
        return true;
    }
  }
}
