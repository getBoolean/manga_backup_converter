import 'package:manga_backup_core/src/common/normalize_chapter_number.dart';
import 'package:manga_backup_core/src/conversion/manga_details.dart';

class SourceMangaData {
  const SourceMangaData({
    required this.details,
    this.sourceId,
    this.sourceMangaKey,
    this.categories = const <String>[],
    this.chapters = const <SourceChapter>[],
    this.secondarySourceChapters = const <SourceChapter>[],
    this.history = const <SourceHistoryEntry>[],
    this.tracking = const <SourceTrackingEntry>[],
    this.dateAdded,
    this.lastRead,
    this.lastOpened,
    this.lastUpdated,
    this.status,
  });

  final MangaSearchDetails details;
  final String? sourceId;

  /// The source's own identifier for this manga (e.g. Aidoku manga ID, Tachi
  /// manga URL, Paperback source-manga `mangaId`), when known.
  final String? sourceMangaKey;

  /// Ordered category / library-tab names.
  final List<String> categories;

  /// Chapters of the primary source ([sourceId]). Reconciliation against a
  /// destination uses these.
  final List<SourceChapter> chapters;

  /// Chapters (and their state) from other sources linked to the same library
  /// entry, e.g. Paperback secondary sources. Retained with provenance in
  /// [SourceChapter.sourceId]; not reconciled automatically.
  final List<SourceChapter> secondarySourceChapters;
  final List<SourceHistoryEntry> history;
  final List<SourceTrackingEntry> tracking;
  final DateTime? dateAdded;
  final DateTime? lastRead;
  final DateTime? lastOpened;
  final DateTime? lastUpdated;
  final int? status;
}

class SourceChapter {
  SourceChapter({
    required this.title,
    this.chapterKey,
    this.sourceId,
    double? chapterNumber,
    double? volumeNumber,
    this.scanlator,
    this.language,
    this.isRead = false,
    this.isBookmarked = false,
    this.lastPageRead = 0,
    this.totalPages,
    this.dateRead,
    this.dateUploaded,
    this.sourceOrder = 0,
  }) : chapterNumber = chapterNumber == null ? null : normalizeChapterNumber(chapterNumber),
       volumeNumber = volumeNumber == null ? null : normalizeChapterNumber(volumeNumber);

  final String title;

  /// The source's stable identifier for this chapter (chapter ID or URL).
  final String? chapterKey;

  /// The source this chapter belongs to, when it differs from (or must be
  /// distinguished from) the manga's primary source.
  final String? sourceId;

  /// Raw chapter number; negative values (e.g. `-1`) mean unknown.
  final double? chapterNumber;

  /// Raw volume number; `null`, zero and negative values mean unknown.
  final double? volumeNumber;
  final String? scanlator;
  final String? language;
  final bool isRead;
  final bool isBookmarked;
  final int lastPageRead;
  final int? totalPages;

  /// When this chapter was last read, when the source records it per chapter.
  final DateTime? dateRead;
  final DateTime? dateUploaded;
  final int sourceOrder;

  /// Whether this chapter carries reading state that a destination could
  /// receive.
  bool get hasReadingState => isRead || isBookmarked || lastPageRead > 0 || dateRead != null;
}

class SourceHistoryEntry {
  SourceHistoryEntry({
    required this.chapterTitle,
    this.chapterKey,
    double? chapterNumber,
    this.dateRead,
    this.completed = false,
    this.progress,
    this.total,
  }) : chapterNumber = chapterNumber == null ? null : normalizeChapterNumber(chapterNumber);

  /// Display title of the chapter. Never a destination identifier.
  final String chapterTitle;

  /// Links this entry to [SourceChapter.chapterKey] of the same manga.
  final String? chapterKey;
  final double? chapterNumber;
  final DateTime? dateRead;
  final bool completed;
  final int? progress;
  final int? total;
}

class SourceTrackingEntry {
  SourceTrackingEntry({
    required this.syncId,
    this.libraryId,
    this.mediaId,
    this.trackingUrl,
    this.title,
    double? lastChapterRead,
    this.totalChapters,
    this.score,
    this.status,
    this.startedReadingDate,
    this.finishedReadingDate,
  }) : lastChapterRead = lastChapterRead == null ? null : normalizeChapterNumber(lastChapterRead);

  final int syncId;
  final int? libraryId;
  final int? mediaId;
  final String? trackingUrl;
  final String? title;
  final double? lastChapterRead;
  final int? totalChapters;
  final double? score;
  final int? status;
  final DateTime? startedReadingDate;
  final DateTime? finishedReadingDate;
}

/// An input record a codec could read but not turn into [SourceMangaData]
/// (for example a Paperback library entry whose primary-source link does not
/// resolve). Reported as an unresolved manga, never dropped silently (KTD8).
class ExtractionLoss {
  const ExtractionLoss({required this.subject, required this.reason});

  /// Identifies the record (title, or the backup's own ID when no title is
  /// reachable).
  final String subject;
  final String reason;
}
