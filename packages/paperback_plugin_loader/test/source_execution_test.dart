// AE4 / U6 real-artifact evidence: the original pinned Paperback bundles of
// both API families run search and details-with-chapters through their own
// asynchronous host requests, across the network bridge, replaying the
// committed captures (no server is contacted). The path is the desktop one:
// provider -> supervisor -> protocol 1.1 -> worker -> adapter -> QuickJS;
// only the process boundary is replaced by in-memory pipes (the built
// executable runs the same scenario in e2e/paperback_worker_e2e_test.dart).
@TestOn('vm')
@Timeout(Duration(minutes: 45))
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import 'support/host_harness.dart';
import 'support/paperback_scenarios.dart';
import 'support/scripted_browser_port.dart';

/// Runs [site]'s scenario against its committed capture. [port] serves
/// browser reverse requests when given.
Future<(List<BundleRun>, MultiReplayHttpClient)> _replay(String site, {BrowserPort? port}) async {
  final client = MultiReplayHttpClient.load(<Directory>[Directory('${paperbackFixtures().path}/$site')]);
  final repos = <PinnedRepository>[for (final PinnedBundle b in captureSites[site]!) PinnedRepository.load(b.repoDir)];
  final BrowserReverseBridge? bridge = port == null
      ? null
      : BrowserReverseBridge(
          port: port,
          resolveSource: (String? packageId, String sourceId) {
            for (final r in repos) {
              for (final MapEntry<String, Map<String, Object?>> pin in r.pins.entries) {
                final PaperbackCatalogEntry e = r.entry(pin.key);
                if (e.packageId == packageId && e.sourceId == sourceId) {
                  return SourceIdentity(
                    ecosystem: 'paperback',
                    packageId: e.packageId,
                    sourceId: sourceId,
                    artifact: ArtifactBinding(
                      sha256: pin.value['sha256']! as String,
                      kind: e.family.artifactKind,
                      version: e.version,
                    ),
                  );
                }
              }
            }
            return null;
          },
        );
  final supervisor = WorkerSupervisor(
    spec: const WorkerSpec(label: 'paperback', executable: 'in-process'),
    limits: const SupervisorLimits(
      maxConcurrentPackages: 1,
      operationDeadline: Duration(minutes: 15),
      cancelGrace: Duration(seconds: 5),
      interactionTimeout: Duration(seconds: 5),
      shutdownGrace: Duration(seconds: 5),
    ),
    launcher: inProcessPaperbackLauncher(
      client: client,
      limits: testLimits(deadline: const Duration(minutes: 15)),
    ),
    onReverseRequest: bridge?.handle,
  );
  bridge?.emitEvent = supervisor.sendEvent;
  final Directory cache = Directory.systemTemp.createTempSync('paperback_exec');
  final provider = PaperbackSourceProvider(
    client: client,
    cache: ArtifactCache(cache),
    trust: PinnedRepository.pinnedTrust(repos),
    worker: () async => (await supervisor.start()).map((_) => supervisor),
  );
  try {
    return (await runSiteScenario(provider, site), client);
  } finally {
    await supervisor.close();
    await bridge?.close();
    cache.deleteSync(recursive: true);
  }
}

MangaSnapshot _snapshot(BundleRun run) => (run.details! as SourceSuccess<MangaSnapshot>).value;

SearchPage _page(BundleRun run) => (run.page1! as SourceSuccess<SearchPage>).value;

void _checkChapters(MangaSnapshot s, {required int count}) {
  check(s.chapters).length.equals(count);
  final ids = <String>{for (final NativeChapter c in s.chapters) c.chapterId};
  check(ids).length.equals(count);
  check(<int>[for (final NativeChapter c in s.chapters) c.sourceOrder])
      .deepEquals(List<int>.generate(count, (int i) => i));
  check(s.chapters.every((NativeChapter c) => c.chapterId.isNotEmpty)).isTrue();
}

