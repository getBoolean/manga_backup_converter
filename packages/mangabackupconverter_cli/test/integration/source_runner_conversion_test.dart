// Conversions through the CLI's own composition (cliRuntimeRegistry and
// DesktopTachiRuntime, as `convert` builds them) with the real runtimes: the
// JVM worker, the Paperback QuickJS worker (in process) and the desktop
// WebView helper. Every request replays committed captures; the helper runs
// offline, so a request with no capture fails instead of reaching a server.
@TestOn('vm')
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:desktop_webview/desktop_webview.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/conversion_composition.dart';
import 'package:mangabackupconverter_cli/src/commands/desktop_runtime.dart';
import 'package:mangabackupconverter_cli/src/commands/plugin_cache.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_tachi.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';
import 'package:test/scaffolding.dart';

const String _weebCentralId = '2131019126180322627';
const String _mangaDexEnId = '2499283573021220255';
const String _inkdex = 'https://inkdex.github.io/extensions/0.9/stable/';

/// A second Tachi repository (synthetic `repo.json` and `index.json`, built
/// in memory from the committed index entries) that lists only Weeb Central.
/// Its artifacts are the committed keiyoushi-signed files, so it publishes
/// keiyoushi's fingerprint; trust is still decided per repository.
final Uri _mirrorRepository = Uri.parse('https://mirror.invalid/keiyoushi/repo');

final ({TachiWorkerLocation? location, String? skip}) _worker = testWorkerLocation();

Directory _repoDir(String relative) {
  Directory dir = Directory.current.absolute;
  while (!Directory(p.join(dir.path, relative)).existsSync()) {
    if (dir.parent.path == dir.path) throw StateError('$relative not found');
    dir = dir.parent;
  }
  return Directory(p.join(dir.path, relative));
}

/// The helper built for this host (debug), building it when missing; `null`
/// with [_helperSkip] when cargo cannot build it.
String? _helperSkip;
Future<File?> _helperManifest() async {
  File? manifest = locateWebViewHelperManifest(searchFrom: Directory.current);
  if (manifest == null) {
    final Directory pkg = _repoDir('packages/desktop_webview');
    final ProcessResult built = await Process.run(
      Platform.resolvedExecutable.contains('flutter_tester') ? 'dart' : Platform.resolvedExecutable,
      <String>['run', 'tool/build_helper.dart'],
      workingDirectory: pkg.path,
      runInShell: true,
    );
    if (built.exitCode != 0) {
      _helperSkip = 'desktop WebView helper not built: ${built.stderr}';
      return null;
    }
    manifest = locateWebViewHelperManifest(searchFrom: Directory.current);
  }
  return manifest;
}

/// Serves the pinned inkdex 0.9 catalog and bundles.
http.Client _catalogClient(Directory fixtures) => MockClient((http.Request r) async {
  final url = r.url.toString();
  if (url.startsWith(_inkdex)) {
    final file = File(p.join(fixtures.path, 'inkdex-0.9', url.substring(_inkdex.length)));
    if (file.existsSync()) return http.Response.bytes(file.readAsBytesSync(), 200);
  }
  return http.Response('not found', 404);
});

/// A Paperback backup with chapter 1 read and chapter 2 partly read, written
/// by the Paperback writer.
Future<Uint8List> _paperbackInput() async {
  const identity = SourceIdentity(
    ecosystem: 'paperback',
    packageId: 'origin',
    sourceId: 'en.origin',
    artifact: ArtifactBinding(sha256: 'abc', kind: 'test', version: '1'),
  );
  const ref = NativeMangaRef(source: identity, mangaId: 'origin-manga', settingsRevision: 'rev');
  final manga = SourceMangaData(
    details: MangaSearchDetails(title: "ONIMAI - I'm Now Your Sister!"),
    categories: const <String>['Reading'],
    chapters: <SourceChapter>[
      SourceChapter(title: 'Step 1', chapterKey: 'o1', chapterNumber: 1, isRead: true, dateRead: DateTime.utc(2024)),
      SourceChapter(title: 'Step 2', chapterKey: 'o2', chapterNumber: 2, lastPageRead: 4, totalPages: 18),
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
              for (var i = 1; i <= 2; i++)
                NativeChapter(
                  chapterId: 'origin-$i',
                  sourceOrder: 2 - i,
                  chapterNumber: i.toDouble(),
                  title: 'Step $i',
                  language: 'en',
                ),
            ],
          ),
        ),
      );
  return cliFormatRegistry().writerFor(const Paperback())!.build(<MangaConversionPlan>[planConversion(c)]).toData();
}

