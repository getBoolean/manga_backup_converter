import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Tachi sourceMangaDataEntries', () {
    test('produces correct entries with category resolution', () {
      final backup = TachiBackup(
        backupCategories: <TachiBackupCategory>[
          TachiBackupCategory(name: 'Favorites', order: 0, flags: 1),
          TachiBackupCategory(name: 'Reading', order: 1, flags: 1),
        ],
        backupSources: <TachiBackupSource>[
          const TachiBackupSource(name: 'MangaDex', sourceId: 123),
        ],
        backupManga: <TachiBackupManga>[
          const TachiBackupManga(
            url: '/manga/1',
            title: 'Test Manga',
            artist: 'Art',
            author: 'Auth',
            description: 'Desc',
            genre: <String>['Action'],
            status: 1,
            thumbnailUrl: 'https://example.com/thumb.jpg',
            source: 123,
            dateAdded: 0,
            viewer: 0,
            chapterFlags: 0,
            favorite: true,
            viewerFlags: 0,
            chapters: <TachiBackupChapter>[
              TachiBackupChapter(
                url: '/ch/1',
                name: 'Chapter 1',
                scanlator: '',
                read: true,
                bookmark: false,
                lastPageRead: 10,
                dateFetch: 0,
                dateUpload: 0,
                chapterNumber: 1,
                sourceOrder: 0,
              ),
            ],
            history: <TachiBackupHistory>[
              TachiBackupHistory(url: '/ch/1', lastRead: 5000, readDuration: 300),
            ],
            categories: <int>[0],
            tracking: <TachiBackupTracking>[
              TachiBackupTracking(
                syncId: 1,
                libraryId: 1,
                mediaIdInt: 1,
                trackingUrl: 'https://tracker.com/1',
                title: 'Test Manga',
                lastChapterRead: 1,
                totalChapters: 50,
                score: 8.0,
                status: 1,
                startedReadingDate: 1000,
                finishedReadingDate: 0,
                mediaId: 1,
              ),
            ],
          ),
        ],
      );

      final List<SourceMangaData> entries = backup.sourceMangaDataEntries;
      check(entries).length.equals(1);

      final SourceMangaData entry = entries[0];
      check(entry.details.title).equals('Test Manga');
      check(entry.sourceId).equals('MangaDex');
      check(entry.categories).deepEquals(<String>['Favorites']);
      check(entry.chapters).length.equals(1);
      check(entry.chapters[0].isRead).isTrue();
      check(entry.history).length.equals(1);
      check(entry.history[0].chapterTitle).equals('Chapter 1');
      check(entry.history[0].chapterKey).isNotNull().equals(entry.chapters[0].chapterKey!);
      check(entry.tracking).length.equals(1);
      check(entry.tracking[0].syncId).equals(1);
    });

    test('empty backup returns empty list', () {
      const backup = TachiBackup();
      check(backup.sourceMangaDataEntries).isEmpty();
    });

    test('out-of-range category index falls back to label', () {
      final backup = TachiBackup(
        backupCategories: <TachiBackupCategory>[
          TachiBackupCategory(name: 'Only', order: 0, flags: 1),
        ],
        backupManga: <TachiBackupManga>[
          const TachiBackupManga(
            url: '/manga/1',
            title: 'M',
            artist: '',
            author: '',
            description: '',
            genre: <String>[],
            status: 0,
            thumbnailUrl: '',
            source: 1,
            dateAdded: 0,
            viewer: 0,
            chapterFlags: 0,
            favorite: true,
            viewerFlags: 0,
            chapters: <TachiBackupChapter>[],
            history: <TachiBackupHistory>[],
            categories: <int>[0, 5],
            tracking: <TachiBackupTracking>[],
          ),
        ],
      );

      final SourceMangaData entry = backup.sourceMangaDataEntries[0];
      check(entry.sourceId).equals('Source 1');
      check(entry.categories).length.equals(2);
      check(entry.categories[0]).equals('Only');
      check(entry.categories[1]).equals('Category 5');
    });
  });

  group('Aidoku sourceMangaDataEntries', () {
    test('filters chapters and history per manga', () {
      final backup = AidokuBackup(
        library: <AidokuBackupLibraryManga>{
          AidokuBackupLibraryManga(
            lastOpened: DateTime(2024),
            lastUpdated: DateTime(2024),
            lastRead: null,
            dateAdded: DateTime(2024),
            categories: const <String>['Favorites'],
            mangaId: 'manga-1',
            sourceId: 'src.a',
          ),
        },
        history: <AidokuBackupHistory>{
          AidokuBackupHistory(
            dateRead: DateTime(2024),
            sourceId: 'src.a',
            chapterId: 'ch-1',
            mangaId: 'manga-1',
            progress: 10,
            total: 20,
            completed: true,
          ),
        },
        manga: <AidokuBackupManga>{
          AidokuBackupManga(id: 'manga-1', sourceId: 'src.a', title: 'Aidoku Manga'),
          AidokuBackupManga(id: 'manga-2', sourceId: 'src.a', title: 'Other Manga'),
        },
        chapters: <AidokuBackupChapter>{
          AidokuBackupChapter(
            sourceId: 'src.a',
            mangaId: 'manga-1',
            id: 'ch-1',
            title: 'Chapter 1',
            scanlator: null,
            lang: 'en',
            chapter: 1.0,
            volume: null,
            dateUploaded: null,
            sourceOrder: 0,
          ),
          AidokuBackupChapter(
            sourceId: 'src.a',
            mangaId: 'manga-2',
            id: 'ch-2',
            title: 'Chapter 1',
            scanlator: null,
            lang: 'en',
            chapter: 1.0,
            volume: null,
            dateUploaded: null,
            sourceOrder: 0,
          ),
        },
        trackItems: null,
        categories: const <String>{'Favorites'},
        sources: const <String>{'src.a'},
        date: DateTime(2024),
        name: 'test',
        version: '1',
      );

      final List<SourceMangaData> entries = backup.sourceMangaDataEntries;
      check(entries).length.equals(2);

      final SourceMangaData entry1 = entries.firstWhere((SourceMangaData e) => e.details.title == 'Aidoku Manga');
      check(entry1.sourceId).equals('src.a');
      check(entry1.chapters).length.equals(1);
      check(entry1.history).length.equals(1);
      check(entry1.history[0].completed).isTrue();
      check(entry1.history[0].chapterKey).isNotNull().equals(entry1.chapters[0].chapterKey!);
      check(entry1.sourceMangaKey).isNotNull();
      check(entry1.categories).deepEquals(<String>['Favorites']);

      final SourceMangaData entry2 = entries.firstWhere((SourceMangaData e) => e.details.title == 'Other Manga');
      check(entry2.chapters).length.equals(1);
      check(entry2.history).isEmpty();
      check(entry2.categories).isEmpty();
    });

    test('empty backup returns empty list', () {
      final backup = AidokuBackup(
        library: null,
        history: null,
        manga: null,
        chapters: null,
        trackItems: null,
        categories: null,
        sources: null,
        date: DateTime(2024),
        name: null,
        version: null,
      );
      check(backup.sourceMangaDataEntries).isEmpty();
    });
  });

  group('Paperback sourceMangaDataEntries', () {
    test('links chapters through sourceManga', () {
      final backup = PaperbackBackup(
        mangaInfo: <PaperbackBackupMangaInfo>[
          PaperbackBackupMangaInfo(
            tags: const <PaperbackBackupMangaTag>[],
            desc: 'A manga',
            titles: const <String>['PB Manga'],
            covers: const <String>[],
            author: 'Auth',
            image: '',
            hentai: false,
            additionalInfo: PaperbackBackupMangaAdditionalInfo(),
            artist: 'Art',
            id: 'info-1',
            status: 'Ongoing',
          ),
        ],
        sourceManga: <PaperbackBackupSourceManga>[
          PaperbackBackupSourceManga(
            sourceId: 'en.source',
            mangaId: 'manga-key',
            id: 'sm-1',
            mangaInfo: PaperbackBackupItemReference(type: PaperbackBackupItemType.mangaInfoV4, id: 'info-1'),
          ),
        ],
        chapters: <PaperbackBackupChapter>[
          PaperbackBackupChapter(
            volume: 1,
            langCode: 'en',
            group: 'GroupA',
            sortingIndex: 0,
            id: 'ch-1',
            chapNum: 1,
            chapterId: 'ch-1-id',
            time: DateTime(2024),
            isNew: false,
            name: 'Chapter 1',
            sourceManga: PaperbackBackupItemReference(type: PaperbackBackupItemType.sourceMangaV4, id: 'sm-1'),
          ),
        ],
        chapterProgressMarker: <PaperbackBackupChapterProgressMarker>[
          PaperbackBackupChapterProgressMarker(
            totalPages: 20,
            completed: true,
            chapter: PaperbackBackupItemReference(type: PaperbackBackupItemType.chapterV4, id: 'ch-1'),
            lastPage: 19,
            time: DateTime(2024),
            hidden: false,
          ),
        ],
        libraryManga: <PaperbackBackupLibraryManga>[
          PaperbackBackupLibraryManga(
            libraryTabs: <PaperbackBackupLibraryTab>[
              PaperbackBackupLibraryTab(sortOrder: 0, id: 'tab-1', name: 'Favorites'),
            ],
            lastRead: DateTime(2024),
            primarySource: PaperbackBackupItemReference(type: PaperbackBackupItemType.sourceMangaV4, id: 'sm-1'),
            dateBookmarked: DateTime(2024),
            trackedSources: const <PaperbackBackupItemReference>[],
            id: 'info-1',
            secondarySources: const <PaperbackBackupItemReference>[],
          ),
        ],
      );

      final List<SourceMangaData> entries = backup.sourceMangaDataEntries;
      check(entries).length.equals(1);

      final SourceMangaData entry = entries[0];
      check(entry.details.title).equals('PB Manga');
      check(entry.sourceId).equals('en.source');
      check(entry.chapters).length.equals(1);
      check(entry.chapters[0].isRead).isTrue();
      check(entry.chapters[0].lastPageRead).equals(19);
      check(entry.categories).deepEquals(<String>['Favorites']);
    });

    test('empty backup returns empty list', () {
      const backup = PaperbackBackup();
      check(backup.sourceMangaDataEntries).isEmpty();
    });
  });
}
