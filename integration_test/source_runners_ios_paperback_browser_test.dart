// U10 iOS device cases: local Paperback execution in an in-app worker isolate
// (QuickJS-ng built for iOS) and the WKWebView BrowserPort (KTD13, KTD20).
// U9's Tachi cases live in source_runners_ios_test.dart on its own branch.
//
// Run on an iOS Simulator (evidence is labelled "simulator"):
//
//   flutter test integration_test/source_runners_ios_paperback_browser_test.dart \
//     -d <udid> --dart-define=SRT_REPO_ROOT=$PWD [--dart-define=SRT_BENCH=true]
//
// The Paperback cases replay the committed captures under
// fixtures/source_captures/paperback/, read from SRT_REPO_ROOT on the host
// filesystem (the Simulator shares it), so no capture or bundle is ever
// packaged into the app. A physical iPhone needs another, still test-only,
// delivery of those files (see docs/validation/source-runners/ios/README.md).
// No case contacts a server: Paperback HTTP is served from captures and every
// WKWebView session in these tests runs with a content rule list that blocks
// all network loads except the loopback server the test itself starts.
// ignore_for_file: do_not_use_environment, avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_ios/source_runtime_ios.dart';
import 'package:source_runtime_testing/source_runtime_testing.dart';

import '../packages/paperback_plugin_loader/benchmark/bundle_benchmark.dart';
import '../packages/paperback_plugin_loader/test/support/in_app_support.dart';
import '../packages/paperback_plugin_loader/test/support/paperback_scenarios.dart';

const String _repoRoot = String.fromEnvironment('SRT_REPO_ROOT');
const bool _bench = bool.fromEnvironment('SRT_BENCH');
const bool _manual = bool.fromEnvironment('SRT_MANUAL');

final Map<String, Object?> _report = <String, Object?>{
  'unit': 'U10',
  'evidence': Platform.resolvedExecutable.contains('/CoreSimulator/')
      ? 'simulator'
      : 'physical-device',
  'os': Platform.operatingSystemVersion,
  'dart': Platform.version,
  'locale': Platform.localeName,
};

void _record(String key, Object? value) {
  _report[key] = value;
  print('SRT_U10 $key ${jsonEncode(value)}');
}

const SupervisorLimits _supervisorLimits = SupervisorLimits(
  maxConcurrentPackages: 1,
  operationDeadline: Duration(minutes: 15),
  cancelGrace: Duration(seconds: 5),
  interactionTimeout: Duration(seconds: 5),
  shutdownGrace: Duration(seconds: 5),
);

PaperbackRuntimeLimits _limits({
  Duration deadline = const Duration(minutes: 15),
}) => PaperbackRuntimeLimits(
  memoryLimitBytes: 64 * 1024 * 1024,
  maxStackBytes: 256 * 1024,
  operationDeadline: deadline,
  jobSlice: const Duration(milliseconds: 5),
);

// --- loopback server for the browser cases ----------------------------------------

/// Pages the browser cases load: one origin on port A, a second origin on
/// port B (cross-origin frames). Nothing leaves the device.
final class _Server {
  _Server._(this._a, this._b) {
    for (final s in <HttpServer>[_a, _b]) {
      // dart:io sends X-Frame-Options: SAMEORIGIN by default, which would
      // keep the cross-origin frame from loading at all.
      s.defaultResponseHeaders.clear();
      s.listen(_serve);
    }
  }

  static Future<_Server> start() async => _Server._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  final HttpServer _a;
  final HttpServer _b;
  final List<Completer<void>> _held = <Completer<void>>[];

