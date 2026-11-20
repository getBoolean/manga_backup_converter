import 'package:checks/checks.dart';
import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/manga_details.dart';
import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/conversion/target_backup_builder.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_chapter.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_history.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_library_manga.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_manga.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup.dart';
import 'package:test/scaffolding.dart';

import '../fixtures/paperback_fixtures.dart' as fx;
import '../support/test_refs.dart';

void main() {
  group('AidokuBackupBuilder', () {
    const builder = AidokuBackupBuilder();

    test('empty confirmations produces empty backup', () {
      final ConvertableBackup result = buildFrom(builder, const <MangaMatchConfirmation>[]);
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
          confirmedMatch: testResult(
            pluginSourceId: 'multi.mangadex',
            mangaKey: '/manga/abc123',
            title: 'Matched Title',
            coverUrl: 'https://example.com/cover.jpg',
            authors: <String>['Author A'],
          ),
        ),
      ];

      final ConvertableBackup result = buildFrom(builder, confirmations);
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
          confirmedMatch: testResult(
            pluginSourceId: 'en.source',
            mangaKey: 'key1',
            title: 'Kept Manga',
          ),
        ),
      ];

      final ConvertableBackup result = buildFrom(builder, confirmations);
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
          confirmedMatch: testResult(
            pluginSourceId: 'multi.mangadex',
            mangaKey: 'key-a',
            title: 'Manga A',
          ),
        ),
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'Manga B'),
          ),
          confirmedMatch: testResult(
            pluginSourceId: 'multi.mangadex',
            mangaKey: 'key-b',
            title: 'Manga B',
          ),
        ),
      ];

      final ConvertableBackup result = buildFrom(builder, confirmations);
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
          confirmedMatch: testResult(
            pluginSourceId: 'en.src',
            mangaKey: 'k',
            title: 'No Tags',
          ),
        ),
      ];

      final ConvertableBackup result = buildFrom(builder, confirmations);
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
          confirmedMatch: testResult(
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

      final ConvertableBackup result = buildFrom(builder, confirmations);
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
          confirmedMatch: testResult(
            pluginSourceId: 'en.src',
            mangaKey: 'tracked-key',
            title: 'Tracked',
          ),
        ),
      ];

      final report = ConversionReport();
      final ConvertableBackup result = buildFrom(builder, confirmations, report: report);
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
          confirmedMatch: testResult(
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
          confirmedMatch: testResult(
            pluginSourceId: 'src',
            mangaKey: 'b',
            title: 'B',
          ),
        ),
      ];

      final ConvertableBackup result = buildFrom(builder, confirmations);
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
      check(() => buildFrom(builder, const <MangaMatchConfirmation>[])).throws<UnimplementedError>();
    });
  });

  group('AidokuBackupBuilder characterization (chapter state)', () {
    const builder = AidokuBackupBuilder();
    final PluginSearchResult match = testResult(
      pluginSourceId: 'dest.src',
      mangaKey: 'dest-manga',
      title: 'Fixture Manga',
    );

    AidokuBackup buildOne(
      List<SourceChapter> chapters,
      List<PluginChapter> target, {
      List<SourceHistoryEntry>? history,
    }) {
      return buildFrom(builder, <MangaMatchConfirmation>[
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
      ]) as AidokuBackup;
    }

    Map<String, AidokuBackupHistory> historyById(AidokuBackup backup) => <String, AidokuBackupHistory>{
      for (final AidokuBackupHistory h in backup.history ?? const <AidokuBackupHistory>{}) h.chapterId: h,
    };

    void checkHistoryReferencesEmittedChapters(AidokuBackup backup) {
      final emitted = <String>{
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
          SourceHistoryEntry(
            chapterTitle: 'Chapter 3',
            chapterNumber: 3,
            completed: true,
            dateRead: DateTime.utc(2024),
          ),
        ],
      );

      checkHistoryReferencesEmittedChapters(backup);
    });

    test('no history is emitted when destination chapters were not fetched', () {
      final AidokuBackup backup = buildOne(
        <SourceChapter>[SourceChapter(title: 'Chapter 3', chapterNumber: 3, isRead: true)],
        const <PluginChapter>[],
        history: <SourceHistoryEntry>[
          SourceHistoryEntry(
            chapterTitle: 'Chapter 3',
            chapterNumber: 3,
            completed: true,
            dateRead: DateTime.utc(2024),
          ),
        ],
      );

      check(backup.history).isNull();
    });
  });

  group('AidokuBackupBuilder reconciliation output', () {
    const builder = AidokuBackupBuilder();
    final PluginSearchResult match = testResult(
      pluginSourceId: 'dest.src',
      mangaKey: 'dest-manga',
      title: 'Fixture Manga',
    );

    test('history linked by source chapter ID reaches the matched destination chapter', () {
      final backup = buildFrom(builder, <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'Fixture Manga'),
            chapters: <SourceChapter>[
              SourceChapter(title: 'Old Title 3', chapterKey: 'src-3', chapterNumber: 3),
            ],
            history: <SourceHistoryEntry>[
              SourceHistoryEntry(
                chapterTitle: 'Old Title 3',
                chapterKey: 'src-3',
                progress: 4,
                total: 18,
                dateRead: DateTime.utc(2024, 5, 6),
              ),
            ],
          ),
          confirmedMatch: match,
          targetChapters: <PluginChapter>[
            PluginChapter(chapterId: 'd-3', title: 'New Title', chapterNumber: 3),
          ],
        ),
      ]) as AidokuBackup;

      final AidokuBackupHistory h = backup.history!.single;
      check(h.chapterId).equals('d-3');
      check(h.completed).isFalse();
      check(h.progress).equals(4);
      check(h.total).equals(18);
      check(h.dateRead).equals(DateTime.utc(2024, 5, 6));
    });

    test('per-chapter read dates are used instead of the manga-level date', () {
      final backup = buildFrom(builder, <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'Fixture Manga'),
            lastRead: DateTime.utc(2025),
            chapters: <SourceChapter>[
              SourceChapter(title: 'c1', chapterNumber: 1, isRead: true, dateRead: DateTime.utc(2023, 2)),
              SourceChapter(title: 'c2', chapterNumber: 2, isRead: true, dateRead: DateTime.utc(2023, 3)),
            ],
          ),
          confirmedMatch: match,
          targetChapters: <PluginChapter>[
            PluginChapter(chapterId: 'd1', chapterNumber: 1),
            PluginChapter(chapterId: 'd2', chapterNumber: 2),
          ],
        ),
      ]) as AidokuBackup;

      final dates = <String, DateTime>{
        for (final AidokuBackupHistory h in backup.history!) h.chapterId: h.dateRead,
      };
      check(dates).deepEquals(<String, DateTime>{'d1': DateTime.utc(2023, 2), 'd2': DateTime.utc(2023, 3)});
    });

    test('report accounts for unresolved manga, ambiguous chapters, collisions, orphan history and bookmarks', () {
      final report = ConversionReport();
      buildFrom(builder, <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(details: MangaSearchDetails(title: 'Unmatched Manga')),
        ),
        MangaMatchConfirmation(
          sourceManga: SourceMangaData(
            details: MangaSearchDetails(title: 'Fixture Manga'),
            chapters: <SourceChapter>[
              SourceChapter(title: 'c5', chapterNumber: 5, isRead: true),
              SourceChapter(title: 'c7a', chapterNumber: 7, scanlator: 'A', isRead: true),
              SourceChapter(title: 'c7b', chapterNumber: 7, scanlator: 'B', isRead: true),
              SourceChapter(title: 'c9', chapterNumber: 9, isRead: true, isBookmarked: true),
            ],
            secondarySourceChapters: <SourceChapter>[
              SourceChapter(title: 'other', chapterNumber: 1, sourceId: 'OtherSrc', isRead: true),
            ],
            history: <SourceHistoryEntry>[SourceHistoryEntry(chapterTitle: 'Gone Chapter', completed: true)],
          ),
          confirmedMatch: match,
          targetChapters: <PluginChapter>[
            PluginChapter(chapterId: 'd5a', chapterNumber: 5, scanlator: 'X'),
            PluginChapter(chapterId: 'd5b', chapterNumber: 5, scanlator: 'Y'),
            PluginChapter(chapterId: 'd7', chapterNumber: 7),
            PluginChapter(chapterId: 'd9', chapterNumber: 9),
          ],
        ),
      ], report: report);

      check(
        report.where(RecordKind.manga, RecordDisposition.unresolved).map((ReportEntry e) => e.manga).toList(),
      ).deepEquals(<String>['Unmatched Manga']);
      check(report.where(RecordKind.manga, RecordDisposition.transferred).single.manga).equals('Fixture Manga');
      final List<ReportEntry> unresolved = report.where(RecordKind.chapterState, RecordDisposition.unresolved).toList();
      // c5 ambiguous, c7a + c7b collide on d7, the secondary-source chapter is not reconciled.
      check(unresolved.length).equals(4);
      check(report.count(RecordKind.chapterState, RecordDisposition.transferred)).equals(1);
      check(report.count(RecordKind.history, RecordDisposition.unresolved)).equals(1);
      check(report.count(RecordKind.field, RecordDisposition.unrepresentable)).equals(1);
      check(report.isPartial).isTrue();

      final String text = report.describe().join('\n');
      check(text).contains('Unmatched Manga');
      check(text).contains('2 equally plausible destination chapters');
      check(text).contains('2 source chapters');
      check(text).contains('bookmark');
    });

    test('Paperback fixture: progress, read dates and identity flow through to Aidoku history', () {
      final SourceMangaData source = PaperbackBackup.fromData(fx.libraryLinkageArchive()).sourceMangaDataEntries.single;
      final backup = buildFrom(builder, <MangaMatchConfirmation>[
        MangaMatchConfirmation(
          sourceManga: source,
          confirmedMatch: match,
          targetChapters: <PluginChapter>[
            PluginChapter(chapterId: 'd1', chapterNumber: 1),
            PluginChapter(chapterId: 'd2', chapterNumber: 2, sourceOrder: 1),
          ],
        ),
      ]) as AidokuBackup;

      final history = <String, AidokuBackupHistory>{
        for (final AidokuBackupHistory h in backup.history!) h.chapterId: h,
      };
      check(history['d1']!.completed).isTrue();
      check(history['d1']!.dateRead).equals(fx.fixtureReadInstant);
      check(history['d2']!.completed).isFalse();
      check(history['d2']!.progress).equals(7);
      check(history['d2']!.total).equals(20);
      check(backup.library!.single.categories).deepEquals(<String>['読書中', 'Zweite Ä']);
    });
  });
}
