import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

/// Paperback loader (U6): lists repository catalogs and opens each bundle
/// through [PaperbackSourceProvider], reaching the pipeline through
/// [SessionPluginSource] (KTD15).
///
/// Trust (KTD6): every bundle load, including a cache hit replayed by
/// `CachingPluginLoader`, re-admits the bytes: the core
/// [RepositoryTrustGate] decides the bundle's digest-and-family fingerprint
/// under a per-bundle key, before any JavaScript runs. Without a gate no
/// bundle is trusted.
class PaperbackPluginLoader extends PluginLoader {
  PaperbackPluginLoader({
    required this.client,
    required ArtifactCache cache,
    required Future<SourceOutcome<WorkerSupervisor>> Function(ConversionOwner? owner) worker,
    this.onSettings,
    this._trust,
    this.settingsFor = noExtensionSettings,
  }) {
    _provider = PaperbackSourceProvider(
      client: client,
      cache: cache,
      trust: (Uri key, String fingerprint) async => await _trust?.admit('paperback', key, fingerprint) ?? false,
      trustCheck: (Uri key, String fingerprint) async =>
          await _trust?.check('paperback', key, fingerprint) ??
          (_trust == null ? const TrustFailure(TrustFailureReason.firstSeen, 'No trust gate in this run') : null),
      worker: () => worker(_owner),
    );
  }

  final http.Client client;
  final void Function(SettingsSnapshot settings)? onSettings;

  /// The user's settings for each bundle.
  final ExtensionSettingsProvider settingsFor;
  RepositoryTrustGate? _trust;
  late final PaperbackSourceProvider _provider;
  ConversionOwner? _owner;

  /// The identity a bundle may open a browser session for (a source of a
  /// package this loader opened), or `null`; a conversion scope's
  /// `resolveBrowserSource` (KTD20).
  SourceIdentity? browserIdentity(String? packageId, String sourceId) =>
      _provider.browserIdentity(packageId, sourceId);

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
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async {
    final plugins = <PluginSource>[];
    for (final (int i, ExtensionEntry entry) in extensions.indexed) {
      onProgress?.call(i + 1, extensions.length, 'Loading plugin: ${entry.name}');
      final Uint8List? bytes = await downloadPluginBytes(entry);
      final SourceOutcome<List<PluginSource>> loaded = bytes == null
          ? const SourceFailed<List<PluginSource>>(SourceErrorFailure('Download failed'))
          : await loadPluginFromBytes(entry, bytes, owner: owner);
      switch (loaded) {
        case SourceSuccess<List<PluginSource>>(:final List<PluginSource> value):
          plugins.addAll(value);
        case SourceFailed<List<PluginSource>>(:final SourceFailure failure):
          onFailure?.call(PluginLoadFailure(extensionId: entry.id, failure: failure));
          onProgress?.call(i + 1, extensions.length, 'Warning: failed to load ${entry.name}: ${failure.message}');
      }
    }
    return plugins;
  }

  @override
  Future<Uint8List?> downloadPluginBytes(ExtensionEntry entry) async {
    if (entry is! PaperbackExtensionEntry) return null;
    return (await _provider.downloadBundle(_catalogEntry(entry))).valueOrNull;
  }

  /// Admits [bytes] (trust, digest, family) and opens them in the worker;
  /// adopts the package into [owner] as soon as it is open.
  @override
  Future<SourceOutcome<List<PluginSource>>> loadPluginFromBytes(
    ExtensionEntry entry,
    Uint8List bytes, {
    ConversionOwner? owner,
  }) async {
    if (entry is! PaperbackExtensionEntry) {
      return const SourceFailed<List<PluginSource>>(UnsupportedApiFailure('Not a Paperback extension entry'));
    }
    _owner = owner ?? _owner;
    // Written without switch-pattern bindings and with the closer in its own
    // class: the Dart 3.14 AOT compiler crashes (linearscan "unreachable
    // code") on the equivalent pattern-matching form of this method.
    final SourceOutcome<ArtifactLease> admitted = await _provider.admit(_catalogEntry(entry), bytes);
    final ArtifactLease? lease = admitted.valueOrNull;
    if (lease == null) return SourceFailed<List<PluginSource>>(admitted.failureOrNull!);
    final SettingsSnapshot settings = settingsFor(entry);
    onSettings?.call(settings);
    final SourceOutcome<SourcePackage> opened = await _provider.openPackage(lease, settings);
    final SourcePackage? package = opened.valueOrNull;
    if (package == null) {
      lease.release();
      return SourceFailed<List<PluginSource>>(opened.failureOrNull!);
    }
    final closer = _PackageCloser(package, lease);
    await owner?.adopt(closer.close);
    final SourceSession? session = package.sessions.firstOrNull;
    if (session == null) {
      await closer.close();
      return const SourceFailed<List<PluginSource>>(ArtifactIncompatibleFailure('Package exposes no source'));
    }
    final plugin = SessionPluginSource(session, onDispose: closer.close);
    await owner?.adopt(plugin.dispose);
    return SourceSuccess<List<PluginSource>>(<PluginSource>[plugin]);
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
