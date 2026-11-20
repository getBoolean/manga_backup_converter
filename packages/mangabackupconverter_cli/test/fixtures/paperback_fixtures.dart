// Sanitized Paperback (.pas4) characterization fixtures.
//
// Hand-constructed from the defect descriptions in the source-runners plan's
// prior read-only audits (Apple-reference epoch, library linkage via primary
// source, UTF-8, partial progress, duplicate numbers), using anonymized IDs,
// titles and values. They are NOT derived from any private backup, and the
// archive contract they encode (timestamps as seconds since the Apple
// reference date, 2001-01-01T00:00:00Z — the default Swift `JSONEncoder` date
// strategy — and the sentinel values below) was not independently confirmed
// against a real archive when they were written.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Seconds between the Unix epoch and the Apple reference date.
const int appleReferenceOffsetSeconds = 978307200;

/// 2023-03-08T20:26:40Z expressed as Apple-reference seconds.
const int fixtureReadAppleSeconds = 700000000;
final DateTime fixtureReadInstant = DateTime.utc(2023, 3, 8, 20, 26, 40);

/// 2022-01-01T00:00:00Z expressed as Apple-reference seconds.
const int fixtureUploadAppleSeconds = 662688000;
final DateTime fixtureUploadInstant = DateTime.utc(2022);

/// Swift `Date.distantPast` as Apple-reference seconds.
const double appleDistantPastSeconds = -63114076800;

/// Swift `Date.distantFuture` as Apple-reference seconds.
const double appleDistantFutureSeconds = 63113904000;

/// Unix epoch (1970-01-01) as Apple-reference seconds — what a JavaScript
/// extension's `new Date(0)` becomes once Paperback stores it.
const int appleUnixEpochSeconds = -appleReferenceOffsetSeconds;

/// Builds a .pas4 ZIP from archive entry name → JSON object, encoding every
/// entry as UTF-8 (as Paperback does).
Uint8List buildPaperbackArchive(Map<String, Map<String, dynamic>> entries) {
  final archive = Archive();
  for (final MapEntry<String, Map<String, dynamic>> entry in entries.entries) {
    archive.addFile(ArchiveFile.string(entry.key, jsonEncode(entry.value)));
  }
  return ZipEncoder().encodeBytes(archive);
}

Map<String, dynamic> mangaInfoJson(String id, {required List<String> titles}) => <String, dynamic>{
  'id': id,
  'titles': titles,
  'covers': <String>[],
  'image': 'https://img.invalid/$id.jpg',
  'desc': 'Description $id',
  'author': 'Author $id',
  'artist': 'Artist $id',
  'hentai': false,
  'status': 'Ongoing',
  'tags': <Map<String, dynamic>>[],
  'additionalInfo': <String, dynamic>{},
};

Map<String, dynamic> sourceMangaJson(String id, {required String mangaInfoId, String sourceId = 'SourceAlpha'}) =>
    <String, dynamic>{
      'id': id,
      'sourceId': sourceId,
      'mangaId': 'remote-$id',
      'mangaInfo': <String, dynamic>{'type': '__MANGA_INFO_V4', 'id': mangaInfoId},
    };

Map<String, dynamic> chapterJson(
  String id, {
  required String sourceMangaId,
  required num chapNum,
  String name = '',
  num volume = 0,
  String langCode = 'en',
  String group = '',
  num time = fixtureUploadAppleSeconds,
  int sortingIndex = 0,
}) => <String, dynamic>{
  'id': id,
  'chapterId': 'remote-$id',
  'sourceManga': <String, dynamic>{'type': '__SOURCE_MANGA_V4', 'id': sourceMangaId},
  'chapNum': chapNum,
  'volume': volume,
  'langCode': langCode,
  'group': group,
  'name': name,
  'time': time,
  'sortingIndex': sortingIndex,
  'isNew': false,
};

Map<String, dynamic> progressMarkerJson(
  String chapterId, {
  required bool completed,
  int lastPage = 0,
  int totalPages = 20,
  num time = fixtureReadAppleSeconds,
  bool hidden = false,
}) => <String, dynamic>{
  'chapter': <String, dynamic>{'type': '__CHAPTER_V4', 'id': chapterId},
  'completed': completed,
  'lastPage': lastPage,
  'totalPages': totalPages,
  'time': time,
  'hidden': hidden,
};

Map<String, dynamic> libraryMangaJson(
  String id, {
  required String primarySourceId,
  List<String> secondarySourceIds = const <String>[],
  List<Map<String, dynamic>> tabs = const <Map<String, dynamic>>[],
  num? lastRead = fixtureReadAppleSeconds,
  num? dateBookmarked = fixtureUploadAppleSeconds,
}) => <String, dynamic>{
  'id': id,
  'primarySource': <String, dynamic>{'type': '__SOURCE_MANGA_V4', 'id': primarySourceId},
  'secondarySources': <Map<String, dynamic>>[
    for (final String s in secondarySourceIds) <String, dynamic>{'type': '__SOURCE_MANGA_V4', 'id': s},
  ],
  'trackedSources': <Map<String, dynamic>>[],
  'libraryTabs': tabs,
  'lastRead': lastRead,
  'dateBookmarked': dateBookmarked,
};

Map<String, dynamic> libraryTabJson(String id, {required String name, required int sortOrder}) => <String, dynamic>{
  'id': id,
  'name': name,
  'sortOrder': sortOrder,
};

/// A library whose library-manga IDs differ from the manga-info IDs; the only
/// link is `primarySource` → source manga → `mangaInfo`. It also contains a
/// manga-info entry that is not in the library (history/browse metadata), and
/// Unicode tab and chapter names.
Uint8List libraryLinkageArchive() => buildPaperbackArchive(<String, Map<String, dynamic>>{
  '__MANGA_INFO_V4': <String, dynamic>{
    'info-A': mangaInfoJson('info-A', titles: <String>['Library Title A']),
    'info-B': mangaInfoJson('info-B', titles: <String>['Browsed Title B']),
  },
  '__SOURCE_MANGA_V4': <String, dynamic>{
    'sm-A': sourceMangaJson('sm-A', mangaInfoId: 'info-A'),
    'sm-B': sourceMangaJson('sm-B', mangaInfoId: 'info-B'),
  },
  '__CHAPTER_V4': <String, dynamic>{
    'ch-A1': chapterJson('ch-A1', sourceMangaId: 'sm-A', chapNum: 1, name: 'Chapitre 1 — Été 日本語'),
    'ch-A2': chapterJson('ch-A2', sourceMangaId: 'sm-A', chapNum: 2, name: 'Chapter 2', sortingIndex: 1),
    'ch-B1': chapterJson('ch-B1', sourceMangaId: 'sm-B', chapNum: 1, name: 'Browsed 1'),
  },
  '__CHAPTER_PROGRESS_MARKER_V4-1': <String, dynamic>{
    'ch-A1': progressMarkerJson('ch-A1', completed: true, lastPage: 19),
    'ch-A2': progressMarkerJson('ch-A2', completed: false, lastPage: 7),
    'ch-B1': progressMarkerJson('ch-B1', completed: true, lastPage: 10),
  },
  '__LIBRARY_MANGA_V4': <String, dynamic>{
    'lib-uuid-1': libraryMangaJson(
      'lib-uuid-1',
      primarySourceId: 'sm-A',
      tabs: <Map<String, dynamic>>[
        libraryTabJson('tab-2', name: 'Zweite Ä', sortOrder: 2),
        libraryTabJson('tab-1', name: '読書中', sortOrder: 1),
      ],
    ),
  },
});
