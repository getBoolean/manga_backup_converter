import 'dart:typed_data';

import 'package:aidoku_plugin_loader/aidoku_plugin_loader.dart' show RemoteSourceList, SourceEntry, SourceListManager;
import 'package:aidoku_plugin_loader/source_adapter.dart' show AidokuSourceProvider;
import 'package:http/http.dart' as http;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_loaders/src/bytes_artifact.dart';
import 'package:source_loaders/src/provider_plugin_loader.dart';
import 'package:source_runtime/source_contracts.dart';

/// Settings an Aidoku extension entry runs with: the user's [user] settings
/// over the repository's base URL default, when it lists one.
SettingsSnapshot aidokuSettingsFor(AidokuExtensionEntry entry, [SettingsSnapshot? user]) =>
    withDefaults(user ?? SettingsSnapshot(), <String, Object>{'url': ?entry.baseUrl});

/// Aidoku loader: lists repositories and opens each `.aix` through the
/// backend-neutral `AidokuSourceProvider`, reaching the pipeline through
/// [SessionPluginSource] (KTD15). Aidoku repositories are unsigned.
class AidokuPluginLoader extends ProviderPluginLoader<AidokuExtensionEntry> {
  AidokuPluginLoader({
    this.providerFactory = AidokuSourceProvider.new,
    this.client,
    super.onSettings,
    super.settingsFor,
    super.cache,
  });

  /// Builds the source provider: the desktop adapter by default; a platform
  /// backend (the iOS backgrounding gate, a replaying client in tests)
  /// otherwise.
  final SourceProvider Function() providerFactory;

  /// Fetches repository lists and `.aix` downloads; a new live client when
  /// `null`. (Source traffic goes through the provider's own client.)
  final http.Client? client;

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async {
    // Aidoku repositories are unsigned; [trust] is never consulted.
    final entries = <ExtensionEntry>[];
    final manager = SourceListManager(httpClient: client);
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
              contentRating: ContentRatingLevel.fromScale(s.contentRating),
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
  Future<SourceOutcome<Uint8List>> download(AidokuExtensionEntry entry) async {
    final Uri url = Uri.parse(entry.downloadUrl);
    final http.Response response = await (client?.get(url) ?? http.get(url));
    if (response.statusCode != 200) {
      return SourceFailed<Uint8List>(SourceErrorFailure('Download of $url failed: HTTP ${response.statusCode}'));
    }
    return SourceSuccess<Uint8List>(Uint8List.fromList(response.bodyBytes));
  }

  /// The user's settings over the repository's base URL default.
  @override
  SettingsSnapshot settingsOf(AidokuExtensionEntry entry) => aidokuSettingsFor(entry, settingsFor(entry));

  /// An Aidoku package hosts one source: the list is a singleton.
  @override
  Future<SourceOutcome<List<PluginSource>>> open(
    AidokuExtensionEntry entry,
    Uint8List bytes,
    SettingsSnapshot settings,
    ConversionOwner? owner,
  ) => providerFactory()
      .openPackage(BytesArtifact(bytes, kind: AidokuSourceProvider.artifactKind, version: '${entry.version}'), settings)
      .andThen(
        (SourcePackage package) => ProviderPluginLoader.adoptPackage(
          package,
          owner,
          close: package.close,
          plugins: (List<SourceSession> sessions) => <PluginSource>[
            SessionPluginSource(sessions.first, onDispose: package.close),
          ],
        ),
      );
}
