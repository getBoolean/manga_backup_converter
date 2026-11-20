// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/convertable.dart';
import 'package:mangabackupconverter_cli/src/common/paperback_date_time_mapper.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_chapter.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_chapter_progress_marker.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_item_reference.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_library_manga.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_library_tab.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_manga_info.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup_source_manga.dart';
import 'package:mangabackupconverter_cli/src/pipeline/source_manga_data.dart';

part 'paperback_backup.mapper.dart';

/// Decodes one archive entry. Paperback writes UTF-8 JSON; decoding bytes as
/// Latin-1 code units (the previous behaviour) corrupts every non-ASCII title,
/// tab and chapter name.
Map<String, dynamic> _decodeArchiveJson(Uint8List bytes) {
  String text = utf8.decode(bytes);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return jsonDecode(text) as Map<String, dynamic>;
}

Map<String, dynamic> _toIdMap<T>(List<T>? items, String Function(T) idOf) {
  if (items == null) return const <String, dynamic>{};
  return <String, dynamic>{
    for (final T item in items) idOf(item): (item as dynamic).toMap(),
  };
}

@MappableClass(includeCustomMappers: <MapperBase<Object>>[SecondsEpochDateTimeMapper()])
class PaperbackBackup with PaperbackBackupMappable implements ConvertableBackup {
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

  factory PaperbackBackup.fromData(Uint8List bytes, {String? name}) {
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final ArchiveFile? chapterProgressMarkersArchive = archive.findFile('__CHAPTER_PROGRESS_MARKER_V4-1');
    final ArchiveFile? chaptersArchive = archive.findFile('__CHAPTER_V4');
    final ArchiveFile? libraryMangaArchive = archive.findFile('__LIBRARY_MANGA_V4');
    final ArchiveFile? mangaInfoArchive = archive.findFile('__MANGA_INFO_V4');
    final ArchiveFile? sourceMangaArchive = archive.findFile('__SOURCE_MANGA_V4');
    final Uint8List? chapterProgressMarkersArchiveContent = chapterProgressMarkersArchive?.content;
    final Uint8List? chaptersArchiveContent = chaptersArchive?.content;
    final Uint8List? libraryMangaArchiveContent = libraryMangaArchive?.content;
    final Uint8List? mangaInfoArchiveContent = mangaInfoArchive?.content;
    final Uint8List? sourceMangaArchiveContent = sourceMangaArchive?.content;

    return PaperbackBackup(
      name: name,
      chapterProgressMarker: chapterProgressMarkersArchiveContent == null
          ? null
          : _decodeArchiveJson(chapterProgressMarkersArchiveContent).entries
                .map(
                  (MapEntry<String, dynamic> e) =>
                      PaperbackBackupChapterProgressMarker.fromMap(e.value as Map<String, dynamic>),
                )
                .toList(),
      chapters: chaptersArchiveContent == null
          ? null
          : _decodeArchiveJson(chaptersArchiveContent).entries
                .map((MapEntry<String, dynamic> e) => PaperbackBackupChapter.fromMap(e.value as Map<String, dynamic>))
                .toList(),
      libraryManga: libraryMangaArchiveContent == null
          ? null
          : _decodeArchiveJson(libraryMangaArchiveContent).entries
                .map(
                  (MapEntry<String, dynamic> e) => PaperbackBackupLibraryManga.fromMap(e.value as Map<String, dynamic>),
                )
                .toList(),
      mangaInfo: mangaInfoArchiveContent == null
          ? null
          : _decodeArchiveJson(mangaInfoArchiveContent).entries
                .map((MapEntry<String, dynamic> e) => PaperbackBackupMangaInfo.fromMap(e.value as Map<String, dynamic>))
                .toList(),
      sourceManga: sourceMangaArchiveContent == null
          ? null
          : _decodeArchiveJson(sourceMangaArchiveContent).entries
                .map(
                  (MapEntry<String, dynamic> e) => PaperbackBackupSourceManga.fromMap(e.value as Map<String, dynamic>),
                )
                .toList(),
    );
  }

  static const PaperbackBackup Function(Map<String, dynamic> map) fromMap = PaperbackBackupMapper.fromMap;
  static const PaperbackBackup Function(String json) fromJson = PaperbackBackupMapper.fromJson;

  @override
  List<PaperbackBackupMangaInfo> get mangaSearchEntries => mangaInfo ?? const <PaperbackBackupMangaInfo>[];

