// U12 device cases, registered from source_runners_android_test.dart:
// Paperback in an app-owned worker isolate on the vendored QuickJS-ng, and
// the app-process Android WebView BrowserPort (KTD19, KTD20, KTD23, KTD25).
//
// No case contacts a server. Paperback HTTP replays the committed captures
// (fixtures/source_captures/paperback/, delivered through the plugin's
// debug-only asset folder); every BrowserPort in these cases runs in replay
// mode: the process's WebViews go through a loopback proxy that refuses
// every request with no DIRECT fallback, so only the loopback server this
// file starts answers. Each case prints one `U12_RECEIPT {json}` line.
//
// Evidence from an emulator is labelled `emulator`; it never stands in for
// the physical ARM64 cells.

// ignore_for_file: avoid_print, do_not_use_environment

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_android/source_runtime_android.dart';
import 'package:source_runtime_testing/source_runtime_testing.dart';

import '../packages/paperback_plugin_loader/benchmark/bundle_benchmark.dart';
import '../packages/paperback_plugin_loader/test/support/in_app_support.dart';
import '../packages/paperback_plugin_loader/test/support/paperback_scenarios.dart';

const bool _bench = bool.fromEnvironment('SRT_BENCH');

void _receipt(String scenario, Map<String, Object?> data) {
  print(
    'U12_RECEIPT ${jsonEncode(<String, Object?>{'scenario': scenario, 'evidence': _evidence, 'abi': '${Abi.current()}', ...data})}',
  );
}

/// `emulator` on an Android emulator image, else `physical-device`.
final String _evidence = () {
  try {
    final String hw = File('/proc/cpuinfo').readAsStringSync();
    final bool emulated =
        Abi.current() == Abi.androidX64 ||
        hw.contains('QEMU') ||
        hw.contains('Android virtual');
    return emulated ? 'emulator' : 'physical-device';
  } on Object {
    return 'unknown';
  }
}();

const SupervisorLimits _supervisorLimits = SupervisorLimits(
  maxConcurrentPackages: 1,
  operationDeadline: Duration(minutes: 15),
  cancelGrace: Duration(seconds: 5),
  interactionTimeout: Duration(seconds: 30),
  shutdownGrace: Duration(seconds: 5),
);

/// Small override limits for the loop cases (contract-test values, KTD25).
PaperbackRuntimeLimits _loopLimits(
  Duration deadline, {
  int memory = 64 * 1024 * 1024,
}) => PaperbackRuntimeLimits(
  memoryLimitBytes: memory,
  maxStackBytes: 256 * 1024,
  operationDeadline: deadline,
  jobSlice: const Duration(milliseconds: 5),
);

// --- loopback server ---------------------------------------------------------

