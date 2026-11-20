// Desktop-specific BrowserPort behaviour over the real helper: isolation,
// crash and late-reply settlement, interaction mode, typed start-up
// failures, helper-side scheme enforcement, the artifact manifest and the
// frame bound.
@TestOn('vm')
// Each test starts real WebView2 processes; parallel test files slow them.
@Timeout.factor(4)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:desktop_webview/desktop_webview.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import 'support/helper_fixture.dart';

SourceIdentity _source(String id) => SourceIdentity(
  ecosystem: 'test',
  packageId: 'test.package',
  sourceId: id,
  artifact: const ArtifactBinding(sha256: '00', kind: 'test', version: '1'),
);

Future<void> main() async {
  final File? helper = await builtHelper();
  if (helper == null) {
    test('desktop BrowserPort', () {}, skip: 'helper not built: $helperUnavailableReason');
    return;
  }

  late FixtureServer server;
  late Directory dataRoot;
  setUpAll(() async {
    server = await FixtureServer.start();
    dataRoot = await Directory.systemTemp.createTemp('dwv-desktop-');
  });
  tearDownAll(() async {
    await server.close();
    try {
      await dataRoot.delete(recursive: true);
    } on FileSystemException {
      // Browser process still releasing the directory.
    }
  });

  Future<DesktopBrowserPort> newPort({
    bool visible = false,
    List<String> args = const <String>[],
    List<String>? log,
  }) async {
    final port = DesktopBrowserPort(
      testConfig(helper, dataRoot, allowVisibleWindows: visible, extraArguments: args, log: log),
    );
    addTearDown(() async {
      await server.releaseHeld();
      await port.dispose();
    });
    return port;
  }

  Future<DesktopBrowserSession> open(DesktopBrowserPort port, String source, {int generation = 1}) async {
    final BrowserOutcome<BrowserSession> o = await port.openSession(
      BrowserSessionRequest(source: _source(source), generation: generation),
    );
    check(o).isA<BrowserCompleted<BrowserSession>>();
    final s = o.valueOrNull! as DesktopBrowserSession;
    check(await s.loadUrl(server.url('/page'))).isA<BrowserCompleted<BrowserPage>>();
    return s;
  }

  String held(String result) {
    server.armHeld();
    return 'fetch("/hold").then(function () { return $result; })';
  }

  group('isolation', () {
    test('two live sessions keep cookies apart; closing one cancels only its pending operations', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession a = await open(port, 'a');
      final DesktopBrowserSession b = await open(port, 'b');
      check(await a.loadUrl(server.url('/set-cookie'))).isA<BrowserCompleted<BrowserPage>>();
      check(await a.setCookie(server.url('/'), const BrowserCookie(name: 'a', value: '1')))
          .isA<BrowserCompleted<void>>();
      check(await b.setCookie(server.url('/'), const BrowserCookie(name: 'b', value: '2')))
          .isA<BrowserCompleted<void>>();
      final aNames = <String>[for (final c in (await a.getCookies(server.url('/'))).valueOrNull!) c.name];
      final bNames = <String>[for (final c in (await b.getCookies(server.url('/'))).valueOrNull!) c.name];
      check(aNames).unorderedEquals(<String>['server', 'a']);
      check(bNames).deepEquals(<String>['b']);

      final Future<BrowserOutcome<String>> aPending = a.evaluate(held('"a"'));
      final Future<BrowserOutcome<String>> bPending = b.evaluate(held('"b"'));
      check(await a.close()).isA<BrowserCompleted<void>>();
      check(await aPending).isA<BrowserCancelled<String>>();
      await server.releaseHeld();
      check((await bPending).valueOrNull).equals('"b"');
      check((await b.evaluate('1 + 2')).valueOrNull).equals('3');
    });
  });

  group('settlement', () {
    test('a helper crash cancels pending operations once; the next session starts a fresh helper', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      final int firstPid = port.helperInfo!.pid;
      final Future<BrowserOutcome<String>> pending = s.evaluate(held('"never"'));
      await port.debugKillHelper();
      final BrowserOutcome<String> outcome = await pending;
      check(outcome).isA<BrowserCancelled<String>>();
      check((outcome as BrowserCancelled<String>).reason).contains('helper exited');
      check(await s.evaluate('1')).isA<BrowserCancelled<String>>();
      // Deletion cannot be confirmed by a dead helper: reported, not hidden.
      check(await s.close()).isA<BrowserCapabilityUnavailable<void>>();

      final DesktopBrowserSession again = await open(port, 'a');
      check(port.helperInfo!.pid).not((Subject<int> it) => it.equals(firstPid));
      check((await again.evaluate('2 * 3')).valueOrNull).equals('6');
    });

    test('a reply arriving after cancellation is discarded and never resolves a later request', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      final cancel = CancellationSource();
      final Future<BrowserOutcome<String>> first = s.evaluate(held('"late"'), cancel: cancel.token);
      cancel.cancel('test cancelled');
      check(await first).isA<BrowserCancelled<String>>();
      await server.releaseHeld(); // the helper now sends the late reply
      await Future<void>.delayed(const Duration(milliseconds: 300));
      check((await s.evaluate('"current"')).valueOrNull).equals('"current"');
      check(await first).isA<BrowserCancelled<String>>();
    });

    test('fencing closes the older generation and leaves the newer one working', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession old = await open(port, 'a');
      final DesktopBrowserSession current = await open(port, 'b', generation: 2);
      final Future<BrowserOutcome<String>> stale = old.evaluate(held('"old"'));
      await port.fence(2);
      check(await stale).isA<BrowserCancelled<String>>();
      check(old.isClosed).isTrue();
      check((await current.evaluate('"ok"')).valueOrNull).equals('"ok"');
    });
  });

  group('scripts and messages', () {
    test('a throwing script completes with null (Android parity) and is logged', () async {
      final log = <String>[];
      final DesktopBrowserPort port = await newPort(log: log);
      final DesktopBrowserSession s = await open(port, 'a');
      check((await s.evaluate('throw new Error("boom")')).valueOrNull).equals('null');
      check(log.where((String l) => l.contains('boom'))).isNotEmpty();
      check((await s.evaluate('Promise.resolve({a: [1]})')).valueOrNull).equals('{"a":[1]}');
    });

    test('a disabled channel stops delivering messages', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      final messages = <String>[];
      check(await s.setMessageHandler('bridge', messages.add)).isA<BrowserCompleted<void>>();
      await s.evaluate('bridge.postMessage("one")');
      check(await s.setMessageHandler('bridge', null)).isA<BrowserCompleted<void>>();
      await s.evaluate('bridge.postMessage("two")');
      check(messages).deepEquals(<String>['one']);
      check(await s.setMessageHandler('not a name', messages.add)).isA<BrowserCapabilityUnavailable<void>>();
    });

    test('same-origin child frames get the channel and are delivered', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      final messages = <String>[];
      check(await s.setMessageHandler('bridge', messages.add)).isA<BrowserCompleted<void>>();
      check(await s.loadUrl(server.url('/same-framed'))).isA<BrowserCompleted<BrowserPage>>();
      const frame = 'document.querySelector("iframe").contentWindow';
      check((await s.evaluate('typeof $frame.bridge')).valueOrNull).equals('"object"');
      // The frame's own script context posts (eval in the frame's realm).
      await s.evaluate('$frame.eval(\'bridge.postMessage("from child")\')');
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
      while (messages.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      check(messages).deepEquals(<String>['from child']);
    });

    test('channels exist at document start of later pages', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      final messages = <String>[];
      await s.setMessageHandler('early', messages.add);
      check(
        await s.loadData(
          '<html><head><script>early.postMessage("inline:" + document.readyState)</script></head></html>',
          baseUrl: Uri.parse('https://example.org/page'),
        ),
      ).isA<BrowserCompleted<BrowserPage>>();
      check(messages).deepEquals(<String>['inline:loading']);
    });
  });

  group('requests', () {
    test('observe tier reports request headers; replace tier substitutes responses', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      if (port.helperInfo!.capabilities.requestObserve != 'all') {
        markTestSkipped('engine has no subresource observation');
        return;
      }
      final seen = <BrowserRequest>[];
      check(await s.observeRequests(seen.add)).isA<BrowserCompleted<void>>();
      await s.evaluate('fetch("/observed").then(function (r) { return r.status; })');
      final BrowserRequest observed = seen.firstWhere((BrowserRequest r) => r.url.path == '/observed');
      // WebView2 reports fetch() with its XML_HTTP_REQUEST resource context.
      check(<String>['fetch', 'xhr']).contains(observed.context);
      check(observed.headers.keys.map((String k) => k.toLowerCase())).contains('sec-ch-ua');

      check(
        await s.replaceRequests(
          (BrowserRequest r) => r.url.path == '/replaced'
              ? BrowserReplacement(
                  status: 200,
                  headers: const {'Content-Type': 'text/plain'},
                  body: utf8.encode('swapped'),
                )
              : null,
        ),
      ).isA<BrowserCompleted<void>>();
      check((await s.evaluate('fetch("/replaced").then(function (r) { return r.text(); })')).valueOrNull)
          .equals('"swapped"');
      check((await s.evaluate('fetch("/page").then(function (r) { return r.status; })')).valueOrNull).equals('200');
    });

    test('offline mode sees and blocks a cross-origin iframe request', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      final seen = <BrowserRequest>[];
      check(await s.observeRequests(seen.add)).isA<BrowserCompleted<void>>();
      check(
        await s.loadData(
          '<html><body><iframe src="https://frame-probe.invalid/x"></iframe></body></html>',
          baseUrl: Uri.parse('https://offline-probe.invalid/'),
        ),
      ).isA<BrowserCompleted<BrowserPage>>();
      check(seen.map((BrowserRequest r) => r.url.host)).contains('frame-probe.invalid');
    });

    test('offline mode blocks non-loopback requests nobody answers', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      check(await s.loadUrl(Uri.parse('https://example.org/'))).isA<BrowserNavigationFailed<BrowserPage>>();
    });
  });

  group('interaction', () {
    test('the interaction timeout is enforced and hides the window', () async {
      final DesktopBrowserPort port = await newPort(visible: true);
      final DesktopBrowserSession s = await open(port, 'a');
      final BrowserOutcome<void> shown = await s.showForInteraction(timeout: const Duration(milliseconds: 500));
      check(shown).isA<BrowserInteractionRequired<void>>();
      check((shown as BrowserInteractionRequired<void>).reason).contains('timed out');
    });

    test('closing the window completes the interaction; operations keep running while it shows', () async {
      final DesktopBrowserPort port = await newPort(visible: true);
      final DesktopBrowserSession s = await open(port, 'a');
      final Future<BrowserOutcome<void>> shown = s.showForInteraction(timeout: const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Operations are not blocked by (and their time is separate from) the
      // visible interaction.
      check((await s.evaluate('"during"')).valueOrNull).equals('"during"');
      check(await s.debugRequestClose()).isA<BrowserCompleted<void>>();
      check(await shown).isA<BrowserCompleted<void>>();
    });

    test('closing the session cancels a showing interaction', () async {
      final DesktopBrowserPort port = await newPort(visible: true);
      final DesktopBrowserSession s = await open(port, 'a');
      final Future<BrowserOutcome<void>> shown = s.showForInteraction(timeout: const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      check(await s.close()).isA<BrowserCompleted<void>>();
      check(await shown).isA<BrowserCancelled<void>>();
    });
  });

  group('start-up wipe', () {
    test('removes a stale data directory before any session opens', () async {
      final Directory root = await Directory.systemTemp.createTemp('dwv-wipe-');
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          // Browser process still releasing the directory.
        }
      });
      final stale = Directory(p.join(root.path, 'h-999999'));
      await File(p.join(stale.path, 'EBWebView', 'leftover')).create(recursive: true);
      final port = DesktopBrowserPort(testConfig(helper, root));
      addTearDown(port.dispose);
      check(await port.wipeAllSourceData()).isA<BrowserCompleted<void>>();
      check(port.helperInfo!.wipeRemoved).equals(1);
      check(stale.existsSync()).isFalse();
    });

    test('the next helper removes a killed helper directory', () async {
      final Directory root = await Directory.systemTemp.createTemp('dwv-wipe-');
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          // Browser process still releasing the directory.
        }
      });
      final port = DesktopBrowserPort(testConfig(helper, root));
      addTearDown(port.dispose);
      final DesktopBrowserSession s = await open(port, 'a');
      check(await s.evaluate('localStorage.setItem("k", "v")')).isA<BrowserCompleted<String>>();
      final killed = Directory(p.join(root.path, 'h-${port.helperInfo!.pid}'));
      check(killed.existsSync()).isTrue();
      await port.debugKillHelper();
      await open(port, 'a'); // starts a fresh helper
      // The dead helper's browser processes may hold files for a moment.
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
      BrowserOutcome<void> wiped = await port.wipeAllSourceData();
      while (killed.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        wiped = await port.wipeAllSourceData();
      }
      check(killed.existsSync()).isFalse();
      check(wiped).isA<BrowserCompleted<void>>();
    });
  });

  group('typed start-up failures', () {
    for (final code in <String>['runtime-missing', 'no-display']) {
      test('$code yields capability-unavailable, not a hang', () async {
        final DesktopBrowserPort port = await newPort(args: <String>['--simulate-fatal', code]);
        final BrowserOutcome<BrowserSession> o = await port.openSession(
          BrowserSessionRequest(source: _source('a'), generation: 1),
        );
        check(o).isA<BrowserCapabilityUnavailable<BrowserSession>>();
        check((o as BrowserCapabilityUnavailable<BrowserSession>).reason).contains(code);
      });
    }

    test('a missing helper binary yields capability-unavailable', () async {
      final port = DesktopBrowserPort(testConfig(File(p.join(dataRoot.path, 'missing.exe')), dataRoot));
      final BrowserOutcome<BrowserSession> o = await port.openSession(
        BrowserSessionRequest(source: _source('a'), generation: 1),
      );
      check(o).isA<BrowserCapabilityUnavailable<BrowserSession>>();
    });
  });

  group('helper protocol', () {
    test('the helper enforces the scheme policy on its own', () async {
      final DesktopBrowserPort port = await newPort();
      await open(port, 'a');
      final HelperProcess h = port.debugHelper!;
      for (final (String op, Map<String, Object?> params) in <(String, Map<String, Object?>)>[
        ('load', <String, Object?>{'url': 'file:///C:/Windows/win.ini'}),
        ('load', <String, Object?>{'url': 'javascript:alert(1)'}),
        ('loadData', <String, Object?>{'html': '<p>x</p>', 'baseUrl': 'about:blank'}),
        ('loadData', <String, Object?>{'html': '<p>x</p>', 'baseUrl': 'file:///tmp/'}),
        ('cookies', <String, Object?>{'url': 'file:///tmp/'}),
      ]) {
        final HelperReply r = await h.request(op, <String, Object?>{...params, 'session': 's1'});
        check(r).isA<HelperError>().has((HelperError e) => e.code, 'code').equals('capability-unavailable');
      }
    });

    test('a request over the frame bound is refused before it is sent', () async {
      final DesktopBrowserPort port = await newPort();
      await open(port, 'a');
      final HelperReply r = await port.debugHelper!.request('eval', <String, Object?>{
        'session': 's1',
        'script': 'x' * (helperMaxFrameBytes + 1),
      });
      check(r).isA<HelperError>().has((HelperError e) => e.code, 'code').equals('invalid');
      check(port.debugHelper!.isAlive).isTrue();
    });
  });

  group('runtime artifact manifest', () {
    test('locates the host helper and rejects a changed binary', () async {
      final Directory dir = await Directory.systemTemp.createTemp('dwv-manifest-');
      addTearDown(() => dir.delete(recursive: true));
      final copy = File(p.join(dir.path, 'bin', p.basename(helper.path)));
      await copy.parent.create();
      await helper.copy(copy.path);
      final RuntimeArtifact good = RuntimeArtifactManifest.load(
        File(p.join(packageDir().path, 'build', 'helper', RuntimeArtifactManifest.fileName)),
      ).findForHost(RuntimeArtifactManifest.webviewHelper)!;
      final manifest = File(p.join(dir.path, RuntimeArtifactManifest.fileName));
      await manifest.writeAsString(
        RuntimeArtifactManifest(<RuntimeArtifact>[
          RuntimeArtifact(
            name: good.name,
            os: good.os,
            arch: good.arch,
            path: 'bin/${p.basename(helper.path)}',
            sha256: good.sha256,
          ),
        ]).encode(),
      );
      final RuntimeArtifact found = RuntimeArtifactManifest.load(manifest)
          .findForHost(RuntimeArtifactManifest.webviewHelper)!;
      check(found.verifiedFile().path).equals(copy.path);
      await copy.writeAsBytes(<int>[1, 2, 3], mode: FileMode.append);
      check(found.verifiedFile).throws<RuntimeArtifactException>();
      check(RuntimeArtifactManifest.load(manifest).find(good.name, os: 'plan9', arch: 'x64')).isNull();
    });
  });
}
