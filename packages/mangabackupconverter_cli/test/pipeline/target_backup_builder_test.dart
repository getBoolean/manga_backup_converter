import 'package:checks/checks.dart';
import 'package:mangabackupconverter_cli/src/common/convertable.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_chapter.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_history.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_library_manga.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_manga.dart';
import 'package:mangabackupconverter_cli/src/pipeline/manga_details.dart';
import 'package:mangabackupconverter_cli/src/pipeline/migration_pipeline.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source.dart';
import 'package:mangabackupconverter_cli/src/pipeline/source_manga_data.dart';
import 'package:mangabackupconverter_cli/src/pipeline/target_backup_builder.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('AidokuBackupBuilder', () {
    const builder = AidokuBackupBuilder();

    test('empty confirmations produces empty backup', () {
      final ConvertableBackup result = builder.build(const <MangaMatchConfirmation>[]);
      check(result).isA<AidokuBackup>();
      final backup = result as AidokuBackup;
      check(backup.manga).isNotNull().isEmpty();
      check(backup.library).isNotNull().isEmpty();
      check(backup.sources).isNotNull().isEmpty();
      check(backup.history).isNull();
      check(backup.chapters).isNull();
      check(backup.trackItems).isNull();
      check(backup.categories).isNull();
    });

    test('single confirmed match produces correct manga and library entry', () {
      final confirmations = <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(
              title: 'Original Title',
              authors: <String>['Author A'],
              artists: <String>['Artist B'],
              tagNames: <String>['Action', 'Comedy'],
              description: 'A great manga',
            ),
            categories: const <String>['Favorites'],
            dateAdded: DateTime(2024),
          ),
          confirmedMatch: const PluginSearchResult(
            pluginSourceId: 'multi.mangadex',
            mangaKey: '/manga/abc123',
            title: 'Matched Title',
            coverUrl: 'https://example.com/cover.jpg',
            authors: <String>['Author A'],
          ),
        ),
      ];

      final ConvertableBackup result = builder.build(confirmations);
      final backup = result as AidokuBackup;

      check(backup.manga).isNotNull().length.equals(1);
      final AidokuBackupManga manga = backup.manga!.first;
      check(manga.sourceId).equals('multi.mangadex');
      check(manga.id).equals('/manga/abc123');
      check(manga.title).equals('Matched Title');
      check(manga.cover).equals('https://example.com/cover.jpg');
      check(manga.author).equals('Author A');
      check(manga.artist).equals('Artist B');
      check(manga.desc).equals('A great manga');
      check(manga.tags).isNotNull().deepEquals(<Object?>['Action', 'Comedy']);

      check(backup.library).isNotNull().length.equals(1);
      final AidokuBackupLibraryManga lib = backup.library!.first;
      check(lib.mangaId).equals('/manga/abc123');
      check(lib.sourceId).equals('multi.mangadex');
      check(lib.categories).deepEquals(<String>['Favorites']);
      check(lib.dateAdded).equals(DateTime(2024));

      check(backup.sources).isNotNull().length.equals(1);
      check(backup.sources!.contains('multi.mangadex')).isTrue();

      check(backup.categories).isNotNull().contains('Favorites');
    });

    test('skipped (null) match is filtered out', () {
      final confirmations = <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'Skipped Manga'),
          ),
        ),
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'Kept Manga'),
          ),
          confirmedMatch: const PluginSearchResult(
            pluginSourceId: 'en.source',
            mangaKey: 'key1',
            title: 'Kept Manga',
          ),
        ),
      ];

      final ConvertableBackup result = builder.build(confirmations);
      final backup = result as AidokuBackup;

      check(backup.manga).isNotNull().length.equals(1);
      check(backup.manga!.first.title).equals('Kept Manga');
    });

    test('multiple matches with same source deduplicates sources', () {
      final confirmations = <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'Manga A'),
          ),
          confirmedMatch: const PluginSearchResult(
            pluginSourceId: 'multi.mangadex',
            mangaKey: 'key-a',
            title: 'Manga A',
          ),
        ),
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'Manga B'),
          ),
          confirmedMatch: const PluginSearchResult(
            pluginSourceId: 'multi.mangadex',
            mangaKey: 'key-b',
            title: 'Manga B',
          ),
        ),
      ];

      final ConvertableBackup result = builder.build(confirmations);
      final backup = result as AidokuBackup;

      check(backup.manga).isNotNull().length.equals(2);
      check(backup.library).isNotNull().length.equals(2);
      check(backup.sources).isNotNull().length.equals(1);
    });

    test('manga with no tags sets tags to null', () {
      final confirmations = <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'No Tags'),
          ),
          confirmedMatch: const PluginSearchResult(
            pluginSourceId: 'en.src',
            mangaKey: 'k',
            title: 'No Tags',
          ),
        ),
      ];

      final ConvertableBackup result = builder.build(confirmations);
      final backup = result as AidokuBackup;
      check(backup.manga!.first.tags).isNull();
    });

    test('chapters from source manga are migrated', () {
      final confirmations = <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'With Chapters'),
            chapters: <SourceChapter>[
              SourceChapter(
                title: 'Chapter 1',
                chapterNumber: 1,
                isRead: true,
              ),
              SourceChapter(
                title: 'Chapter 2',
                chapterNumber: 2,
                sourceOrder: 1,
              ),
            ],
          ),
          confirmedMatch: const PluginSearchResult(
            pluginSourceId: 'en.src',
            mangaKey: 'manga-key',
            title: 'With Chapters',
          ),
          targetChapters: <PluginChapter>[
            PluginChapter(chapterId: 'ch-1', title: 'Chapter 1', chapterNumber: 1),
            PluginChapter(chapterId: 'ch-2', title: 'Chapter 2', chapterNumber: 2, sourceOrder: 1),
          ],
        ),
      ];

      final ConvertableBackup result = builder.build(confirmations);
      final backup = result as AidokuBackup;

      check(backup.chapters).isNotNull().length.equals(2);
      final List<AidokuBackupChapter> chs = backup.chapters!.toList();
      check(chs[0].title).equals('Chapter 1');
      check(chs[0].chapter).equals(1.0);
      check(chs[0].mangaId).equals('manga-key');
      check(chs[0].sourceId).equals('en.src');
      check(chs[1].title).equals('Chapter 2');

      // Read chapter should produce history entry
      check(backup.history).isNotNull().isNotEmpty();
      final AidokuBackupHistory historyEntry = backup.history!.first;
      check(historyEntry.completed).isTrue();
      check(historyEntry.mangaId).equals('manga-key');
    });

    test('tracking is not migrated (target tracker IDs are unknown)', () {
      final confirmations = <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'Tracked'),
          ),
          confirmedMatch: const PluginSearchResult(
            pluginSourceId: 'en.src',
            mangaKey: 'tracked-key',
            title: 'Tracked',
          ),
        ),
      ];

      final ConvertableBackup result = builder.build(confirmations);
      final backup = result as AidokuBackup;

      check(backup.trackItems).isNull();
    });

    test('categories are collected from all confirmed manga', () {
      final confirmations = <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'A'),
            categories: <String>['Favorites', 'Action'],
          ),
          confirmedMatch: const PluginSearchResult(
            pluginSourceId: 'src',
            mangaKey: 'a',
            title: 'A',
          ),
        ),
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'B'),
            categories: <String>['Action', 'Comedy'],
          ),
          confirmedMatch: const PluginSearchResult(
            pluginSourceId: 'src',
            mangaKey: 'b',
            title: 'B',
          ),
        ),
      ];

      final ConvertableBackup result = builder.build(confirmations);
      final backup = result as AidokuBackup;

      check(backup.categories).isNotNull().length.equals(3);
      check(backup.categories!).contains('Favorites');
      check(backup.categories!).contains('Action');
      check(backup.categories!).contains('Comedy');
    });
  });

  group('UnimplementedBackupBuilder', () {
    test('throws UnimplementedError', () {
      const builder = UnimplementedBackupBuilder();
      check(() => builder.build(const <MangaMatchConfirmation>[])).throws<UnimplementedError>();
    });
  });

  group('AidokuBackupBuilder characterization (chapter state)', () {
    const builder = AidokuBackupBuilder();
    const match = PluginSearchResult(pluginSourceId: 'dest.src', mangaKey: 'dest-manga', title: 'Fixture Manga');

    AidokuBackup buildOne(List<SourceChapter> chapters, List<PluginChapter> target, {List<SourceHistoryEntry>? history}) {
      return builder.build(<MangaMatchConfirmation>[
            MangaMatchConfirmation(
              sourceManga: SourceMangaData(
                details: MangaSearchDetails(title: 'Fixture Manga'),
                sourceId: 'origin.src',
                chapters: chapters,
                history: history ?? const <SourceHistoryEntry>[],
              ),
              confirmedMatch: match,
              targetChapters: target,
            ),
          ])
          as AidokuBackup;
    }

    Map<String, AidokuBackupHistory> historyById(AidokuBackup backup) => <String, AidokuBackupHistory>{
      for (final AidokuBackupHistory h in backup.history ?? const <AidokuBackupHistory>{}) h.chapterId: h,
    };

    void checkHistoryReferencesEmittedChapters(AidokuBackup backup) {
      final Set<String> emitted = <String>{
        for (final AidokuBackupChapter c in backup.chapters ?? const <AidokuBackupChapter>{}) '${c.mangaId}|${c.id}',
      };
      for (final AidokuBackupHistory h in backup.history ?? const <AidokuBackupHistory>{}) {
        check(emitted).contains('${h.mangaId}|${h.chapterId}');
      }
    }

    test('AE2: same chapter number in different volumes stays distinct; partial progress is not completion', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[
          SourceChapter(title: 'Vol.1 Ch.1', chapterNumber: 1, volumeNumber: 1, isRead: true),
          SourceChapter(title: 'Vol.2 Ch.1', chapterNumber: 1, volumeNumber: 2, lastPageRead: 5, sourceOrder: 1),
        ],
        <PluginChapter>[
          PluginChapter(chapterId: 'd-v1c1', chapterNumber: 1, volumeNumber: 1),
          PluginChapter(chapterId: 'd-v2c1', chapterNumber: 1, volumeNumber: 2, sourceOrder: 1),
        ],
      );

      final Map<String, AidokuBackupHistory> history = historyById(backup);
      check(history.keys.toSet()).deepEquals(<String>{'d-v1c1', 'd-v2c1'});
      check(history['d-v1c1']!.completed).isTrue();
      check(history['d-v2c1']!.completed).isFalse();
      check(history['d-v2c1']!.progress).equals(5);
      checkHistoryReferencesEmittedChapters(backup);
    });

    test('AE3: one read chapter does not fan out across scanlator duplicates', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[SourceChapter(title: 'Chapter 5', chapterNumber: 5, scanlator: 'Group A', isRead: true)],
        <PluginChapter>[
          PluginChapter(chapterId: 'd-5a', chapterNumber: 5, scanlator: 'Group A'),
          PluginChapter(chapterId: 'd-5b', chapterNumber: 5, scanlator: 'Group B', sourceOrder: 1),
        ],
      );

      check(historyById(backup).keys.toSet()).deepEquals(<String>{'d-5a'});
    });

    test('AE3: equally plausible destinations leave the chapter unresolved', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[SourceChapter(title: 'Chapter 5', chapterNumber: 5, isRead: true)],
        <PluginChapter>[
          PluginChapter(chapterId: 'd-5a', chapterNumber: 5, scanlator: 'Group A'),
          PluginChapter(chapterId: 'd-5b', chapterNumber: 5, scanlator: 'Group B', sourceOrder: 1),
        ],
      );

      check(backup.history).isNull();
    });

    test('AE3: unknown -1 chapter numbers are not shared match keys', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[SourceChapter(title: 'Extra', chapterNumber: -1, isRead: true)],
        <PluginChapter>[
          PluginChapter(chapterId: 'd-omake', title: 'Omake', chapterNumber: -1),
          PluginChapter(chapterId: 'd-special', title: 'Special', chapterNumber: -1, sourceOrder: 1),
        ],
      );

      check(backup.history).isNull();
    });

    test('AE3: a conflicting known language rejects the candidate', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[SourceChapter(title: 'Chapter 3', chapterNumber: 3, language: 'en', isRead: true)],
        <PluginChapter>[PluginChapter(chapterId: 'd-3-es', chapterNumber: 3, language: 'es')],
      );

      check(backup.history).isNull();
    });

    test('two source chapters claiming one destination chapter form a collision with no state', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[
          SourceChapter(title: 'Chapter 7', chapterNumber: 7, scanlator: 'Group A', isRead: true),
          SourceChapter(title: 'Chapter 7', chapterNumber: 7, scanlator: 'Group B', lastPageRead: 3, sourceOrder: 1),
        ],
        <PluginChapter>[PluginChapter(chapterId: 'd-7', chapterNumber: 7)],
      );

      check(backup.history).isNull();
    });

    test('partial progress on a uniquely matched chapter is preserved', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[SourceChapter(title: 'Chapter 2', chapterNumber: 2, lastPageRead: 12)],
        <PluginChapter>[PluginChapter(chapterId: 'd-2', chapterNumber: 2)],
      );

      final AidokuBackupHistory h = historyById(backup)['d-2']!;
      check(h.completed).isFalse();
      check(h.progress).equals(12);
    });

    test('every emitted history record references a fetched destination chapter', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[SourceChapter(title: 'Chapter 3', chapterNumber: 3, isRead: true)],
        <PluginChapter>[PluginChapter(chapterId: 'd-3', chapterNumber: 3)],
        history: <SourceHistoryEntry>[
          SourceHistoryEntry(chapterTitle: 'Chapter 3', chapterNumber: 3, completed: true, dateRead: DateTime.utc(2024)),
        ],
      );

      checkHistoryReferencesEmittedChapters(backup);
    });

    test('no history is emitted when destination chapters were not fetched', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[SourceChapter(title: 'Chapter 3', chapterNumber: 3, isRead: true)],
        const <PluginChapter>[],
        history: <SourceHistoryEntry>[
          SourceHistoryEntry(chapterTitle: 'Chapter 3', chapterNumber: 3, completed: true, dateRead: DateTime.utc(2024)),
        ],
      );

      check(backup.history).isNull();
    });
  });
}
