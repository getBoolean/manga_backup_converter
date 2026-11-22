// Replays MangaFire's browser behaviour offline through the desktop helper:
// the real solver page from the committed extension JAR, loaded the way
// keiyoushi's runWebViewBlocking does on its fallback path (user agent,
// cookies, page-start script, `window.bridge.postMessage(string)`,
// loadData with base URL https://mangafire.to/@waf/solver). Site responses
// come from a synthetic committed fixture; offline mode blocks anything else.
//
// Engines without the replace tier (WKWebView) cannot answer requests for
// https://mangafire.to, so there the same page runs against a loopback
// server that serves the same fixture: the site origin and the OpenCV URL are
// rewritten to loopback. That variant checks the page's own script path on
// the engine (user agent, pushed cookie, page-start script, bridge channel,
// relative fetches), not the real origin.
@TestOn('vm')
// Each test starts real WebView2 processes; parallel test files slow them.
@Timeout.factor(4)
library;

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:checks/checks.dart';
import 'package:desktop_webview/desktop_webview.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import 'support/helper_fixture.dart';

const String _androidChromeUa =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

String _solverHtml() {
  final jar = File(
    p.join(
      repoRoot().path,
      'fixtures',
      'source_captures',
      'tachi',
      'all.mangafire',
      'tachiyomi-all.mangafire-v1.6.38.jar',
    ),
  );
  final Archive archive = ZipDecoder().decodeBytes(jar.readAsBytesSync());
  final ArchiveFile solver = archive.files.firstWhere((ArchiveFile f) => f.name == 'assets/solver.html');
  return String.fromCharCodes(solver.content);
}

Future<void> main() async {
  final File? helper = await builtHelper();
  if (helper == null) {
    test('MangaFire solver replay', () {}, skip: 'helper not built: $helperUnavailableReason');
    return;
  }

  test('MangaFire solver page completes through the window.bridge fallback offline', () async {
    final Directory dataRoot = await Directory.systemTemp.createTemp('dwv-mangafire-');
    final log = <String>[];
    final port = DesktopBrowserPort(testConfig(helper, dataRoot, log: log));
    addTearDown(() async {
      await port.dispose();
      try {
        await dataRoot.delete(recursive: true);
      } on FileSystemException {
        // Browser process still releasing the directory.
      }
    });
    final CaptureSet captures = loadCaptureSet(
      Directory(p.join(packageDir().path, 'test', 'fixtures', 'mangafire_solver')),
    );
    final replay = BrowserCaptureReplay(captures);
    final List<CaptureKey> misses = replay.misses;
    final requests = <BrowserRequest>[];

    final BrowserOutcome<BrowserSession> opened = await port.openSession(
      const BrowserSessionRequest(
        source: SourceIdentity(
          ecosystem: 'tachi',
          packageId: 'eu.kanade.tachiyomi.extension.all.mangafire',
          sourceId: '1',
          artifact: ArtifactBinding(
            sha256: 'dacbcbb39c3e5a37fd64110142f277151213c1331d424b446de87b5155c62a5f',
            kind: 'jar',
            version: '1.6.38',
          ),
        ),
        generation: 1,
      ),
    );
    final s = opened.valueOrNull! as DesktopBrowserSession;
    if (!s.capabilities.supports(BrowserFeature.replaceRequests)) {
      await _loopbackVariant(s, captures);
      return;
    }
    final Uri base = Uri.parse('https://mangafire.to/@waf/solver');

    check(await s.setUserAgent(_androidChromeUa)).isA<BrowserCompleted<void>>();
    check(
      await s.setRequestReplacer((BrowserRequest r) {
        requests.add(r);
        return replay.serve(r) ?? BrowserReplacement(status: 599, reason: 'No committed capture');
      }),
    ).isA<BrowserCompleted<void>>();
    check(
      await s.setCookie(Uri.parse('https://mangafire.to/'), const BrowserCookie(name: 'pushed', value: 'from-jar')),
    ).isA<BrowserCompleted<void>>();
    check(await s.addPageStartScript('window.__pageStart = document.readyState;')).isA<BrowserCompleted<void>>();
    final message = Completer<String>();
    check(await s.setMessageHandler('bridge', message.complete)).isA<BrowserCompleted<void>>();

    final BrowserOutcome<BrowserPage> loaded = await s.loadData(_solverHtml(), baseUrl: base);
    check(loaded).isA<BrowserCompleted<BrowserPage>>();
    check(loaded.valueOrNull!.finalUrl).equals(base);

    // Every solve throws on the fixture's three shapes, so the page reports
    // `${complete}` == "false" through the bridge.
    check(await message.future.timeout(const Duration(seconds: 30))).equals('false');

    check((await s.evaluate('location.href')).valueOrNull).equals('"$base"');
    check((await s.evaluate('window.__pageStart')).valueOrNull).equals('"loading"');
    check((await s.evaluate('navigator.userAgent')).valueOrNull).equals('"$_androidChromeUa"');
    check((await s.evaluate('document.cookie')).valueOrNull!).contains('pushed=from-jar');

    final List<BrowserRequest> generate = requests.where((BrowserRequest r) => r.url.path == '/@waf/generate').toList();
    check(generate).isNotEmpty();
    check(requests.where((BrowserRequest r) => r.url.host == 'docs.opencv.org')).isNotEmpty();
    // Chromium client hints reach the observe/replace tier on WebView2.
    if (port.helperInfo!.capabilities.requestObserve == 'all') {
      check(generate.first.headers.keys.map((String k) => k.toLowerCase())).contains('sec-ch-ua');
      check(generate.first.headers['User-Agent']).equals(_androidChromeUa);
    }
    // Only the browser's own favicon probe may be missing from the fixture.
    check(misses.where((CaptureKey k) => !k.url.endsWith('/favicon.ico'))).isEmpty();
    check(await s.close()).isA<BrowserCompleted<void>>();
  });
}

