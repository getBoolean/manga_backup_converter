import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:checks/checks.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_chapter.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_chapter_progress_marker.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_item_reference.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_item_type.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_library_manga.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_library_tab.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_manga_info.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_source_manga.dart';
import 'package:test/scaffolding.dart';

import '../../fixtures/paperback_fixtures.dart' as fx;

Uint8List _buildZip(Map<String, String> files) {
  final archive = Archive();
  for (final MapEntry<String, String> entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  final epoch = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  group('PaperbackBackup', () {
    group('fromData', () {
      test('parses ZIP with all expected archive file names', () {
        final Uint8List bytes = _buildZip(<String, String>{
          '__MANGA_INFO_V4': jsonEncode(<String, dynamic>{
            'info1': <String, dynamic>{
              'id': 'info1',
              'titles': <String>['My Manga'],
              'covers': <String>[],
              'image': 'https://example.com/cover.jpg',
              'desc': 'A description',
              'author': 'Author A',
              'artist': 'Artist B',
              'hentai': false,
              'status': 'Ongoing',
              'tags': <Map<String, dynamic>>[],
              'additionalInfo': <String, dynamic>{},
            },
          }),
          '__CHAPTER_V4': jsonEncode(<String, dynamic>{}),
          '__LIBRARY_MANGA_V4': jsonEncode(<String, dynamic>{}),
          '__SOURCE_MANGA_V4': jsonEncode(<String, dynamic>{}),
          '__CHAPTER_PROGRESS_MARKER_V4-1': jsonEncode(<String, dynamic>{}),
        });

        final backup = PaperbackBackup.fromData(bytes, name: 'test');

        check(backup.name).equals('test');
        check(backup.mangaInfo).isNotNull().length.equals(1);
        check(backup.mangaInfo!.first.id).equals('info1');
      });

      test('handles missing archive entries gracefully', () {
        final Uint8List bytes = _buildZip(<String, String>{
          '__MANGA_INFO_V4': jsonEncode(<String, dynamic>{
            'info1': <String, dynamic>{
              'id': 'info1',
              'titles': <String>['My Manga'],
              'covers': <String>[],
              'image': 'img.jpg',
              'desc': '',
              'author': '',
              'artist': '',
              'hentai': false,
              'status': 'Ongoing',
              'tags': <Map<String, dynamic>>[],
              'additionalInfo': <String, dynamic>{},
            },
          }),
        });

        final backup = PaperbackBackup.fromData(bytes);

        check(backup.mangaInfo).isNotNull().length.equals(1);
        check(backup.chapters).isNull();
        check(backup.chapterProgressMarker).isNull();
        check(backup.libraryManga).isNull();
        check(backup.sourceManga).isNull();
      });
    });

    group('toData', () {
      test('produces a valid ZIP with expected archive entries', () async {
        final sourceMangaRef = PaperbackBackupItemReference(
          type: PaperbackBackupItemType.sourceMangaV4,
          id: 'sm1',
        );

        final backup = PaperbackBackup(
          name: 'test',
          mangaInfo: <PaperbackBackupMangaInfo>[
            PaperbackBackupMangaInfo(
              id: 'info1',
              titles: <String>['Test Manga'],
              covers: <String>[],
              image: 'img.jpg',
              desc: 'Desc',
              author: 'Auth',
              artist: 'Art',
              hentai: false,
              status: 'Ongoing',
              tags: <PaperbackBackupMangaTag>[],
              additionalInfo: PaperbackBackupMangaAdditionalInfo(),
            ),
          ],
          chapters: <PaperbackBackupChapter>[
            PaperbackBackupChapter(
              volume: 1,
              langCode: 'en',
              group: 'Scanlator',
              sortingIndex: 0,
              id: 'ch1',
              chapNum: 1,
              chapterId: 'ch1',
              time: epoch,
              isNew: false,
              name: 'Chapter 1',
              sourceManga: sourceMangaRef,
            ),
          ],
        );

        final Uint8List bytes = await backup.toData();
        final Archive archive = ZipDecoder().decodeBytes(bytes);

        final Set<String> fileNames = archive.files.map((ArchiveFile f) => f.name).toSet();
        check(fileNames).contains('__MANGA_INFO_V4');
        check(fileNames).contains('__CHAPTER_V4');
        check(fileNames).contains('__LIBRARY_MANGA_V4');
        check(fileNames).contains('__SOURCE_MANGA_V4');
        check(fileNames).contains('__CHAPTER_PROGRESS_MARKER_V4-1');
      });

      test('round-trips through toData and fromData', () async {
        final sourceMangaRef = PaperbackBackupItemReference(
          type: PaperbackBackupItemType.sourceMangaV4,
          id: 'sm1',
        );

        final backup = PaperbackBackup(
          name: 'roundtrip',
          mangaInfo: <PaperbackBackupMangaInfo>[
            PaperbackBackupMangaInfo(
              id: 'info1',
              titles: <String>['Test Manga'],
              covers: <String>[],
              image: 'img.jpg',
              desc: 'Desc',
              author: 'Auth',
              artist: 'Art',
              hentai: false,
              status: 'Ongoing',
              tags: <PaperbackBackupMangaTag>[],
              additionalInfo: PaperbackBackupMangaAdditionalInfo(),
            ),
          ],
          chapters: <PaperbackBackupChapter>[
            PaperbackBackupChapter(
              volume: 1,
              langCode: 'en',
              group: 'Scanlator',
              sortingIndex: 0,
              id: 'ch1',
              chapNum: 1,
              chapterId: 'ch1',
              time: epoch,
              isNew: false,
              name: 'Chapter 1',
              sourceManga: sourceMangaRef,
            ),
          ],
        );

        final Uint8List bytes = await backup.toData();
        final restored = PaperbackBackup.fromData(bytes, name: 'roundtrip');

        check(restored.name).equals('roundtrip');
        check(restored.mangaInfo).isNotNull().length.equals(1);
        check(restored.mangaInfo!.first.id).equals('info1');
        check(restored.mangaInfo!.first.titles.first).equals('Test Manga');
        check(restored.chapters).isNotNull().length.equals(1);
        check(restored.chapters!.first.id).equals('ch1');
        check(restored.chapters!.first.name).equals('Chapter 1');
      });
    });

    group('mangaSearchEntries', () {
      test('returns manga info list', () {
        final backup = PaperbackBackup(
          mangaInfo: <PaperbackBackupMangaInfo>[
            PaperbackBackupMangaInfo(
              id: 'info1',
              titles: <String>['Manga A'],
              covers: <String>[],
              image: 'img.jpg',
              desc: '',
              author: 'A',
              artist: 'B',
              hentai: false,
              status: 'Ongoing',
              tags: <PaperbackBackupMangaTag>[],
              additionalInfo: PaperbackBackupMangaAdditionalInfo(),
            ),
          ],
        );

        check(backup.mangaSearchEntries.length).equals(1);
      });

      test('returns empty list when mangaInfo is null', () {
        const backup = PaperbackBackup();
        check(backup.mangaSearchEntries).isEmpty();
      });
    });

    group('sourceMangaDataEntries', () {
      test('links chapters and progress markers through sourceManga', () {
        final mangaInfoRef = PaperbackBackupItemReference(
          type: PaperbackBackupItemType.mangaInfoV4,
          id: 'info1',
        );
        final sourceMangaRef = PaperbackBackupItemReference(
          type: PaperbackBackupItemType.sourceMangaV4,
          id: 'sm1',
        );
        final chapterRef = PaperbackBackupItemReference(
          type: PaperbackBackupItemType.chapterV4,
          id: 'ch1',
        );

        final backup = PaperbackBackup(
          mangaInfo: <PaperbackBackupMangaInfo>[
            PaperbackBackupMangaInfo(
              id: 'info1',
              titles: <String>['Test'],
              covers: <String>[],
              image: 'img.jpg',
              desc: 'Desc',
              author: 'Auth',
              artist: 'Art',
              hentai: false,
              status: 'Ongoing',
              tags: <PaperbackBackupMangaTag>[
                PaperbackBackupMangaTag(id: 'tag1', label: 'Action'),
              ],
              additionalInfo: PaperbackBackupMangaAdditionalInfo(),
            ),
          ],
          sourceManga: <PaperbackBackupSourceManga>[
            PaperbackBackupSourceManga(
              sourceId: 'src1',
              mangaId: 'manga1',
              id: 'sm1',
              mangaInfo: mangaInfoRef,
            ),
          ],
          chapters: <PaperbackBackupChapter>[
            PaperbackBackupChapter(
              volume: 1,
              langCode: 'en',
              group: 'Group',
              sortingIndex: 0,
              id: 'ch1',
              chapNum: 1,
              chapterId: 'ch1',
              time: epoch,
              isNew: false,
              name: 'Chapter 1',
              sourceManga: sourceMangaRef,
            ),
          ],
          chapterProgressMarker: <PaperbackBackupChapterProgressMarker>[
            PaperbackBackupChapterProgressMarker(
              totalPages: 20,
              completed: true,
              chapter: chapterRef,
              lastPage: 19,
              time: epoch,
              hidden: false,
            ),
          ],
          libraryManga: <PaperbackBackupLibraryManga>[
            PaperbackBackupLibraryManga(
              id: 'info1',
              libraryTabs: <PaperbackBackupLibraryTab>[
                PaperbackBackupLibraryTab(
                  sortOrder: 0,
                  id: 'tab1',
                  name: 'Reading',
                ),
              ],
              lastRead: epoch,
              primarySource: sourceMangaRef,
              dateBookmarked: epoch,
              trackedSources: <PaperbackBackupItemReference>[],
              secondarySources: <PaperbackBackupItemReference>[],
            ),
          ],
        );

        final List<SourceMangaData> entries = backup.sourceMangaDataEntries;
        check(entries.length).equals(1);

        final SourceMangaData entry = entries.first;
        check(entry.details.title).equals('Test');
        check(entry.sourceId).equals('src1');
        check(entry.categories).deepEquals(<String>['Reading']);
        check(entry.chapters.length).equals(1);
        check(entry.chapters.first.title).equals('Chapter 1');
        check(entry.chapters.first.isRead).isTrue();
        check(entry.chapters.first.lastPageRead).equals(19);
        check(entry.dateAdded).isNotNull();
        check(entry.lastRead).isNotNull();
      });

      test('chapter isRead is false when no progress marker', () {
        final mangaInfoRef = PaperbackBackupItemReference(
          type: PaperbackBackupItemType.mangaInfoV4,
          id: 'info1',
        );
        final sourceMangaRef = PaperbackBackupItemReference(
          type: PaperbackBackupItemType.sourceMangaV4,
          id: 'sm1',
        );

        final backup = PaperbackBackup(
          mangaInfo: <PaperbackBackupMangaInfo>[
            PaperbackBackupMangaInfo(
              id: 'info1',
              titles: <String>['Test'],
              covers: <String>[],
              image: 'img.jpg',
              desc: '',
              author: '',
              artist: '',
              hentai: false,
              status: 'Ongoing',
              tags: <PaperbackBackupMangaTag>[],
              additionalInfo: PaperbackBackupMangaAdditionalInfo(),
            ),
          ],
          sourceManga: <PaperbackBackupSourceManga>[
            PaperbackBackupSourceManga(
              sourceId: 'src1',
              mangaId: 'manga1',
              id: 'sm1',
              mangaInfo: mangaInfoRef,
            ),
          ],
          chapters: <PaperbackBackupChapter>[
            PaperbackBackupChapter(
              volume: 0,
              langCode: 'en',
              group: '',
              sortingIndex: 0,
              id: 'ch1',
              chapNum: 1,
              chapterId: 'ch1',
              time: epoch,
              isNew: false,
              name: 'Ch 1',
              sourceManga: sourceMangaRef,
            ),
          ],
          // Only library manga are migrated; this entry links via primarySource.
          libraryManga: <PaperbackBackupLibraryManga>[
            PaperbackBackupLibraryManga(
              id: 'lib1',
              libraryTabs: <PaperbackBackupLibraryTab>[],
              lastRead: null,
              primarySource: sourceMangaRef,
              dateBookmarked: null,
              trackedSources: <PaperbackBackupItemReference>[],
              secondarySources: <PaperbackBackupItemReference>[],
            ),
          ],
        );

        final List<SourceMangaData> entries = backup.sourceMangaDataEntries;
        check(entries.first.chapters.first.isRead).isFalse();
        check(entries.first.chapters.first.hasReadingState).isFalse();
      });
    });
  });

  group('PaperbackBackup characterization (sanitized fixtures)', () {
    test('decodes timestamps as seconds since the Apple reference date', () {
      final backup = PaperbackBackup.fromData(fx.libraryLinkageArchive());

      final PaperbackBackupChapter ch = backup.chapters!.firstWhere((PaperbackBackupChapter c) => c.id == 'ch-A1');
      check(ch.time.toUtc()).equals(fx.fixtureUploadInstant);

      final PaperbackBackupChapterProgressMarker marker = backup.chapterProgressMarker!.firstWhere(
        (PaperbackBackupChapterProgressMarker m) => m.chapter.id == 'ch-A1',
      );
      check(marker.time.toUtc()).equals(fx.fixtureReadInstant);

      final PaperbackBackupLibraryManga lib = backup.libraryManga!.single;
      check(lib.lastRead).isNotNull().has((DateTime d) => d.toUtc(), 'utc').equals(fx.fixtureReadInstant);
      check(lib.dateBookmarked).isNotNull().has((DateTime d) => d.toUtc(), 'utc').equals(fx.fixtureUploadInstant);
    });

    test('writes timestamps back as Apple-reference seconds', () async {
      final backup = PaperbackBackup.fromData(fx.libraryLinkageArchive());
      final Uint8List bytes = await backup.toData();
      final Archive archive = ZipDecoder().decodeBytes(bytes);

      final chapters =
          jsonDecode(utf8.decode(archive.findFile('__CHAPTER_V4')!.content as List<int>)) as Map<String, dynamic>;
      check((chapters['ch-A1'] as Map<String, dynamic>)['time'] as num).equals(fx.fixtureUploadAppleSeconds);

      final library =
          jsonDecode(utf8.decode(archive.findFile('__LIBRARY_MANGA_V4')!.content as List<int>)) as Map<String, dynamic>;
      check((library['lib-uuid-1'] as Map<String, dynamic>)['lastRead'] as num).equals(fx.fixtureReadAppleSeconds);
    });

    test('decodes archive entries as UTF-8', () {
      final backup = PaperbackBackup.fromData(fx.libraryLinkageArchive());

      final PaperbackBackupChapter ch = backup.chapters!.firstWhere((PaperbackBackupChapter c) => c.id == 'ch-A1');
      check(ch.name).equals('Chapitre 1 — Été 日本語');
      check(
        backup.libraryManga!.single.libraryTabs.map((PaperbackBackupLibraryTab t) => t.name).toSet(),
      ).deepEquals(<String>{'Zweite Ä', '読書中'});
    });

    test('Unicode chapter titles and tabs survive a serialization round trip', () async {
      final backup = PaperbackBackup.fromData(fx.libraryLinkageArchive());
      final restored = PaperbackBackup.fromData(await backup.toData());

      final PaperbackBackupChapter ch = restored.chapters!.firstWhere((PaperbackBackupChapter c) => c.id == 'ch-A1');
      check(ch.name).equals('Chapitre 1 — Été 日本語');
      check(ch.time.toUtc()).equals(fx.fixtureUploadInstant);
    });

    test('library manga link to manga info through the primary source, not by ID', () {
      final backup = PaperbackBackup.fromData(fx.libraryLinkageArchive());
      final List<SourceMangaData> entries = backup.sourceMangaDataEntries;

      // Only the library manga is selected; the browsed manga-info entry is not.
      check(entries).length.equals(1);
      final SourceMangaData entry = entries.single;
      check(entry.details.title).equals('Library Title A');
      check(entry.sourceId).equals('SourceAlpha');
      // Tabs follow the library's sort order, not archive order.
      check(entry.categories).deepEquals(<String>['読書中', 'Zweite Ä']);
      check(entry.dateAdded).isNotNull().has((DateTime d) => d.toUtc(), 'utc').equals(fx.fixtureUploadInstant);
      check(entry.lastRead).isNotNull().has((DateTime d) => d.toUtc(), 'utc').equals(fx.fixtureReadInstant);
      check(entry.chapters.map((SourceChapter c) => c.title).toList()).deepEquals(<String>[
        'Chapitre 1 — Été 日本語',
        'Chapter 2',
      ]);
    });

    test('missing-date sentinels are not reported as real dates', () {
      final Uint8List bytes = fx.buildPaperbackArchive(<String, Map<String, dynamic>>{
        '__MANGA_INFO_V4': <String, dynamic>{
          'info-A': fx.mangaInfoJson('info-A', titles: <String>['A']),
        },
        '__SOURCE_MANGA_V4': <String, dynamic>{'sm-A': fx.sourceMangaJson('sm-A', mangaInfoId: 'info-A')},
        '__CHAPTER_V4': <String, dynamic>{
          'c1': fx.chapterJson('c1', sourceMangaId: 'sm-A', chapNum: 1, time: fx.appleDistantPastSeconds),
          'c2': fx.chapterJson('c2', sourceMangaId: 'sm-A', chapNum: 2, time: fx.appleUnixEpochSeconds),
          'c3': fx.chapterJson('c3', sourceMangaId: 'sm-A', chapNum: 3, time: fx.appleDistantFutureSeconds),
          'c4': fx.chapterJson('c4', sourceMangaId: 'sm-A', chapNum: 4),
        },
        '__LIBRARY_MANGA_V4': <String, dynamic>{
          'lib-1': fx.libraryMangaJson('lib-1', primarySourceId: 'sm-A'),
        },
      });

      final SourceMangaData entry = PaperbackBackup.fromData(bytes).sourceMangaDataEntries.single;
      final uploaded = <double?, DateTime?>{
        for (final SourceChapter c in entry.chapters) c.chapterNumber: c.dateUploaded,
      };
      check(uploaded[1]).isNull();
      check(uploaded[2]).isNull();
      check(uploaded[3]).isNull();
      check(uploaded[4]).isNotNull().has((DateTime d) => d.toUtc(), 'utc').equals(fx.fixtureUploadInstant);
    });

    test('sentinel timestamps are written back unchanged', () async {
      final Uint8List bytes = fx.buildPaperbackArchive(<String, Map<String, dynamic>>{
        '__CHAPTER_V4': <String, dynamic>{
          'c1': fx.chapterJson('c1', sourceMangaId: 'sm-A', chapNum: 1, time: fx.appleDistantPastSeconds),
        },
      });
      final Archive archive = ZipDecoder().decodeBytes(await PaperbackBackup.fromData(bytes).toData());
      final chapters =
          jsonDecode(utf8.decode(archive.findFile('__CHAPTER_V4')!.content as List<int>)) as Map<String, dynamic>;
      check((chapters['c1'] as Map<String, dynamic>)['time'] as num).equals(fx.appleDistantPastSeconds);
    });
  });

  group('PaperbackBackup chapter identity and progress', () {
    test('carries chapter identity, partial progress and per-chapter read dates', () {
      final SourceMangaData entry = PaperbackBackup.fromData(fx.libraryLinkageArchive()).sourceMangaDataEntries.single;
      check(entry.sourceMangaKey).equals('remote-sm-A');

      final SourceChapter ch1 = entry.chapters.firstWhere((SourceChapter c) => c.chapterKey == 'remote-ch-A1');
      check(ch1.sourceId).equals('SourceAlpha');
      check(ch1.isRead).isTrue();
      check(ch1.dateRead).equals(fx.fixtureReadInstant);
      check(ch1.dateUploaded).equals(fx.fixtureUploadInstant);

      final SourceChapter ch2 = entry.chapters.firstWhere((SourceChapter c) => c.chapterKey == 'remote-ch-A2');
      check(ch2.isRead).isFalse();
      check(ch2.lastPageRead).equals(7);
      check(ch2.totalPages).equals(20);
      check(ch2.hasReadingState).isTrue();
    });

    test('secondary-source chapters are kept separately with provenance', () {
      final Uint8List bytes = fx.buildPaperbackArchive(<String, Map<String, dynamic>>{
        '__MANGA_INFO_V4': <String, dynamic>{
          'info-A': fx.mangaInfoJson('info-A', titles: <String>['A']),
        },
        '__SOURCE_MANGA_V4': <String, dynamic>{
          'sm-P': fx.sourceMangaJson('sm-P', mangaInfoId: 'info-A', sourceId: 'PrimarySrc'),
          'sm-S': fx.sourceMangaJson('sm-S', mangaInfoId: 'info-A', sourceId: 'SecondarySrc'),
        },
        '__CHAPTER_V4': <String, dynamic>{
          'p1': fx.chapterJson('p1', sourceMangaId: 'sm-P', chapNum: 1),
          's1': fx.chapterJson('s1', sourceMangaId: 'sm-S', chapNum: 1),
        },
        '__CHAPTER_PROGRESS_MARKER_V4-1': <String, dynamic>{
          'p1': fx.progressMarkerJson('p1', completed: true),
          's1': fx.progressMarkerJson('s1', completed: true),
        },
        '__LIBRARY_MANGA_V4': <String, dynamic>{
          'lib-1': fx.libraryMangaJson('lib-1', primarySourceId: 'sm-P', secondarySourceIds: <String>['sm-S']),
        },
      });

      final SourceMangaData entry = PaperbackBackup.fromData(bytes).sourceMangaDataEntries.single;
      check(entry.sourceId).equals('PrimarySrc');
      check(entry.chapters.map((SourceChapter c) => c.chapterKey).toList()).deepEquals(<String?>['remote-p1']);
      check(entry.secondarySourceChapters).length.equals(1);
      check(entry.secondarySourceChapters.single.sourceId).equals('SecondarySrc');
      check(entry.secondarySourceChapters.single.isRead).isTrue();
    });

    test('non-library manga info is retained separately', () {
      final backup = PaperbackBackup.fromData(fx.libraryLinkageArchive());
      final List<SourceMangaData> others = backup.nonLibrarySourceMangaDataEntries;
      check(others.map((SourceMangaData m) => m.details.title).toList()).deepEquals(<String>['Browsed Title B']);
      check(others.single.chapters).length.equals(1);
    });
  });
}
