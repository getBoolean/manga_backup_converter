import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/src/admission.dart';
import 'package:paperback_plugin_loader/src/catalog.dart';
import 'package:source_runtime/source_runtime.dart';

/// Decides whether a bundle may run: asked once per first-seen or changed
/// `(trustKey, fingerprint)` pair (KTD6). The composition root answers it
/// with the core `RepositoryTrustGate` (`admit('paperback', trustKey,
/// fingerprint)`); a qualification run answers it from pinned digests.
typedef PaperbackTrustDecision = Future<bool> Function(Uri trustKey, String fingerprint);

/// The cache profile of admitted Paperback bundles. The API family is part
/// of the host compatibility, so one digest admitted for 0.8 is never served
/// to a 0.9 load.
ArtifactProfile paperbackArtifactProfile(PaperbackApiFamily family) =>
    ArtifactProfile(producer: 'paperback-bundle', converterVersion: '1', hostCompatibility: family.wire);

/// Paperback [SourceProvider] (U6): discovers repository catalogs, admits
/// bundles through trust and digest checks into the artifact cache, and
/// opens them in the supervised Paperback worker.
///
/// Trust (KTD6): Paperback repositories are unsigned, so each bundle's trust
/// decision binds its exact SHA-256 and API family
/// ([bundleTrustFingerprint]) under a per-bundle key ([bundleTrustKey]).
/// The decision is re-checked on every admission, cache hits included; the
/// cache re-hashes staged bytes on every read; and the worker re-hashes and
/// re-checks the family before evaluating anything.
final class PaperbackSourceProvider implements SourceProvider {
  PaperbackSourceProvider({
    required this.client,
    required this.cache,
    required this.trust,
    required this.worker,
  });

  /// Fetches catalogs and bundles (live in production; replay in tests).
  final http.Client client;
  final ArtifactCache cache;
  final PaperbackTrustDecision trust;

  /// The started Paperback worker supervisor, created on first use
  /// (`ConversionRuntimeScope.worker(WorkerKind.paperback)` on desktop).
  final Future<SourceOutcome<WorkerSupervisor>> Function() worker;

  final Map<String, PaperbackCatalogEntry> _admitted = <String, PaperbackCatalogEntry>{};
  final Map<String, PaperbackCatalogEntry> _entries = <String, PaperbackCatalogEntry>{};

  @override
  String get ecosystem => 'paperback';

  /// Fetches and parses [repository]'s catalog.
  Future<SourceOutcome<PaperbackCatalog>> fetchCatalog(Uri repository, {CancellationToken? cancel}) async {
    final Uri url = PaperbackCatalog.catalogUrl(repository);
    try {
      final http.Response response = await client.get(url);
      if (response.statusCode != 200) {
        return SourceFailed<PaperbackCatalog>(SourceErrorFailure('Catalog $url answered HTTP ${response.statusCode}'));
      }
      final PaperbackCatalog catalog = PaperbackCatalog.parse(repository, utf8.decode(response.bodyBytes));
      for (final PaperbackCatalogEntry e in catalog.entries) {
        _entries[e.packageId] = e;
      }
      return SourceSuccess<PaperbackCatalog>(catalog);
    } on FormatException catch (e) {
      return SourceFailed<PaperbackCatalog>(UnsupportedApiFailure('Catalog $url: ${e.message}'));
    } on Object catch (e) {
      return SourceFailed<PaperbackCatalog>(SourceErrorFailure('Catalog $url could not be fetched: $e'));
    }
  }

  @override
  Future<SourceOutcome<List<PackageListing>>> discoverPackages(Uri repository, {CancellationToken? cancel}) async =>
      (await fetchCatalog(repository, cancel: cancel)).map(
        (PaperbackCatalog c) => <PackageListing>[for (final PaperbackCatalogEntry e in c.entries) e.toListing()],
      );

  /// The catalog entry behind a [PackageListing.packageId] seen by
  /// [discoverPackages] or [fetchCatalog].
  PaperbackCatalogEntry? entryFor(String packageId) => _entries[packageId];

  /// Downloads [entry]'s bundle from its installation entry point.
  Future<SourceOutcome<Uint8List>> downloadBundle(PaperbackCatalogEntry entry) async {
    try {
      final http.Response response = await client.get(entry.bundleUrl);
      if (response.statusCode != 200) {
        return SourceFailed<Uint8List>(
          SourceErrorFailure('Bundle ${entry.bundleUrl} answered HTTP ${response.statusCode}'),
        );
      }
      return SourceSuccess<Uint8List>(response.bodyBytes);
    } on Object catch (e) {
      return SourceFailed<Uint8List>(SourceErrorFailure('Bundle ${entry.bundleUrl} could not be fetched: $e'));
    }
  }