  /// Request headers of the last request per path (lower-case names).
  final Map<String, Map<String, String>> lastHeaders =
      <String, Map<String, String>>{};

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_a.port}$path');

  Uri otherOrigin(String path) => Uri.parse('http://127.0.0.1:${_b.port}$path');

  /// A port nothing listens on.
  Future<Uri> closedPortUrl() async {
    final HttpServer s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final int port = s.port;
    await s.close(force: true);
    return Uri.parse('http://127.0.0.1:$port/gone');
  }

  bool _released = false;

  /// Answers every held request, and every later one until [hold].
  void release() {
    _released = true;
    for (final Completer<void> c in _held) {
      if (!c.isCompleted) c.complete();
    }
    _held.clear();
  }

  /// Holds `/held` requests again.
  void hold() => _released = false;

  static const String _frameScript = '''
<script>
window.addEventListener('message', function (e) {
  var d = e.data;
  if (!d || typeof d.name !== 'string') return;
  try { window[d.name].postMessage(d.msg); } catch (x) {}
  parent.postMessage('posted', '*');
});
</script>''';

  Future<void> _serve(HttpRequest request) async {
    final HttpResponse r = request.response;
    final String path = request.uri.path;
    final headers = <String, String>{};
    request.headers.forEach(
      (String name, List<String> values) =>
          headers[name.toLowerCase()] = values.join(', '),
    );
    lastHeaders[path] = headers;
    final String body = await utf8.decoder.bind(request).join();
    void html(String text, {int status = 200}) {
      r.statusCode = status;
      r.headers.contentType = ContentType.html;
      r.write(text);
    }

    switch (path) {
      case '/page':
        html(
          '<html><head><title>contract</title></head><body>contract</body></html>',
        );
      case '/to-file':
        r.statusCode = 302;
        r.headers.set('location', 'file:///etc/passwd');
      case '/framed':
        html(
          '<html><head><title>framed</title><script>${_WkHarness.crossOriginHelper}</script></head><body>'
          '<iframe src="${otherOrigin('/frame')}"></iframe></body></html>',
        );
      case '/same-framed':
        html(
          '<html><head><title>framed</title></head><body><iframe src="/frame"></iframe></body></html>',
        );
      case '/frame':
        html(
          '<html><head><title>frame</title>$_frameScript</head><body>frame</body></html>',
        );
      case '/echo':
        r.headers.set('access-control-allow-origin', '*');
        r.headers.contentType = ContentType.text;
        r.write('${request.method} $body');
      case '/held':
        if (!_released) {
          final c = Completer<void>();
          _held.add(c);
          await c.future;
        }
        r.headers.contentType = ContentType.text;
        r.write('released');
      case '/set-cookie':
        r.headers.set('set-cookie', 'srv=from-server; Path=/');
        html(
          '<html><head><title>cookie</title></head><body>cookie</body></html>',
        );
      case '/echo-cookie':
        r.headers.contentType = ContentType.text;
        r.write(request.headers.value('cookie') ?? '');
      case '/bytes':
        r.headers.contentType = ContentType.binary;
        r.headers.set('access-control-allow-origin', '*');
        r.add(List<int>.generate(256, (int i) => i));
      case '/utf8':
        r.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
        r.write(
          '<html><head><title>Onimai — お兄ちゃんはおしまい！</title></head><body>ÄÖÜ 漢字 🙂</body></html>',
        );
      case '/missing':
        html('<html><head><title>missing</title></head></html>', status: 404);
      default:
        html('<html></html>', status: 404);
    }
    await r.close();
  }

  Future<void> close() async {
    release();
    await _a.close(force: true);
    await _b.close(force: true);
  }
}

late _Server _server;

/// The hosts the offline content rule list lets through: only this test's
/// loopback server.
const Set<String> _loopback = <String>{'127.0.0.1'};

WKWebViewBrowserPort _port({bool allowInteraction = false}) =>
    WKWebViewBrowserPort(
      config: WKWebViewBrowserConfig(
        allowInteraction: allowInteraction,
        offlineAllowedHosts: _loopback,
        storageDeletionTimeout: const Duration(seconds: 10),
        onLog: print,
      ),
    );

final class _WkHarness implements BrowserPortHarness {
  WKWebViewBrowserPort? _current;

  @override
  Future<BrowserPort> start() async {
    _server.hold();
    return _current = _port();
  }

  @override
  Future<void> kill() async => _current?.debugAbandon();

  @override
  Future<void> stop() async {
    _server.release();
    await _current?.dispose();
    _current = null;
  }

  @override
  Uri get pageUrl => _server.url('/page');

  @override
  Uri get redirectToFileUrl => _server.url('/to-file');

  @override
  bool get canShowInteraction => false;

  @override
  String heldScript(String resultJson) =>
      'fetch("/held").then(function (r) { return r.text(); }).then(function () { return $resultJson; })';

  @override
  Future<void> releaseHeld() async => _server.release();

  @override
  Uri get crossOriginFramePageUrl => _server.url('/framed');

  @override
  String crossOriginFramePostScript(String name, String message) => '''
crossOriginFramePost(${jsonEncode(name)}, ${jsonEncode(message)})''';

  /// Defines `crossOriginFramePost` in the page: asks the child frame to
  /// post until it acknowledges (it may still be starting), and settles
  /// `true` once it has made the call, or `false` after 5 s.
  static const String crossOriginHelper = '''
window.crossOriginFramePost = function (name, msg) {
  return new Promise(function (resolve) {
    var done = false;
    window.addEventListener('message', function h(e) {
      if (e.data === 'posted' && !done) { done = true; window.removeEventListener('message', h); resolve(true); }
    });
    var tries = 0;
    (function send() {
      if (done) return;
      if (tries++ > 50) { done = true; resolve(false); return; }
      var f = document.querySelector('iframe');
      if (f && f.contentWindow) f.contentWindow.postMessage({name: name, msg: msg}, '*');
      setTimeout(send, 100);
    })();
  });
};''';

