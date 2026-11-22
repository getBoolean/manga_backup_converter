import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:source_runtime/src/contracts/cancellation.dart';
import 'package:source_runtime/src/contracts/identity.dart';
import 'package:source_runtime/src/contracts/outcome.dart';

/// Operations a source session may support. Capability discovery covers the
/// requested operation, not every method in the ecosystem.
enum SourceOperation { search, mangaDetails, chapterList, settings, browser }

/// What a source session can do on this host.
@immutable
final class SourceCapabilities {
  SourceCapabilities({
    required Set<SourceOperation> operations,
    Set<String> apiFamilies = const <String>{},
    this.requiresBrowser = false,
  }) : operations = Set<SourceOperation>.unmodifiable(operations),
       apiFamilies = Set<String>.unmodifiable(apiFamilies);

  factory SourceCapabilities.fromJson(Map<String, Object?> json) => SourceCapabilities(
    operations: <SourceOperation>{
      for (final Object? o in json['operations']! as List<Object?>) SourceOperation.values.byName(o! as String),
    },
    apiFamilies: <String>{
      for (final Object? f in json['apiFamilies'] as List<Object?>? ?? const <Object?>[]) f! as String,
    },
    requiresBrowser: json['requiresBrowser'] as bool? ?? false,
  );

  final Set<SourceOperation> operations;

  /// Host API families the source uses, for example `paperback-0.8`.
  final Set<String> apiFamilies;

  /// Whether the source needs a `BrowserPort`.
  final bool requiresBrowser;

  bool supports(SourceOperation operation) => operations.contains(operation);

  /// The typed failure for an unsupported [operation] (KTD15).
  CapabilityUnavailableFailure unavailable(SourceOperation operation) =>
      CapabilityUnavailableFailure(operation.name, 'Source does not support ${operation.name} on this host');

  Map<String, Object?> toJson() => <String, Object?>{
    'operations': <String>[for (final SourceOperation o in operations) o.name],
    'apiFamilies': apiFamilies.toList(),
    'requiresBrowser': requiresBrowser,
  };
}

/// Search input. [cursor] is the source's opaque pagination token from a
/// previous [SearchPage.nextCursor]; `null` requests the first page.
@immutable
final class SearchRequest {
  const SearchRequest({required this.query, this.cursor});

  factory SearchRequest.fromJson(Map<String, Object?> json) =>
      SearchRequest(query: json['query']! as String, cursor: json['cursor'] as String?);

  final String query;
  final String? cursor;

  Map<String, Object?> toJson() => <String, Object?>{'query': query, 'cursor': cursor};
}

/// One search result, carrying the durable reference to confirm it with.
@immutable
final class SearchHit {
  const SearchHit({required this.ref, required this.title, this.coverUrl, this.authors = const <String>[]});

  factory SearchHit.fromJson(Map<String, Object?> json, {SessionHandle? handle}) => SearchHit(
    ref: NativeMangaRef.fromJson(json['ref']! as Map<String, Object?>).withHandle(handle),
    title: json['title']! as String,
    coverUrl: json['coverUrl'] as String?,
    authors: _strings(json['authors']),
  );

  final NativeMangaRef ref;
  final String title;
  final String? coverUrl;
  final List<String> authors;

  Map<String, Object?> toJson() => <String, Object?>{
    'ref': ref.toJson(),
    'title': title,
    'coverUrl': coverUrl,
    'authors': authors,
  };
}

/// A page of search results. An empty [hits] list is a successful empty
/// result, not a failure.
@immutable
final class SearchPage {
  const SearchPage({required this.hits, this.nextCursor, this.warnings = const <String>[]});

  final List<SearchHit> hits;

  /// Opaque token for the next page; `null` when there is none.
  final String? nextCursor;

  /// Non-fatal host diagnostics produced while searching.
  final List<String> warnings;
}

enum PublishingStatus { unknown, ongoing, completed, cancelled, hiatus }

enum ContentRatingLevel { unknown, safe, suggestive, nsfw }

/// Manga metadata as fetched from the destination source.
@immutable
final class MangaMetadata {
  const MangaMetadata({
    required this.title,
    this.altTitles = const <String>[],
    this.authors = const <String>[],
    this.artists = const <String>[],
    this.description,
    this.tags = const <String>[],
    this.status = PublishingStatus.unknown,
    this.contentRating = ContentRatingLevel.unknown,
    this.url,
    this.coverUrl,
  });

  factory MangaMetadata.fromJson(Map<String, Object?> json) => MangaMetadata(
    title: json['title']! as String,
    altTitles: _strings(json['altTitles']),
    authors: _strings(json['authors']),
    artists: _strings(json['artists']),
    description: json['description'] as String?,
    tags: _strings(json['tags']),
    status: PublishingStatus.values.byName(json['status'] as String? ?? 'unknown'),
    contentRating: ContentRatingLevel.values.byName(json['contentRating'] as String? ?? 'unknown'),
    url: json['url'] as String?,
    coverUrl: json['coverUrl'] as String?,
  );

