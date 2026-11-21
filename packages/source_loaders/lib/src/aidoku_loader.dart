import 'dart:typed_data';

import 'package:aidoku_plugin_loader/aidoku_plugin_loader.dart' show RemoteSourceList, SourceEntry, SourceListManager;
import 'package:aidoku_plugin_loader/source_adapter.dart' show AidokuSourceProvider;
import 'package:http/http.dart' as http;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_loaders/src/bytes_artifact.dart';
import 'package:source_runtime/source_contracts.dart';

/// Settings an Aidoku extension entry runs with: the user's [user] settings
/// over the repository's base URL default, when it lists one.
SettingsSnapshot aidokuSettingsFor(AidokuExtensionEntry entry, [SettingsSnapshot? user]) =>
    withDefaults(user ?? SettingsSnapshot(), <String, Object>{'url': ?entry.baseUrl});

/// Aidoku loader: lists repositories and opens each `.aix` through the
/// backend-neutral `AidokuSourceProvider`, reaching the pipeline through
/// [SessionPluginSource] (KTD15).
class AidokuPluginLoader extends PluginLoader {
  const AidokuPluginLoader({
    this.providerFactory = AidokuSourceProvider.new,
    this.onSettings,
    this.settingsFor = noExtensionSettings,
  });

  /// The user's settings for each extension.
  final ExtensionSettingsProvider settingsFor;

  /// Builds the source provider: the desktop adapter by default; a platform
  /// backend (the iOS backgrounding gate, a replaying client in tests)
  /// otherwise.
  final SourceProvider Function() providerFactory;

  /// Receives each settings snapshot a source is opened with, so the host
  /// can register its secrets with the log redactor (KTD9).
  final void Function(SettingsSnapshot settings)? onSettings;

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async {
    // Aidoku repositories are unsigned; [trust] is never consulted.
    final entries = <ExtensionEntry>[];
    final manager = SourceListManager();
    for (final url in repoUrls) {
      try {
        final RemoteSourceList sourceList = await manager.fetchRemoteSourceList(url);
        final Uri sourceListUri = Uri.parse(sourceList.url);
        entries.addAll(
          sourceList.sources.map((SourceEntry s) {
            final downloadUrl = sourceListUri.resolve(s.downloadUrl).toString();
            final iconUrl = sourceListUri.resolve(s.iconUrl).toString();
            return AidokuExtensionEntry(
              id: s.id,
              name: s.name,
              languages: s.languages,
              version: s.version,
              iconUrl: iconUrl,
              downloadUrl: downloadUrl,
              contentRating: s.contentRating,
              baseUrl: s.baseUrl,
              altNames: s.altNames,
            );
          }),
        );
      } on Exception catch (e) {
        onWarning?.call('Failed to fetch repo $url: $e');
      }
    }
    return entries;
  }

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
      final Uint8List? bytes = await _download(entry, onFailure);
      if (bytes == null) {
        onProgress?.call(i + 1, extensions.length, 'Warning: failed to download ${entry.name}');
        continue;
      }
      final SourceOutcome<List<PluginSource>> loaded = await loadPluginFromBytes(entry, bytes, owner: owner);
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

  Future<Uint8List?> _download(ExtensionEntry entry, void Function(PluginLoadFailure failure)? onFailure) async {
    try {
      final Uint8List? bytes = await downloadPluginBytes(entry);
      if (bytes == null) {
        onFailure?.call(
          PluginLoadFailure(extensionId: entry.id, failure: const SourceErrorFailure('Download failed')),
        );
      }
      return bytes;
    } on Exception catch (e) {
      onFailure?.call(PluginLoadFailure(extensionId: entry.id, failure: SourceErrorFailure('Download failed: $e')));
      return null;
    }
  }

  @override
  Future<Uint8List?> downloadPluginBytes(ExtensionEntry entry) async {
    final aidokuEntry = entry as AidokuExtensionEntry;
    final http.Response response = await http.get(Uri.parse(aidokuEntry.downloadUrl));
    if (response.statusCode != 200) return null;
    return Uint8List.fromList(response.bodyBytes);
  }

  /// Opens [bytes] as a source session and adopts it into [owner] as soon as
  /// it exists. An Aidoku package hosts one source: the list is a singleton.
  @override
  Future<SourceOutcome<List<PluginSource>>> loadPluginFromBytes(
    ExtensionEntry entry,
    Uint8List bytes, {
    ConversionOwner? owner,
  }) async {
    final aidokuEntry = entry as AidokuExtensionEntry;
    final SettingsSnapshot settings = aidokuSettingsFor(aidokuEntry, settingsFor(aidokuEntry));
    onSettings?.call(settings);
    final SourceOutcome<SourcePackage> opened = await providerFactory().openPackage(
      BytesArtifact(bytes, kind: AidokuSourceProvider.artifactKind, version: '${aidokuEntry.version}'),
      settings,
    );
    switch (opened) {
      case SourceFailed<SourcePackage>(:final SourceFailure failure):
        return SourceFailed<List<PluginSource>>(failure);
      case SourceSuccess<SourcePackage>(value: final SourcePackage package):
        await owner?.adopt(package.close);
        final SourceSession? session = package.sessions.firstOrNull;
        if (session == null) {
          await package.close();
          return const SourceFailed<List<PluginSource>>(ArtifactIncompatibleFailure('Package exposes no source'));
        }
        final plugin = SessionPluginSource(session, onDispose: package.close);
        await owner?.adopt(plugin.dispose);
        return SourceSuccess<List<PluginSource>>(<PluginSource>[plugin]);
    }
  }
}
