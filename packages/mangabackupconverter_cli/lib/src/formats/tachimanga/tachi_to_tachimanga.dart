import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup_db.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup_db_models.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup_meta.dart';

/// Tachi to Tachimanga direct conversion. Lives with the native-dependent
/// Tachimanga codec, outside the portable core, so the portable Tachi model
/// has no reverse dependency on the SQLite-backed format (KTD14).
extension TachiToTachimanga on TachiBackup {
  TachimangaBackup toTachimangaBackup() {
    // Categories — sequential IDs starting at 1
    final categoryTable = <TachimangaBackupCategory>[
      for (var i = 0; i < backupCategories.length; i++)
        TachimangaBackupCategory(
          id: i + 1,
          name: backupCategories[i].name,
          order: backupCategories[i].order,
          isDefault: false,
        ),
    ];

    // Manga — sequential IDs starting at 1
    final mangaTable = <TachimangaBackupManga>[];
    final chapterTable = <TachimangaBackupChapter>[];
    final categoryMangaTable = <TachimangaBackupCategoryManga>[];
    final historyTable = <TachimangaBackupHistory>[];
    final trackRecordTable = <TachimangaBackupTrackRecord>[];

    var chapterId = 1;
    var categoryMangaId = 1;
    var historyId = 1;
    var trackId = 1;

    for (var mangaIdx = 0; mangaIdx < backupManga.length; mangaIdx++) {
      final TachiBackupManga manga = backupManga[mangaIdx];
      final int mangaId = mangaIdx + 1;

      mangaTable.add(
        TachimangaBackupManga(
          id: mangaId,
          url: manga.url,
          title: manga.title,
          initialized: true,
          artist: manga.artist.isEmpty ? null : manga.artist,
          author: manga.author.isEmpty ? null : manga.author,
          description: manga.description.isEmpty ? null : manga.description,
          genre: manga.genre.isEmpty ? null : manga.genre.join(', '),
          status: manga.status,
          thumbnailUrl: manga.thumbnailUrl.isEmpty ? null : manga.thumbnailUrl,
          thumbnailUrlLastFetched: 0,
          inLibrary: true,
          defaultCategory: false,
          inLibraryAt: manga.dateAdded,
          source: manga.source,
          realUrl: null,
          lastFetchedAt: 0,
          chaptersLastFetchedAt: 0,
          updateStrategy: manga.updateStrategy.index.toString(),
          lastDownloadAt: 0,
        ),
      );

      // Chapters — build URL→chapterId map for history lookup
      final chapterUrlToId = <String, int>{};
      for (final TachiBackupChapter ch in manga.chapters) {
        final int id = chapterId++;
        chapterUrlToId[ch.url] = id;
        chapterTable.add(
          TachimangaBackupChapter(
            id: id,
            url: ch.url,
            name: ch.name,
            dateUpload: ch.dateUpload,
            chapterNumber: ch.chapterNumber,
            scanlator: ch.scanlator.isEmpty ? null : ch.scanlator,
            read: ch.read,
            bookmark: ch.bookmark,
            lastPageRead: ch.lastPageRead,
            lastReadAt: ch.lastModifiedAt ?? 0,
            fetchedAt: ch.dateFetch,
            sourceOrder: ch.sourceOrder,
            realUrl: null,
            isDownloaded: false,
            pageCount: 0,
            manga: mangaId,
          ),
        );
      }

      // CategoryManga junction
      for (final int catIdx in manga.categories) {
        categoryMangaTable.add(
          TachimangaBackupCategoryManga(
            id: categoryMangaId++,
            category: catIdx + 1,
            manga: mangaId,
          ),
        );
      }

      // History — Tachimanga has UNIQUE(manga_id), so collapse all
      // per-chapter history entries into one row per manga: latest chapter
      // by lastRead timestamp, summed readDuration.
      if (manga.history.isNotEmpty) {
        final TachiBackupHistory latestHistory = manga.history.reduce(
          (TachiBackupHistory a, TachiBackupHistory b) => a.lastRead >= b.lastRead ? a : b,
        );
        final int totalDuration = manga.history.fold<int>(
          0,
          (int sum, TachiBackupHistory h) => sum + h.readDuration,
        );
        historyTable.add(
          TachimangaBackupHistory(
            id: historyId++,
            createAt: 0,
            isDelete: false,
            mangaId: mangaId,
            lastChapterId: chapterUrlToId[latestHistory.url] ?? 0,
            lastReadAt: totalDuration,
          ),
        );
      }

      // Tracking
      for (final TachiBackupTracking t in manga.tracking) {
        trackRecordTable.add(
          TachimangaBackupTrackRecord(
            id: trackId++,
            mangaId: mangaId,
            syncId: t.syncId,
            remoteId: t.mediaId,
            libraryId: t.libraryId == -1 ? null : t.libraryId,
            title: t.title,
            lastChapterRead: t.lastChapterRead,
            totalChapters: t.totalChapters,
            status: t.status,
            score: t.score,
            remoteUrl: t.trackingUrl,
            startDate: t.startedReadingDate,
            finishDate: t.finishedReadingDate,
          ),
        );
      }
    }

    // Sources
    final sourceTable = <TachimangaBackupSource>[
      for (final TachiBackupSource s in <TachiBackupSource>[...backupSources, ...backupBrokenSources])
        TachimangaBackupSource(
          id: s.sourceId,
          name: s.name,
          lang: '',
          extension: 0,
          isNsfw: false,
          isDirect: null,
          randomUa: null,
        ),
    ];

    // Repos
    final repoTable = <TachimangaBackupRepo>[
      for (var i = 0; i < backupExtensionRepo.length; i++)
        TachimangaBackupRepo(
          id: i + 1,
          type: 0,
          name: backupExtensionRepo[i].name,
          metaUrl: '',
          baseUrl: backupExtensionRepo[i].baseUrl,
          homepage: backupExtensionRepo[i].website,
          deleted: false,
          createAt: 0,
          updateAt: 0,
        ),
    ];

    return TachimangaBackup(
      meta: TachimangaBackupMeta(
        name: 'Converted Backup',
        remoteBackup: false,
        downloaded: false,
        backupId: 0,
        updateAt: 0,
        type: 0,
        size: 0,
        checksum: '',
        createAt: 0,
        cloudBackup: false,
        version: 1,
        downloadProgress: 0,
        state: 0,
        extInfo: null,
      ),
      db: TachimangaBackupDb(
        categoryTable: categoryTable,
        categoryMangaTable: categoryMangaTable,
        categoryMetaTable: const <TachimangaBackupCategoryMeta>[],
        chapterTable: chapterTable,
        chapterMetaTable: const <TachimangaBackupChapterMeta>[],
        extensionTable: const <TachimangaBackupExtension>[],
        historyTable: historyTable,
        mangaTable: mangaTable,
        mangaMetaTable: const <TachimangaBackupMangaMeta>[],
        migrationsTable: const <TachimangaBackupDbMigrations>[],
        pageTable: const <TachimangaBackupPage>[],
        repoTable: repoTable,
        settingTable: const <TachimangaBackupSetting>[],
        sourceTable: sourceTable,
        trackRecordTable: trackRecordTable,
        sqliteSequenceTable: const <TachimangaBackupSqliteSequence>[],
      ),
    );
  }
}
