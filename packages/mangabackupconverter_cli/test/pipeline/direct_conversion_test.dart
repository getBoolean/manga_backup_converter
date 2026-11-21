import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/mangabackupconverter_lib.dart'
    show StubPluginLoader, TachimangaBackup, legacyDirectConvert;
import 'package:mangabackupconverter_cli/src/commands/conversion_composition.dart';
import 'package:test/scaffolding.dart';

TachiBackup _tachiBackup({List<TachiBackupHistory> history = const <TachiBackupHistory>[]}) => TachiBackup(
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
      tracking: const <TachiBackupTracking>[],
      history: history,
    ),
  ],
);

MigrationPipeline _pipeline() => MigrationPipeline(
  repoUrls: const <String>[],
  pluginLoader: const StubPluginLoader('tachi'),
  directConverter: legacyDirectConvert,
  // The CLI registry re-reads the Tachimanga output before it may be published.
  formats: cliFormatRegistry(),
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

    test('direct conversion is fully accounted: manga transferred, history folding noted, output re-read', () async {
      final ConversionDraft draft = await _pipeline().run(
        sourceBackup: _tachiBackup(
          history: const <TachiBackupHistory>[
            TachiBackupHistory(url: '/c1', lastRead: 1000, readDuration: 5),
            TachiBackupHistory(url: '/c2', lastRead: 2000, readDuration: 7),
          ],
        ),
        sourceFormat: const Mihon(),
        targetFormat: const Tachimanga(),
      );
      check(draft.report.count(RecordKind.manga, RecordDisposition.transferred)).equals(1);
      check(draft.report.notes.single).contains('1 older history row(s) were folded');
      check(draft.report.isPartial).isFalse();
      final TachimangaBackup reread = await TachimangaBackup.fromData(draft.bytes);
      check(reread.db.mangaTable.single.url).equals('/manga/1');
      check(reread.db.historyTable).length.equals(1);
    });
  });
}
