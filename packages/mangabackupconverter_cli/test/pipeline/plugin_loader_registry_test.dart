import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_loader.dart';
import 'package:test/scaffolding.dart';

void main() {
  test('pluginLoaderFor returns correct type for each format category', () {
    check(pluginLoaderFor(const Aidoku())).isA<AidokuPluginLoader>();
    check(pluginLoaderFor(const Paperback())).isA<PaperbackPluginLoader>();
    check(pluginLoaderFor(const Mihon())).isA<TachiPluginLoader>();
    check(pluginLoaderFor(const TachiSy())).isA<TachiPluginLoader>();
    check(pluginLoaderFor(const TachiJ2k())).isA<TachiPluginLoader>();
    check(pluginLoaderFor(const TachiYokai())).isA<TachiPluginLoader>();
    check(pluginLoaderFor(const TachiNeko())).isA<TachiPluginLoader>();
    check(pluginLoaderFor(const Tachimanga())).isA<TachiPluginLoader>();
    check(pluginLoaderFor(const Mangayomi())).isA<MangayomiPluginLoader>();
  });
}