  /// Library manga only: each library entry is linked to its manga info
  /// through `primarySource` → source manga → `mangaInfo` (library and
  /// manga-info IDs are not guaranteed to match). Manga that only appear in
  /// history/browse metadata are available from
  /// [nonLibrarySourceMangaDataEntries].
  @override
  List<SourceMangaData> get sourceMangaDataEntries {
    final index = _PaperbackIndex(this);
    final entries = <SourceMangaData>[];
    for (final PaperbackBackupLibraryManga lib in libraryManga ?? const <PaperbackBackupLibraryManga>[]) {
      final _LibraryLink? link = index.resolveLibrary(lib);
      if (link == null) continue;
      final tabs = <PaperbackBackupLibraryTab>[...lib.libraryTabs]
        ..sort((PaperbackBackupLibraryTab a, PaperbackBackupLibraryTab b) => a.sortOrder.compareTo(b.sortOrder));
      entries.add(
        index.toSourceMangaData(
          link.info,
          primary: link.primary,
          secondary: link.secondary,
          categories: tabs.map((PaperbackBackupLibraryTab t) => t.name).toList(),
          dateAdded: PaperbackDateCodec.meaningful(lib.dateBookmarked),
          lastRead: PaperbackDateCodec.meaningful(lib.lastRead),
        ),
      );
    }
    return entries;
  }

  /// Manga info that no library entry references (history/browse metadata),
  /// kept separately so it is never selected for migration by default.
  List<SourceMangaData> get nonLibrarySourceMangaDataEntries {
    final index = _PaperbackIndex(this);
    final libraryInfoIds = <String>{
      for (final PaperbackBackupLibraryManga lib in libraryManga ?? const <PaperbackBackupLibraryManga>[])
        ?index.resolveLibrary(lib)?.info.id,
    };
    return <SourceMangaData>[
      for (final PaperbackBackupMangaInfo info in mangaInfo ?? const <PaperbackBackupMangaInfo>[])
        if (!libraryInfoIds.contains(info.id))
          index.toSourceMangaData(
            info,
            primary: index.sourcesByInfoId[info.id]?.firstOrNull,
            secondary: index.sourcesByInfoId[info.id]?.skip(1).toList() ?? const <PaperbackBackupSourceManga>[],
          ),
    ];
  }

  @override
  Future<Uint8List> toData() async {
    final archive = Archive();

    archive.addFile(
      ArchiveFile.string(
        '__CHAPTER_PROGRESS_MARKER_V4-1',
        jsonEncode(_toIdMap(chapterProgressMarker, (PaperbackBackupChapterProgressMarker pm) => pm.chapter.id)),
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        '__CHAPTER_V4',
        jsonEncode(_toIdMap(chapters, (PaperbackBackupChapter c) => c.id)),
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        '__LIBRARY_MANGA_V4',
        jsonEncode(_toIdMap(libraryManga, (PaperbackBackupLibraryManga l) => l.id)),
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        '__MANGA_INFO_V4',
        jsonEncode(_toIdMap(mangaInfo, (PaperbackBackupMangaInfo m) => m.id)),
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        '__SOURCE_MANGA_V4',
        jsonEncode(_toIdMap(sourceManga, (PaperbackBackupSourceManga sm) => sm.id)),
      ),
    );
    return ZipEncoder().encodeBytes(archive);
  }

  @override
  void verbosePrint(bool verbose) {
    if (!verbose) return;
    print('Manga Info: ${mangaInfo?.length}');
    print('Library Manga: ${libraryManga?.length}');
    print('Chapters: ${chapters?.length}');
    print('Chapter Progress Marker: ${chapterProgressMarker?.length}');
    print('Source Manga: ${sourceManga?.length}');
    final List<PaperbackBackupLibraryManga>? trackedManga = libraryManga
        ?.where((PaperbackBackupLibraryManga i) => i.trackedSources.isNotEmpty)
        .toList();
    print('Tracked Manga: ${trackedManga?.length}');
    final List<PaperbackBackupLibraryManga>? mangaWithSecondarySources = libraryManga
        ?.where((PaperbackBackupLibraryManga i) => i.secondarySources.isNotEmpty)
        .toList();
    print('Manga with Secondary Sources: ${mangaWithSecondarySources?.length}');
    final List<PaperbackBackupMangaInfo>? mangaTagsWithTags = mangaInfo
        ?.where(
          (PaperbackBackupMangaInfo i) => i.tags.where((PaperbackBackupMangaTag e) => e.tags.isNotEmpty).isNotEmpty,
        )
        .toList();
    print('Manga with Tags: ${mangaTagsWithTags?.length}');
  }
}

class _LibraryLink {
  const _LibraryLink(this.info, this.primary, this.secondary);

  final PaperbackBackupMangaInfo info;
  final PaperbackBackupSourceManga? primary;
  final List<PaperbackBackupSourceManga> secondary;
}