final class _Server {
  _Server._(this._a, this._b) {
    for (final s in <HttpServer>[_a, _b]) {
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
  final Map<String, Map<String, String>> lastHeaders =
      <String, Map<String, String>>{};
  bool _released = false;

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_a.port}$path');

  Uri otherOrigin(String path) => Uri.parse('http://127.0.0.1:${_b.port}$path');

  Future<Uri> closedPortUrl() async {
    final HttpServer s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final int port = s.port;
    await s.close(force: true);
    return Uri.parse('http://127.0.0.1:$port/gone');
  }

  void release() {
    _released = true;
    for (final Completer<void> c in _held) {
      if (!c.isCompleted) c.complete();
    }
    _held.clear();
  }

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
          '<html><head><title>framed</title><script>$crossOriginHelper</script></head><body>'
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
        r.headers.set('access-control-allow-origin', '*');
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
      case '/cf':
        // A Cloudflare-style interstitial (title marker), cleared only once
        // the visitor holds cf_clearance.
        if ((request.headers.value('cookie') ?? '').contains('cf_clearance=')) {
          html(
            '<html><head><title>cleared</title></head><body>cleared</body></html>',
          );
        } else {
          html(
            '<html><head><title>Just a moment...</title></head><body> '
            '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/x.js"></script></body></html>',
            status: 403,
          );
        }
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

Future<AndroidWebViewBrowserPort> _startPort({
  bool allowInteraction = false,
  bool disableProfiles = false,
  List<String>? log,
}) async {
  final SourceOutcome<AndroidWebViewBrowserPort> started =
      await AndroidWebViewBrowserPort.start(
        config: AndroidBrowserConfig(
          allowInteraction: allowInteraction,
          offline: true,
          disableProfiles: disableProfiles,
          onLog: (String l) {
            log?.add(l);
            print(l);
          },
        ),
      );
  if (started case SourceFailed<AndroidWebViewBrowserPort>(
    :final SourceFailure failure,
  )) {
    fail('Browser port did not start: ${failure.code}: ${failure.message}');
  }
  return started.valueOrNull!;
}

final class _AndroidHarness implements InteractiveBrowserPortHarness {
  AndroidWebViewBrowserPort? _current;

  @override
  Future<BrowserPort> start() async {
    _server.hold();
    return _current = await _startPort(allowInteraction: true);
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
  bool get canShowInteraction => true;

  @override
  Future<void> closeInteractionWindow() async {
    final AndroidWebViewBrowserPort port = _current!;
    await _waitUntil(
      () async => (await port.debugState())['interactionActivity'] != null,
      'the interaction Activity to show',
    );
    if (!await port.debugCloseInteractionAsUser()) {
      fail('No interaction Activity to close');
    }
  }

  @override
  String heldScript(String resultJson) =>
      'fetch("/held").then(function (r) { return r.text(); }).then(function () { return $resultJson; })';

  @override
  Future<void> releaseHeld() async => _server.release();

  @override
  Uri get crossOriginFramePageUrl => _server.url('/framed');

  @override
  String crossOriginFramePostScript(String name, String message) =>
      'crossOriginFramePost(${jsonEncode(name)}, ${jsonEncode(message)})';

  @override
  Uri get sameOriginFramePageUrl => _server.url('/same-framed');

  @override
  Uri get sameOriginFrameUrl => _server.url('/frame');

  @override
  Uri get echoUrl => _server.url('/echo');
}

SourceIdentity _source(String id) => SourceIdentity(
  ecosystem: 'paperback',
  packageId: 'u12.$id',
  sourceId: id,
  artifact: const ArtifactBinding(sha256: '00', kind: 'test', version: '1'),
);

Future<AndroidWebViewBrowserSession> _open(
  AndroidWebViewBrowserPort port,
  String id, {
  String? ua,
}) async {
  final BrowserOutcome<BrowserSession> opened = await port.openSession(
    BrowserSessionRequest(source: _source(id), generation: 1, userAgent: ua),
  );
  expect(opened, isA<BrowserCompleted<BrowserSession>>());
  return opened.valueOrNull! as AndroidWebViewBrowserSession;
}

Future<void> _waitUntil(
  FutureOr<bool> Function() condition,
  String what, {
  Duration bound = const Duration(seconds: 15),
}) async {
  final DateTime deadline = DateTime.now().add(bound);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

PaperbackBrowser _paperbackBrowser(
  InProcessBrowserChannel channel,
  String sourceId,
) => PaperbackBrowser(
  channel,
  sourceId: sourceId,
  resultTimeout: const Duration(seconds: 30),
);

InProcessBrowserChannel _channel(
  AndroidWebViewBrowserPort port,
  SourceIdentity source, {
  List<String>? log,
}) => InProcessBrowserChannel(
  port: port,
  source: source,
  interactionTimeout: const Duration(seconds: 30),
  onLog: (String l) => log?.add(l),
);

/// Registers the U12 cases. The Paperback group copies the fixtures from the
/// plugin's debug asset folder into the app cache first.
void registerU12Cases() {
  group('U12 Paperback in an app worker isolate', () {
    late Directory previous;
    late PaperbackWorkerPlan plan;

    setUpAll(() async {
      previous = Directory.current;
      final String copied = copyFixtureAssetDirectory(
        'source_captures/paperback',
      );
      // <cache>/fixtures/source_captures/paperback → <cache>
      Directory.current = Directory(copied).parent.parent.parent;
      expect(paperbackFixtures().existsSync(), isTrue);
      plan = await planPaperbackIsolateWorker();
    });

    tearDownAll(() => Directory.current = previous);

    test('QuickJS-ng: the vendored build for this ABI loads and evaluates on the root and a worker isolate', () async {
      final runtime = JsRuntime();
      final JsContext c = runtime.newContext();
      final Object? sum = c.toDart(c.eval('6 * 7'));
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
      expect(
        AndroidPaperbackBackend.register(_FakeProvider('paperback')),
        isA<SourceSuccess<AndroidPaperbackBackend>>(),
      );
      expect(
        AndroidPaperbackBackend.register(_FakeProvider('tachi')),
        isA<SourceFailed<AndroidPaperbackBackend>>(),
      );
      _receipt('quickjs', <String, Object?>{
        'nativeLibrary': paperbackNativeLibrary,
        'rootThreadStack': QuickJs.threadStackAvailable(),
        'workerThreadStack': worker['threadStack'],
        'physicalMemory': QuickJs.physicalMemory(),
        'processors': Platform.numberOfProcessors,
      });
    });

    test(
      'KTD25: limits derived on this device from a worker isolate measurement',
      () async {
        _receipt('sizing', <String, Object?>{
          ...plan.sizing.toJson(),
          'deadlineHeadroomMicros': plan.deadlineHeadroom.inMicroseconds,
          'cancelGraceMicros': plan.cancelGrace.inMicroseconds,
          'handshakeDeadlineMicros': plan.handshakeDeadline.inMicroseconds,
        });
        expect(
          plan.sizing.limits.maxStackBytes,
          lessThan(plan.sizing.device.threadStackBytes ?? 1 << 40),
        );
      },
    );

    test(
      'KTD25 benchmark: real bundles on this device (provisional on an emulator)',
      () async {
        final String fixtures = paperbackFixtures().path;
        final Map<String, Object?> report = await Isolate.run(
          () => runBundleBenchmark(fixtures, runs: 3),
          debugName: 'paperback-benchmark',
        );
        _receipt('benchmark', report);
      },
      skip: _bench ? false : 'Benchmark runs only with --dart-define=SRT_BENCH=true (takes several minutes)',
      timeout: const Timeout(Duration(minutes: 60)),
    );

    test('AE4: WeebCentral 0.9 and both 0.8 bundles search, fetch details and chapters (KTD25 limits)', () async {
      final InAppSiteRun run = await runSiteInIsolate(
        'weebcentral',
        limits: plan.sizing.limits,
        deadlineHeadroom: plan.deadlineHeadroom,
        supervisorLimits: _supervisorLimits,
      );
      _receipt('paperback-weebcentral', <String, Object?>{
        'runs': <Object?>[for (final BundleRun r in run.runs) r.toJson()],
        'misses': run.misses,
      });
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
        final MangaSnapshot s =
            (r.details! as SourceSuccess<MangaSnapshot>).value;
        expect(s.metadata.authors, <String>['Nekotoufu']);
        expect(s.chapters, hasLength(114));
        expect(s.chapters.first.chapterId, '01KWM07QYFJMAP46S1A3ZVDWYG');
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('AE4: MangaDex 0.9 and 0.8 (community 3.0.6) complete the JSON chapter feed', () async {
      final InAppSiteRun run = await runSiteInIsolate(
        'mangadex',
        limits: plan.sizing.limits,
        deadlineHeadroom: plan.deadlineHeadroom,
        supervisorLimits: _supervisorLimits,
      );
      _receipt('paperback-mangadex', <String, Object?>{
        'runs': <Object?>[for (final BundleRun r in run.runs) r.toJson()],
        'misses': run.misses,
      });
      expect(run.misses, isEmpty);
      final BundleRun inkdex = run.runs.firstWhere(
        (BundleRun r) => r.family == PaperbackApiFamily.v09,
      );
      final MangaSnapshot s =
          (inkdex.details! as SourceSuccess<MangaSnapshot>).value;
      expect(s.metadata.title, "ONIMAI: I'm Now Your Sister!");
      expect(s.chapters, hasLength(223));
      final BundleRun community = run.runs.firstWhere(
        (BundleRun r) => r.family == PaperbackApiFamily.v08,
      );
      final MangaSnapshot c =
          (community.details! as SourceSuccess<MangaSnapshot>).value;
      expect(c.metadata.authors, <String>['Nekotoufu']);
      expect(c.chapters, hasLength(223));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('AE4: Mangahub 0.8 (Cloudflare-fronted) searches, fetches details and chapters from its capture', () async {
      final InAppSiteRun run = await runSiteInIsolate(
        'mangahub',
        limits: plan.sizing.limits,
        deadlineHeadroom: plan.deadlineHeadroom,
        supervisorLimits: _supervisorLimits,
      );
      _receipt('paperback-mangahub', <String, Object?>{
        'runs': <Object?>[for (final BundleRun r in run.runs) r.toJson()],
        'misses': run.misses,
      });
      expect(run.misses, isEmpty);
      final BundleRun r = run.runs.single;
      expect(r.family, PaperbackApiFamily.v08);
      final SearchPage page = (r.page1! as SourceSuccess<SearchPage>).value;
      expect(page.hits, hasLength(11));
      final MangaSnapshot s =
          (r.details! as SourceSuccess<MangaSnapshot>).value;
      expect(s.ref.mangaId, 'onii-chan-wa-oshimai');
      expect(s.metadata.title, 'Onii-Chan wa Oshimai');
      expect(s.chapters, isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('AE11: MangaFire 0.9 executeInWebView runs on the app-process WebView (offline replay; outcome recorded)', () async {
      final log = <String>[];
      final AndroidWebViewBrowserPort port = await _startPort(log: log);
      try {
        final InAppSiteRun run = await runSiteInIsolate(
          'mangafire',
          limits: plan.sizing.limits,
          deadlineHeadroom: plan.deadlineHeadroom,
          supervisorLimits: _supervisorLimits,
          port: port,
        );
        final BundleRun r = run.runs.single;
        final Map<String, Object?> state = await port.debugState();
        _receipt('paperback-mangafire', <String, Object?>{
          ...r.toJson(),
          'served': run.served,
          'misses': run.misses,
          'browserLog': <String>[
            for (final String l in <String>[...run.log, ...log])
              if (l.contains('android-webview') || l.contains('browser')) l,
          ],
          'sessionsLeftOpen': port.sessions.length,
          'refusedBrowserRequests': state['refusedRequests'],
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
              limits: _loopLimits(const Duration(milliseconds: 400)),
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
          _receipt('loop-$mode', <String, Object?>{
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

    test('memory exhaustion in one JS call stops at the native memory limit while the isolate is blocked', () async {
      final IsolateWorkerHarness h = await IsolateWorkerHarness.start(
        PaperbackIsolateWorkerConfig(
          limits: _loopLimits(
            const Duration(minutes: 5),
            memory: 16 * 1024 * 1024,
          ),
          clientFactory: () => LoggingReplayClient(const <String>[]),
          adapterFactory: (_, _, _) => const LoopingAdapter(),
        ),
      );
      await h.handshake();
      expect((await h.loadLoopPackage()).error, isNull);
      final watch = Stopwatch()..start();
      final ProtocolFrame reply = await h
          .reply(h.search('memory'))
          .timeout(const Duration(seconds: 30));
      watch.stop();
      _receipt('memory-exhaustion', <String, Object?>{
        'code': reply.error!['code'],
        'message': reply.error!['message'],
        'elapsedMs': watch.elapsedMilliseconds,
      });
      expect(reply.error!['code'], 'source-error');
      expect(reply.error!['message']! as String, contains('memory limit'));
      expect(await h.shutdown(), 0);
    });

    test('kill stops a JS loop from the root isolate through the adopted interrupt token', () async {
      final IsolateWorkerHarness h = await IsolateWorkerHarness.start(
        PaperbackIsolateWorkerConfig(
          limits: _loopLimits(const Duration(minutes: 5)),
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
      _receipt('kill', <String, Object?>{
        'exit': exit,
        'elapsedMs': watch.elapsedMilliseconds,
      });
      expect(exit, -9);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a host call that never completes is bounded by the deadline; interaction events pause it', () async {
      const deadline = Duration(milliseconds: 300);
      final IsolateWorkerHarness h = await IsolateWorkerHarness.start(
        PaperbackIsolateWorkerConfig(
          limits: _loopLimits(deadline),
          clientFactory: () => LoggingReplayClient(const <String>[]),
          adapterFactory: (_, _, _) => const LoopingAdapter(),
        ),
      );
      await h.handshake();
      expect((await h.loadLoopPackage()).error, isNull);
      expect(
        (await h.reply(h.search('host')).timeout(const Duration(seconds: 10)))
            .error!['code'],
        'timeout',
      );
      final String id = h.search('host');
      ProtocolFrame? early;
      final Future<ProtocolFrame> reply = h.reply(id);
      unawaited(reply.then((ProtocolFrame f) => early = f));
      h.event(
        WorkerInteractionStarted.op,
        WorkerInteractionStarted(of: id, timeout: deadline * 10).toJson(),
      );
      await Future<void>.delayed(deadline * 4);
      expect(early, isNull);
      h.event(
        WorkerInteractionEnded.op,
        WorkerInteractionEnded(of: id, paused: deadline * 4).toJson(),
      );
      expect(
        (await reply.timeout(const Duration(seconds: 10))).error!['code'],
        'timeout',
      );
      expect(await h.shutdown(), 0);
      _receipt('host-call-deadline-and-pause', <String, Object?>{'ok': true});
    });
  });

  group('U12 app-process BrowserPort', () {
    setUpAll(() async => _server = await _Server.start());
    tearDownAll(() => _server.close());

    group('contract', () {
      runBrowserPortContractSuite(
        'Android WebView (app process)',
        _AndroidHarness.new,
      );
    });

    test('isolation: profile per session where multi-profile exists; setProfile timing probed in both processes', () async {
      final AndroidWebViewBrowserPort port = await _startPort();
      try {
        final Map<String, Object?> app = await port.debugProbeProfiles();
        final gate = AndroidSourceRuntime();
        Map<String, Object?> service;
        try {
          await gate.bind().timeout(const Duration(seconds: 60));
          service = jsonDecode(
            await gate
                .call('profileProbe')
                .timeout(const Duration(seconds: 90)),
          ) as Map<String, Object?>;
        } finally {
          gate.dispose();
        }
        final AndroidWebViewBrowserSession a = await _open(port, 'a');
        final AndroidWebViewBrowserSession b = await _open(port, 'b');
        final Map<String, Object?> state = await port.debugState();
        _receipt('isolation-probe', <String, Object?>{
          'webView': port.info['webViewPackage'],
          'features': port.info['features'],
          'isolation': port.isolationReport,
          'sessionProfiles': <String?>[a.profile, b.profile],
          'profilesWhileOpen': state['profiles'],
          'appProcessSetProfile': app,
          'serviceProcessSetProfile': service,
        });
        if (port.sourceIsolationAvailable) {
          expect(a.profile, isNotNull);
          expect(a.profile, isNot(b.profile));
        }
        expect(await a.close(), isA<BrowserCompleted<void>>());
        expect(await b.close(), isA<BrowserCompleted<void>>());
        final Map<String, Object?> after = await port.debugState();
        // Each closed session's profile is deleted, or parked verified empty
        // for reuse while Chromium still holds it.
        final List<Object?> free = after['freeProfiles']! as List<Object?>;
        expect(
          (after['profiles']! as List<Object?>).where(
            (Object? p) =>
                '$p'.startsWith('srt-') &&
                !'$p'.startsWith('srt-probe-') &&
                !free.contains(p),
          ),
          isEmpty,
        );
        _receipt('isolation-close', <String, Object?>{
          'profilesAfterClose': after['profiles'],
          'freeProfiles': free,
        });
      } finally {
        await port.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('isolation unavailable (no multi-profile): a second source is refused by name, never shares storage', () async {
      final AndroidWebViewBrowserPort port = await _startPort(
        disableProfiles: true,
      );
      try {
        expect(port.sourceIsolationAvailable, isFalse);
        final AndroidWebViewBrowserSession a = await _open(port, 'a');
        expect(a.profile, isNull);
        expect(
          await a.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        await a.setCookie(
          _server.url('/'),
          const BrowserCookie(name: 'shared', value: 'x'),
        );
        await a.evaluate('localStorage.setItem("k", "v")');
        final BrowserOutcome<BrowserSession> refused = await port.openSession(
          BrowserSessionRequest(source: _source('b'), generation: 1),
        );
        expect(
          refused,
          isA<BrowserCapabilityUnavailable<BrowserSession>>().having(
            (BrowserCapabilityUnavailable<BrowserSession> f) => f.reason,
            'reason',
            contains('isolation unavailable'),
          ),
        );
        expect(await a.close(), isA<BrowserCompleted<void>>());
        final AndroidWebViewBrowserSession b = await _open(port, 'b');
        expect(
          await b.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        expect((await b.getCookies(_server.url('/'))).valueOrNull, isEmpty);
        expect(
          (await b.evaluate('localStorage.getItem("k")')).valueOrNull,
          'null',
        );
        _receipt('isolation-unavailable', <String, Object?>{
          'isolation': port.isolationReport,
          'refused': '$refused',
        });
        await b.close();
      } finally {
        await port.dispose();
      }
    });

    test('replay mode fails closed: a non-loopback load and page fetch reach only the refusing proxy (no DNS)', () async {
      final AndroidWebViewBrowserPort port = await _startPort();
      try {
        final AndroidWebViewBrowserSession s = await _open(port, 'a');
        final BrowserOutcome<BrowserPage> blocked = await s.loadUrl(
          Uri.parse('https://example.com/'),
        );
        expect(blocked, isA<BrowserNavigationFailed<BrowserPage>>());
        expect(
          await s.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        final BrowserOutcome<String> fetched = await s.evaluate(
          'fetch("https://u12-replay-check.invalid/x").then(function () { return "reached"; }, function () { return "failed"; })',
        );
        expect(fetched.valueOrNull, '"failed"');
        final List<String> refused =
            ((await port.debugState())['refusedRequests']! as List<Object?>)
                .cast<String>();
        _receipt('replay-fails-closed', <String, Object?>{
          'blockedLoad': '$blocked',
          'pageFetch': fetched.valueOrNull,
          'offlineProxy': port.info['offlineProxy'],
          'refusedRequests': refused,
        });
        expect(refused.any((String l) => l.contains('example.com')), isTrue);
        expect(
          refused.any((String l) => l.contains('u12-replay-check.invalid')),
          isTrue,
        );
        await s.close();
      } finally {
        await port.dispose();
      }
    });

    test('navigation: status codes, a refused connection, and the scheme policy on redirects', () async {
      final AndroidWebViewBrowserPort port = await _startPort();
      try {
        final AndroidWebViewBrowserSession s = await _open(port, 'a');
        final BrowserOutcome<BrowserPage> ok = await s.loadUrl(
          _server.url('/page'),
        );
        final BrowserOutcome<BrowserPage> missing = await s.loadUrl(
          _server.url('/missing'),
        );
        final BrowserOutcome<BrowserPage> gone = await s.loadUrl(
          await _server.closedPortUrl(),
        );
        final BrowserOutcome<BrowserPage> toFile = await s.loadUrl(
          _server.url('/to-file'),
        );
        _receipt('navigation', <String, Object?>{
          'ok': '${ok.valueOrNull?.statusCode}',
          'missing': '${missing.valueOrNull?.statusCode}',
          'closedPort': '$gone',
          'redirectToFile': '$toFile',
        });
        expect(ok, isA<BrowserCompleted<BrowserPage>>());
        expect(missing.valueOrNull?.statusCode, 404);
        expect(gone, isA<BrowserNavigationFailed<BrowserPage>>());
        expect(toFile, isA<BrowserCapabilityUnavailable<BrowserPage>>());
        expect(s.pendingOperations, 0);
        await s.close();
      } finally {
        await port.dispose();
      }
    });

    test('cookies, user agent, language, binary and UTF-8 stay consistent and per source', () async {
      final AndroidWebViewBrowserPort port = await _startPort();
      try {
        final AndroidWebViewBrowserSession a = await _open(
          port,
          'a',
          ua: paperbackDefaultUserAgent,
        );
        final AndroidWebViewBrowserSession b = await _open(port, 'b');
        expect(
          await a.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        expect(
          jsonDecode((await a.evaluate('navigator.userAgent')).valueOrNull!),
          paperbackDefaultUserAgent,
        );
        expect(
          _server.lastHeaders['/page']!['user-agent'],
          paperbackDefaultUserAgent,
        );
        await a.setUserAgent('U12-UA/1.0');
        expect(
          await a.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        expect(_server.lastHeaders['/page']!['user-agent'], 'U12-UA/1.0');
        final navLanguage = jsonDecode(
          (await a.evaluate('navigator.language')).valueOrNull!,
        ) as String;
        final String acceptLanguage =
            _server.lastHeaders['/page']!['accept-language'] ?? '';
        expect(
          acceptLanguage.toLowerCase(),
          startsWith(navLanguage.toLowerCase().split('-').first),
        );
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
        final b64 = jsonDecode(
          (await a.evaluate(
            'fetch("/bytes").then(function (r) { return r.arrayBuffer(); }).then(function (buf) {'
            ' var s = ""; new Uint8Array(buf).forEach(function (x) { s += String.fromCharCode(x); }); return btoa(s); })',
          )).valueOrNull!,
        ) as String;
        expect(base64.decode(b64), List<int>.generate(256, (int i) => i));
        expect(
          await a.loadUrl(_server.url('/utf8')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        expect(
          jsonDecode((await a.evaluate('document.title')).valueOrNull!),
          'Onimai — お兄ちゃんはおしまい！',
        );
        final utf = <String>[];
        await a.setMessageHandler('bridge', utf.add);
        await a.evaluate(
          BrowserMessageChannel.postScript('bridge', 'ÄÖÜ 漢字 🙂'),
        );
        await _waitUntil(() => utf.isNotEmpty, 'the UTF-8 message');
        expect(utf.single, 'ÄÖÜ 漢字 🙂');
        _receipt('consistency', <String, Object?>{
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

    test('request observation: navigations and subresources with the headers WebView reports', () async {
      final AndroidWebViewBrowserPort port = await _startPort();
      try {
        final AndroidWebViewBrowserSession s = await _open(port, 'a');
        final observed = <BrowserRequest>[];
        expect(
          await s.setRequestObserver(observed.add),
          isA<BrowserCompleted<void>>(),
        );
        expect(
          await s.loadUrl(
            _server.url('/page'),
            headers: const <String, String>{'X-Contract': 'yes'},
          ),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        await s.evaluate(
          'fetch("/echo").then(function (r) { return r.text(); })',
        );
        final BrowserRequest main = observed.firstWhere(
          (BrowserRequest r) => r.url == _server.url('/page'),
        );
        final BrowserRequest sub = observed.firstWhere(
          (BrowserRequest r) => r.url == _server.url('/echo'),
        );
        _receipt('request-observation', <String, Object?>{
          'mainHeaders': main.headers.keys.toList(),
          'subresourceHeaders': sub.headers.keys.toList(),
          'clientHintsSeen':
              main.header('sec-ch-ua') != null ||
              sub.header('sec-ch-ua') != null,
        });
        expect(main.mainFrame, isTrue);
        expect(main.header('x-contract'), 'yes');
        expect(sub.mainFrame, isFalse);
        await s.close();
      } finally {
        await port.dispose();
      }
    });

    test('interaction: user close, timeout and cancel; Activity recreation keeps the WebView and its pending script', () async {
      final AndroidWebViewBrowserPort port = await _startPort(
        allowInteraction: true,
      );
      try {
        final AndroidWebViewBrowserSession s = await _open(port, 'a');
        expect(
          await s.loadUrl(_server.url('/page')),
          isA<BrowserCompleted<BrowserPage>>(),
        );
        _server.hold();
        final Future<BrowserOutcome<String>> held = s.evaluate(
          'fetch("/held").then(function (r) { return r.text(); }).then(function () { return document.title; })',
        );
        final Future<BrowserOutcome<void>> shown = s.showForInteraction(
          timeout: const Duration(seconds: 60),
        );
        await _waitUntil(
          () async => (await port.debugState())['interactionActivity'] == s.id,
          'the Activity to show',
        );
        await Future<void>.delayed(
          const Duration(seconds: 1),
        ); // visible on the device for the record
        expect(await port.debugRecreateInteraction(), isTrue);
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(await port.debugRecreateInteraction(), isTrue);
        await _waitUntil(
          () async => (await port.debugState())['interactionActivity'] == s.id,
          'the Activity to return',
        );
        _server.release();
        expect(
          (await held).valueOrNull,
          '"contract"',
          reason: 'the script survived two Activity recreations',
        );
        expect(s.isShowingInteraction, isTrue);
        expect(await port.debugCloseInteractionAsUser(), isTrue);
        final BrowserOutcome<void> closed = await shown;
        expect(closed, isA<BrowserCompleted<void>>());
        expect((await s.evaluate('1 + 1')).valueOrNull, '2');

        final BrowserOutcome<void> timedOut = await s.showForInteraction(
          timeout: const Duration(seconds: 2),
        );
        expect(timedOut, isA<BrowserInteractionRequired<void>>());
        await _waitUntil(
          () async => (await port.debugState())['interactionActivity'] == null,
          'the Activity to hide',
        );

        final cancel = CancellationSource();
        final Future<BrowserOutcome<void>> cancelled = s.showForInteraction(
          timeout: const Duration(seconds: 60),
          cancel: cancel.token,
        );
        await _waitUntil(
          () async => (await port.debugState())['interactionActivity'] == s.id,
          'the Activity again',
        );
        cancel.cancel('operation deadline');
        expect(await cancelled, isA<BrowserCancelled<void>>());
        _receipt('interaction', <String, Object?>{
          'closedByUser': '$closed',
          'timeout': '$timedOut',
          'recreations': 2,
        });
        await s.close();
      } finally {
        _server.release();
        await port.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('executeInWebView: cookies round-trip; survives Activity recreation; interaction-required while backgrounded', () async {
      final AndroidWebViewBrowserPort port = await _startPort(
        allowInteraction: true,
      );
      final SourceIdentity source = _source('pb');
      final InProcessBrowserChannel channel = _channel(port, source);
      try {
        final PaperbackBrowser browser = _paperbackBrowser(
          channel,
          source.sourceId,
        );
        final Map<String, Object?> done = await browser.execute(
          WebViewExecution(
            html: '<html><body>pb</body></html>',
            baseUrl: _server.url('/').toString(),
            inject: 'document.cookie = "made=inpage; path=/"; return document.cookie.indexOf("seeded=1") >= 0;',
            cookies: const <BrowserCookie>[
              BrowserCookie(name: 'seeded', value: '1'),
            ],
          ),
          CancellationToken.none,
        );
        expect(done['result'], isTrue);
        expect(
          <String>[
            for (final Object? c in done['cookies']! as List<Object?>)
              (c! as Map<String, Object?>)['name']! as String,
          ],
          containsAll(<String>['seeded', 'made']),
        );
        expect(port.sessions, isEmpty);

        // An execution in flight while the interaction Activity is recreated.
        _server.hold();
        final Future<Map<String, Object?>> inFlight = browser.execute(
          WebViewExecution(
            html: '<html><body>pb</body></html>',
            baseUrl: _server.url('/').toString(),
            inject: 'const r = await fetch("/held"); return await r.text();',
          ),
          CancellationToken.none,
        );
        final AndroidWebViewBrowserSession other = await _open(port, 'other');
        await other.loadUrl(_server.url('/page'));
        final cancelShow = CancellationSource();
        final Future<BrowserOutcome<void>> shown = other.showForInteraction(
          timeout: const Duration(seconds: 60),
          cancel: cancelShow.token,
        );
        await _waitUntil(
          () async =>
              (await port.debugState())['interactionActivity'] == other.id,
          'the Activity',
        );
        expect(await port.debugRecreateInteraction(), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        _server.release();
        final Map<String, Object?> survived = await inFlight;
        expect(survived['result'], 'released');
        cancelShow.cancel('done');
        expect(await shown, isA<BrowserCancelled<void>>());
        await other.close();

        // Backgrounded: no visible Activity can serve the source.
        port.setBackgroundedOverride(true);
        Object? background;
        try {
          await browser.execute(
            WebViewExecution(
              html: '<p>x</p>',
              baseUrl: _server.url('/').toString(),
              inject: 'return 1;',
            ),
            CancellationToken.none,
          );
        } on PaperbackBrowserException catch (e) {
          background = e.failure;
        }
        port.setBackgroundedOverride(null);
        expect(background, isA<InteractionRequiredFailure>());
        _receipt('execute-in-webview', <String, Object?>{
          'result': done['result'],
          'survivedRecreation': survived['result'],
          'backgrounded': '$background',
        });
      } finally {
        _server.release();
        await channel.close();
        await port.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
      'executeInWebView rejects late callbacks after session disposal',
      () async {
        final AndroidWebViewBrowserPort port = await _startPort();
        final SourceIdentity source = _source('late');
        final InProcessBrowserChannel channel = _channel(port, source);
        try {
          final PaperbackBrowser browser = _paperbackBrowser(
            channel,
            source.sourceId,
          );
          _server.hold();
          Object? failure;
          final Future<void> pending = browser
              .execute(
                WebViewExecution(
                  html: '<html><body>late</body></html>',
                  baseUrl: _server.url('/').toString(),
                  inject:
                      'const r = await fetch("/held"); return await r.text();',
                ),
                CancellationToken.none,
              )
              .then<void>(
                (_) => failure = 'completed',
                onError: (Object e) => failure = e,
              );
          await _waitUntil(
            () => port.sessions.isNotEmpty,
            'the session to open',
          );
          final AndroidWebViewBrowserSession s = port.sessions.values.single;
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await port.fence(2); // the conversion's generation moves on: disposal
          await pending;
          _server.release();
          await Future<void>.delayed(const Duration(seconds: 1));
          _receipt('late-callbacks', <String, Object?>{
            'outcome': '$failure',
            'pending': s.pendingOperations,
          });
          expect(failure, isA<PaperbackBrowserException>());
          expect(s.isClosed, isTrue);
          expect(s.pendingOperations, 0);
          expect(port.sessions, isEmpty);
        } finally {
          _server.release();
          await channel.close();
          await port.dispose();
        }
      },
    );

    test('0.8 Cloudflare bypass: shown in the interaction Activity when interactive, interaction-required unattended', () async {
      final SourceIdentity source = _source('cf');
      final Uri url = _server.url('/cf');
      // Unattended: the challenge is not shown and the bypass fails by name.
      final AndroidWebViewBrowserPort unattended = await _startPort();
      final InProcessBrowserChannel quiet = _channel(unattended, source);
      Object? unattendedFailure;
      try {
        await _paperbackBrowser(quiet, source.sourceId).bypassCloudflare(
          CloudflareBypass(url: url.toString()),
          CancellationToken.none,
          autoSolveWait: const Duration(seconds: 1),
        );
      } on PaperbackBrowserException catch (e) {
        unattendedFailure = e.failure;
      } finally {
        await quiet.close();
        await unattended.dispose();
      }
      expect(unattendedFailure, isA<InteractionRequiredFailure>());

      // Interactive: the user solves it in the Activity, then closes it.
      final AndroidWebViewBrowserPort port = await _startPort(
        allowInteraction: true,
      );
      final InProcessBrowserChannel channel = _channel(port, source);
      try {
        final Future<Map<String, Object?>> bypass =
            _paperbackBrowser(channel, source.sourceId).bypassCloudflare(
              CloudflareBypass(url: url.toString()),
              CancellationToken.none,
              autoSolveWait: const Duration(seconds: 1),
            );
        await _waitUntil(
          () async => (await port.debugState())['interactionActivity'] != null,
          'the challenge Activity',
          bound: const Duration(seconds: 30),
        );
        final AndroidWebViewBrowserSession s = port.sessions.values.single;
        // The "user" passes the challenge: the clearance cookie, then the site.
        await s.setCookie(
          url,
          const BrowserCookie(name: 'cf_clearance', value: 'solved'),
        );
        expect(await s.loadUrl(url), isA<BrowserCompleted<BrowserPage>>());
        expect(await port.debugCloseInteractionAsUser(), isTrue);
        final Map<String, Object?> cleared = await bypass;
        final cookieNames = <String>[
          for (final Object? c in cleared['cookies']! as List<Object?>)
            (c! as Map<String, Object?>)['name']! as String,
        ];
        _receipt('cloudflare-bypass', <String, Object?>{
          'unattended': '$unattendedFailure',
          'cookieNames': cookieNames,
          'userAgent': cleared['userAgent'] != null,
        });
        expect(cookieNames, contains('cf_clearance'));
        expect(port.sessions, isEmpty);
      } finally {
        await channel.close();
        await port.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('JNI global references return to baseline after repeated session open and close', () async {
      final AndroidWebViewBrowserPort port = await _startPort();
      try {
        Future<void> cycle() async {
          final AndroidWebViewBrowserSession s = await _open(port, 'jni');
          await s.loadUrl(_server.url('/page'));
          await s.evaluate('1 + 1');
          await s.close();
        }

        await cycle();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final Map<String, Object?> before =
            AndroidSourceRuntime.jniGlobalReferenceSummary();
        const rounds = 10;
        for (var i = 0; i < rounds; i++) {
          await cycle();
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final Map<String, Object?> after =
            AndroidSourceRuntime.jniGlobalReferenceSummary();
        int owned(Map<String, Object?> s) {
          var n = 0;
          for (final MapEntry<String, Object?> e
              in ((s['classes'] as Map<String, Object?>?) ??
                      const <String, Object?>{})
                  .entries) {
            if (e.key.contains('sourceruntime') ||
                e.key.contains('PortProxy') ||
                e.key.contains('jni')) {
              n += (e.value! as num).toInt();
            }
          }
          return n;
        }

        _receipt('jni-references', <String, Object?>{
          'rounds': rounds,
          'totalBefore': before['total'],
          'totalAfter': after['total'],
          'ownedBefore': owned(before),
          'ownedAfter': owned(after),
        });
        expect(owned(after) - owned(before), lessThanOrEqualTo(2));
      } finally {
        await port.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

final class _FakeProvider implements SourceProvider {
  _FakeProvider(this.ecosystem);

  @override
  final String ecosystem;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
