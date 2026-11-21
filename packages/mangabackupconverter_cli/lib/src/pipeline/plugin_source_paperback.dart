import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';

/// The hidden subcommand under which the CLI executable runs the Paperback
/// worker, so the desktop build ships one binary (`dart build cli` bundles the
/// QuickJS native asset for it).
const String paperbackWorkerCommand = '__paperback-worker';

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
  }) {
    _provider = PaperbackSourceProvider(
      client: client,
      cache: cache,
      trust: (Uri key, String fingerprint) async => await _trust?.admit('paperback', key, fingerprint) ?? false,
      worker: () => worker(_owner),
    );
  }

  /// The desktop composition: the CLI executable re-launched as the worker
  /// ([paperbackWorkerCommand]) with limits from the KTD25 sizing rule, an
  /// artifact cache under [cacheRoot], and the live network.
  factory PaperbackPluginLoader.desktop({
    required String cacheRoot,
    void Function(SettingsSnapshot settings)? onSettings,
    void Function(String line)? onLog,
  }) {
    final client = http.Client();
    WorkerSupervisor? supervisor;
    return PaperbackPluginLoader(
      client: client,
      cache: ArtifactCache(Directory(p.join(cacheRoot, 'paperback_artifacts'))),
      onSettings: onSettings,
      worker: (ConversionOwner? owner) async {
        if (supervisor == null) {
          // The worker is this executable re-launched; under `dart run` the
          // resolved executable is the Dart VM, which has no such command.
          final String exe = p.basenameWithoutExtension(Platform.resolvedExecutable).toLowerCase();
          if (exe == 'dart' || exe == 'flutter_tester') {
            return const SourceFailed<WorkerSupervisor>(
              RuntimeUnavailableFailure(
                'Paperback sources need the built CLI executable (dart build cli); '
                'they cannot run under dart run',
              ),
            );
          }
          final PaperbackWorkerPlan plan = planPaperbackWorker();
          // KTD25: record the rule, its inputs and the derived limits, and any
          // cap that left a limit below the measured need.
          onLog?.call('[paperback] sizing ${jsonEncode(plan.sizing.toJson())}');
          for (final String warning in plan.sizing.warnings) {
            onLog?.call('[paperback] sizing warning: $warning');
          }
          final created = WorkerSupervisor(
            spec: WorkerSpec(
              label: 'paperback',
              executable: Platform.resolvedExecutable,
              arguments: <String>[paperbackWorkerCommand, ...plan.arguments],
              environment: scrubbedEnvironment(),
            ),
            // The worker reports its supervisor-side deadline (engine
            // deadline plus measured headroom); the rest are not QuickJS
            // limits and come from the desktop policy (KTD4).
            limits: AdoptWorkerLimits(
              handshakeDeadline: plan.handshakeDeadline,
              maxConcurrentPackages: 1,
              cancelGrace: plan.cancelGrace,
              interactionTimeout: const Duration(minutes: 5),
              shutdownGrace: plan.cancelGrace,
            ),
            onLog: onLog,
          );
          supervisor = created;
          await owner?.adopt(() async {
            await created.close();
            client.close();
          });
        }
        final WorkerSupervisor s = supervisor!;
        return (await s.start()).map((_) => s);
      },
    );
  }

  final http.Client client;
  final void Function(SettingsSnapshot settings)? onSettings;
  RepositoryTrustGate? _trust;
  late final PaperbackSourceProvider _provider;
  ConversionOwner? _owner;

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
    final settings = SettingsSnapshot();
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
