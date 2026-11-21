import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/src/artifact_store.dart';
import 'package:tachi_plugin_loader/src/catalog.dart';

/// [SourceIdentity.ecosystem] of Tachi sources.
const String tachiEcosystem = 'tachi';

/// Host compatibility version of prepared artifacts: part of their cache
/// identity (KTD5; `docs/source-runners.md`, artifact paths).
const String tachiHostCompatibility = 'tachi-host.1';

/// Returns the conversion's started JVM worker, for example
/// `() => scope.worker(WorkerKind.jvm)`. Every package of a conversion is
/// hosted by the one supervisor this returns (KTD1).
typedef TachiWorkerAccess = Future<SourceOutcome<WorkerSupervisor>> Function();

/// The signing identity a package's artifacts were verified against (KTD5):
/// the fingerprint the user approved (or a manifest pinned) for the
/// repository. A JAR and an APK share a trust identity only when both were
/// verified against the same repository fingerprint.
@immutable
final class TachiTrustIdentity {
  TachiTrustIdentity({required Uri repository, required String fingerprint})
    : repository = tachiRepositoryBase(repository),
      fingerprint = ArtifactTrustAnchor.normalizeFingerprint(fingerprint);

  final Uri repository;

  /// Certificate SHA-256, 64 lowercase hex digits.
  final String fingerprint;

  ArtifactTrustAnchor get anchor => ArtifactTrustAnchor(signerFingerprints: <String>[fingerprint]);

  @override
  bool operator ==(Object other) =>
      other is TachiTrustIdentity && other.repository == repository && other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(repository, fingerprint);

  @override
  String toString() => 'TachiTrustIdentity($repository, ${fingerprint.substring(0, 8)}…)';
}

/// A package artifact that passed `artifact.prepare`: signature verified by
/// the worker against [trust], converted when it was an APK, re-hashed and
/// admitted to the cache. The only artifact [TachiRuntime.openPackage]
/// accepts.
final class TachiPreparedArtifact implements VerifiedArtifact {
  TachiPreparedArtifact._({
    required this.packageId,
    required this.lease,
    required this.sourceKind,
    required this.sourceUrl,
    required this.input,
    required this.trust,
  });

  /// Repository package identifier.
  final String packageId;

  /// The prepared bytes the worker loads.
  final ArtifactLease lease;

  /// The kind that was downloaded and verified.
  final TachiArtifactKind sourceKind;
  final Uri sourceUrl;

  /// Binding of the downloaded (unprepared) bytes.
  final ArtifactBinding input;
  final TachiTrustIdentity trust;

  @override
  ArtifactBinding get binding => lease.binding;

  @override
  Future<Uint8List> readVerified() => lease.readVerified();
}

/// Tachi's [SourceProvider] over the conversion's shared JVM worker.
///
/// - [prepare] downloads (or takes) a package artifact, admits it unprepared,
///   and runs `artifact.prepare` with the approved repository fingerprint as
///   `trustedSigners`. Failures are typed and leave earlier cache entries
///   untouched: the cache is content-addressed and re-hashes on admission.
/// - [openPackage] loads a prepared package once and returns sessions for
///   every source it enumerates. Opening it again with the same artifact and
///   settings shares the hosted package; a different artifact digest for the
///   same package replaces it and makes every earlier session stale.
/// - A hosted package is unloaded when its last session closes, so disposing
///   one selection never unloads another selection's package.
class TachiRuntime implements SourceProvider {
  TachiRuntime({required this.worker, required this.store, this.catalog, this.policy = const TachiArtifactPolicy()});

  final TachiWorkerAccess worker;
  final TachiArtifactStore store;
  final TachiCatalog? catalog;
  final TachiArtifactPolicy policy;

  final Map<String, _HostedPackage> _hosted = <String, _HostedPackage>{};
  final Map<String, Future<void>> _locks = <String, Future<void>>{};
  int _prepares = 0;

  /// `artifact.prepare` requests sent to the worker.
  int get prepareCount => _prepares;

  /// Package identifiers currently hosted in the worker.
  Iterable<String> get hostedPackages => _hosted.keys;

