import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';

/// A runtime source identity as a destination runtime reports it.
SourceIdentity runtimeIdentity(String ecosystem, String sourceId, {String packageId = 'pkg'}) => SourceIdentity(
  ecosystem: ecosystem,
  packageId: packageId,
  sourceId: sourceId,
  artifact: const ArtifactBinding(sha256: 'abc', kind: 'test', version: '1'),
);

/// A confirmed, fetched destination for [manga] on [identity]: [chapters]
/// as the runtime returned them, under its native [mangaId].
MangaMatchConfirmation fetchedConfirmation(
  SourceMangaData manga,
  SourceIdentity identity, {
  required String mangaId,
  required List<NativeChapter> chapters,
  String title = 'Destination Title',
  String sourceName = 'Destination',
  List<String> tags = const <String>['Comedy'],
  List<String> artists = const <String>['Artist B'],
}) {
  final ref = NativeMangaRef(
    source: identity,
    mangaId: mangaId,
    settingsRevision: 'rev',
    // An ephemeral supervisor handle: never written to a backup.
    handle: const SessionHandle(generation: 7, value: 'handle-123'),
  );
  return MangaMatchConfirmation(
    sourceManga: manga,
    confirmedMatch: PluginSearchResult(ref: ref, title: title, pluginSourceName: sourceName),
  ).withDestination(
    FetchedManga(
      MangaSnapshot(
        ref: ref,
        metadata: MangaMetadata(
          title: title,
          authors: const <String>['Author A'],
          artists: artists,
          description: 'Desc',
          tags: tags,
          status: PublishingStatus.ongoing,
          coverUrl: 'https://img.invalid/cover.jpg',
        ),
        chapters: chapters,
      ),
    ),
  );
}

/// Source manga with: chapter 1 read, chapter 2 partially read (page 5 of
/// 20), chapter 3 bookmarked, plus categories, dates and a tracking record.
SourceMangaData statefulManga({String title = 'Onimai', String? sourceId = 'origin', String? language}) =>
    SourceMangaData(
      details: MangaSearchDetails(title: title),
      sourceId: sourceId,
      sourceMangaKey: 'origin-key',
      categories: const <String>['Reading', 'Favourites'],
      dateAdded: DateTime.utc(2024, 1, 2),
      lastRead: DateTime.utc(2024, 3, 4),
      chapters: <SourceChapter>[
        SourceChapter(
          title: 'One',
          chapterKey: 's1',
          chapterNumber: 1,
          language: language,
          isRead: true,
          dateRead: DateTime.utc(2024, 3),
        ),
        SourceChapter(
          title: 'Two',
          chapterKey: 's2',
          chapterNumber: 2,
          language: language,
          lastPageRead: 5,
          totalPages: 20,
          dateRead: DateTime.utc(2024, 3, 4),
        ),
        SourceChapter(title: 'Three', chapterKey: 's3', chapterNumber: 3, language: language, isBookmarked: true),
      ],
      tracking: <SourceTrackingEntry>[SourceTrackingEntry(syncId: 2, mediaId: 99, title: 'Onimai')],
    );

/// Destination chapters 1-4 with source-native IDs and web URLs.
List<NativeChapter> destinationChapters({String prefix = '/chapters/'}) => <NativeChapter>[
  for (var i = 4; i >= 1; i--)
    NativeChapter(
      chapterId: '$prefix$i',
      sourceOrder: 4 - i,
      chapterNumber: i.toDouble(),
      title: 'Chapter $i',
      scanlators: const <String>['Group A', 'Group B'],
      language: 'en',
      dateUploaded: DateTime.utc(2023, 1, i),
      url: 'https://site.invalid/read$prefix$i',
      context: <String, Object?>{'scanlator': 'Group A & Group B', 'chapter_number': i.toDouble()},
    ),
];
