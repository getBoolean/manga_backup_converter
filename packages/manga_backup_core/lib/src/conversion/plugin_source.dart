import 'package:manga_backup_core/src/common/normalize_chapter_number.dart';
import 'package:manga_backup_core/src/conversion/chapter_data.dart';
import 'package:manga_backup_core/src/conversion/details_outcome.dart';
import 'package:source_runtime/source_contracts.dart';

/// A loaded source as the migration pipeline sees it. Implemented over the
/// backend-neutral `SourceSession` by `SessionPluginSource` (KTD15).
abstract interface class PluginSource {
  /// Runtime source ID ([SourceIdentity.sourceId]).
  String get sourceId;
  String get sourceName;

  /// The verified identity the source runs as.
  SourceIdentity get identity;

  /// Secret-free revision of the settings the source runs with.
  String get settingsRevision;

  /// Searches; failures are typed, never thrown.
  Future<SourceOutcome<PluginSearchPageResult>> search(String query, int page);

  /// Fetches metadata and the complete chapter list for [ref].
  Future<DetailsOutcome> fetchDetails(NativeMangaRef ref);

  /// Closes the source; awaited by the conversion owner.
  Future<void> dispose();
}

/// One search hit. Carries the source's durable [NativeMangaRef] (KTD3) —
/// never only a handle-like key string.
class PluginSearchResult {
  const PluginSearchResult({
    required this.ref,
    required this.title,
    this.pluginSourceName,
    this.coverUrl,
    this.authors = const <String>[],
    this.details,
    this.chapters = const <PluginChapter>[],
    this.fetched,
  });

  final NativeMangaRef ref;
  final String? pluginSourceName;
  final String title;
  final String? coverUrl;
  final List<String> authors;
  final PluginMangaDetails? details;
  final List<PluginChapter> chapters;

  /// The destination snapshot [details] and [chapters] came from, when this
  /// result was enriched; views reuse it instead of fetching again.
  final FetchedManga? fetched;

  /// The enriched snapshot as a [DetailsOutcome], or `null` when not fetched.
  DetailsOutcome? get fetchedOutcome {
    final FetchedManga? f = fetched;
    if (f == null) return null;
    return f.chapters.isEmpty ? DetailsEmpty(f) : DetailsFetched(f);
  }

  /// Runtime source ID of [ref].
  String get pluginSourceId => ref.source.sourceId;

  /// Source-native manga ID of [ref].
  String get mangaKey => ref.mangaId;

  /// A copy carrying fetched details (search fields are kept; detail-level
  /// authors win when present).
  PluginSearchResult enrichedWith(FetchedManga fetched) => PluginSearchResult(
    ref: ref,
    pluginSourceName: pluginSourceName,
    title: title,
    coverUrl: coverUrl,
    authors: fetched.details.authors.isNotEmpty ? fetched.details.authors : authors,
    details: fetched.details,
    chapters: fetched.chapters,
    fetched: fetched,
  );
}

class PluginSearchPageResult {
  const PluginSearchPageResult({
    required this.results,
    required this.hasNextPage,
    this.warnings = const <String>[],
  });

  final List<PluginSearchResult> results;
  final bool hasNextPage;
  final List<String> warnings;
}

enum MangaPublishingStatus { unknown, ongoing, completed, cancelled, hiatus }

enum MangaContentRating { safe, suggestive, nsfw }

class PluginMangaDetails {
  const PluginMangaDetails({
    required this.key,
    required this.title,
    this.coverUrl,
    this.authors = const <String>[],
    this.artists = const <String>[],
    this.description,
    this.tags = const <String>[],
    this.status = MangaPublishingStatus.unknown,
    this.contentRating = MangaContentRating.safe,
    this.url,
  });

  final String key;
  final String title;
  final String? coverUrl;
  final List<String> authors;
  final List<String> artists;
  final String? description;
  final List<String> tags;
  final MangaPublishingStatus status;
  final MangaContentRating contentRating;
  final String? url;
}

/// Maps contract metadata to [PluginMangaDetails].
PluginMangaDetails pluginDetailsFromMetadata(String key, MangaMetadata m) => PluginMangaDetails(
  key: key,
  title: m.title,
  coverUrl: m.coverUrl,
  authors: m.authors,
  artists: m.artists,
  description: m.description,
  tags: m.tags,
  status: switch (m.status) {
    PublishingStatus.unknown => MangaPublishingStatus.unknown,
    PublishingStatus.ongoing => MangaPublishingStatus.ongoing,
    PublishingStatus.completed => MangaPublishingStatus.completed,
    PublishingStatus.cancelled => MangaPublishingStatus.cancelled,
    PublishingStatus.hiatus => MangaPublishingStatus.hiatus,
  },
  contentRating: switch (m.contentRating) {
    ContentRatingLevel.safe || ContentRatingLevel.unknown => MangaContentRating.safe,
    ContentRatingLevel.suggestive => MangaContentRating.suggestive,
    ContentRatingLevel.nsfw => MangaContentRating.nsfw,
  },
  url: m.url,
);

/// A destination chapter. Keeps every scanlator the source reported
/// ([scanlators]); [scanlator] joins them for single-field formats.
class PluginChapter implements ChapterData {
  PluginChapter({
    required this.chapterId,
    this.title,
    double? chapterNumber,
    double? volumeNumber,
    String? scanlator,
    List<String>? scanlators,
    this.language,
    this.dateUploaded,
    this.url,
    this.sourceOrder = 0,
  }) : chapterNumber = chapterNumber == null ? null : normalizeChapterNumber(chapterNumber),
       volumeNumber = volumeNumber == null ? null : normalizeChapterNumber(volumeNumber),
       scanlators = List<String>.unmodifiable(
         scanlators ?? (scanlator == null || scanlator.isEmpty ? const <String>[] : <String>[scanlator]),
       );

  /// Maps a contract chapter, keeping all of its scanlators.
  factory PluginChapter.fromNative(NativeChapter c) => PluginChapter(
    chapterId: c.chapterId,
    title: c.title,
    chapterNumber: c.chapterNumber,
    volumeNumber: c.volumeNumber,
    scanlators: c.scanlators.where((String s) => s.trim().isNotEmpty).toList(),
    language: c.language,
    dateUploaded: c.dateUploaded,
    url: c.url,
    sourceOrder: c.sourceOrder,
  );

  @override
  final String chapterId;

  @override
  final String? title;

  @override
  final double? chapterNumber;

  @override
  final double? volumeNumber;

  /// Every scanlator group, in source order.
  final List<String> scanlators;

  /// All [scanlators] joined with `, `, or `null` when there are none.
  @override
  String? get scanlator => scanlators.isEmpty ? null : scanlators.join(', ');

  @override
  final String? language;

  @override
  final DateTime? dateUploaded;

  @override
  final String? url;

  @override
  final int sourceOrder;
}
