// All six R5 directions through the CLI's real destination runtimes —
// Aidoku (in-process WASM), Paperback (the QuickJS worker, in process) and
// Tachi (the shared JVM worker) — replaying the committed WeebCentral
// captures. No request reaches a server. Each run goes through the core
// ConversionJob, which validates the exact published bytes (KTD8).
@TestOn('vm')
@Timeout(Duration(minutes: 20))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/source_adapter.dart' show AidokuSourceProvider;
import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/conversion_composition.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_loader.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_tachi.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';
import 'package:test/scaffolding.dart';

const String _tachiWeebCentralId = '2131019126180322627';
const String _weebCentralSeries = '/series/01J76XYF0TGKQ7XJ4XVPV1C0BP/ONIMAI-Im-Now-Your-Sister';
const String _inkdex = 'https://inkdex.github.io/extensions/0.9/stable/';

final ({TachiWorkerLocation? location, String? skip}) _worker = testWorkerLocation();

Directory _repoDir(String relative) {
  Directory dir = Directory.current.absolute;
  while (!Directory('${dir.path}/$relative').existsSync()) {
    if (dir.parent.path == dir.path) throw StateError('$relative not found');
    dir = dir.parent;
  }
  return Directory('${dir.path}/$relative');
}

File get _weebCentralAix =>
    File('${_repoDir('packages/aidoku_plugin_loader/test/aidoku/fixtures').path}/en.weebcentral-v6.aix');

/// Lists the one fixture `.aix` and loads it through the real Aidoku loader.
final class _AidokuFixtureLoader extends PluginLoader {
  _AidokuFixtureLoader(this.inner);

  final AidokuPluginLoader inner;

  static const entry = AidokuExtensionEntry(
    id: 'en.weebcentral',
    name: 'Weeb Central',
    version: 6,
    iconUrl: '',
    downloadUrl: '',
    languages: <String>['en'],
  );

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async => const <ExtensionEntry>[entry];

  @override
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async => (await inner.loadPluginFromBytes(entry, _weebCentralAix.readAsBytesSync(), owner: owner)).valueOrNull!;
}

/// Serves the pinned inkdex 0.9 catalog and bundles.
http.Client _catalogClient(Directory fixtures) => MockClient((http.Request r) async {
  final url = r.url.toString();
  if (url.startsWith(_inkdex)) {
    final file = File('${fixtures.path}/inkdex-0.9/${url.substring(_inkdex.length)}');
    if (file.existsSync()) return http.Response.bytes(file.readAsBytesSync(), 200);
  }
  return http.Response('not found', 404);
});

/// An input backup of [format] with chapter 1 read, chapter 2 partly read and
/// chapter 3 bookmarked, written by the format's own writer.
Future<Uint8List> _input(BackupFormat format) async {
  final String ecosystem = switch (format) {
    Aidoku() => 'aidoku',
    Paperback() => 'paperback',
    _ => 'tachi',
  };
  final identity = SourceIdentity(
    ecosystem: ecosystem,
    packageId: 'origin',
    sourceId: ecosystem == 'tachi' ? '1234567890123456789' : 'en.origin',
    artifact: const ArtifactBinding(sha256: 'abc', kind: 'test', version: '1'),
  );
  final ref = NativeMangaRef(source: identity, mangaId: 'origin-manga', settingsRevision: 'rev');
  final manga = SourceMangaData(
    details: MangaSearchDetails(title: "ONIMAI - I'm Now Your Sister!"),
    categories: const <String>['Reading'],
    chapters: <SourceChapter>[
      SourceChapter(title: 'Step 1', chapterKey: 'o1', chapterNumber: 1, isRead: true, dateRead: DateTime.utc(2024)),
      SourceChapter(title: 'Step 2', chapterKey: 'o2', chapterNumber: 2, lastPageRead: 4, totalPages: 18),
      SourceChapter(title: 'Step 3', chapterKey: 'o3', chapterNumber: 3, isBookmarked: true),
    ],
  );
  final MangaMatchConfirmation c =
      MangaMatchConfirmation(
        sourceManga: manga,
        confirmedMatch: PluginSearchResult(ref: ref, title: manga.details.title),
      ).withDestination(
        FetchedManga(
          MangaSnapshot(
            ref: ref,
            metadata: MangaMetadata(title: manga.details.title),
            chapters: <NativeChapter>[
              for (var i = 1; i <= 3; i++)
                NativeChapter(
                  chapterId: 'origin-$i',
                  sourceOrder: 3 - i,
                  chapterNumber: i.toDouble(),
                  title: 'Step $i',
                  language: 'en',
                ),
            ],
          ),
        ),
      );
  return cliFormatRegistry().writerFor(format)!.build(<MangaConversionPlan>[planConversion(c)]).toData();
}

