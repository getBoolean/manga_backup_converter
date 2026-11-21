import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_loader.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_tachi.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

void main() {
  final tachi = DesktopTachiRuntime(
    locate: () => const SourceFailed(RuntimeUnavailableFailure('not used')),
    cacheDirectory: Directory.systemTemp,
    fetch: (Uri url) async => Uint8List(0),
  );

  test('pluginLoaderFor returns correct type for each format category', () {
    check(pluginLoaderFor(const Aidoku())).isA<AidokuPluginLoader>();
    check(pluginLoaderFor(const Paperback())).isA<PaperbackPluginLoader>();
    for (final format in const <BackupFormat>[
      Mihon(),
      TachiSy(),
      TachiJ2k(),
      TachiYokai(),
      TachiNeko(),
      Tachimanga(),
    ]) {
      check(pluginLoaderFor(format, tachi: tachi)).isA<TachiPluginLoader>();
      check(pluginLoaderFor(format)).isA<UnavailableTachiPluginLoader>();
    }
    check(pluginLoaderFor(const Mangayomi())).isA<MangayomiPluginLoader>();
  });

  test('without a Tachi runtime every package fails with a typed capability failure, never a stub source', () async {
    final failures = <PluginLoadFailure>[];
    final List<PluginSource> loaded = await pluginLoaderFor(const Mihon()).loadPlugins(<ExtensionEntry>[
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
