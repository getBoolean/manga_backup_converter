import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/mangabackupconverter_lib.dart'
    show StubPluginLoader, TachimangaBackup, legacyDirectConvert;
import 'package:test/scaffolding.dart';

TachiBackup _tachiBackup() => const TachiBackup(
  backupManga: <TachiBackupManga>[
    TachiBackupManga(
      source: 1,
      url: '/manga/1',
      title: 'Test',
      artist: '',
      author: '',
      description: '',
      genre: <String>[],
      status: 0,
      thumbnailUrl: '',
      dateAdded: 0,
      viewer: 0,
      viewerFlags: 0,
      chapterFlags: 0,
      favorite: true,
      chapters: <TachiBackupChapter>[],
      categories: <int>[],
      tracking: <TachiBackupTracking>[],
      history: <TachiBackupHistory>[],
    ),
  ],
);

MigrationPipeline _pipeline() => MigrationPipeline(
  repoUrls: const <String>[],
  pluginLoader: const StubPluginLoader('tachi'),
  directConverter: legacyDirectConvert,
  selection: CallbackSelectionPort(
    onSelectExtensions: (List<ExtensionEntry> e) async => e,
    onConfirmMatches: (_, _, _, _) async => <MangaMatchConfirmation>[],
  ),
  onProgress: (_, _, _) {},
);

void main() {
  group('CLI direct conversion adapter', () {
    test('Tachi → Tachimanga converts directly through the legacy adapter', () async {
      final ConversionDraft draft = await _pipeline().run(
        sourceBackup: _tachiBackup(),
        sourceFormat: const Mihon(),
        targetFormat: const Tachimanga(),
      );
      check(draft.backup).isA<TachimangaBackup>();
      check(draft.report.isPartial).isFalse();
    });

    test('Tachi fork → Tachimanga also converts directly', () async {
      final ConversionDraft draft = await _pipeline().run(
        sourceBackup: _tachiBackup(),
        sourceFormat: const TachiSy(),
        targetFormat: const Tachimanga(),
      );
      check(draft.backup).isA<TachimangaBackup>();
    });
  });
}