  @override
  Uri get sameOriginFramePageUrl => _server.url('/same-framed');

  @override
  Uri get sameOriginFrameUrl => _server.url('/frame');

  @override
  Uri get echoUrl => _server.url('/echo');
}

SourceIdentity _source(String id, {String ecosystem = 'paperback'}) =>
    SourceIdentity(
      ecosystem: ecosystem,
      packageId: 'u10.$id',
      sourceId: id,
      artifact: const ArtifactBinding(sha256: '00', kind: 'test', version: '1'),
    );

Future<WKWebViewBrowserSession> _open(
  WKWebViewBrowserPort port,
  String id, {
  int generation = 1,
  String? ua,
}) async {
  final BrowserOutcome<BrowserSession> opened = await port.openSession(
    BrowserSessionRequest(
      source: _source(id),
      generation: generation,
      userAgent: ua,
    ),
  );
  expect(opened, isA<BrowserCompleted<BrowserSession>>());
  return opened.valueOrNull! as WKWebViewBrowserSession;
}

Future<void> _waitUntil(
  bool Function() condition,
  String what, {
  Duration bound = const Duration(seconds: 10),
}) async {
  final DateTime deadline = DateTime.now().add(bound);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _server = await _Server.start();
    _record('platformThread', ui.isRunningOnPlatformThread);
    _record(
      'wkwebviewUnavailableReason',
      WKWebViewBrowserPort.unavailableReason,
    );
    _record('capabilities', wkWebViewCapabilities.toJson());
  });

  tearDownAll(() async {
    await _server.close();
    binding.reportData = _report;
    print('SRT_U10_REPORT ${jsonEncode(_report)}');
  });

  group('QuickJS on iOS', () {
    test('the vendored QuickJS-ng library loads and evaluates on the root and a worker isolate', () async {
      final runtime = JsRuntime();
      final sum =
          (runtime.newContext().toDart(runtime.newContext().eval('6 * 7')) ?? 0)
              as int;
      runtime.dispose();
      expect(sum, 42);
      final Map<String, Object?> worker = await Isolate.run(() {
        final r = JsRuntime();
        final JsContext c = r.newContext();
        final Object? v = c.toDart(c.eval('[1,2,3].map(x => x * 2).join(",")'));
        r.dispose();
        return <String, Object?>{
          'value': v,
          'threadStack': QuickJs.threadStackAvailable(),
        };
      });
      expect(worker['value'], '2,4,6');
      _record('quickjsSmoke', <String, Object?>{
        'rootThreadStack': QuickJs.threadStackAvailable(),
        'workerThreadStack': worker['threadStack'],
        'physicalMemory': QuickJs.physicalMemory(),
        'processors': Platform.numberOfProcessors,
      });
    });

    test(
      'KTD25: limits derived on this device from a worker isolate measurement',
      () async {
        final PaperbackWorkerPlan plan = await planPaperbackIsolateWorker();
        _record('sizing', <String, Object?>{
          ...plan.sizing.toJson(),
          'deadlineHeadroomMicros': plan.deadlineHeadroom.inMicroseconds,
          'cancelGraceMicros': plan.cancelGrace.inMicroseconds,
        });
        expect(
          plan.sizing.limits.maxStackBytes,
          lessThan(plan.sizing.device.threadStackBytes ?? 1 << 40),
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'KTD25 benchmark: real bundles on this device (provisional, simulator)',
      () async {
        const fixtures = '$_repoRoot/fixtures/source_captures/paperback';
        final Map<String, Object?> report = await Isolate.run(
          () => runBundleBenchmark(fixtures, runs: 3),
          debugName: 'paperback-benchmark',
        );
        _record('benchmark', report);
      },
      skip: _bench ? false : 'Benchmark runs only with --dart-define=SRT_BENCH=true (takes several minutes)',
      timeout: const Timeout(Duration(minutes: 60)),
    );
  });

  group('Paperback in an in-app worker isolate (AE4, AE7)', () {
    setUpAll(() {
      if (_repoRoot.isEmpty) {
        fail(
          'Pass --dart-define=SRT_REPO_ROOT=<repository root> (host path, Simulator)',
        );
      }
      Directory.current = _repoRoot;
    });

    test('WeebCentral: 0.9 and both 0.8 bundles search, fetch details and chapters', () async {
      final InAppSiteRun run = await runSiteInIsolate(
        'weebcentral',
        limits: _limits(),
        supervisorLimits: _supervisorLimits,
      );
      _record('weebcentral', <Object?>[
        for (final BundleRun r in run.runs) r.toJson(),
      ]);
      expect(run.misses, isEmpty);
      expect(
        run.runs.map((BundleRun r) => r.family).toList(),
        <PaperbackApiFamily>[
          PaperbackApiFamily.v09,
          PaperbackApiFamily.v08,
          PaperbackApiFamily.v08,
        ],
      );
      for (final BundleRun r in run.runs) {
        final SearchPage page = (r.page1! as SourceSuccess<SearchPage>).value;
        expect(page.hits.first.ref.mangaId, '01J76XYF0TGKQ7XJ4XVPV1C0BP');
        expect(page.hits.first.title, "ONIMAI - I'm Now Your Sister!");
        final MangaSnapshot s =
            (r.details! as SourceSuccess<MangaSnapshot>).value;
        expect(s.metadata.authors, <String>['Nekotoufu']);
        expect(s.chapters, hasLength(114));
        expect(s.chapters.first.chapterId, '01KWM07QYFJMAP46S1A3ZVDWYG');
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('MangaDex: 0.9 completes the JSON chapter feed; 0.8 meets the recorded challenge visibly', () async {
      final InAppSiteRun run = await runSiteInIsolate(
        'mangadex',
        limits: _limits(),
        supervisorLimits: _supervisorLimits,
      );
      _record('mangadex', <Object?>[
        for (final BundleRun r in run.runs) r.toJson(),
      ]);
      expect(run.misses, isEmpty);
      final BundleRun inkdex = run.runs.firstWhere(
        (BundleRun r) => r.family == PaperbackApiFamily.v09,
      );
      final MangaSnapshot s =
          (inkdex.details! as SourceSuccess<MangaSnapshot>).value;
      expect(s.metadata.title, "ONIMAI: I'm Now Your Sister!");
      expect(s.chapters, hasLength(223));
      final BundleRun neihc = run.runs.firstWhere(
        (BundleRun r) => r.family == PaperbackApiFamily.v08,
      );
      expect(neihc.page1, isA<SourceFailed<SearchPage>>());
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('AE11: MangaFire 0.9 executeInWebView runs on WKWebView (offline replay; outcome recorded)', () async {
      final port = WKWebViewBrowserPort(
        config: const WKWebViewBrowserConfig(
          allowInteraction: false,
          // Block every network load: the page's own scripts would reach
          // mangafire.to, and tests never contact a server.
          offlineAllowedHosts: <String>{},
          storageDeletionTimeout: Duration(seconds: 10),
          onLog: print,
        ),
      );
      try {
        final InAppSiteRun run = await runSiteInIsolate(
          'mangafire',
          limits: _limits(deadline: const Duration(minutes: 2)),
          supervisorLimits: _supervisorLimits,
          port: port,
        );
        final BundleRun r = run.runs.single;
        _record('mangafire', <String, Object?>{
          ...r.toJson(),
          'served': run.served,
          'browserLog': <String>[
            for (final String l in run.log)
              if (l.contains('wkwebview') || l.contains('browser')) l,
          ],
          'sessionsLeftOpen': port.sessions.length,
        });
        expect(run.misses, isEmpty);
        // A named failure, never an empty success; every session closed.
        expect(r.page1, isA<SourceFailed<SearchPage>>());
        expect(port.sessions, isEmpty);
      } finally {
        await port.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    for (final mode in <String>['sync', 'jobs']) {
      test(
        'a $mode JS loop ends at the native deadline while the worker isolate is blocked',
        () async {
          final IsolateWorkerHarness h = await IsolateWorkerHarness.start(
            PaperbackIsolateWorkerConfig(
              limits: _limits(deadline: const Duration(milliseconds: 400)),
              clientFactory: () => LoggingReplayClient(const <String>[]),
              adapterFactory: (_, _, _) => const LoopingAdapter(),
            ),
          );
          await h.handshake();
          expect((await h.loadLoopPackage()).error, isNull);
          final watch = Stopwatch()..start();
          final String id = h.search(mode);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          h.cancel(id);
          final ProtocolFrame reply = await h
              .reply(id)
              .timeout(const Duration(seconds: 10));
          watch.stop();
          final code = reply.error!['code']! as String;
          _record('loop-$mode', <String, Object?>{
            'code': code,
            'elapsedMs': watch.elapsedMilliseconds,
          });
          if (mode == 'sync') expect(code, 'timeout');
          expect(<String>{'timeout', 'cancelled'}, contains(code));
          final ProtocolFrame next = await h
              .reply(h.search('again'))
              .timeout(const Duration(seconds: 10));
          expect(next.ok!['warnings'], <String>['ok:again']);
          expect(await h.shutdown(), 0);
        },
      );
    }

    test('kill stops a JS loop from the root isolate through the adopted interrupt token', () async {
      final IsolateWorkerHarness h = await IsolateWorkerHarness.start(
        PaperbackIsolateWorkerConfig(
          limits: _limits(deadline: const Duration(minutes: 5)),
          clientFactory: () => LoggingReplayClient(const <String>[]),
          adapterFactory: (_, _, _) => const LoopingAdapter(),
        ),
      );
      await h.handshake();
      expect((await h.loadLoopPackage()).error, isNull);
      h.search('sync');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final watch = Stopwatch()..start();
      expect(h.process.kill(), isTrue);
      final int exit = await h.process.exitCode.timeout(
        const Duration(seconds: 10),
      );
      watch.stop();
      _record('kill', <String, Object?>{
        'exit': exit,
        'elapsedMs': watch.elapsedMilliseconds,
      });
      expect(exit, -9);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test(
      'a host call that never completes is bounded by the deadline',
      () async {
        final IsolateWorkerHarness h = await IsolateWorkerHarness.start(
          PaperbackIsolateWorkerConfig(
            limits: _limits(deadline: const Duration(milliseconds: 300)),
            clientFactory: () => LoggingReplayClient(const <String>[]),
            adapterFactory: (_, _, _) => const LoopingAdapter(),
          ),
        );
        await h.handshake();
        expect((await h.loadLoopPackage()).error, isNull);
        final ProtocolFrame reply = await h
            .reply(h.search('host'))
            .timeout(const Duration(seconds: 10));
        expect(reply.error!['code'], 'timeout');
        expect(await h.shutdown(), 0);
      },
    );
  });

  group('WKWebView BrowserPort', () {
    group('contract', () {
      runBrowserPortContractSuite('WKWebView (iOS)', _WkHarness.new);
    });

    test('AE8: creation on the platform thread, completion with status, and navigation failure', () async {
      final WKWebViewBrowserPort port = _port();
      try {
        expect(ui.isRunningOnPlatformThread, isTrue);
        final WKWebViewBrowserSession s = await _open(port, 'a');
        final BrowserOutcome<BrowserPage> ok = await s.loadUrl(
          _server.url('/page'),
        );
        expect(ok.valueOrNull?.statusCode, 200);
        final BrowserOutcome<BrowserPage> missing = await s.loadUrl(
          _server.url('/missing'),
        );
        expect(missing.valueOrNull?.statusCode, 404);
        final Uri gone = await _server.closedPortUrl();
        final BrowserOutcome<BrowserPage> failed = await s.loadUrl(gone);
        expect(failed, isA<BrowserNavigationFailed<BrowserPage>>());
        // Offline rule list: a non-loopback host is blocked, never fetched.
        final BrowserOutcome<BrowserPage> blocked = await s.loadUrl(
          Uri.parse('https://example.com/'),
        );
        expect(blocked, isA<BrowserNavigationFailed<BrowserPage>>());
        _record('ae8-navigation', <String, Object?>{
          'missing': '${missing.valueOrNull?.statusCode}',
          'closedPort': '$failed',
          'offlineBlocked': '$blocked',
        });
        expect(s.pendingOperations, 0);
        expect(await s.close(), isA<BrowserCompleted<void>>());
      } finally {
        await port.dispose();
      }
    });

    test('the cross-origin child frame runs and acknowledges, so the origin-rule drop is real', () async {
      final WKWebViewBrowserPort port = _port();
      try {
        final WKWebViewBrowserSession s = await _open(port, 'a');
        // Registered before the load, so the child frame has the channel
        // object too and really calls it.
        final messages = <String>[];
        await s.setMessageHandler('bridge', messages.add);
        expect(
          await s.loadUrl(_server.url('/framed')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        final BrowserOutcome<String> posted = await s.evaluate(
          _WkHarness().crossOriginFramePostScript(
            'bridge',
            'from-cross-origin-frame',
          ),
        );
        await s.evaluate(
          BrowserMessageChannel.postScript('bridge', 'same-origin'),
        );
        await _waitUntil(
          () => messages.contains('same-origin'),
          'the same-origin marker',
        );
        _record('cross-origin-frame', <String, Object?>{
          'acknowledged': '$posted',
          'delivered': messages,
        });
        expect(posted.valueOrNull, 'true');
        expect(messages, <String>['same-origin']);
        await s.close();
      } finally {
        await port.dispose();
      }
    });

    test('AE8: a visible interaction completes on user dismissal, or times out, and settles once', () async {
      final WKWebViewBrowserPort port = _port(allowInteraction: true);
      try {
        final WKWebViewBrowserSession s = await _open(port, 'a');
        expect(
          await s.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        final Future<BrowserOutcome<void>> shown = s.showForInteraction(
          timeout: const Duration(seconds: 30),
        );
        await _waitUntil(() => s.isShowingInteraction, 'the sheet to present');
        await Future<void>.delayed(
          const Duration(seconds: 2),
        ); // visible on the device for the record
        await s.debugUserDismiss();
        final BrowserOutcome<void> first = await shown;
        expect(first, isA<BrowserCompleted<void>>());
        await s.debugUserDismiss(); // a late second dismissal changes nothing
        expect(await shown, same(first));

        final BrowserOutcome<void> timedOut = await s.showForInteraction(
          timeout: const Duration(seconds: 1),
        );
        expect(timedOut, isA<BrowserInteractionRequired<void>>());
        expect(s.isShowingInteraction, isFalse);

        final cancel = CancellationSource();
        final Future<BrowserOutcome<void>> cancelled = s.showForInteraction(
          timeout: const Duration(seconds: 30),
          cancel: cancel.token,
        );
        await _waitUntil(
          () => s.isShowingInteraction,
          'the sheet to present again',
        );
        cancel.cancel('operation deadline');
        expect(await cancelled, isA<BrowserCancelled<void>>());
        _record('ae8-interaction', <String, Object?>{
          'dismissed': '$first',
          'timeout': '$timedOut',
        });
        await s.close();
      } finally {
        await port.dispose();
      }
    });

    test(
      'AE8 (manual): a real swipe-down of the presented sheet completes the interaction',
      () async {
        final WKWebViewBrowserPort port = _port(allowInteraction: true);
        try {
          final WKWebViewBrowserSession s = await _open(port, 'a');
          expect(
            await s.loadUrl(_server.url('/utf8')),
            isA<BrowserCompleted<BrowserPage>>(),
          );
          final Future<BrowserOutcome<void>> shown = s.showForInteraction(
            timeout: const Duration(seconds: 120),
          );
          await _waitUntil(
            () => s.isShowingInteraction,
            'the sheet to present',
          );
          _record('manual-sheet', 'presented');
          final BrowserOutcome<void> outcome = await shown;
          _record('manual-sheet-outcome', '$outcome');
          expect(outcome, isA<BrowserCompleted<void>>());
          await s.close();
        } finally {
          await port.dispose();
        }
      },
      skip: _manual ? false : 'Needs a person or device automation to swipe the sheet (--dart-define=SRT_MANUAL=true)',
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'AE8 (manual): real app backgrounding through the Flutter lifecycle',
      () async {
        final WKWebViewBrowserPort port = _port()..bindToAppLifecycle();
        try {
          final WKWebViewBrowserSession s = await _open(port, 'a');
          expect(
            await s.loadUrl(_server.url('/page')),
            isA<BrowserCompleted<BrowserPage>>(),
          );
          _server.hold();
          final Future<BrowserOutcome<String>> held = s.evaluate(
            _WkHarness().heldScript('"late"'),
          );
          _record('manual-background', 'waiting');
          await _waitUntil(
            () => port.isBackgrounded,
            'the app to enter the background',
            bound: const Duration(seconds: 90),
          );
          final BrowserOutcome<String> cancelled = await held;
          await _waitUntil(
            () => !port.isBackgrounded,
            'the app to return',
            bound: const Duration(seconds: 90),
          );
          _server.release();
          final BrowserOutcome<BrowserPage> resumed = await s.loadUrl(
            _server.url('/page'),
          );
          _record('manual-background-outcome', <String, String>{
            'pending': '$cancelled',
            'afterForeground': '$resumed',
          });
          expect(cancelled, isA<BrowserCancelled<String>>());
          expect(resumed, isA<BrowserCompleted<BrowserPage>>());
          await s.close();
        } finally {
          await port.dispose();
        }
      },
      skip: _manual ? false : 'Needs device automation to background the app (--dart-define=SRT_MANUAL=true)',
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test('AE8: backgrounding cancels pending work once, refuses new work, and resumes in the foreground', () async {
      final WKWebViewBrowserPort port = _port();
      try {
        final WKWebViewBrowserSession s = await _open(port, 'a');
        expect(
          await s.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        _server.hold();
        final Future<BrowserOutcome<String>> held = s.evaluate(
          _WkHarness().heldScript('"late"'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        port.setBackgrounded(true);
        expect(await held, isA<BrowserCancelled<String>>());
        expect(
          await s.loadUrl(_server.url('/page')),
          isA<BrowserCancelled<BrowserPage>>(),
        );
        expect(await s.evaluate('1'), isA<BrowserCancelled<String>>());
        // The held fetch completes now; its late callback is discarded.
        _server.release();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(await held, isA<BrowserCancelled<String>>());
        port.setBackgrounded(false);
        expect(
          await s.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        expect((await s.evaluate('1 + 1')).valueOrNull, '2');
        expect(s.pendingOperations, 0);
        await s.close();
      } finally {
        await port.dispose();
      }
    });

    test('AE8: late callbacks after supersession, close and fencing settle the right operation once', () async {
      final WKWebViewBrowserPort port = _port();
      try {
        final WKWebViewBrowserSession s = await _open(port, 'a');
        final Future<BrowserOutcome<BrowserPage>> first = s.loadUrl(
          _server.url('/page'),
        );
        final Future<BrowserOutcome<BrowserPage>> second = s.loadUrl(
          _server.url('/utf8'),
        );
        expect(await first, isA<BrowserCancelled<BrowserPage>>());
        expect((await second).valueOrNull?.finalUrl, _server.url('/utf8'));

        _server.hold();
        final Future<BrowserOutcome<String>> pendingEval = s.evaluate(
          _WkHarness().heldScript('1'),
        );
        final Future<BrowserOutcome<BrowserPage>> pendingLoad = s.loadUrl(
          _server.url('/page'),
        );
        final messages = <String>[];
        await s.setMessageHandler('bridge', messages.add);
        final BrowserOutcome<void> closed = await s.close();
        expect(closed, isA<BrowserCompleted<void>>());
        expect(await pendingEval, isA<BrowserCancelled<String>>());
        expect(await pendingLoad, isA<BrowserCancelled<BrowserPage>>());
        _server.release();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(messages, isEmpty);
        expect(s.pendingOperations, 0);
        expect(await s.evaluate('1'), isA<BrowserCancelled<String>>());

        final WKWebViewBrowserSession old = await _open(port, 'b');
        await port.fence(2);
        expect(old.isClosed, isTrue);
        expect(
          await old.loadUrl(_server.url('/page')),
          isA<BrowserCancelled<BrowserPage>>(),
        );
      } finally {
        await port.dispose();
      }
    });

    test('cookies, user agent, language, binary and UTF-8 stay consistent and per source', () async {
      final WKWebViewBrowserPort port = _port();
      try {
        final WKWebViewBrowserSession a = await _open(
          port,
          'a',
          ua: paperbackDefaultUserAgent,
        );
        final WKWebViewBrowserSession b = await _open(port, 'b');
        // User agent: what the page sees and what the server receives.
        expect(
          await a.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        expect(await a.debugUserAgent(), paperbackDefaultUserAgent);
        expect(
          _server.lastHeaders['/page']!['user-agent'],
          paperbackDefaultUserAgent,
        );
        await a.setUserAgent('U10-UA/1.0');
        expect(
          await a.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        expect(_server.lastHeaders['/page']!['user-agent'], 'U10-UA/1.0');
        // Language: navigator and Accept-Language agree.
        final navLanguage = jsonDecode(
          (await a.evaluate('navigator.language')).valueOrNull!,
        ) as String;
        final String acceptLanguage =
            _server.lastHeaders['/page']!['accept-language'] ?? '';
        expect(
          acceptLanguage.toLowerCase(),
          startsWith(navLanguage.toLowerCase().split('-').first),
        );
        // Cookies: server-set and port-set cookies flow both ways, per source.
        expect(
          await a.loadUrl(_server.url('/set-cookie')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        await a.setCookie(
          _server.url('/'),
          const BrowserCookie(name: 'port', value: 'set-by-port'),
        );
        final names = <String>[
          for (final BrowserCookie c in (await a.getCookies(
            _server.url('/page'),
          )).valueOrNull!)
            c.name,
        ];
        expect(names, containsAll(<String>['srv', 'port']));
        final seen = jsonDecode(
          (await a.evaluate(
            'fetch("/echo-cookie").then(function (r) { return r.text(); })',
          )).valueOrNull!,
        ) as String;
        expect(
          seen,
          allOf(contains('srv=from-server'), contains('port=set-by-port')),
        );
        expect((await b.getCookies(_server.url('/page'))).valueOrNull, isEmpty);
        // Binary: a page fetch of all 256 byte values arrives intact.
        final b64 = jsonDecode(
          (await a.evaluate(
            'fetch("/bytes").then(function (r) { return r.arrayBuffer(); }).then(function (buf) {'
            ' var s = ""; new Uint8Array(buf).forEach(function (x) { s += String.fromCharCode(x); }); return btoa(s); })',
          )).valueOrNull!,
        ) as String;
        expect(base64.decode(b64), List<int>.generate(256, (int i) => i));
        // UTF-8: page text, evaluate results and channel messages.
        expect(
          await a.loadUrl(_server.url('/utf8')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        expect(
          jsonDecode((await a.evaluate('document.title')).valueOrNull!),
          'Onimai — お兄ちゃんはおしまい！',
        );
        expect(
          jsonDecode(
            (await a.evaluate('document.body.textContent')).valueOrNull!,
          ),
          'ÄÖÜ 漢字 🙂',
        );
        final utf = <String>[];
        await a.setMessageHandler('bridge', utf.add);
        await a.evaluate(
          BrowserMessageChannel.postScript('bridge', 'ÄÖÜ 漢字 🙂'),
        );
        await _waitUntil(() => utf.isNotEmpty, 'the UTF-8 message');
        expect(utf.single, 'ÄÖÜ 漢字 🙂');
        await a.loadData(
          '<html><body>データ ✓</body></html>',
          baseUrl: Uri.parse('https://example.org/'),
        );
        expect(
          jsonDecode(
            (await a.evaluate('document.body.textContent')).valueOrNull!,
          ),
          'データ ✓',
        );
        _record('consistency', <String, Object?>{
          'navigatorLanguage': navLanguage,
          'acceptLanguage': acceptLanguage,
          'cookieNames': names,
        });
        await a.close();
        await b.close();
      } finally {
        await port.dispose();
      }
    });

    test("Tachi android.webkit translation: the shim's reverse requests through the bridge on WKWebView", () async {
      final WKWebViewBrowserPort port = _port();
      final SourceIdentity tachi = _source('mangafire', ecosystem: 'tachi');
      final events = <(String, Map<String, Object?>)>[];
      final bridge =
          BrowserReverseBridge(
              port: port,
              interactionTimeout: const Duration(seconds: 5),
              resolveSource: (String? packageId, String sourceId) =>
                  packageId == tachi.packageId && sourceId == tachi.sourceId
                  ? tachi
                  : null,
              replacementTimeout: const Duration(seconds: 5),
              onLog: print,
            )
            ..emitEvent = (
              String op,
              Map<String, Object?> payload, {
              required int generation,
            }) => events.add((op, payload));
      Future<SourceOutcome<Map<String, Object?>>> send(
        HostBrowserRequest<ProtocolPayload> r,
      ) => bridge.handle(
        ReverseRequest(
          op: r.operation.wire,
          payload: r.toJson(),
          packageId: tachi.packageId,
          generation: 1,
          cancel: CancellationToken.none,
          protocolMinor: 2,
        ),
      );
      Map<String, Object?> ok(SourceOutcome<Map<String, Object?>> o) =>
          (o as SourceSuccess<Map<String, Object?>>).value;
      try {
        final opened = HostBrowserOpened.fromJson(
          ok(
            await send(
              HostBrowserOpen(
                sourceId: tachi.sourceId,
                userAgent: 'Mozilla/5.0 (Linux; Android 14)',
              ),
            ),
          ),
        );
        final String session = opened.session;
        expect(opened.capabilities, wkWebViewCapabilities);
        // MangaFire's fallback path: addJavascriptInterface(obj, "ipc"),
        // a page-start script, loadDataWithBaseURL, then evaluateJavascript.
        ok(
          await send(
            HostBrowserSetMessageHandler(
              session: session,
              name: 'ipc',
              enabled: true,
            ),
          ),
        );
        ok(
          await send(
            HostBrowserAddPageStartScript(
              session: session,
              script: 'window.ipc.postMessage("start:" + location.href)',
            ),
          ),
        );
        ok(
          await send(
            HostBrowserSetRequestInterception(
              session: session,
              mode: HostBrowserInterception.observe,
            ),
          ),
        );
        final SourceOutcome<Map<String, Object?>> replace = await send(
          HostBrowserSetRequestInterception(
            session: session,
            mode: HostBrowserInterception.replace,
          ),
        );
        expect(
          (replace as SourceFailed<Map<String, Object?>>).failure,
          isA<CapabilityUnavailableFailure>().having(
            (CapabilityUnavailableFailure f) => f.message,
            'message',
            contains('replaceRequests'),
          ),
        );
        ok(
          await send(
            HostBrowserLoadData(
              session: session,
              html: '<html><body><script>window.ipc.postMessage("solved")</script></body></html>',
              baseUrl: Uri.parse('https://mangafire.to/'),
            ),
          ),
        );
        final evaluated = HostBrowserEvaluated.fromJson(
          ok(
            await send(
              HostBrowserEvaluate(
                session: session,
                script: 'throw new Error("probe")',
              ),
            ),
          ),
        );
        // The shim ignores scriptError: Android semantics (result "null").
        expect(evaluated.result, 'null');
        expect(evaluated.scriptError, contains('probe'));
        await _waitUntil(
          () => events.where((e) => e.$1 == HostBrowserMessage.op).length >= 2,
          'ipc messages',
        );
        final messages = <String>[
          for (final (String op, Map<String, Object?> p) in events)
            if (op == HostBrowserMessage.op)
              HostBrowserMessage.fromJson(p).message,
        ];
        expect(
          messages,
          containsAll(<String>['start:https://mangafire.to/', 'solved']),
        );
        ok(await send(HostBrowserClose(session: session)));
        _record('tachi-translation', <String, Object?>{
          'messages': messages,
          'scriptError': evaluated.scriptError,
        });
      } finally {
        await bridge.close();
        await port.dispose();
      }
    });
  });
}