  @override
  String get ecosystem => tachiEcosystem;

  /// Lists [repository]'s packages from its live index. Trust is decided by
  /// the caller before any listing is used (the core trust gate).
  @override
  Future<SourceOutcome<List<PackageListing>>> discoverPackages(Uri repository, {CancellationToken? cancel}) async {
    final TachiCatalog? c = catalog;
    if (c == null) {
      return const SourceFailed<List<PackageListing>>(
        CapabilityUnavailableFailure('discoverPackages', 'No Tachi catalog is configured'),
      );
    }
    try {
      final List<TachiPackageListing> listings = await c.fetchPackages(await c.fetchRepository(repository));
      return SourceSuccess<List<PackageListing>>(<PackageListing>[
        for (final TachiPackageListing l in listings)
          if (policy.select(l) case SourceSuccess<TachiArtifactChoice>(:final TachiArtifactChoice value))
            PackageListing(
              packageId: l.packageId,
              name: l.name,
              version: l.versionName,
              downloadUrl: value.url,
              languages: l.languages,
              contentRating: l.contentRating,
            ),
      ]);
    } on TachiCatalogException catch (e) {
      return SourceFailed<List<PackageListing>>(SourceErrorFailure(e.message));
    } on Exception catch (e) {
      return SourceFailed<List<PackageListing>>(SourceErrorFailure('Could not read $repository: $e'));
    }
  }

  /// Prepares [listing]'s [choice] artifact for loading.
  ///
  /// [bytes] are the downloaded artifact when the caller already has them
  /// (for example from its download cache); otherwise they are downloaded.
  /// The package's API family is checked against the worker's handshake
  /// before anything is downloaded or prepared.
  Future<SourceOutcome<TachiPreparedArtifact>> prepare(
    TachiPackageListing listing,
    TachiArtifactChoice choice, {
    required TachiTrustIdentity trust,
    Uint8List? bytes,
    CancellationToken? cancel,
  }) async {
    if (trust.repository != listing.repository.baseUrl) {
      return SourceFailed<TachiPreparedArtifact>(
        ArtifactIncompatibleFailure(
          '${listing.packageId}: trust was approved for ${trust.repository}, not ${listing.repository.baseUrl}',
        ),
      );
    }
    final SourceOutcome<WorkerSupervisor> started = await worker();
    final WorkerSupervisor supervisor;
    switch (started) {
      case SourceFailed<WorkerSupervisor>(:final SourceFailure failure):
        return SourceFailed<TachiPreparedArtifact>(failure);
      case SourceSuccess<WorkerSupervisor>(:final WorkerSupervisor value):
        supervisor = value;
    }
    final Set<String> families = supervisor.handshake?.capabilities.apiFamilies ?? const <String>{};
    if (!families.contains(listing.apiFamily)) {
      return SourceFailed<TachiPreparedArtifact>(
        UnsupportedApiFailure(
          '${listing.packageId} needs ${listing.apiFamily}; the worker hosts ${(families.toList()..sort()).join(', ')}',
        ),
      );
    }
    var data = bytes;
    if (data == null) {
      switch (await store.download(choice)) {
        case SourceFailed<Uint8List>(:final SourceFailure failure):
          return SourceFailed<TachiPreparedArtifact>(failure);
        case SourceSuccess<Uint8List>(:final Uint8List value):
          data = value;
      }
    }
    final ArtifactLease raw;
    switch (await store.admit(data, kind: choice.kind, version: listing.versionName)) {
      case SourceFailed<ArtifactLease>(:final SourceFailure failure):
        return SourceFailed<TachiPreparedArtifact>(failure);
      case SourceSuccess<ArtifactLease>(:final ArtifactLease value):
        raw = value;
    }
    try {
      _prepares++;
      final SourceOutcome<ArtifactLease> prepared = await supervisor.prepareArtifact(
        packageId: listing.packageId,
        input: raw,
        trust: trust.anchor,
        cache: store.cache,
        hostCompatibility: tachiHostCompatibility,
        cancel: cancel,
      );
      return prepared.map(
        (ArtifactLease lease) => TachiPreparedArtifact._(
          packageId: listing.packageId,
          lease: lease,
          sourceKind: choice.kind,
          sourceUrl: choice.url,
          input: raw.binding,
          trust: trust,
        ),
      );
    } finally {
      raw.release();
    }
  }

