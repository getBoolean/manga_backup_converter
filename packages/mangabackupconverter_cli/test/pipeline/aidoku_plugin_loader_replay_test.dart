// The CLI's production Aidoku path — AidokuPluginLoader → AidokuSourceProvider
// → SessionPluginSource → MigrationPipeline — against the committed MangaDex
// plugin and captures. No network: requests without a capture fail.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/source_adapter.dart' show AidokuSourceProvider;
import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/plugin_cache.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

File _aix() {
  for (final prefix in <String>['../aidoku_plugin_loader/', 'packages/aidoku_plugin_loader/']) {
    final file = File('${prefix}test/aidoku/fixtures/multi.mangadex-v12.aix');
    if (file.existsSync()) return file;
  }
  return File('missing.aix');
}

/// Loads the fixture bytes through the real loader instead of downloading.
class _FixtureLoader extends PluginLoader {
  _FixtureLoader(this.inner, this.bytes);

  final AidokuPluginLoader inner;
  final Uint8List bytes;

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async => const <ExtensionEntry>[_entry];

  @override
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async => (await inner.loadPluginFromBytes(_entry, bytes, owner: owner)).valueOrNull!;
}

const _entry = AidokuExtensionEntry(
  id: 'multi.mangadex',
  name: 'MangaDex',
  version: 12,
  iconUrl: '',
  downloadUrl: '',
  contentRating: ContentRatingLevel.suggestive,
);

const String _mangaId = 'ed996855-70de-449f-bba2-e8e24224c14d';

void main() {
  final File aix = _aix();
  group('AidokuPluginLoader (replayed MangaDex)', skip: aix.existsSync() ? null : 'Missing multi.mangadex-v12.aix', () {
    late ReplayHttpClient replay;
    late AidokuPluginLoader loader;

    setUp(() {
      final Directory? dir = findCaptureDir('aidoku', 'multi.mangadex');
      if (dir == null) throw StateError('Missing committed captures for multi.mangadex');
      replay = ReplayHttpClient(loadCaptureSet(dir));
      loader = AidokuPluginLoader(
        providerFactory: () => AidokuSourceProvider(
          httpClient: replay,
          // Same seeded login default as the adapter's own replay test.
          defaultsFor: (_) => <String, dynamic>{
            'login': Uint8List.fromList(<int>[2, 0x7B, 0x7D]),
          },
        ),
      );
    });

    tearDown(() => check(because: 'requests without a committed capture', replay.misses).isEmpty());

    test('search carries native references; details are typed and keep every chapter', () async {
      final owner = ConversionOwner();
      final PluginSource source = (await loader.loadPluginFromBytes(
        _entry,
        aix.readAsBytesSync(),
        owner: owner,
      )).valueOrNull!.single;
      check(source.identity.ecosystem).equals('aidoku');
      check(source.identity.artifact.kind).equals('aix');

      final PluginSearchPageResult page = (await source.search('Onimai')).valueOrNull!;
      final PluginSearchResult hit = page.results.firstWhere((PluginSearchResult r) => r.mangaKey == _mangaId);
      check(hit.ref.source).equals(source.identity);
      check(hit.ref.settingsRevision).equals(source.settingsRevision);

      final DetailsOutcome details = await source.fetchDetails(hit.ref);
      final FetchedManga fetched = details.fetchedOrNull!;
      check(details).isA<DetailsFetched>();
      check(fetched.chapters).isNotEmpty();
      await owner.close();
    });

    test('a missing manga is a typed failure through the pipeline boundary', () async {
      final owner = ConversionOwner();
      final PluginSource source = (await loader.loadPluginFromBytes(
        _entry,
        aix.readAsBytesSync(),
        owner: owner,
      )).valueOrNull!.single;
      final DetailsOutcome outcome = await source.fetchDetails(
        NativeMangaRef(
          source: source.identity,
          mangaId: '00000000-0000-0000-0000-000000000000',
          settingsRevision: source.settingsRevision,
        ),
      );
      check(outcome).isA<DetailsFailed>();
      replay.misses.clear();
      await owner.close();
    });

    test('cached byte-loading still returns the singleton source of an Aidoku package', () async {
      final Directory temp = Directory.systemTemp.createTempSync('aidoku_cache_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final cache = PluginCache(cacheDir: temp)..put(_entry, aix.readAsBytesSync());
      final owner = ConversionOwner();
      final failures = <PluginLoadFailure>[];
      final List<PluginSource> sources = await AidokuPluginLoader(
        providerFactory: loader.providerFactory,
        cache: cache,
      ).loadPlugins(const <ExtensionEntry>[_entry], owner: owner, onFailure: failures.add);
      check(failures).isEmpty();
      check(sources).length.equals(1);
      check(sources.single.identity.ecosystem).equals('aidoku');
      await owner.close();
    });

    test('the pipeline converts a library entry to Aidoku through the real loader', () async {
      final ConversionDraft draft =
          await MigrationPipeline(
            repoUrls: const <String>['https://repo.invalid'],
            session: ConversionSession(
              selection: CallbackSelectionPort(
                onSelectExtensions: (List<ExtensionEntry> e) async => e,
                onConfirmMatches: (_, List<SourceMangaData> manga, onSearch, _) async {
                  final results = <PluginSearchResult>[];
                  await for (final PluginSearchEvent e in onSearch('Onimai')) {
                    if (e is PluginSearchResults) results.addAll(e.results);
                  }
                  return <MangaMatchConfirmation>[
                    MangaMatchConfirmation(
                      sourceManga: manga.single,
                      confirmedMatch: results.firstWhere((PluginSearchResult r) => r.mangaKey == _mangaId),
                    ),
                  ];
                },
              ),
            ),
          ).execute(
            MigrationRoute(writer: const AidokuBackupBuilder(), loader: _FixtureLoader(loader, aix.readAsBytesSync())),
            sourceBackup: _OneManga(),
            sourceFormat: const Mihon(),
            targetFormat: const Aidoku(),
          );
      final backup = draft.backup as AidokuBackup;
      check(backup.manga!.single.id).equals(_mangaId);
      check(backup.manga!.single.sourceId).equals('multi.mangadex');
      check(backup.chapters).isNotNull().isNotEmpty();
      check(draft.report.isPartial).isFalse();
    });
  });
}

class _OneManga implements ConvertableBackup {
  @override
  List<SourceMangaData> get sourceMangaDataEntries => <SourceMangaData>[
    SourceMangaData(
      details: MangaSearchDetails(title: "Onimai: I'm Now Your Sister!"),
      sourceId: 'other',
    ),
  ];

  @override
  List<ExtractionLoss> get extractionLosses => const <ExtractionLoss>[];

  @override
  List<MangaSearchEntry> get mangaSearchEntries => const <MangaSearchEntry>[];

  @override
  List<String> get diagnostics => const <String>[];

  @override
  Future<Uint8List> toData() async => Uint8List(0);
}
