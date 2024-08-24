import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';

part 'paperback_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class PaperbackBackup with PaperbackBackupMappable {
  final Map<String, dynamic>? chapterProgressMarker;
  final Map<String, dynamic>? chapters;
  final Map<String, dynamic>? libraryManga;
  final Map<String, dynamic>? mangaInfo;
  final Map<String, dynamic>? sourceManga;

  const PaperbackBackup({
    this.chapterProgressMarker,
    this.chapters,
    this.libraryManga,
    this.mangaInfo,
    this.sourceManga,
  });

  static PaperbackBackup? fromZip(Uint8List bytes) {
    // TODO: Read json files from zip file
    final archive = ZipDecoder().decodeBytes(bytes);
    final chapterProgressMarkersArchive =
        archive.findFile('__CHAPTER_PROGRESS_MARKER_V4-1');
    final chaptersArchive = archive.findFile('__CHAPTER_V4');
    final libraryMangaArchive = archive.findFile('__LIBRARY_MANGA_V4');
    final mangaInfoArchive = archive.findFile('__MANGA_INFO_V4');
    final sourceMangaArchive = archive.findFile('__SOURCE_MANGA_V4');
    return PaperbackBackup(
      chapterProgressMarker: chapterProgressMarkersArchive?.content == null
          ? null
          : jsonDecode(String.fromCharCodes(
              chapterProgressMarkersArchive!.content as Uint8List,
            )),
      chapters: chaptersArchive?.content == null
          ? null
          : jsonDecode(String.fromCharCodes(
              chaptersArchive!.content as Uint8List,
            )),
      libraryManga: libraryMangaArchive?.content == null
          ? null
          : jsonDecode(String.fromCharCodes(
              libraryMangaArchive!.content as Uint8List,
            )),
      mangaInfo: mangaInfoArchive?.content == null
          ? null
          : jsonDecode(String.fromCharCodes(
              mangaInfoArchive!.content as Uint8List,
            )),
      sourceManga: sourceMangaArchive?.content == null
          ? null
          : jsonDecode(String.fromCharCodes(
              sourceMangaArchive!.content as Uint8List,
            )),
    );
  }

  Uint8List? toZip() {
    final archive = Archive();

    archive.addFile(ArchiveFile.string(
        '__CHAPTER_PROGRESS_MARKER_V4-1', jsonEncode(chapterProgressMarker)));
    archive.addFile(ArchiveFile.string('__CHAPTER_V4', jsonEncode(chapters)));
    archive.addFile(
        ArchiveFile.string('__LIBRARY_MANGA_V4', jsonEncode(libraryManga)));
    archive
        .addFile(ArchiveFile.string('__MANGA_INFO_V4', jsonEncode(mangaInfo)));
    archive.addFile(
        ArchiveFile.string('__SOURCE_MANGA_V4', jsonEncode(sourceManga)));
    final encodingResult = ZipEncoder().encode(archive);
    return encodingResult == null ? null : Uint8List.fromList(encodingResult);
  }

  static final fromMap = PaperbackBackupMapper.fromMap;
  static final fromJson = PaperbackBackupMapper.fromJson;
}
