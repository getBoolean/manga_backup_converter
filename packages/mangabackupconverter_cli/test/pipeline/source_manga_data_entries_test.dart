import 'package:checks/checks.dart';
import 'package:mangabackupconverter_cli/mangabackupconverter_lib.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Tachimanga sourceMangaDataEntries', () {
    test('filters data per manga', () {
      const db = TachimangaBackupDb(
        categoryTable: <TachimangaBackupCategory>[
          TachimangaBackupCategory(id: 1, name: 'Favorites', order: 0, isDefault: false),
          TachimangaBackupCategory(id: 2, name: 'Reading', order: 1, isDefault: false),
        ],
        categoryMangaTable: <TachimangaBackupCategoryManga>[
          TachimangaBackupCategoryManga(id: 1, category: 1, manga: 10),
          TachimangaBackupCategoryManga(id: 2, category: 2, manga: 20),
        ],
        categoryMetaTable: <TachimangaBackupCategoryMeta>[],
        chapterTable: <TachimangaBackupChapter>[
          TachimangaBackupChapter(
            id: 100,
            url: '/ch/1',
            name: 'Ch 1',
            dateUpload: 0,
            chapterNumber: 1,
            scanlator: null,
            read: true,
            bookmark: false,
            lastPageRead: 5,
            lastReadAt: 1000,
            fetchedAt: 0,
            sourceOrder: 0,
            realUrl: null,
            isDownloaded: false,
            pageCount: 20,
            manga: 10,
          ),
          TachimangaBackupChapter(
            id: 200,
            url: '/ch/2',
            name: 'Ch 2',
            dateUpload: 0,
            chapterNumber: 1,
            scanlator: null,
            read: false,
            bookmark: false,
            lastPageRead: 0,
            lastReadAt: 0,
            fetchedAt: 0,
            sourceOrder: 0,
            realUrl: null,
            isDownloaded: false,
            pageCount: 10,
            manga: 20,
          ),
        ],
        chapterMetaTable: <TachimangaBackupChapterMeta>[],
        extensionTable: <TachimangaBackupExtension>[],
        historyTable: <TachimangaBackupHistory>[
          TachimangaBackupHistory(
            id: 1,
            createAt: 0,
            isDelete: false,
            mangaId: 10,
            lastChapterId: 100,
            lastReadAt: 5000,
          ),
        ],
        mangaTable: <TachimangaBackupManga>[
          TachimangaBackupManga(
            id: 10,
            url: '/manga/10',
            title: 'Manga A',
            initialized: true,
            artist: null,
            author: null,
            description: null,
            genre: null,
            status: 0,
            thumbnailUrl: null,
            thumbnailUrlLastFetched: 0,
            inLibrary: true,
            defaultCategory: false,
            inLibraryAt: 0,
            source: 1,
            realUrl: null,
            lastFetchedAt: 0,
            chaptersLastFetchedAt: 0,
            updateStrategy: 'AlwaysUpdate',
            lastDownloadAt: 0,
          ),
          TachimangaBackupManga(
            id: 20,
            url: '/manga/20',
            title: 'Manga B',
            initialized: true,
            artist: null,
            author: null,
            description: null,
            genre: null,
            status: 0,
            thumbnailUrl: null,
            thumbnailUrlLastFetched: 0,
            inLibrary: true,
            defaultCategory: false,
            inLibraryAt: 0,
            source: 1,
            realUrl: null,
            lastFetchedAt: 0,
            chaptersLastFetchedAt: 0,
            updateStrategy: 'AlwaysUpdate',
            lastDownloadAt: 0,
          ),
        ],
        mangaMetaTable: <TachimangaBackupMangaMeta>[],
        migrationsTable: <TachimangaBackupDbMigrations>[],
        pageTable: <TachimangaBackupPage>[],
        repoTable: <TachimangaBackupRepo>[],
        settingTable: <TachimangaBackupSetting>[],
        sourceTable: <TachimangaBackupSource>[
          TachimangaBackupSource(
            id: 1,
            name: 'MangaDex',
            lang: 'en',
            extension: 0,
            isNsfw: false,
            isDirect: false,
            randomUa: false,
          ),
        ],
        trackRecordTable: <TachimangaBackupTrackRecord>[],
        sqliteSequenceTable: <TachimangaBackupSqliteSequence>[],
      );

      final backup = TachimangaBackup(
        meta: TachimangaBackupMeta(
          name: 'test',
          version: 1,
          remoteBackup: false,
          downloaded: false,
          backupId: 0,
          updateAt: 0,
          type: 0,
          size: 0,
          checksum: '',
          createAt: 0,
          cloudBackup: false,
          downloadProgress: 0,
          state: 0,
          extInfo: null,
        ),
        db: db,
      );

      final List<SourceMangaData> entries = backup.sourceMangaDataEntries;
      check(entries).length.equals(2);

      final SourceMangaData entryA = entries[0];
      check(entryA.details.title).equals('Manga A');
      check(entryA.sourceId).equals('MangaDex');
      check(entryA.chapters).length.equals(1);
      check(entryA.chapters[0].title).equals('Ch 1');
      check(entryA.history).length.equals(1);
      check(entryA.history[0].chapterKey).isNotNull().equals(entryA.chapters[0].chapterKey!);
      check(entryA.categories).deepEquals(<String>['Favorites']);

      final SourceMangaData entryB = entries[1];
      check(entryB.details.title).equals('Manga B');
      check(entryB.sourceId).equals('MangaDex');
      check(entryB.chapters).length.equals(1);
      check(entryB.chapters[0].title).equals('Ch 2');
      check(entryB.history).isEmpty();
      check(entryB.categories).deepEquals(<String>['Reading']);
    });

    test('empty backup returns empty list', () {
      const db = TachimangaBackupDb(
        categoryTable: <TachimangaBackupCategory>[],
        categoryMangaTable: <TachimangaBackupCategoryManga>[],
        categoryMetaTable: <TachimangaBackupCategoryMeta>[],
        chapterTable: <TachimangaBackupChapter>[],
        chapterMetaTable: <TachimangaBackupChapterMeta>[],
        extensionTable: <TachimangaBackupExtension>[],
        historyTable: <TachimangaBackupHistory>[],
        mangaTable: <TachimangaBackupManga>[],
        mangaMetaTable: <TachimangaBackupMangaMeta>[],
        migrationsTable: <TachimangaBackupDbMigrations>[],
        pageTable: <TachimangaBackupPage>[],
        repoTable: <TachimangaBackupRepo>[],
        settingTable: <TachimangaBackupSetting>[],
        sourceTable: <TachimangaBackupSource>[],
        trackRecordTable: <TachimangaBackupTrackRecord>[],
        sqliteSequenceTable: <TachimangaBackupSqliteSequence>[],
      );

      final backup = TachimangaBackup(
        meta: TachimangaBackupMeta(
          name: 'test',
          version: 1,
          remoteBackup: false,
          downloaded: false,
          backupId: 0,
          updateAt: 0,
          type: 0,
          size: 0,
          checksum: '',
          createAt: 0,
          cloudBackup: false,
          downloadProgress: 0,
          state: 0,
          extInfo: null,
        ),
        db: db,
      );
      check(backup.sourceMangaDataEntries).isEmpty();
    });
  });

  group('Mangayomi sourceMangaDataEntries', () {
    test('filters data per manga and resolves categories', () {
      const backup = MangayomiBackup(
        db: MangayomiBackupDb(
          manga: <MangayomiBackupManga>[
            MangayomiBackupManga(
              id: 1,
              source: 'src',
              author: 'A',
              artist: 'B',
              genre: null,
              imageUrl: null,
              lang: 'en',
              link: '/m/1',
              name: 'Manga 1',
              status: 0,
              description: null,
              categories: '1,2',
            ),
            MangayomiBackupManga(
              id: 2,
              source: 'src',
              author: null,
              artist: null,
              genre: null,
              imageUrl: null,
              lang: 'en',
              link: '/m/2',
              name: 'Manga 2',
              status: 0,
              description: null,
              categories: '2',
            ),
          ],
          categories: <MangayomiBackupCategory>[
            MangayomiBackupCategory(id: 1, name: 'Favorites', forItemType: 0),
            MangayomiBackupCategory(id: 2, name: 'Reading', forItemType: 0),
          ],
          chapters: <MangayomiBackupChapter>[
            MangayomiBackupChapter(id: 10, mangaId: 1, name: 'Ch 1'),
            MangayomiBackupChapter(id: 20, mangaId: 2, name: 'Ch 2'),
          ],
          history: <MangayomiBackupHistory>[
            MangayomiBackupHistory(
              itemType: ItemType.manga,
              chapterId: 10,
              mangaId: 1,
              date: '2024-01-01',
            ),
          ],
          tracks: <MangayomiBackupTrack>[
            MangayomiBackupTrack(id: 1, mangaId: 1, syncId: 1, status: 1),
          ],
        ),
      );

      final List<SourceMangaData> entries = backup.sourceMangaDataEntries;
      check(entries).length.equals(2);

      final SourceMangaData e1 = entries.firstWhere((SourceMangaData e) => e.details.title == 'Manga 1');
      check(e1.sourceId).equals('src');
      check(e1.chapters).length.equals(1);
      check(e1.history).length.equals(1);
      check(e1.history[0].chapterKey).isNotNull().equals(e1.chapters[0].chapterKey!);
      check(e1.tracking).length.equals(1);
      check(e1.categories).length.equals(2);
      check(e1.categories).contains('Favorites');
      check(e1.categories).contains('Reading');

      final SourceMangaData e2 = entries.firstWhere((SourceMangaData e) => e.details.title == 'Manga 2');
      check(e2.chapters).length.equals(1);
      check(e2.history).isEmpty();
      check(e2.tracking).isEmpty();
      check(e2.categories).deepEquals(<String>['Reading']);
    });

    test('empty backup returns empty list', () {
      const backup = MangayomiBackup(db: MangayomiBackupDb());
      check(backup.sourceMangaDataEntries).isEmpty();
    });
  });
}
