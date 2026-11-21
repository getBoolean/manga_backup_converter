import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_stub.dart';
import 'package:source_runtime/source_contracts.dart';

export 'package:mangabackupconverter_cli/src/pipeline/plugin_source_paperback.dart' show PaperbackPluginLoader;
export 'package:source_loaders/source_loaders.dart' show AidokuPluginLoader, BytesArtifact, aidokuSettingsFor;

/// Loader for ecosystems whose runtime is not wired yet: every entry becomes
/// a [StubPluginSource] that answers with a typed capability failure.
class StubPluginLoader extends PluginLoader {
  const StubPluginLoader(this.ecosystem);

  final String ecosystem;

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async => <ExtensionEntry>[];

  @override
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async => <PluginSource>[
    for (final ExtensionEntry e in extensions)
      StubPluginSource(ecosystem: ecosystem, sourceId: e.id, sourceName: e.name),
  ];
}

class MangayomiPluginLoader extends StubPluginLoader {
  const MangayomiPluginLoader() : super('mangayomi');
}

/// Tachi on a host without a desktop Tachi runtime: lists nothing and fails
/// every package with [CapabilityUnavailableFailure].
class UnavailableTachiPluginLoader extends PluginLoader {
  const UnavailableTachiPluginLoader();

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async {
    if (repoUrls.isNotEmpty) onWarning?.call('Tachi sources cannot run on this host: no Tachi runtime is configured');
    return <ExtensionEntry>[];
  }

  @override
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async {
    for (final e in extensions) {
      onFailure?.call(
        PluginLoadFailure(
          extensionId: e.id,
          failure: const CapabilityUnavailableFailure('worker.jvm', 'No Tachi runtime is configured on this host'),
        ),
      );
    }
    return <PluginSource>[];
  }
}
