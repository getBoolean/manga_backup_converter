import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_loaders/src/provider_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

/// Paperback loader (U6): lists repository catalogs and opens each bundle
/// through [PaperbackSourceProvider], reaching the pipeline through
/// [SessionPluginSource] (KTD15).
///
/// Trust (KTD6): every bundle load, including a cache hit, re-admits the
/// bytes: the core
/// [RepositoryTrustGate] decides the bundle's digest-and-family fingerprint
/// under a per-bundle key, before any JavaScript runs. Without a gate no
/// bundle is trusted.
class PaperbackPluginLoader extends ProviderPluginLoader<PaperbackExtensionEntry> {
  PaperbackPluginLoader({
    required this.client,
    required ArtifactCache artifacts,
    required Future<SourceOutcome<WorkerSupervisor>> Function(ConversionOwner? owner) worker,
    this._trust,
    super.onSettings,
    super.settingsFor,
    super.cache,
  }) {
    _provider = PaperbackSourceProvider(
      client: client,
      cache: artifacts,
      trust: (Uri key, String fingerprint) async => await _trust?.admit('paperback', key, fingerprint) ?? false,
      trustCheck: (Uri key, String fingerprint) async =>
          await _trust?.check('paperback', key, fingerprint) ??
          (_trust == null ? const TrustFailure(TrustFailureReason.firstSeen, 'No trust gate in this run') : null),
      worker: () => worker(_owner),
    );
  }

  final http.Client client;
  RepositoryTrustGate? _trust;
  late final PaperbackSourceProvider _provider;
  ConversionOwner? _owner;

  /// The identity a bundle may open a browser session for (a source of a
  /// package this loader opened), or `null`; a conversion scope's
  /// `resolveBrowserSource` (KTD20).
  SourceIdentity? browserIdentity(String? packageId, String sourceId) => _provider.browserIdentity(packageId, sourceId);

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async {
    _trust = trust ?? _trust;
    final entries = <ExtensionEntry>[];
    for (final url in repoUrls) {
      final SourceOutcome<PaperbackCatalog> catalog = await _provider.fetchCatalog(Uri.parse(url));
      switch (catalog) {
        case SourceFailed<PaperbackCatalog>(:final SourceFailure failure):
          onWarning?.call('Failed to fetch repo $url: ${failure.message}');
        case SourceSuccess<PaperbackCatalog>(:final PaperbackCatalog value):
          entries.addAll(value.entries.map(entryOf));
      }
    }
    return entries;
  }

  /// The [PaperbackExtensionEntry] for a catalog entry.
  static PaperbackExtensionEntry entryOf(PaperbackCatalogEntry e) => PaperbackExtensionEntry(
    id: e.packageId,
    name: e.name,
    sourceId: e.sourceId,
    version: e.version,
    repository: e.repository.toString(),
    bundleUrl: e.bundleUrl.toString(),
    apiFamily: e.family.wire,
    languages: e.languages,
    contentRating: e.contentRating,
  );

  /// The catalog entry behind [entry]: the one seen while listing, or one
  /// rebuilt from the entry's own fields (a resumed conversion).
  PaperbackCatalogEntry _catalogEntry(PaperbackExtensionEntry entry) =>
      _provider.entryFor(entry.id) ??
      PaperbackCatalogEntry(
        repository: Uri.parse(entry.repository),
        family: PaperbackApiFamily.fromWire(entry.apiFamily) ?? PaperbackApiFamily.v09,
        sourceId: entry.sourceId,
        name: entry.name,
        version: entry.version,
        bundleUrl: Uri.parse(entry.bundleUrl),
        contentRating: entry.contentRating,
        languages: entry.languages,
      );

  @override
  Future<SourceOutcome<Uint8List>> download(PaperbackExtensionEntry entry) =>
      _provider.downloadBundle(_catalogEntry(entry));

  /// Admits [bytes] (trust, digest, family) and opens them in the worker;
  /// adopts the package into [owner] as soon as it is open.
  @override
  Future<SourceOutcome<List<PluginSource>>> open(
    PaperbackExtensionEntry entry,
    Uint8List bytes,
    SettingsSnapshot settings,
    ConversionOwner? owner,
  ) {
    _owner = owner ?? _owner;
    return _provider
        .admit(_catalogEntry(entry), bytes)
        .andThen((ArtifactLease lease) => _openAdmitted(lease, settings, owner));
  }

  /// Opens the admitted [lease]; releases it if the package does not open.
  Future<SourceOutcome<List<PluginSource>>> _openAdmitted(
    ArtifactLease lease,
    SettingsSnapshot settings,
    ConversionOwner? owner,
  ) async {
    switch (await _provider.openPackage(lease, settings)) {
      case SourceFailed<SourcePackage>(:final SourceFailure failure):
        lease.release();
        return SourceFailed<List<PluginSource>>(failure);
      case SourceSuccess<SourcePackage>(value: final SourcePackage package):
        final closer = _PackageCloser(package, lease);
        return ProviderPluginLoader.adoptPackage(
          package,
          owner,
          close: closer.close,
          plugins: (List<SourceSession> sessions) => <PluginSource>[
            SessionPluginSource(sessions.first, onDispose: closer.close),
          ],
        );
    }
  }
}

/// Closes an opened package and releases its artifact lease, once.
final class _PackageCloser {
  _PackageCloser(this._package, this._lease);

  final SourcePackage _package;
  final ArtifactLease _lease;
  Future<void>? _closing;

  Future<void> close() => _closing ??= () async {
    await _package.close();
    _lease.release();
  }();
}
