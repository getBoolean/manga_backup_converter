import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_loader.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

void main() {
  test('without a Tachi runtime every package fails with a typed capability failure, never a stub source', () async {
    final failures = <PluginLoadFailure>[];
    final List<PluginSource> loaded = await const UnavailableTachiPluginLoader().loadPlugins(<ExtensionEntry>[
      const TachiExtensionEntry(
        id: 'eu.kanade.tachiyomi.extension.en.weebcentral',
        name: 'Weeb Central',
        repositoryUrl: 'https://example.invalid/repo',
        versionName: '1.6.27',
        versionCode: 106027,
        artifactKind: 'jar',
      ),
    ], onFailure: failures.add);
    check(loaded).isEmpty();
    check(failures.single.failure).isA<CapabilityUnavailableFailure>();
  });
}
