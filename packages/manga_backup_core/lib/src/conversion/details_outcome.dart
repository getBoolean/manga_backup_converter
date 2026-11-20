import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:source_runtime/source_contracts.dart';

/// A confirmed destination snapshot (`DestinationSnapshot` in the plan): the
/// fetched metadata and complete, immutable chapter list bound to the native
/// reference it was fetched by.
final class FetchedManga {
  FetchedManga(this.snapshot)
    : details = pluginDetailsFromMetadata(snapshot.ref.mangaId, snapshot.metadata),
      chapters = List<PluginChapter>.unmodifiable(snapshot.chapters.map(PluginChapter.fromNative));

  final MangaSnapshot snapshot;
  final PluginMangaDetails details;
  final List<PluginChapter> chapters;

  NativeMangaRef get ref => snapshot.ref;

  /// Durable, secret-free form (the ephemeral handle is omitted).
  Map<String, Object?> toJson() => <String, Object?>{
    'ref': snapshot.ref.toJson(),
    'metadata': snapshot.metadata.toJson(),
    'chapters': <Map<String, Object?>>[for (final NativeChapter c in snapshot.chapters) c.toJson()],
  };

  factory FetchedManga.fromJson(Map<String, Object?> json) => FetchedManga(
    MangaSnapshot(
      ref: NativeMangaRef.fromJson(json['ref']! as Map<String, Object?>),
      metadata: MangaMetadata.fromJson(json['metadata']! as Map<String, Object?>),
      chapters: <NativeChapter>[
        for (final Object? c in json['chapters']! as List<Object?>) NativeChapter.fromJson(c! as Map<String, Object?>),
      ],
    ),
  );
}

/// Outcome of fetching a selected manga's details and chapters (U1 step 6).
///
/// A successful fetch with no chapters ([DetailsEmpty]) is distinct from a
/// failed one ([DetailsFailed]); a failure never masquerades as an empty
/// complete chapter list.
sealed class DetailsOutcome {
  const DetailsOutcome();

  /// Translates a source session outcome.
  factory DetailsOutcome.fromSnapshot(SourceOutcome<MangaSnapshot> outcome) => switch (outcome) {
    SourceSuccess<MangaSnapshot>(:final MangaSnapshot value) =>
      value.chapters.isEmpty ? DetailsEmpty(FetchedManga(value)) : DetailsFetched(FetchedManga(value)),
    SourceFailed<MangaSnapshot>(:final SourceFailure failure) => DetailsFailed(failure),
  };

  /// The fetched manga for a success (empty or not), else `null`.
  FetchedManga? get fetchedOrNull => switch (this) {
    DetailsFetched(:final FetchedManga manga) || DetailsEmpty(:final FetchedManga manga) => manga,
    DetailsFailed() => null,
  };
}

/// Details and a non-empty chapter list.
final class DetailsFetched extends DetailsOutcome {
  const DetailsFetched(this.manga);
  final FetchedManga manga;
}

/// Details fetched successfully; the source lists no chapters.
final class DetailsEmpty extends DetailsOutcome {
  const DetailsEmpty(this.manga);
  final FetchedManga manga;
}

/// The fetch failed; [failure] says why.
final class DetailsFailed extends DetailsOutcome {
  const DetailsFailed(this.failure);
  final SourceFailure failure;
}