void main() {
  test('WeebCentral: 0.9 and both 0.8 bundles search, fetch details and chapters (Cheerio, HTML)', () async {
    final (List<BundleRun> runs, MultiReplayHttpClient client) = await _replay('weebcentral');
    check(client.misses).isEmpty();
    check(runs.map((BundleRun r) => r.family).toList()).deepEquals(<PaperbackApiFamily>[
      PaperbackApiFamily.v09,
      PaperbackApiFamily.v08,
      PaperbackApiFamily.v08,
    ]);
    for (final run in runs) {
      final SearchPage page = _page(run);
      check(page.hits.first.ref.mangaId).equals('01J76XYF0TGKQ7XJ4XVPV1C0BP');
      check(page.hits.first.title).equals("ONIMAI - I'm Now Your Sister!");
      check(page.hits.first.ref.context['apiFamily']).equals(run.family.wire);
      final MangaSnapshot s = _snapshot(run);
      check(s.metadata.title).equals("ONIMAI - I'm Now Your Sister!");
      check(s.metadata.authors).deepEquals(<String>['Nekotoufu']);
      check(s.metadata.status).equals(PublishingStatus.ongoing);
      _checkChapters(s, count: 114);
      // Chapter identities are the site's own, identical across families.
      check(s.chapters.first.chapterId).equals('01KWM07QYFJMAP46S1A3ZVDWYG');
      check(s.chapters.first.chapterNumber).equals(100);
      check(s.chapters.first.context['apiFamily']).equals(run.family.wire);
    }
  });

  test('MangaDex: the 0.9 bundle searches, fetches details and the complete chapter feed (JSON API)', () async {
    final (List<BundleRun> runs, MultiReplayHttpClient client) = await _replay('mangadex');
    check(client.misses).isEmpty();
    final BundleRun inkdex = runs.firstWhere((BundleRun r) => r.family == PaperbackApiFamily.v09);
    final SearchPage page = _page(inkdex);
    check(page.hits).length.equals(2);
    check(page.hits.first.ref.mangaId).equals('ed996855-70de-449f-bba2-e8e24224c14d');
    check(page.nextCursor).isNull();
    final MangaSnapshot s = _snapshot(inkdex);
    check(s.metadata.title).equals("ONIMAI: I'm Now Your Sister!");
    check(s.metadata.contentRating).equals(ContentRatingLevel.safe);
    _checkChapters(s, count: 223);
    check(s.chapters.first.scanlators).isNotEmpty();
    check(s.chapters.first.dateUploaded).isNotNull();
  });

  test('MangaDex 0.8 (neihc1002) echoes getDefaultUserAgent, and the host puts no user agent on the wire', () async {
    // Replay keys ignore headers, so this pins what the capture sent: the
    // bundle's interceptor sets `user-agent: getDefaultUserAgent()` and a
    // referer; the 0.8 adapter drops the echoed default, so the HTTP client's
    // own user agent applies (as for the 0.9 bundle, which sets none).
    final repo = PinnedRepository.load('neihc1002-0.8');
    final HostUnderTest h = await HostUnderTest.load(
      repo.bundle('Mangadex'),
      PaperbackApiFamily.v08,
      handler: (http.Request r) async => http.Response('{"result":"ok","data":[],"total":0}', 200),
    );
    try {
      await h.search(qualificationQuery);
      check(h.requests).isNotEmpty();
      for (final http.Request r in h.requests) {
        check(r.url.host).equals('api.mangadex.org');
        check(r.headers.keys.map((String k) => k.toLowerCase()))
            .not((Subject<Iterable<String>> it) => it.contains('user-agent'));
        check(r.headers['referer']).equals('https://mangadex.org');
      }
    } finally {
      h.dispose();
    }
  });

  test('MangaDex 0.8 (neihc1002) searches, fetches details and the complete chapter feed (JSON API)', () async {
    // Re-recorded with no host user agent on the wire (the test above): no
    // edge challenge. The bundle hard-codes `contentRating[]=suggestive` and
    // defaults to Vietnamese, so the search for the `safe`-rated Onimai is a
    // real, empty result and details use the pinned fallback manga.
    final (List<BundleRun> runs, MultiReplayHttpClient client) = await _replay('mangadex');
    check(client.misses).isEmpty();
    check(client.served.map((CaptureKey k) => k.url).where((String u) => u.contains('/edge/challenge'))).isEmpty();
    final BundleRun neihc = runs.firstWhere((BundleRun r) => r.family == PaperbackApiFamily.v08);
    final SearchPage page = _page(neihc);
    check(page.hits).isEmpty();
    check(page.nextCursor).isNull();
    check(neihc.detailsRef!.mangaId).equals('ed996855-70de-449f-bba2-e8e24224c14d');
    final MangaSnapshot s = _snapshot(neihc);
    check(s.metadata.title).equals('ONIMAI: Giờ tao là chị mày!');
    _checkChapters(s, count: 174);
    check(s.chapters.first.chapterId).equals('106147e6-0551-4a7c-9b01-2c6206c7a2d2');
    check(s.chapters.first.chapterNumber).equals(1);
    check(s.chapters.first.context['apiFamily']).equals('paperback-0.8');
    check(s.chapters.first.dateUploaded).isNotNull();
  });

  test('MangaFire 0.9 without a browser port: a named capability failure, not an empty result', () async {
    final (List<BundleRun> runs, MultiReplayHttpClient client) = await _replay('mangafire');
    check(client.misses).isEmpty();
    final BundleRun run = runs.single;
    check(run.page1)
        .isA<SourceFailed<SearchPage>>()
        .has((SourceFailed<SearchPage> f) => f.failure, 'failure')
        .isA<CapabilityUnavailableFailure>()
        .has((CapabilityUnavailableFailure f) => f.operation, 'operation')
        .equals('executeInWebView');
    // The source's own redirect (/home -> /) went through the host hop by
    // hop; the source caches the page in its own state for later operations.
    check(client.served.map((CaptureKey k) => k.url).toList()).deepEquals(<String>[
      'https://mangafire.to/home',
      'https://mangafire.to',
    ]);
    check(run.details)
        .isA<SourceFailed<MangaSnapshot>>()
        .has((SourceFailed<MangaSnapshot> f) => f.failure, 'failure')
        .isA<CapabilityUnavailableFailure>();
  });

  test('MangaFire 0.9 executeInWebView completes through a BrowserPort over worker reverse requests', () async {
    // The fake page answers the source's VRF capture with "no match", so the
    // source reports its own timeout: the browser call completed and its
    // result reached the source. Signing against the real site needs U2's
    // helper (U8 join).
    final port = ScriptedBrowserPort(respond: (ScriptedPage page) => '{"matched":"","all":[]}');
    final (List<BundleRun> runs, MultiReplayHttpClient client) = await _replay('mangafire', port: port);
    check(client.misses).isEmpty();
    final BundleRun run = runs.single;
    check(run.page1)
        .isA<SourceFailed<SearchPage>>()
        .has((SourceFailed<SearchPage> f) => f.failure, 'failure')
        .isA<SourceErrorFailure>()
        .has((SourceErrorFailure f) => f.message, 'message')
        .contains('VRF capture timed out');
    check(port.pages).isNotEmpty();
    final ScriptedPage page = port.pages.first;
    check(page.baseUrl.toString()).startsWith('https://mangafire.to');
    check(page.html!).contains('__vrfCapture');
    check(page.userAgent).equals(paperbackDefaultUserAgent);
    // Every session the source opened was closed (its storage deleted).
    check(port.closed).length.equals(port.pages.length);
  });
}