/// ID lookups over one [PaperbackBackup].
class _PaperbackIndex {
  _PaperbackIndex(PaperbackBackup backup)
    : infoById = <String, PaperbackBackupMangaInfo>{
        for (final PaperbackBackupMangaInfo i in backup.mangaInfo ?? const <PaperbackBackupMangaInfo>[]) i.id: i,
      },
      sourceById = <String, PaperbackBackupSourceManga>{
        for (final PaperbackBackupSourceManga s in backup.sourceManga ?? const <PaperbackBackupSourceManga>[]) s.id: s,
      },
      markerByChapterId = <String, PaperbackBackupChapterProgressMarker>{
        for (final PaperbackBackupChapterProgressMarker m
            in backup.chapterProgressMarker ?? const <PaperbackBackupChapterProgressMarker>[])
          m.chapter.id: m,
      } {
    for (final PaperbackBackupSourceManga s in backup.sourceManga ?? const <PaperbackBackupSourceManga>[]) {
      (sourcesByInfoId[s.mangaInfo.id] ??= <PaperbackBackupSourceManga>[]).add(s);
    }
    for (final PaperbackBackupChapter c in backup.chapters ?? const <PaperbackBackupChapter>[]) {
      (chaptersBySourceId[c.sourceManga.id] ??= <PaperbackBackupChapter>[]).add(c);
    }
  }

  final Map<String, PaperbackBackupMangaInfo> infoById;
  final Map<String, PaperbackBackupSourceManga> sourceById;
  final Map<String, List<PaperbackBackupSourceManga>> sourcesByInfoId = <String, List<PaperbackBackupSourceManga>>{};
  final Map<String, List<PaperbackBackupChapter>> chaptersBySourceId = <String, List<PaperbackBackupChapter>>{};
  final Map<String, PaperbackBackupChapterProgressMarker> markerByChapterId;

  /// Follows `primarySource` → source manga → manga info. Falls back to a
  /// manga info whose ID equals the library ID only when the primary source
  /// reference is dangling.
  _LibraryLink? resolveLibrary(PaperbackBackupLibraryManga lib) {
    final PaperbackBackupSourceManga? primary = sourceById[lib.primarySource.id];
    final PaperbackBackupMangaInfo? info = primary != null ? infoById[primary.mangaInfo.id] : infoById[lib.id];
    if (info == null) return null;
    final secondary = <PaperbackBackupSourceManga>[
      for (final PaperbackBackupItemReference ref in lib.secondarySources)
        if (ref.id != primary?.id) ?sourceById[ref.id],
    ];
    return _LibraryLink(info, primary ?? sourcesByInfoId[info.id]?.firstOrNull, secondary);
  }

  SourceMangaData toSourceMangaData(
    PaperbackBackupMangaInfo info, {
    required PaperbackBackupSourceManga? primary,
    required List<PaperbackBackupSourceManga> secondary,
    List<String> categories = const <String>[],
    DateTime? dateAdded,
    DateTime? lastRead,
  }) {
    return SourceMangaData(
      details: info.toMangaSearchDetails(),
      sourceId: primary?.sourceId,
      sourceMangaKey: primary?.mangaId,
      categories: categories,
      chapters: primary == null ? const <SourceChapter>[] : _chaptersOf(primary),
      secondarySourceChapters: <SourceChapter>[
        for (final PaperbackBackupSourceManga s in secondary) ..._chaptersOf(s),
      ],
      dateAdded: dateAdded,
      lastRead: lastRead,
    );
  }

  List<SourceChapter> _chaptersOf(PaperbackBackupSourceManga source) {
    return <SourceChapter>[
      for (final PaperbackBackupChapter c in chaptersBySourceId[source.id] ?? const <PaperbackBackupChapter>[])
        _toSourceChapter(c, source, markerByChapterId[c.id]),
    ];
  }

  SourceChapter _toSourceChapter(
    PaperbackBackupChapter c,
    PaperbackBackupSourceManga source,
    PaperbackBackupChapterProgressMarker? marker,
  ) {
    return SourceChapter(
      title: c.name,
      chapterKey: c.chapterId,
      sourceId: source.sourceId,
      chapterNumber: c.chapNum.toDouble(),
      volumeNumber: c.volume.toDouble(),
      scanlator: c.group.isEmpty ? null : c.group,
      language: c.langCode.isEmpty ? null : c.langCode,
      isRead: marker?.completed ?? false,
      lastPageRead: marker?.lastPage ?? 0,
      totalPages: marker == null || marker.totalPages <= 0 ? null : marker.totalPages,
      dateRead: marker == null ? null : PaperbackDateCodec.meaningful(marker.time),
      dateUploaded: PaperbackDateCodec.meaningful(c.time),
      sourceOrder: c.sortingIndex,
    );
  }
}