/// The fixture served from a loopback server, by path (see the header).
Future<void> _loopbackVariant(DesktopBrowserSession s, CaptureSet captures) async {
  check(s.capabilities.reasonFor(BrowserFeature.replaceRequests)).isNotNull().isNotEmpty();
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final served = <String, CapturedResponse>{
    for (final CaptureExchange e in captures.manifest.exchanges) Uri.parse(e.key.url).path: captures.lookup(e.key),
  };
  final seen = <(String, String?)>[];
  server.listen((HttpRequest r) async {
    seen.add((r.uri.path, r.headers.value(HttpHeaders.userAgentHeader)));
    final CapturedResponse? response = served[r.uri.path];
    if (response == null) {
      r.response.statusCode = HttpStatus.notFound;
    } else {
      r.response.statusCode = response.status;
      response.headers.forEach(r.response.headers.set);
      r.response.add(response.body);
    }
    await r.response.close();
  });
  final origin = 'http://127.0.0.1:${server.port}';
  final Uri base = Uri.parse('$origin/@waf/solver');
  final String html = _solverHtml().replaceAll('https://docs.opencv.org/', '$origin/');
  check(html).contains('$origin/5.0/opencv.js');

  check(await s.setUserAgent(_androidChromeUa)).isA<BrowserCompleted<void>>();
  check(await s.setCookie(Uri.parse('$origin/'), const BrowserCookie(name: 'pushed', value: 'from-jar')))
      .isA<BrowserCompleted<void>>();
  check(await s.addPageStartScript('window.__pageStart = document.readyState;')).isA<BrowserCompleted<void>>();
  final message = Completer<String>();
  check(await s.setMessageHandler('bridge', message.complete)).isA<BrowserCompleted<void>>();

  final BrowserOutcome<BrowserPage> loaded = await s.loadData(html, baseUrl: base);
  check(loaded).isA<BrowserCompleted<BrowserPage>>();
  check(loaded.valueOrNull!.finalUrl).equals(base);
  check(await message.future.timeout(const Duration(seconds: 30))).equals('false');

  check((await s.evaluate('location.href')).valueOrNull).equals('"$base"');
  check((await s.evaluate('window.__pageStart')).valueOrNull).equals('"loading"');
  check((await s.evaluate('navigator.userAgent')).valueOrNull).equals('"$_androidChromeUa"');
  check((await s.evaluate('document.cookie')).valueOrNull!).contains('pushed=from-jar');
  final List<(String, String?)> generate = seen.where(((String, String?) e) => e.$1 == '/@waf/generate').toList();
  check(generate).isNotEmpty();
  check(generate.first.$2).equals(_androidChromeUa);
  check(seen.map(((String, String?) e) => e.$1)).contains('/5.0/opencv.js');
  check(await s.close()).isA<BrowserCompleted<void>>();
}