final class _MemoryOutput implements ConversionOutput {
  Uint8List? bytes;

  @override
  Future<void> publish(Uint8List b) async => bytes = b;
}

/// Counts worker launches and keeps every launched process.
final class _CountingLauncher {
  final List<WorkerProcess> launched = <WorkerProcess>[];

  Future<WorkerProcess> call(WorkerSpec spec) async {
    final WorkerProcess process = await launchWorkerProcess(spec);
    launched.add(process);
    return process;
  }
}

void main() {
  final Directory paperbackFixtures = _repoDir('fixtures/source_captures/paperback');
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('u8_runner_'));
  tearDown(() => deleteTestDirectory(temp));

  DesktopTachiRuntime tachiRuntime(FixtureFetch fetch, {WorkerLauncher? launcher, BrowserPort? browser}) =>
      DesktopTachiRuntime(
        locate: () => _worker.location == null
            ? const SourceFailed<TachiWorkerLocation>(RuntimeUnavailableFailure('no test worker'))
            : SourceSuccess<TachiWorkerLocation>(_worker.location!),
        cacheDirectory: Directory(p.join(temp.path, 'tachi-artifacts')),
        fetch: fetch.call,
        replay: <String>[for (final TachiCapture c in tachiCaptures()) c.directory.path],
        stateDirectory: (Directory(p.join(temp.path, 'tachi-state'))..createSync(recursive: true)).path,
        launcher: launcher,
        browserPort: browser,
        browserReplacementTimeout: CliBrowserPolicy.replacementTimeout,
        interactionTimeout: CliBrowserPolicy.interactionTimeout,
      );

  RuntimeRegistry registry(DesktopTachiRuntime tachi, {BrowserPort? browser, List<String> paperbackSites = const []}) =>
      cliRuntimeRegistry(
        cache: PluginCache(cacheDir: Directory(p.join(temp.path, 'plugin-cache'))),
        tachi: tachi,
        cacheRoot: temp.path,
        interactionTimeout: CliBrowserPolicy.interactionTimeout,
        browserPort: browser,
        browserReplacementTimeout: CliBrowserPolicy.replacementTimeout,
        paperbackClient: _catalogClient(paperbackFixtures),
        paperbackLauncher: inProcessPaperbackLauncher(
          client: MultiReplayHttpClient.load(<Directory>[
            for (final String site in paperbackSites) Directory(p.join(paperbackFixtures.path, site)),
          ]),
          limits: PaperbackRuntimeLimits(
            memoryLimitBytes: 256 << 20,
            maxStackBytes: 512 << 10,
            operationDeadline: const Duration(minutes: 5),
            jobSlice: const Duration(milliseconds: 20),
          ),
        ),
      );

  group('Tachi destination through the CLI composition', skip: _worker.skip, () {
    test('picks packages from two repositories and hosts them all in one JVM worker', () async {
      final fetch = FixtureFetch(<FixtureRepository>[
        FixtureRepository(
          baseUrl: keiyoushiRepository,
          captures: tachiCaptures().where((TachiCapture c) => c.source == 'all.mangadex').toList(),
        ),
        FixtureRepository(
          baseUrl: _mirrorRepository,
          name: 'Mirror',
          captures: tachiCaptures().where((TachiCapture c) => c.source == 'en.weebcentral').toList(),
        ),
      ]);
      final launcher = _CountingLauncher();
      final DesktopTachiRuntime tachi = tachiRuntime(fetch, launcher: launcher.call);
      final trusted = <Uri>[];
      final listedRepos = <String>{};
      final hitsBySource = <String, int>{};
      final selection = CallbackSelectionPort(
        onSelectExtensions: (List<ExtensionEntry> e) async {
          listedRepos.addAll(e.whereType<TachiExtensionEntry>().map((TachiExtensionEntry x) => x.repositoryUrl));
          return e;
        },
        onRepositoryTrust: (RepositoryTrustRequest r) async {
          trusted.add(r.repository);
          return TrustDecision.trustOnce;
        },
        onConfirmMatches: (_, List<SourceMangaData> manga, onSearch, _) async {
          final results = <PluginSearchResult>[];
          await for (final PluginSearchEvent e in onSearch('Onimai')) {
            if (e is PluginSearchResults) results.addAll(e.results);
          }
          for (final r in results) {
            hitsBySource.update(r.ref.source.sourceId, (int n) => n + 1, ifAbsent: () => 1);
          }
          final PluginSearchResult hit = results.firstWhere(
            (PluginSearchResult r) => r.ref.source.sourceId == _weebCentralId,
          );
          return <MangaMatchConfirmation>[MangaMatchConfirmation(sourceManga: manga.single, confirmedMatch: hit)];
        },
        acceptPartial: true,
      );
      final output = _MemoryOutput();
      WorkerSupervisor? workerSeen;
      final ConversionResult result =
          await ConversionJob(
            formats: cliFormatRegistry(),
            runtimes: registry(tachi),
            selection: selection,
            onOwnerOpened: (ConversionOwner owner) async {
              await tachi.attach(owner);
              // Read the handshake for the receipt before the owner closes the scope.
              await owner.adopt(() => workerSeen = tachi.scope?.supervisors[WorkerKind.jvm]);
            },
          ).run(
            ConversionRequest(
              input: await _paperbackInput(),
              sourceFormat: const Paperback(),
              targetFormat: const Mihon(),
              repoUrls: <String>[keiyoushiRepository.toString(), _mirrorRepository.toString()],
              sources: const <String>{_weebCentralId, _mangaDexEnId},
            ),
            output,
          );
      // Both repositories were trusted and listed, both packages loaded and
      // searched, all in the one worker process.
      check(trusted).deepEquals(<Uri>[keiyoushiRepository, _mirrorRepository]);
      check(listedRepos).deepEquals(<String>{keiyoushiRepository.toString(), _mirrorRepository.toString()});
      check(hitsBySource.keys.toSet()).deepEquals(<String>{_weebCentralId, _mangaDexEnId});
      check(launcher.launched).length.equals(1);
      check(output.bytes).isNotNull().deepEquals(result.draft.bytes);
      final TachiBackupManga m = TachiBackup.fromData(output.bytes!).backupManga.single;
      check(m.source.toString()).equals(_weebCentralId);
      check(m.chapters.length).isGreaterThan(100);
      check(result.report.count(RecordKind.manga, RecordDisposition.transferred)).equals(1);
      _writeReceipt('${Platform.operatingSystem}-tachi-two-repositories-one-worker', <String, Object?>{
        ..._workerIdentity(workerSeen),
        'java': _worker.location?.java == null ? null : _javaRuntime(_worker.location!.java),
        'artifacts': <Object?>[
          for (final TachiCapture c in tachiCaptures())
            if (c.source != 'all.mangafire')
              <String, Object?>{
                'kind': 'jar',
                'url': c.urlOf(TachiArtifactKind.jar).toString(),
                'sha256': c.sha256Of(TachiArtifactKind.jar),
              },
        ],
        'apiFamily': 'tachi-1.6',
        'repositories': 2,
        'jvmWorkerLaunches': launcher.launched.length,
        'operation': 'convert paperback -> mihon',
        'query': 'Onimai',
        'outcome': 'completed',
        'destination': <String, Object?>{'format': 'mihon', 'chapters': m.chapters.length},
        'report': <String, Object?>{
          'mangaTransferred': result.report.count(RecordKind.manga, RecordDisposition.transferred),
          'chapterStateTransferred': result.report.count(RecordKind.chapterState, RecordDisposition.transferred),
          'chapterStateRecords': result.report.count(RecordKind.chapterState),
        },
      });
      // The conversion owner closed the scope: the worker exited.
      for (final WorkerProcess w in launcher.launched) {
        check(await w.exitCode.timeout(const Duration(seconds: 30))).isA<int>();
      }
    });
  });

  group('desktop WebView helper through the CLI composition', () {
    late File? manifest;
    setUpAll(() async => manifest = await _helperManifest());

    test('Paperback MangaFire executeInWebView runs in the helper (signing search and details where the browser '
        'capture replays), and closing the owner leaves no helper process', () async {
      if (manifest == null) {
        markTestSkipped(_helperSkip ?? 'desktop WebView helper not built');
        return;
      }
      // Browser capture replay needs the helper's replace tier (WebView2). On
      // WebKit engines the page's site scripts cannot be served, so the VRF
      // capture fails inside the page, as before the capture existed.
      final bool replayable = Platform.isWindows;
      final BrowserCaptureReplay? replay = replayable
          ? BrowserCaptureReplay(loadCaptureSet(Directory(p.join(paperbackFixtures.path, 'mangafire', 'browser'))))
          : null;
      // The CLI's browser policy, offline.
      final browser = DesktopBrowserPort(
        DesktopWebViewConfig(
          helperExecutable: RuntimeArtifactManifest.load(
            manifest!,
          ).findForHost(RuntimeArtifactManifest.webviewHelper)!.verifiedFile(),
          dataRoot: Directory(p.join(temp.path, 'webview')),
          startupTimeout: CliBrowserPolicy.helperStartup,
          shutdownGrace: CliBrowserPolicy.helperShutdownGrace,
          allowVisibleWindows: false,
          offline: true,
          replay: replay,
          wipeRetry: CliBrowserPolicy.wipeRetry,
        ),
      );
      final DesktopTachiRuntime tachi = tachiRuntime(FixtureFetch(const <FixtureRepository>[]), browser: browser);
      final RuntimeRegistry runtimes = registry(tachi, browser: browser, paperbackSites: const <String>['mangafire']);
      final owner = ConversionOwner();
      await owner.adopt(browser.dispose);
      await tachi.attach(owner);
      SourceOutcome<PluginSearchPageResult>? searched;
      DetailsOutcome? details;
      int? helperPid;
      String? engine;
      String? engineVersion;
      ArtifactBinding? mangaFireBinding;
      try {
        final PluginLoader loader = runtimes
            .runtimeFor(const Paperback())!
            .createLoader(
              const RuntimeContext(),
            );
        final List<ExtensionEntry> entries = await loader.fetchExtensionLists(<String>[
          _inkdex,
        ], trust: RepositoryTrustGate(store: InMemoryTrustStore(), decide: (_) async => TrustDecision.trustOnce));
        final ExtensionEntry mangaFire = entries.firstWhere((ExtensionEntry e) => e.id.endsWith('#MangaFire'));
        final List<PluginSource> plugins = await loader.loadPlugins(<ExtensionEntry>[mangaFire], owner: owner);
        check(plugins).length.equals(1);
        searched = await plugins.single.search('Onimai', 1);
        final PluginSearchResult? hit = searched.valueOrNull?.results.firstOrNull;
        if (hit != null) details = await plugins.single.fetchDetails(hit.ref);
        helperPid = browser.helperInfo?.pid;
        engine = browser.helperInfo?.engine;
        engineVersion = browser.helperInfo?.engineVersion;
        mangaFireBinding = browser.debugOpenedSources
            .where((SourceIdentity s) => s.sourceId == 'MangaFire')
            .firstOrNull
            ?.artifact;
      } finally {
        await owner.close();
      }
      // The worker's executeInWebView opened sessions in the real helper for
      // MangaFire's own identity.
      check(browser.debugOpenedSources.map((SourceIdentity s) => s.sourceId)).contains('MangaFire');
      check(helperPid).isNotNull();
      final String outcome;
      if (replay != null) {
        // The page's scripts, served from the capture, signed the requests
        // the worker then replayed.
        final PluginSearchPageResult page = searched.valueOrNull!;
        check(page.results).length.equals(30);
        check(page.results.first.title).equals('Highschool ONIMAI');
        final MangaSnapshot snapshot = (details! as DetailsFetched).manga.snapshot;
        check(snapshot.chapters).length.equals(86);
        check(
          replay.misses.where(
            (CaptureKey k) =>
                Uri.parse(k.url).host == 'mangafire.to' &&
                !k.url.contains('/cdn-cgi/') &&
                !k.url.endsWith('/assets/mangafire/favicon.svg'),
          ),
        ).isEmpty();
        outcome = 'passed: 30 search hits, details of the first hit with ${snapshot.chapters.length} chapters';
      } else {
        check(searched.failureOrNull)
            .isA<SourceErrorFailure>()
            .has((SourceErrorFailure f) => f.message, 'message')
            .contains('VRF capture timed out');
        outcome = 'failed: VRF capture timed out (browser capture replay needs the replace tier, which $engine lacks)';
      }
      _writeReceipt('${Platform.operatingSystem}-paperback-executeinwebview-helper', <String, Object?>{
        'webview': <String, Object?>{'engine': engine, 'engineVersion': engineVersion},
        'artifact': <String, Object?>{
          'kind': 'paperback-bundle-0.9',
          'url': '${_inkdex}MangaFire/index.js',
          'sha256': mangaFireBinding?.sha256,
        },
        'apiFamily': 'paperback-0.9',
        'operation': replay != null
            ? 'search, details and chapters (executeInWebView through the desktop helper, offline replay)'
            : 'search (executeInWebView through the desktop helper, offline replay)',
        'query': 'Onimai',
        'outcome': outcome,
        if (replay != null) ...<String, Object?>{
          'browserCapture': 'fixtures/source_captures/paperback/mangafire/browser',
          'browserRequestsServed': replay.served.length,
          'browserRequestsFailedClosed': replay.misses.length,
        },
        'browserSessionsOpened': browser.debugOpenedSources.length,
        'helperExitedAfterOwnerClose': !_processAlive(helperPid!),
      });
      // Owner closed: no session left, helper exited.
      check(browser.debugOpenSessions).equals(0);
      check(browser.helperInfo).isNull();
      check(_processAlive(helperPid)).isFalse();
    });
  });
}

