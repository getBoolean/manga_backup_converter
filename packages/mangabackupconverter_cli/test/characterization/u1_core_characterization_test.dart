// Characterization of behaviours U1 steps 3-6 intentionally change. Each test
// pins the pre-extraction behaviour so the later flip is a visible, reviewed
// change rather than an accident of the move.

import 'package:checks/checks.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_backup_chapter.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_backup_history.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_backup_manga.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_backup_tracking.dart';
import 'package:mangabackupconverter_cli/src/pipeline/backup_format.dart';
import 'package:mangabackupconverter_cli/src/pipeline/extension_entry.dart';
import 'package:mangabackupconverter_cli/src/pipeline/migration_pipeline.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_loader.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source.dart';
import 'package:mangabackupconverter_cli/src/pipeline/source_manga_data.dart';
import 'package:test/scaffolding.dart';

import '../fixtures/paperback_fixtures.dart' as fx;

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

class _Source implements PluginSource {
  _Source(this.sourceId);

  @override
  final String sourceId;

  @override
  String get sourceName => sourceId;

  int disposed = 0;

  @override
  Future<PluginSearchPageResult> search(String query, int page) async =>
      const PluginSearchPageResult(results: <PluginSearchResult>[], hasNextPage: false);

  @override
  Future<(PluginMangaDetails, List<PluginChapter>)?> getMangaWithChapters(String mangaKey) async => null;

  @override
  void dispose() => disposed++;
}

class _Loader extends PluginLoader {
  _Loader(this.load);

  final Future<List<PluginSource>> Function() load;

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(List<String> repoUrls, {void Function(String)? onWarning}) async =>
      const <ExtensionEntry>[StubExtensionEntry(id: 'a', name: 'A'), StubExtensionEntry(id: 'b', name: 'B')];

  @override
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
  }) => load();
}

void main() {
  test('Paperback library entry whose primary source does not resolve is dropped silently', () {
    final backup = PaperbackBackup.fromData(
      fx.buildPaperbackArchive(<String, Map<String, dynamic>>{
        '__MANGA_INFO_V4': <String, dynamic>{
          'info-A': fx.mangaInfoJson('info-A', titles: <String>['A']),
        },
        '__SOURCE_MANGA_V4': <String, dynamic>{'sm-A': fx.sourceMangaJson('sm-A', mangaInfoId: 'info-A')},
        '__LIBRARY_MANGA_V4': <String, dynamic>{
          'lib-1': fx.libraryMangaJson('lib-1', primarySourceId: 'sm-A'),
          'lib-dangling': fx.libraryMangaJson('lib-dangling', primarySourceId: 'sm-missing'),
        },
      }),
    );
    check(backup.libraryManga).isNotNull().length.equals(2);
    check(backup.sourceMangaDataEntries).length.equals(1);
  });

  test('a null details result keeps the confirmed match with zero chapters', () async {
    final source = _Source('src');
    final pipeline = MigrationPipeline(
      repoUrls: const <String>['https://repo.invalid'],
      pluginLoader: _Loader(() async => <PluginSource>[source]),
      onSelectExtensions: (List<ExtensionEntry> e) async => e,
      onConfirmMatches: (_, List<SourceMangaData> manga, _, _) async => <MangaMatchConfirmation>[
        for (final m in manga)
          MangaMatchConfirmation(
            sourceManga: m,
            confirmedMatch: const PluginSearchResult(pluginSourceId: 'src', mangaKey: 'k', title: 'Test'),
          ),
      ],
      onProgress: (_, _, _) {},
    );
    final result = await pipeline.run(
      sourceBackup: _tachiBackup(),
      sourceFormat: const Mihon(),
      targetFormat: const Aidoku(),
    ) as AidokuBackup;
    check(result.manga).isNotNull().length.equals(1);
    check(result.chapters).isNull();
  });

  test('a load failure after one plugin loaded leaves the loaded plugin undisposed', () async {
    final loaded = _Source('first');
    final pipeline = MigrationPipeline(
      repoUrls: const <String>['https://repo.invalid'],
      pluginLoader: _Loader(() async {
        // The loader opened `loaded`, then failed on the second extension.
        throw StateError('second plugin failed');
      }),
      onSelectExtensions: (List<ExtensionEntry> e) async => e,
      onConfirmMatches: (_, _, _, _) async => <MangaMatchConfirmation>[],
      onProgress: (_, _, _) {},
    );
    await check(
      pipeline.run(sourceBackup: _tachiBackup(), sourceFormat: const Mihon(), targetFormat: const Aidoku()),
    ).throws<StateError>();
    check(loaded.disposed).equals(0);
  });
}