  /// Loads [artifact], which must be a [TachiPreparedArtifact], and returns a
  /// session for every source the package enumerates.
  ///
  /// Takes ownership of the prepared lease: it is held while the package is
  /// hosted (the supervisor reloads from it after a restart) and released
  /// when the package is unloaded, shared, or fails to load.
  @override
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async {
    if (artifact is! TachiPreparedArtifact) {
      return const SourceFailed<SourcePackage>(
        ArtifactIncompatibleFailure('Tachi packages load only artifacts prepared and verified by the worker'),
      );
    }
    if (artifact.lease.isReleased) {
      return const SourceFailed<SourcePackage>(ArtifactIncompatibleFailure('Prepared artifact lease was released'));
    }
    return _serialized(artifact.packageId, () => _open(artifact, settings, cancel));
  }

  Future<SourceOutcome<SourcePackage>> _open(
    TachiPreparedArtifact artifact,
    SettingsSnapshot settings,
    CancellationToken? cancel,
  ) async {
    final String packageId = artifact.packageId;
    final _HostedPackage? existing = _hosted[packageId];
    if (existing != null) {
      if (existing.artifact.binding == artifact.binding && existing.settings.revision == settings.revision) {
        artifact.lease.release();
        return SourceSuccess<SourcePackage>(existing.newSelection());
      }
      await _unload(
        existing,
        reason: 'Package $packageId was replaced by artifact ${artifact.binding.sha256.substring(0, 12)}',
      );
    }
    final SourceOutcome<WorkerSupervisor> started = await worker();
    final WorkerSupervisor supervisor;
    switch (started) {
      case SourceFailed<WorkerSupervisor>(:final SourceFailure failure):
        artifact.lease.release();
        return SourceFailed<SourcePackage>(failure);
      case SourceSuccess<WorkerSupervisor>(:final WorkerSupervisor value):
        supervisor = value;
    }
    final SourceOutcome<PackageLoadResponse> loaded = await supervisor.loadPackage(
      WorkerPackage(packageId: packageId, artifact: artifact.lease, settings: settings),
      cancel: cancel,
    );
    switch (loaded) {
      case SourceFailed<PackageLoadResponse>(:final SourceFailure failure):
        artifact.lease.release();
        return SourceFailed<SourcePackage>(failure);
      case SourceSuccess<PackageLoadResponse>(:final PackageLoadResponse value):
        if (value.sources.isEmpty) {
          await supervisor.unloadPackage(packageId);
          artifact.lease.release();
          return SourceFailed<SourcePackage>(ArtifactIncompatibleFailure('$packageId enumerates no sources'));
        }
        final hosted = _HostedPackage(this, supervisor, artifact, settings, value.sources);
        _hosted[packageId] = hosted;
        return SourceSuccess<SourcePackage>(hosted.newSelection());
    }
  }

  /// Called by a hosted package when its last session closed.
  Future<void> _released(_HostedPackage hosted) =>
      _serialized(hosted.artifact.packageId, () async {
        if (hosted.liveSessions == 0 && identical(_hosted[hosted.artifact.packageId], hosted)) {
          await _unload(hosted, reason: 'Package ${hosted.artifact.packageId} was unloaded');
        }
      });

  Future<void> _unload(_HostedPackage hosted, {required String reason}) async {
    _hosted.remove(hosted.artifact.packageId);
    hosted.invalidate(reason);
    if (hosted.supervisor.state == WorkerState.ready || hosted.supervisor.state == WorkerState.restarting) {
      // Best effort: a failed unload only delays freeing worker memory; the
      // conversion scope kills the worker at the end in any case.
      await hosted.supervisor.unloadPackage(hosted.artifact.packageId);
    }
    hosted.artifact.lease.release();
  }