  final String title;
  final List<String> altTitles;
  final List<String> authors;
  final List<String> artists;
  final String? description;
  final List<String> tags;
  final PublishingStatus status;
  final ContentRatingLevel contentRating;
  final String? url;
  final String? coverUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'altTitles': altTitles,
    'authors': authors,
    'artists': artists,
    'description': description,
    'tags': tags,
    'status': status.name,
    'contentRating': contentRating.name,
    'url': url,
    'coverUrl': coverUrl,
  };
}

/// A chapter exactly as the source returned it. All scanlators are kept.
@immutable
final class NativeChapter {
  const NativeChapter({
    required this.chapterId,
    required this.sourceOrder,
    this.context = const <String, Object?>{},
    this.title,
    this.chapterNumber,
    this.volumeNumber,
    this.scanlators = const <String>[],
    this.language,
    this.dateUploaded,
    this.url,
  });

  factory NativeChapter.fromJson(Map<String, Object?> json) => NativeChapter(
    chapterId: json['chapterId']! as String,
    sourceOrder: json['sourceOrder']! as int,
    context: (json['context'] as Map<String, Object?>?) ?? const <String, Object?>{},
    title: json['title'] as String?,
    chapterNumber: (json['chapterNumber'] as num?)?.toDouble(),
    volumeNumber: (json['volumeNumber'] as num?)?.toDouble(),
    scanlators: _strings(json['scanlators']),
    language: json['language'] as String?,
    dateUploaded: json['dateUploaded'] == null ? null : DateTime.parse(json['dateUploaded']! as String),
    url: json['url'] as String?,
  );

  final String chapterId;

  /// Position in the source's own chapter ordering.
  final int sourceOrder;
  final Map<String, Object?> context;
  final String? title;
  final double? chapterNumber;
  final double? volumeNumber;
  final List<String> scanlators;
  final String? language;
  final DateTime? dateUploaded;
  final String? url;

  Map<String, Object?> toJson() => <String, Object?>{
    'chapterId': chapterId,
    'sourceOrder': sourceOrder,
    'context': context,
    'title': title,
    'chapterNumber': chapterNumber,
    'volumeNumber': volumeNumber,
    'scanlators': scanlators,
    'language': language,
    'dateUploaded': dateUploaded?.toUtc().toIso8601String(),
    'url': url,
  };
}

/// A complete, immutable fetch of one manga: metadata and its full chapter
/// list, bound to the reference it was fetched by. A failed or incomplete
/// fetch is a [SourceFailed] outcome, never an empty snapshot.
@immutable
final class MangaSnapshot {
  MangaSnapshot({required this.ref, required this.metadata, required List<NativeChapter> chapters})
    : chapters = List<NativeChapter>.unmodifiable(chapters);

  final NativeMangaRef ref;
  final MangaMetadata metadata;
  final List<NativeChapter> chapters;
}

/// Artifact bytes that passed integrity checks. [readVerified] re-checks the
/// digest so the bytes checked are the bytes executed.
abstract interface class VerifiedArtifact {
  ArtifactBinding get binding;

  /// Returns the artifact bytes after re-verifying their SHA-256, or throws
  /// if they no longer match [binding].
  Future<Uint8List> readVerified();
}

/// An ecosystem's source loader (Aidoku, Paperback, Tachi).
abstract interface class SourceProvider {
  /// Ecosystem name used in [SourceIdentity.ecosystem].
  String get ecosystem;

  /// Opens a verified package and enumerates its sources. A factory package
  /// may expose several source identities; Aidoku yields one.
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  });
}

/// An opened package and the sessions for the sources it hosts.
abstract interface class SourcePackage {
  String get packageId;

  List<SourceSession> get sessions;

  /// Closes every session and releases the package.
  Future<void> close();
}

/// A logical session with one running source (KTD12). Calls to one package
/// are serialised; every operation returns a typed outcome.
abstract interface class SourceSession {
  SourceIdentity get identity;

  String get displayName;

  SourceCapabilities get capabilities;

  /// Revision of the settings snapshot the session runs with.
  String get settingsRevision;

  Future<SourceOutcome<SearchPage>> search(SearchRequest request, {CancellationToken? cancel});

  /// Fetches metadata and the complete chapter list for [ref]. A reference
  /// bound to another source, artifact or settings revision fails with
  /// [StaleReferenceFailure].
  Future<SourceOutcome<MangaSnapshot>> fetchManga(NativeMangaRef ref, {CancellationToken? cancel});

  Future<void> close();
}

/// Checks that [ref] belongs to [session]'s current source and settings.
StaleReferenceFailure? staleReferenceFor(SourceSession session, NativeMangaRef ref) {
  if (ref.source != session.identity) {
    return StaleReferenceFailure('Reference is bound to ${ref.source}, session is ${session.identity}');
  }
  if (ref.settingsRevision != session.settingsRevision) {
    return const StaleReferenceFailure('Reference was confirmed under a different settings revision');
  }
  return null;
}

List<String> _strings(Object? json) =>
    json == null ? const <String>[] : <String>[for (final Object? s in json as List<Object?>) s! as String];