/// Writes [receipt] as `<SRT_RECEIPT_DIR>/<name>.json` when that variable
/// is set (qualification runs); otherwise does nothing. Receipts carry only
/// identity, public artifact URLs and digests, the public query, outcomes and
/// counts (plan, *Evidence Identity*); `tool/check_evidence_receipts.dart`
/// checks them before they are committed.
void _writeReceipt(String name, Map<String, Object?> receipt) {
  final String? dir = Platform.environment['SRT_RECEIPT_DIR'];
  if (dir == null || dir.isEmpty) return;
  final ProcessResult commit = Process.runSync('git', <String>['rev-parse', 'HEAD']);
  final ProcessResult dirty = Process.runSync('git', <String>['status', '--porcelain', '--untracked-files=no']);
  final file = File(p.join(dir, '$name.json'))..parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'kind': 'source-runner-conversion',
      'evidence': 'replayed-capture',
      'recordedAt': DateTime.now().toUtc().toIso8601String(),
      'hostCommit': (commit.stdout as String).trim(),
      'hostDirty': (dirty.stdout as String).trim().isNotEmpty,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dart': Platform.version.split(' ').first,
      ...receipt,
    })}\n',
  );
}

/// The receipt fields of a started worker supervisor.
Map<String, Object?> _workerIdentity(WorkerSupervisor? s) => <String, Object?>{
  'protocol': '${s?.handshake?.protocolVersion}.${s?.handshake?.protocolMinor}',
  'workerVersion': s?.handshake?.workerVersion,
  'sizing': <String, Object?>{'rule': s?.handshake?.sizing?.rule, 'derived': s?.handshake?.sizing?.derived?.toJson()},
};

/// The runtime version and vendor the worker's [java] reports
/// (`java.runtime.version`, `java.vendor`), e.g. `21.0.13.1+...` from Amazon.
Map<String, String?> _javaRuntime(String java) {
  final ProcessResult r = Process.runSync(java, <String>['-XshowSettings:properties', '-version']);
  String? property(String name) =>
      RegExp('^\\s*${RegExp.escape(name)} = (.+)\$', multiLine: true).firstMatch('${r.stderr}')?.group(1)?.trim();
  return <String, String?>{'version': property('java.runtime.version'), 'vendor': property('java.vendor')};
}

/// Whether a process with [pid] is still running.
bool _processAlive(int pid) {
  if (Platform.isWindows) {
    final ProcessResult r = Process.runSync('tasklist', <String>['/FI', 'PID eq $pid', '/NH']);
    return (r.stdout as String).contains(' $pid ');
  }
  return Process.runSync('kill', <String>['-0', '$pid']).exitCode == 0;
}
