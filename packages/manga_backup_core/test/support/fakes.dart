import 'dart:async';
import 'dart:typed_data';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';

import 'test_refs.dart';

/// An input backup with fixed normalized entries.
class FakeBackup implements ConvertableBackup {
  FakeBackup(this.entries, {this.losses = const <ExtractionLoss>[]});

  final List<SourceMangaData> entries;
  final List<ExtractionLoss> losses;

  @override
  List<SourceMangaData> get sourceMangaDataEntries => entries;

  @override
  List<ExtractionLoss> get extractionLosses => losses;

  @override
  List<MangaSearchEntry> get mangaSearchEntries => const <MangaSearchEntry>[];

  @override
  List<String> get diagnostics => const <String>[];

  @override
  Future<Uint8List> toData() async => Uint8List(0);
}

/// A destination manga a fake source knows.
class FakeManga {
  FakeManga(
    this.key,
    this.title, {
    this.chapters = const <NativeChapter>[],
    this.failure,
    this.coverUrl,
    this.authors = const <String>[],
  });

  final String key;
  final String title;

  /// Search-level fields (details carry only the title).
  final String? coverUrl;
  final List<String> authors;
  final List<NativeChapter> chapters;

  /// When set, fetching details fails with it.
  final SourceFailure? failure;
}

/// A fake loaded source with a fixed identity and settings snapshot.
class FakePluginSource implements PluginSource {
  FakePluginSource(
    this.sourceId, {
    SettingsSnapshot? settings,
    this.manga = const <FakeManga>[],
    this.searchFailure,
    String digest = 'digest',
    this.language,
  }) : settings = settings ?? SettingsSnapshot(),
       identity = testIdentity(sourceId, digest: digest);

  @override
  final String sourceId;

  @override
  final String? language;

  @override
  final SourceIdentity identity;

  final SettingsSnapshot settings;
  final List<FakeManga> manga;

  /// When set, every search fails with it.
  final SourceFailure? searchFailure;

  int fetches = 0;
  int disposed = 0;

  @override
  String get sourceName => 'Fake $sourceId';

  @override
  String get settingsRevision => settings.revision;

  NativeMangaRef refFor(String key) =>
      NativeMangaRef(source: identity, mangaId: key, settingsRevision: settingsRevision);

  @override
  Future<SourceOutcome<PluginSearchPageResult>> search(String query, int page) async {
    final SourceFailure? failure = searchFailure;
    if (failure != null) return SourceFailed<PluginSearchPageResult>(failure);
    return SourceSuccess<PluginSearchPageResult>(
      PluginSearchPageResult(
        hasNextPage: false,
        results: <PluginSearchResult>[
          for (final FakeManga m in manga)
            if (m.title.toLowerCase() == query.toLowerCase())
              PluginSearchResult(
                ref: refFor(m.key),
                title: m.title,
                pluginSourceName: sourceName,
                coverUrl: m.coverUrl,
                authors: m.authors,
              ),
        ],
      ),
    );
  }

  @override
  Future<DetailsOutcome> fetchDetails(NativeMangaRef ref) async {
    fetches++;
    final FakeManga? m = manga.where((FakeManga x) => x.key == ref.mangaId).firstOrNull;
    if (m == null) return const DetailsFailed(SourceErrorFailure('unknown manga'));
    final SourceFailure? failure = m.failure;
    if (failure != null) return DetailsFailed(failure);
    return DetailsOutcome.fromSnapshot(
      SourceSuccess<MangaSnapshot>(
        MangaSnapshot(
          ref: ref,
          metadata: MangaMetadata(title: m.title),
          chapters: m.chapters,
        ),
      ),
    );
  }

  @override
  Future<void> dispose() async => disposed++;
}

/// A loader that offers [extensions] and loads [sources] (or runs [load]).
class FakePluginLoader extends PluginLoader {
  FakePluginLoader({
    this.extensions = const <ExtensionEntry>[StubExtensionEntry(id: 'ext', name: 'Ext')],
    this.sources = const <PluginSource>[],
    this.load,
    this.signedRepository,
  });

  final List<ExtensionEntry> extensions;
  final List<PluginSource> sources;

  /// Custom load behaviour; receives the owner.
  final Future<List<PluginSource>> Function(ConversionOwner? owner)? load;

  /// When set, the repository presents this signing fingerprint and its
  /// listings are dropped if the trust gate rejects it.
  final String? signedRepository;

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async {
    final String? fingerprint = signedRepository;
    if (fingerprint != null && trust != null) {
      final bool admitted = await trust.admit('test', Uri.parse(repoUrls.first), fingerprint);
      if (!admitted) return const <ExtensionEntry>[];
    }
    return extensions;
  }

  @override
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async => load == null ? sources : load!(owner);
}

/// A manga entry with [chapters].
SourceMangaData sourceManga(
  String title, {
  String? key,
  List<SourceChapter> chapters = const <SourceChapter>[],
  List<SourceTrackingEntry> tracking = const <SourceTrackingEntry>[],
}) => SourceMangaData(
  details: MangaSearchDetails(title: title),
  sourceId: 'origin',
  sourceMangaKey: key ?? title,
  chapters: chapters,
  tracking: tracking,
);

/// A destination chapter.
NativeChapter nativeChapter(String id, double number, {int order = 0, List<String> scanlators = const <String>[]}) =>
    NativeChapter(
      chapterId: id,
      sourceOrder: order,
      chapterNumber: number,
      title: 'Chapter $id',
      scanlators: scanlators,
    );

/// Confirms each manga with the single exact-title result, keeping failures.
Future<List<MangaMatchConfirmation>> confirmExactTitle(
  List<String> pluginNames,
  List<SourceMangaData> manga,
  Stream<PluginSearchEvent> Function(String query) onSearch,
  FetchDetails onFetchDetails,
) async => <MangaMatchConfirmation>[
  for (final SourceMangaData m in manga) await _confirm(m, onSearch),
];

Future<MangaMatchConfirmation> _confirm(SourceMangaData m, Stream<PluginSearchEvent> Function(String) onSearch) async {
  final results = <PluginSearchResult>[];
  final failures = <PluginSearchFailure>[];
  await for (final PluginSearchEvent e in onSearch(m.details.title)) {
    switch (e) {
      case PluginSearchResults(results: final r):
        results.addAll(r);
      case PluginSearchError(:final failure):
        failures.add(failure);
      case PluginSearchStarted():
        break;
    }
  }
  return MangaMatchConfirmation(sourceManga: m, confirmedMatch: results.firstOrNull, searchFailures: failures);
}
