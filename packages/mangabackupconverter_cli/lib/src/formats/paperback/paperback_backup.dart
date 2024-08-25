import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_chapter.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_chapter_progress_marker.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_library_manga.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_manga_info.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_source_manga.dart';

part 'paperback_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class PaperbackBackup with PaperbackBackupMappable {
  final List<PaperbackBackupChapterProgressMarker>? chapterProgressMarker;
  final List<PaperbackBackupChapter>? chapters;
  final List<PaperbackBackupLibraryManga>? libraryManga;
  final List<PaperbackBackupMangaInfo>? mangaInfo;
  final List<PaperbackBackupSourceManga>? sourceManga;
  final String? name;

  const PaperbackBackup({
    this.chapterProgressMarker,
    this.chapters,
    this.libraryManga,
    this.mangaInfo,
    this.sourceManga,
    this.name,
  });

  static PaperbackBackup? fromZip(Uint8List bytes, {String? name}) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final chapterProgressMarkersArchive =
        archive.findFile('__CHAPTER_PROGRESS_MARKER_V4-1');
    final chaptersArchive = archive.findFile('__CHAPTER_V4');
    final libraryMangaArchive = archive.findFile('__LIBRARY_MANGA_V4');
    final mangaInfoArchive = archive.findFile('__MANGA_INFO_V4');
    final sourceMangaArchive = archive.findFile('__SOURCE_MANGA_V4');
    final chapterProgressMarkersArchiveContent =
        chapterProgressMarkersArchive?.content;
    final chaptersArchiveContent = chaptersArchive?.content;
    final libraryMangaArchiveContent = libraryMangaArchive?.content;
    final mangaInfoArchiveContent = mangaInfoArchive?.content;
    final sourceMangaArchiveContent = sourceMangaArchive?.content;

    return PaperbackBackup(
      name: name,
      chapterProgressMarker: chapterProgressMarkersArchiveContent == null
          ? null
          : (jsonDecode(
              String.fromCharCodes(
                chapterProgressMarkersArchiveContent as Uint8List,
              ),
            ) as Map<String, dynamic>)
              .entries
              .map(
                (e) => PaperbackBackupChapterProgressMarker.fromMap(
                  e.value as Map<String, dynamic>,
                ),
              )
              .toList(),
      chapters: chaptersArchiveContent == null
          ? null
          : (jsonDecode(
              String.fromCharCodes(
                chaptersArchiveContent as Uint8List,
              ),
            ) as Map<String, dynamic>)
              .entries
              .map(
                (e) => PaperbackBackupChapter.fromMap(
                  e.value as Map<String, dynamic>,
                ),
              )
              .toList(),
      libraryManga: libraryMangaArchiveContent == null
          ? null
          : (jsonDecode(
              String.fromCharCodes(
                libraryMangaArchiveContent as Uint8List,
              ),
            ) as Map<String, dynamic>)
              .entries
              .map(
                (e) => PaperbackBackupLibraryManga.fromMap(
                  e.value as Map<String, dynamic>,
                ),
              )
              .toList(),
      mangaInfo: mangaInfoArchiveContent == null
          ? null
          : (jsonDecode(
              String.fromCharCodes(
                mangaInfoArchiveContent as Uint8List,
              ),
            ) as Map<String, dynamic>)
              .entries
              .map(
                (e) => PaperbackBackupMangaInfo.fromMap(
                  e.value as Map<String, dynamic>,
                ),
              )
              .toList(),
      sourceManga: sourceMangaArchiveContent == null
          ? null
          : (jsonDecode(
              String.fromCharCodes(
                sourceMangaArchiveContent as Uint8List,
              ),
            ) as Map<String, dynamic>)
              .entries
              .map(
                (e) => PaperbackBackupSourceManga.fromMap(
                  e.value as Map<String, dynamic>,
                ),
              )
              .toList(),
    );
  }

  Uint8List? toZip() {
    final archive = Archive();

    archive.addFile(
      ArchiveFile.string(
        '__CHAPTER_PROGRESS_MARKER_V4-1',
        jsonEncode(chapterProgressMarker),
      ),
    );
    archive.addFile(ArchiveFile.string('__CHAPTER_V4', jsonEncode(chapters)));
    archive.addFile(
      ArchiveFile.string('__LIBRARY_MANGA_V4', jsonEncode(libraryManga)),
    );
    archive
        .addFile(ArchiveFile.string('__MANGA_INFO_V4', jsonEncode(mangaInfo)));
    archive.addFile(
      ArchiveFile.string('__SOURCE_MANGA_V4', jsonEncode(sourceManga)),
    );
    final encodingResult = ZipEncoder().encode(archive);
    return encodingResult == null ? null : Uint8List.fromList(encodingResult);
  }

  static const fromMap = PaperbackBackupMapper.fromMap;
  static const fromJson = PaperbackBackupMapper.fromJson;
}