/// Picks WeebCentral, trusts its repository once, confirms the Onimai hit.
SelectionPort _selection() => CallbackSelectionPort(
  onSelectExtensions: (List<ExtensionEntry> e) async =>
      e.where((ExtensionEntry x) => x.id.toLowerCase().contains('weebcentral')).toList(),
  onRepositoryTrust: (_) async => TrustDecision.trustOnce,
  onConfirmMatches: (_, List<SourceMangaData> manga, onSearch, _) async {
    final results = <PluginSearchResult>[];
    await for (final PluginSearchEvent e in onSearch('Onimai')) {
      if (e is PluginSearchResults) results.addAll(e.results);
    }
    final PluginSearchResult hit = results.firstWhere(
      (PluginSearchResult r) => r.title.toLowerCase().contains('onimai'),
    );
    return <MangaMatchConfirmation>[MangaMatchConfirmation(sourceManga: manga.single, confirmedMatch: hit)];
  },
  acceptPartial: true,
);

final class _FileOutput implements ConversionOutput {
  _FileOutput(this.file);

  final File file;

  @override
  Future<void> publish(Uint8List bytes) => FileConversionOutput(file.path).publish(bytes);
}

void main() {
  final Directory paperbackFixtures = _repoDir('fixtures/source_captures/paperback');
  late Directory temp;
  late WorkerSupervisor paperbackSupervisor;
  late DesktopTachiRuntime tachi;
  late List<String> calls;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('u7_six_');
    calls = <String>[];
    paperbackSupervisor = WorkerSupervisor(
      spec: const WorkerSpec(label: 'paperback', executable: 'in-process'),
      limits: const SupervisorLimits(
        maxConcurrentPackages: 1,
        operationDeadline: Duration(minutes: 15),
        cancelGrace: Duration(seconds: 5),
        interactionTimeout: Duration(seconds: 5),
        shutdownGrace: Duration(seconds: 5),
      ),
      launcher: inProcessPaperbackLauncher(
        client: MultiReplayHttpClient.load(<Directory>[Directory('${paperbackFixtures.path}/weebcentral')]),
        limits: PaperbackRuntimeLimits(
          memoryLimitBytes: 256 << 20,
          maxStackBytes: 512 << 10,
          operationDeadline: const Duration(minutes: 15),
          jobSlice: const Duration(milliseconds: 20),
        ),
      ),
    );
    final fetch = FixtureFetch(<FixtureRepository>[
      FixtureRepository(baseUrl: keiyoushiRepository, captures: tachiCaptures()),
    ]);
    tachi = DesktopTachiRuntime(
      locate: () => _worker.location == null
          ? const SourceFailed<TachiWorkerLocation>(RuntimeUnavailableFailure('no test worker'))
          : SourceSuccess<TachiWorkerLocation>(_worker.location!),
      cacheDirectory: Directory('${temp.path}/tachi-artifacts'),
      fetch: fetch.call,
      replay: <String>[for (final TachiCapture c in tachiCaptures()) c.directory.path],
      stateDirectory: (Directory('${temp.path}/tachi-state')..createSync(recursive: true)).path,
    );
  });

  tearDown(() async {
    await paperbackSupervisor.close();
    await deleteTestDirectory(temp);
  });

  /// The desktop runtimes, as the CLI registers them, with replaying backends.
  RuntimeRegistry runtimes() => RuntimeRegistry(<DestinationRuntime>[
    DestinationRuntime(
      ecosystem: 'aidoku',
      serves: (BackupFormat f) => f is Aidoku,
      createLoader: (_) {
        calls.add('aidoku');
        final Directory dir = findCaptureDir('aidoku', 'en.weebcentral')!;
        return _AidokuFixtureLoader(
          AidokuPluginLoader(
            providerFactory: () => AidokuSourceProvider(httpClient: ReplayHttpClient(loadCaptureSet(dir))),
          ),
        );
      },
    ),
    DestinationRuntime(
      ecosystem: 'paperback',
      serves: (BackupFormat f) => f is Paperback,
      createLoader: (_) {
        calls.add('paperback');
        return PaperbackPluginLoader(
          client: _catalogClient(paperbackFixtures),
          cache: ArtifactCache(Directory('${temp.path}/pb-cache')),
          worker: (ConversionOwner? owner) async => (await paperbackSupervisor.start()).map((_) => paperbackSupervisor),
        );
      },
    ),
    DestinationRuntime(
      ecosystem: 'tachi',
      serves: (BackupFormat f) => f is Tachiyomi,
      probe: () => probeTachiWorker(tachi),
      createLoader: (_) {
        calls.add('tachi');
        return TachiPluginLoader(runtime: tachi);
      },
    ),
  ]);

  Future<(ConversionResult, Uint8List)> convert(BackupFormat source, BackupFormat target) async {
    final out = File('${temp.path}/out${target.extensions.first}');
    final List<String> repos = switch (target) {
      Paperback() => const <String>[_inkdex],
      Tachiyomi() => <String>[keiyoushiRepository.toString()],
      _ => const <String>['https://aidoku.invalid/index.json'],
    };
    final ConversionResult result =
        await ConversionJob(
          formats: cliFormatRegistry(),
          runtimes: runtimes(),
          onOwnerOpened: tachi.attach,
        ).run(
          ConversionRequest(input: await _input(source), sourceFormat: source, targetFormat: target, repoUrls: repos),
          _FileOutput(out),
          ConversionSession(selection: _selection()),
        );
    final Uint8List published = out.readAsBytesSync();
    check(published).deepEquals(result.draft.bytes);
    check(cliFormatRegistry().writerFor(target)!.validate(published, result.draft.plans)).isEmpty();
    check(calls).deepEquals(<String>[
      switch (target) {
        Aidoku() => 'aidoku',
        Paperback() => 'paperback',
        _ => 'tachi',
      },
    ]);
    // Complete accounting: every state-bearing input chapter has exactly
    // one disposition, and the manga is transferred.
    // (Aidoku and Paperback inputs cannot carry the bookmark, so they hold
    // two state-bearing chapters; Mihon holds three.)
    final int stateful = mergeHistoryIntoChapters(result.input.sourceMangaDataEntries.single).$1
        .where((SourceChapter c) => c.hasReadingState)
        .length;
    check(stateful).equals(source is Tachiyomi ? 3 : 2);
    check(result.report.count(RecordKind.chapterState)).equals(stateful);
    check(result.report.count(RecordKind.manga, RecordDisposition.transferred)).equals(1);
    // WeebCentral's chapters reconcile by number, or by exact title where the
    // Tachi source reports no numbers: all state transfers.
    check(result.report.count(RecordKind.chapterState, RecordDisposition.transferred)).equals(stateful);
    return (result, published);
  }

  void checkAidoku(Uint8List bytes) {
    final AidokuBackup b = AidokuBackup.fromData(bytes);
    check(b.manga!.single.sourceId).equals('en.weebcentral');
    check(b.chapters!.length).isGreaterThan(100);
    check(b.history).isNotNull().isNotEmpty();
  }

  void checkPaperback(Uint8List bytes) {
    final b = PaperbackBackup.fromData(bytes);
    check(b.sourceManga!.single.sourceId).equals('WeebCentral');
    check(b.chapters!.length).isGreaterThan(100);
    check(b.chapterProgressMarker).isNotNull().isNotEmpty();
  }

  void checkTachi(Uint8List bytes) {
    final b = TachiBackup.fromData(bytes);
    final TachiBackupManga m = b.backupManga.single;
    // AE1: the loaded source's exact int64 ID and its own SManga/SChapter URLs.
    check(m.source.toString()).equals(_tachiWeebCentralId);
    check(m.url).equals(_weebCentralSeries);
    check(m.chapters.length).isGreaterThan(100);
    check(m.chapters.every((TachiBackupChapter c) => !c.url.startsWith('http'))).isTrue();
    check(m.chapters.where((TachiBackupChapter c) => c.read)).isNotEmpty();
    // Partial progress stays partial (AE2); Aidoku/Paperback inputs carry no bookmarks.
    final TachiBackupChapter partial = m.chapters.singleWhere((TachiBackupChapter c) => c.lastPageRead > 0);
    check(partial.lastPageRead).equals(4);
    check(partial.read).isFalse();
  }

  test('Paperback → Aidoku', () async => checkAidoku((await convert(const Paperback(), const Aidoku())).$2));
  test('Mihon → Aidoku', () async => checkAidoku((await convert(const Mihon(), const Aidoku())).$2));
  test('Aidoku → Paperback', () async => checkPaperback((await convert(const Aidoku(), const Paperback())).$2));
  test('Mihon → Paperback', () async => checkPaperback((await convert(const Mihon(), const Paperback())).$2));
  group('Tachi destination (JVM worker)', skip: _worker.skip, () {
    test('Aidoku → Mihon', () async => checkTachi((await convert(const Aidoku(), const Mihon())).$2));
    test('Paperback → Mihon', () async => checkTachi((await convert(const Paperback(), const Mihon())).$2));
  });
}
