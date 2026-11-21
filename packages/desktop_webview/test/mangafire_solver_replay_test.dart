// Replays MangaFire's browser behaviour offline through the desktop helper:
// the real solver page from the committed extension JAR, loaded the way
// keiyoushi's runWebViewBlocking does on its fallback path (user agent,
// cookies, page-start script, `window.bridge.postMessage(string)`,
// loadData with base URL https://mangafire.to/@waf/solver). Site responses
// come from a synthetic committed fixture; offline mode blocks anything else.
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
    final misses = <CaptureKey>[];
    final requests = <BrowserRequest>[];
    final BrowserRequestReplacer replay = browserCaptureReplayReplacer(
      captures,
      onMiss: (CaptureKey key, BrowserRequest _) => misses.add(key),
    );

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
    final Uri base = Uri.parse('https://mangafire.to/@waf/solver');

    check(await s.setUserAgent(_androidChromeUa)).isA<BrowserCompleted<void>>();
    check(
      await s.setRequestReplacer((BrowserRequest r) {
        requests.add(r);
        return replay(r);
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