  Future<T> _serialized<T>(String key, Future<T> Function() body) async {
    final Future<void> previous = _locks[key] ?? Future<void>.value();
    final done = Completer<void>();
    final Future<void> mine = done.future;
    _locks[key] = mine;
    try {
      await previous;
      return await body();
    } finally {
      done.complete();
      if (identical(_locks[key], mine)) unawaited(_locks.remove(key));
    }
  }
}

/// A package hosted in the worker, shared by every selection that opened it.
final class _HostedPackage {
  _HostedPackage(this.runtime, this.supervisor, this.artifact, this.settings, this.sources);

  final TachiRuntime runtime;
  final WorkerSupervisor supervisor;
  final TachiPreparedArtifact artifact;
  final SettingsSnapshot settings;
  final List<LoadedSource> sources;
  final Set<_TachiSession> _live = <_TachiSession>{};
  String? _invalidReason;

  int get liveSessions => _live.length;

  TachiSourcePackage newSelection() {
    final sessions = <_TachiSession>[
      for (final LoadedSource s in sources)
        _TachiSession(
          this,
          WorkerSourceSession(
            supervisor: supervisor,
            identity: SourceIdentity(
              ecosystem: tachiEcosystem,
              packageId: artifact.packageId,
              sourceId: s.sourceId,
              artifact: artifact.binding,
            ),
            displayName: s.language == null ? s.name : '${s.name} (${s.language})',
            capabilities: s.capabilities,
            settingsRevision: settings.revision,
          ),
          language: s.language,
        ),
    ];
    _live.addAll(sessions);
    return TachiSourcePackage._(artifact, sessions);
  }

  void invalidate(String reason) {
    _invalidReason = reason;
    for (final _TachiSession s in _live.toList()) {
      s._invalidated = reason;
    }
    _live.clear();
  }

  Future<void> release(_TachiSession session) async {
    if (!_live.remove(session) || _invalidReason != null) return;
    if (_live.isEmpty) await runtime._released(this);
  }
}

/// One selection of a hosted package: a session per source it enumerates.
/// Closing it closes those sessions; the package is unloaded once no
/// selection holds a live session.
final class TachiSourcePackage implements SourcePackage {
  TachiSourcePackage._(this.artifact, List<TachiSourceSession> sessions)
    : sessions = List<TachiSourceSession>.unmodifiable(sessions);

  final TachiPreparedArtifact artifact;

  @override
  String get packageId => artifact.packageId;

  @override
  final List<TachiSourceSession> sessions;

  @override
  Future<void> close() async {
    for (final TachiSourceSession s in sessions) {
      await s.close();
    }
  }
}

/// A Tachi source session; [language] is the source's index language.
abstract interface class TachiSourceSession implements SourceSession {
  String? get language;

  /// Whether the hosted package was replaced or unloaded under this session.
  bool get isStale;
}

final class _TachiSession implements TachiSourceSession {
  _TachiSession(this._package, this._inner, {required this.language});

  final _HostedPackage _package;
  final WorkerSourceSession _inner;
  String? _invalidated;
  bool _closed = false;

  @override
  final String? language;

  @override
  bool get isStale => _invalidated != null;

  @override
  SourceIdentity get identity => _inner.identity;

  @override
  String get displayName => _inner.displayName;

  @override
  SourceCapabilities get capabilities => _inner.capabilities;

  @override
  String get settingsRevision => _invalidated == null ? _inner.settingsRevision : _package.settings.revision;

  SourceFailure? get _unusable {
    if (_invalidated case final String reason) return StaleReferenceFailure(reason);
    if (_closed) return const RuntimeUnavailableFailure('Session closed');
    return null;
  }

  @override
  Future<SourceOutcome<SearchPage>> search(SearchRequest request, {CancellationToken? cancel}) async {
    if (_unusable case final SourceFailure failure) return SourceFailed<SearchPage>(failure);
    return _inner.search(request, cancel: cancel);
  }

  @override
  Future<SourceOutcome<MangaSnapshot>> fetchManga(NativeMangaRef ref, {CancellationToken? cancel}) async {
    if (_unusable case final SourceFailure failure) return SourceFailed<MangaSnapshot>(failure);
    return _inner.fetchManga(ref, cancel: cancel);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_invalidated == null) await _inner.close();
    await _package.release(this);
  }
}