  /// Admits [bytes] as [entry]'s bundle: the trust decision for this exact
  /// digest and family, then the static family check, then staging in the
  /// cache. Nothing is evaluated.
  Future<SourceOutcome<ArtifactLease>> admit(PaperbackCatalogEntry entry, Uint8List bytes) async {
    final binding = ArtifactBinding(
      sha256: bundleDigest(bytes),
      kind: entry.family.artifactKind,
      version: entry.version,
    );
    try {
      final ArtifactLease lease = await cache.admit(
        bytes,
        binding: binding,
        profile: paperbackArtifactProfile(entry.family),
        verifier: (Uint8List b, ArtifactBinding a) => _verify(entry, b, a),
      );
      _admitted[binding.sha256] = entry;
      return SourceSuccess<ArtifactLease>(lease);
    } on BundleAdmissionException catch (e) {
      return SourceFailed<ArtifactLease>(e.failure);
    } on ArtifactIntegrityException catch (e) {
      return SourceFailed<ArtifactLease>(ArtifactIncompatibleFailure(e.message));
    }
  }

  /// A cached admission of [entry] at [sha256], re-hashed and re-checked
  /// against the trust decision; `null` when absent or tampered with.
  Future<SourceOutcome<ArtifactLease>?> cached(PaperbackCatalogEntry entry, String sha256) async {
    final binding = ArtifactBinding(sha256: sha256, kind: entry.family.artifactKind, version: entry.version);
    try {
      final ArtifactLease? lease = await cache.lookup(
        binding: binding,
        profile: paperbackArtifactProfile(entry.family),
        verifier: (Uint8List b, ArtifactBinding a) => _verify(entry, b, a),
      );
      if (lease == null) return null;
      _admitted[sha256] = entry;
      return SourceSuccess<ArtifactLease>(lease);
    } on BundleAdmissionException catch (e) {
      return SourceFailed<ArtifactLease>(e.failure);
    }
  }

  Future<void> _verify(PaperbackCatalogEntry entry, Uint8List bytes, ArtifactBinding binding) async {
    final PaperbackApiFamily family = admitBundle(bytes, binding);
    final bool trusted = await trust(
      bundleTrustKey(entry.repository, entry.sourceId),
      bundleTrustFingerprint(family, binding.sha256),
    );
    if (!trusted) {
      throw BundleAdmissionException(
        ArtifactIncompatibleFailure('The bundle for ${entry.packageId} (${binding.sha256}) is not trusted'),
      );
    }
  }

  @override
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async {
    final PaperbackCatalogEntry? entry = _admitted[artifact.binding.sha256];
    if (artifact is! ArtifactLease || entry == null) {
      return const SourceFailed<SourcePackage>(
        ArtifactIncompatibleFailure('Paperback bundles must be admitted through PaperbackSourceProvider.admit'),
      );
    }
    final SourceOutcome<WorkerSupervisor> started = await worker();
    final WorkerSupervisor supervisor;
    switch (started) {
      case SourceFailed<WorkerSupervisor>(:final SourceFailure failure):
        return SourceFailed<SourcePackage>(failure);
      case SourceSuccess<WorkerSupervisor>(:final WorkerSupervisor value):
        supervisor = value;
    }
    final SourceOutcome<PackageLoadResponse> loaded = await supervisor.loadPackage(
      WorkerPackage(packageId: entry.packageId, artifact: artifact, settings: settings),
      cancel: cancel,
    );
    return loaded.map(
      (PackageLoadResponse r) => _PaperbackPackage(
        supervisor,
        entry.packageId,
        <SourceSession>[
          for (final LoadedSource s in r.sources)
            WorkerSourceSession(
              supervisor: supervisor,
              identity: SourceIdentity(
                ecosystem: ecosystem,
                packageId: entry.packageId,
                sourceId: s.sourceId,
                artifact: artifact.binding,
              ),
              displayName: entry.name,
              capabilities: s.capabilities,
              settingsRevision: settings.revision,
            ),
        ],
      ),
    );
  }
}

final class _PaperbackPackage implements SourcePackage {
  _PaperbackPackage(this._supervisor, this.packageId, this.sessions);

  final WorkerSupervisor _supervisor;

  @override
  final String packageId;

  @override
  final List<SourceSession> sessions;

  bool _closed = false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final SourceSession s in sessions) {
      await s.close();
    }
    if (_supervisor.state == WorkerState.ready) await _supervisor.unloadPackage(packageId);
  }
}
