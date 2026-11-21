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

import 'dart:convert';
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
Future<(List<BundleRun>, MultiReplayHttpClient)> _replay(
  String site, {
  BrowserPort? port,
  http.Client Function(MultiReplayHttpClient replay)? wrap,
}) async {
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
      client: wrap == null ? client : wrap(client),
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

  test('MangaDex 0.8 (community 3.0.6) sets only a referer, and the host adds Paperback-iOS', () async {
    // Replay keys ignore headers, so this pins what the capture sent.
    final repo = PinnedRepository.load('community-0.8');
    final HostUnderTest h = await HostUnderTest.load(
      repo.bundle('MangaDex'),
      PaperbackApiFamily.v08,
      handler: (http.Request r) async => http.Response('{"result":"ok","data":[],"total":0}', 200),
    );
    try {
      await h.search(qualificationQuery);
      check(h.requests).isNotEmpty();
      for (final http.Request r in h.requests) {
        check(r.url.host).equals('api.mangadex.org');
        check(r.headers['user-agent']).equals('Paperback-iOS');
        check(r.headers['referer']).equals('https://mangadex.org/');
      }
    } finally {
      h.dispose();
    }
  });

  test('MangaDex 0.8 (community 3.0.6) searches, pages, fetches details and the complete chapter feed', () async {
    final (List<BundleRun> runs, MultiReplayHttpClient client) = await _replay('mangadex');
    check(client.misses).isEmpty();
    check(client.served.map((CaptureKey k) => k.url).where((String u) => u.contains('/edge/challenge'))).isEmpty();
    final BundleRun community = runs.firstWhere((BundleRun r) => r.family == PaperbackApiFamily.v08);
    final SearchPage page = _page(community);
    check(page.hits).length.equals(2);
    check(page.hits.first.ref.mangaId).equals('ed996855-70de-449f-bba2-e8e24224c14d');
    check(page.hits.first.title).equals('Onii-chan wa Oshimai!');
    check(page.nextCursor).equals('{"offset":100}');
    check((community.page2! as SourceSuccess<SearchPage>).value.hits).isEmpty();
    final MangaSnapshot s = _snapshot(community);
    check(s.metadata.authors).deepEquals(<String>['Nekotoufu']);
    check(s.metadata.status).equals(PublishingStatus.ongoing);
    _checkChapters(s, count: 223);
    check(s.chapters.first.chapterId).equals('3d1ff2d6-d917-4b81-b69e-44c41867e356');
    check(s.chapters.first.chapterNumber).equals(117);
    check(s.chapters.first.scanlators).deepEquals(<String>['daily multivitamin']);
    check(s.chapters.first.context['apiFamily']).equals('paperback-0.8');
    // Chapter identities are MangaDex's own, identical to the 0.9 bundle's.
    final MangaSnapshot inkdex = _snapshot(runs.firstWhere((BundleRun r) => r.family == PaperbackApiFamily.v09));
    check(<String>{for (final NativeChapter c in s.chapters) c.chapterId})
        .deepEquals(<String>{for (final NativeChapter c in inkdex.chapters) c.chapterId});
  });

  group('Mangahub 0.8 (kittycatgit 4.0.0, CLOUDFLARE_BYPASS_REQUIRED)', () {
    final repo = PinnedRepository.load('kittycatgit-0.8');
    MultiReplayHttpClient replay() =>
        MultiReplayHttpClient.load(<Directory>[Directory('${paperbackFixtures().path}/mangahub')]);

    test('searches, fetches details and chapters from the recorded (unchallenged) session', () async {
      final (List<BundleRun> runs, MultiReplayHttpClient client) = await _replay('mangahub');
      check(client.misses).isEmpty();
      final BundleRun run = runs.single;
      final SearchPage page = _page(run);
      check(page.hits).length.equals(11);
      check(page.nextCursor).isNull();
      // The first hit is another title; the scenario selects the Onimai hit by ID.
      check(page.hits.first.ref.mangaId).equals('oshimai');
      check(page.hits.map((SearchHit h) => h.ref.mangaId)).contains('onii-chan-wa-oshimai');
      check(run.detailsRef!.mangaId).equals('onii-chan-wa-oshimai');
      final MangaSnapshot s = _snapshot(run);
      check(s.ref.mangaId).equals('onii-chan-wa-oshimai');
      check(s.metadata.title).equals('Onii-Chan wa Oshimai');
      check(s.metadata.authors).deepEquals(<String>['Nekotoufu']);
      check(s.metadata.status).equals(PublishingStatus.ongoing);
      _checkChapters(s, count: 176);
      check(s.chapters.first.chapterId).equals('117');
      check(s.chapters.first.chapterNumber).equals(117);
    });

    test('the access token: header and cookie agree, and the site-issued token replaces the minted one', () async {
      // Captures do not keep Set-Cookie, so the site's `mhub_access` cookie is
      // added to the first replayed answer here.
      const issued = 'issuedtoken0123456789abcdef01234';
      final client = _Gate(replay(), issueToken: issued);
      final HostUnderTest h = await HostUnderTest.load(repo.bundle('Mangahub'), PaperbackApiFamily.v08, client: client);
      try {
        check((await h.search('Oshimai')).items).length.equals(11);
        await h.details('onii-chan-wa-oshimai');
        check(client.seen).length.equals(3);
        final tokens = <String>[];
        for (final http.BaseRequest r in client.seen) {
          final List<String> cookies = _cookies(r, 'mhub_access');
          check(cookies).length.equals(1);
          check(r.headers['x-mhub-access']).equals(cookies.single);
          tokens.add(cookies.single);
          // No clearance yet: the echoed default user agent is not sent.
          check(r.headers['user-agent']).isNull();
        }
        check(tokens.first).not((Subject<String> it) => it.equals(issued));
        check(tokens.skip(1).toSet()).deepEquals(<String>{issued});
      } finally {
        h.dispose();
      }
    });

    test('a challenge without a browser is interaction-required, not a source error', () async {
      final HostUnderTest h = await HostUnderTest.load(
        repo.bundle('Mangahub'),
        PaperbackApiFamily.v08,
        client: _Gate(replay(), challengeUntilCleared: true),
      );
      try {
        check(await _failureOf(h.search('Oshimai')))
            .isA<InteractionRequiredFailure>()
            .has((SourceFailure f) => f.message, 'message')
            .contains('CLOUDFLARE BYPASS ERROR');
      } finally {
        h.dispose();
      }
    });

    test('a challenge is bypassed through the browser port; search, details and chapters then replay', () async {
      const browserUa = 'ScriptedBrowser/1.0';
      final port = ScriptedBrowserPort(
        probe: (ScriptedPage page) => <String, Object?>{
          'challenged': page.state['solved'] != true,
          'userAgent': page.userAgent ?? browserUa,
        },
        onShow: (ScriptedPage page) {
          page.state['solved'] = true;
          page.cookies['cf_clearance'] = const BrowserCookie(name: 'cf_clearance', value: 'ok', domain: '.mangahub.io');
          // The browser's page visit got a token of its own.
          page.cookies['mhub_access'] = const BrowserCookie(
            name: 'mhub_access',
            value: 'browser',
            domain: 'mangahub.io',
          );
          return const BrowserCompleted<void>(null);
        },
      );
      final channel = InProcessBrowserChannel(
        port: port,
        source: SourceIdentity(
          ecosystem: 'paperback',
          packageId: 'kittycatgit',
          sourceId: 'Mangahub',
          artifact: ArtifactBinding(
            sha256: repo.pinnedSha256('Mangahub'),
            kind: PaperbackApiFamily.v08.artifactKind,
            version: '4.0.0',
          ),
        ),
        interactionTimeout: const Duration(seconds: 5),
      );
      final client = _Gate(replay(), challengeUntilCleared: true, browserUserAgent: browserUa);
      final HostUnderTest h = await HostUnderTest.load(
        repo.bundle('Mangahub'),
        PaperbackApiFamily.v08,
        client: client,
        browser: channel,
      );
      try {
        final PaperbackSearchPage page = await h.search('Oshimai');
        check(page.items).length.equals(11);
        final Map<String, Object?> details = await h.details('onii-chan-wa-oshimai');
        check((details['metadata']! as Map<String, Object?>)['title']).equals('Onii-Chan wa Oshimai');
        check(details['chapters']! as List<Object?>).length.equals(176);
        // One browser session, for the source's own bypass request.
        final ScriptedPage browser = port.pages.single;
        check(browser.loads.single.$1).equals(Uri.parse('https://mangahub.io'));
        check(browser.loads.single.$2).deepEquals(<String, String>{'referer': 'https://mangahub.io/'});
        check(browser.userAgent).isNull();
        check(port.closed).length.equals(1);
        // 1 challenged search, then the cleared search, details and chapters.
        check(client.challenged).equals(1);
        check(client.seen).length.equals(4);
        for (final http.BaseRequest r in client.seen.skip(1)) {
          check(r.headers['user-agent']).equals(browserUa);
          check(_cookies(r, 'cf_clearance')).deepEquals(<String>['ok']);
          // One token, the request's own (matching its header), not the browser's.
          check(r.headers['x-mhub-access']).equals(_cookies(r, 'mhub_access').single);
          check(_cookies(r, 'mhub_access').single).not((Subject<String> it) => it.equals('browser'));
        }
      } finally {
        h.dispose();
        await channel.close();
      }
    });

    test('worker path: a challenged search is interaction-required and the scenario stops there', () async {
      _Gate? gate;
      final (List<BundleRun> runs, MultiReplayHttpClient client) = await _replay(
        'mangahub',
        wrap: (MultiReplayHttpClient replay) => gate = _Gate(replay, challengeUntilCleared: true),
      );
      check(client.misses).isEmpty();
      final BundleRun run = runs.single;
      check(run.page1)
          .isA<SourceFailed<SearchPage>>()
          .has((SourceFailed<SearchPage> f) => f.failure, 'failure')
          .isA<InteractionRequiredFailure>();
      check(run.details).isNull();
      check(gate!.seen).length.equals(1);
    });

    test('worker path: the bypass runs over worker reverse requests and the scenario completes', () async {
      const browserUa = 'ScriptedBrowser/1.0';
      final port = ScriptedBrowserPort(
        probe: (ScriptedPage page) => <String, Object?>{
          'challenged': page.state['solved'] != true,
          'userAgent': page.userAgent ?? browserUa,
        },
        onShow: (ScriptedPage page) {
          page.state['solved'] = true;
          page.cookies['cf_clearance'] = const BrowserCookie(name: 'cf_clearance', value: 'ok', domain: '.mangahub.io');
          return const BrowserCompleted<void>(null);
        },
      );
      _Gate? gate;
      final (List<BundleRun> runs, MultiReplayHttpClient client) = await _replay(
        'mangahub',
        port: port,
        wrap: (MultiReplayHttpClient replay) =>
            gate = _Gate(replay, challengeUntilCleared: true, browserUserAgent: browserUa),
      );
      check(client.misses).isEmpty();
      final BundleRun run = runs.single;
      check(_page(run).hits).length.equals(11);
      _checkChapters(_snapshot(run), count: 176);
      // `show` was served under the supervisor's interaction timeout.
      check(port.pages.single.shown).equals(1);
      check(port.closed).length.equals(1);
      check(gate!.challenged).equals(1);
      for (final http.BaseRequest r in gate!.seen.skip(1)) {
        check(r.headers['user-agent']).equals(browserUa);
        check(_cookies(r, 'cf_clearance')).deepEquals(<String>['ok']);
      }
    });
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

Future<SourceFailure> _failureOf(Future<Object?> operation) async {
  try {
    await operation;
  } on PaperbackRuntimeException catch (e) {
    return e.failure;
  }
  throw StateError('The operation succeeded');
}

/// The values of cookie [name] in [r]'s `cookie` header.
List<String> _cookies(http.BaseRequest r, String name) => <String>[
  for (final String pair in (r.headers['cookie'] ?? '').split(';'))
    if (pair.trim().startsWith('$name=')) pair.trim().substring(name.length + 1),
];

/// Serves a committed capture, optionally as a Cloudflare-fronted site would:
/// with [challengeUntilCleared], every request is answered with a challenge
/// page until it carries the `cf_clearance` cookie and [browserUserAgent]
/// (the clearance is bound to the user agent that earned it). With
/// [issueToken], the first answer sets the `mhub_access` cookie, which a
/// capture cannot hold.
final class _Gate extends http.BaseClient {
  _Gate(this._inner, {this.challengeUntilCleared = false, this.browserUserAgent, this.issueToken});

  final http.Client _inner;
  final bool challengeUntilCleared;
  final String? browserUserAgent;
  final String? issueToken;
  final List<http.BaseRequest> seen = <http.BaseRequest>[];
  int challenged = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request);
    final bool cleared =
        _cookies(request, 'cf_clearance').isNotEmpty &&
        browserUserAgent != null &&
        request.headers['user-agent'] == browserUserAgent;
    if (challengeUntilCleared && !cleared) {
      challenged++;
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            '<!DOCTYPE html><html><head><title>Just a moment...</title></head><body> '
            '<script src="/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1"></script></body></html>',
          ),
        ),
        403,
        request: request,
        headers: <String, String>{'content-type': 'text/html', 'cf-mitigated': 'challenge'},
      );
    }
    final http.StreamedResponse r = await _inner.send(request);
    if (issueToken == null || seen.length != 1) return r;
    return http.StreamedResponse(
      r.stream,
      r.statusCode,
      request: request,
      headers: <String, String>{...r.headers, 'set-cookie': 'mhub_access=$issueToken; Path=/; Domain=mangahub.io'},
    );
  }
}
