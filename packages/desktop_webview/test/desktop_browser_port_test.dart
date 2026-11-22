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
import 'package:source_runtime/source_runtime.dart'
    show CaptureExchange, CaptureKey, CaptureManifest, CaptureSet, CapturedResponse;
import 'package:test/scaffolding.dart';

import 'support/helper_fixture.dart';

SourceIdentity _source(String id) => SourceIdentity(
  ecosystem: 'test',
  packageId: 'test.package',
  sourceId: id,
  artifact: const ArtifactBinding(sha256: '00', kind: 'test', version: '1'),
);

/// Whether the engine lacks [feature]: then the reason it names is checked
/// and the rest of the test is skipped (WKWebView has no observe or replace
/// tier; these cases measure WebView2's).
bool _lacks(BrowserSession s, BrowserFeature feature) {
  if (s.capabilities.supports(feature)) return false;
  final String? reason = s.capabilities.reasonFor(feature);
  check(reason).isNotNull().isNotEmpty();
  markTestSkipped('${feature.name} unavailable: $reason');
  return true;
}

/// Waits until [dir] can be renamed (no process holds it open), probing by
/// renaming it away and back.
Future<void> _waitUntilReleasable(Directory dir, Duration timeout) async {
  final DateTime deadline = DateTime.now().add(timeout);
  // A directory can be renamed while a terminating browser process still
  // has it open with delete sharing, and that process can then fail the
  // next helper's single start-up attempt. On Windows wait first until no
  // process names the directory on its command line (WebView2 passes it as
  // --user-data-dir), which is the release the wipe needs.
  if (Platform.isWindows) await _waitForNoProcessUsing(dir, deadline);
  final probe = '${dir.path}.probe';
  while (true) {
    try {
      Directory(dir.renameSync(probe).path).renameSync(dir.path);
      return;
    } on FileSystemException {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}

/// Waits until no running process has [dir]'s path on its command line.
Future<void> _waitForNoProcessUsing(Directory dir, DateTime deadline) async {
  final String name = dir.absolute.path.replaceAll("'", "''");
  while (true) {
    final command =
        '@(Get-CimInstance Win32_Process | Where-Object { '
        r'$_.CommandLine -like '
        "'*$name*'"
        r' -and $_.ProcessId -ne $PID }).Count';
    final ProcessResult r = await Process.run('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ]);
    if (r.exitCode == 0 && (r.stdout as String).trim() == '0') return;
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Processes still use ${dir.path} after the release bound: ${r.stdout}${r.stderr}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

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
    test('a throwing script or rejected promise is a script error; Android parity reads null', () async {
      final log = <String>[];
      final DesktopBrowserPort port = await newPort(log: log);
      final DesktopBrowserSession s = await open(port, 'a');
      check(s.capabilities.supports(BrowserFeature.scriptErrors)).isTrue();
      final BrowserOutcome<String> thrown = await s.evaluate('throw new Error("boom")');
      check(thrown)
          .isA<BrowserScriptError<String>>()
          .has((BrowserScriptError<String> e) => e.message, 'message')
          .contains('boom');
      check(thrown.androidCompatible.valueOrNull).equals('null');
      check(await s.evaluate('Promise.reject(new Error("later"))')).isA<BrowserScriptError<String>>();
      check(log.where((String l) => l.contains('boom'))).isNotEmpty();
      check((await s.evaluate('Promise.resolve({a: [1]})')).valueOrNull).equals('{"a":[1]}');
      check((await s.evaluate('null')).valueOrNull).equals('null');
    });

    test('channels named like the engine globals leave the page bridge working', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      final messages = <String>[];
      // WKWebView defines `window.webkit` as a non-configurable global: the
      // helper refuses that name with its reason instead of failing silently.
      final names = <String>['chrome', if (!Platform.isMacOS) 'webkit', 'ipc'];
      for (final name in names) {
        check(await s.setMessageHandler(name, (String m) => messages.add('$name:$m'))).isA<BrowserCompleted<void>>();
      }
      if (Platform.isMacOS) {
        check(await s.setMessageHandler('webkit', (_) {}))
            .isA<BrowserCapabilityUnavailable<void>>()
            .has((BrowserCapabilityUnavailable<void> o) => o.reason, 'reason')
            .contains('non-configurable');
      }
      check(await s.loadUrl(server.url('/page'))).isA<BrowserCompleted<BrowserPage>>();
      check((await s.evaluate('6 * 7')).valueOrNull).equals('42');
      await s.evaluate(names.map((String n) => '$n.postMessage("${n[0]}");').join(' '));
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
      while (messages.length < names.length && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      check(messages).unorderedEquals(<String>[for (final n in names) '$n:${n[0]}']);
    });

    test('a pushed cookie reaches page scripts unless it is httpOnly, and every request', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      check(await s.setCookie(server.url('/'), const BrowserCookie(name: 'plain', value: '1')))
          .isA<BrowserCompleted<void>>();
      check(
        await s.setCookie(server.url('/'), const BrowserCookie(name: 'hidden', value: '2', httpOnly: true)),
      ).isA<BrowserCompleted<void>>();
      check(await s.loadUrl(server.url('/page'))).isA<BrowserCompleted<BrowserPage>>();
      check((await s.evaluate('document.cookie')).valueOrNull).equals('"plain=1"');
      await s.evaluate('fetch("/echo")');
      final String sent = server.seen.lastWhere(((String, Map<String, String>) e) => e.$1 == '/echo').$2['cookie']!;
      check(sent).contains('plain=1');
      check(sent).contains('hidden=2');
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
      if (port.helperInfo!.engine == 'webkitgtk') {
        // WebKitGTK cannot attest the posting frame, so channels are injected
        // into the top frame only (L1).
        check((await s.evaluate('typeof $frame.bridge')).valueOrNull).equals('"undefined"');
        return;
      }
      check((await s.evaluate('typeof $frame.bridge')).valueOrNull).equals('"object"');
      // The frame's own script context posts (eval in the frame's realm).
      await s.evaluate('$frame.eval(\'bridge.postMessage("from child")\')');
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
      while (messages.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      check(messages).deepEquals(<String>['from child']);
    });

    test('neither a cross-origin frame nor the page can read the session key (L1)', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      final messages = <String>[];
      check(await s.setMessageHandler('bridge', messages.add)).isA<BrowserCompleted<void>>();
      // Steals any `k` that passes through toJSON or a replaced
      // JSON.stringify, then posts through the channel (if it has one).
      const thief =
          "var got=null;Object.prototype.toJSON=function(){if(this&&typeof this.k==='string')got=this.k;return this}; "
          "var J=JSON.stringify;JSON.stringify=function(v){if(v&&typeof v.k==='string')got=v.k;return J.apply(JSON,arguments)}; "
          "try{bridge.postMessage('{who}')}catch(e){}";
      final String frameScript = thief.replaceAll('{who}', 'from-frame');
      final String topScript = thief.replaceAll('{who}', 'from-top');
      // A sandboxed srcdoc frame runs in an opaque origin: cross-origin to
      // the page, with no network. It reports what it stole to the page.
      final String srcdoc = '<script>$frameScript parent.postMessage("frame:"+(typeof bridge)+":"+got,"*")</script>'
          .replaceAll('&', '&amp;')
          .replaceAll('"', '&quot;');
      check(
        await s.loadData(
          '<html><body><script>window.report=null;addEventListener("message",function(e){window.report=e.data})'
          '</script><iframe sandbox="allow-scripts" srcdoc="$srcdoc"></iframe></body></html>',
          baseUrl: Uri.parse('https://example.org/page'),
        ),
      ).isA<BrowserCompleted<BrowserPage>>();
      String? report;
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        report = (await s.evaluate('window.report')).valueOrNull;
        if (report != null && report != 'null') break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      check(report).isNotNull().endsWith(':null"');
      // The page itself, after hijacking both, still cannot read the key,
      // and its own message is still delivered (the envelope is built
      // without them).
      await s.evaluate(topScript);
      check((await s.evaluate('got')).valueOrNull).equals('null');
      // The current-document channel install runs after the page replaced
      // JSON.stringify: still no key.
      check(await s.setMessageHandler('late', messages.add)).isA<BrowserCompleted<void>>();
      await s.evaluate("late.postMessage('late-top')");
      check((await s.evaluate('got')).valueOrNull).equals('null');
      final DateTime until = DateTime.now().add(const Duration(seconds: 10));
      while (messages.length < 2 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      check(messages).deepEquals(<String>['from-top', 'late-top']);
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
      check(await s.setRequestObserver(seen.add)).isA<BrowserCompleted<void>>();
      await s.evaluate('fetch("/observed").then(function (r) { return r.status; })');
      final BrowserRequest observed = seen.firstWhere((BrowserRequest r) => r.url.path == '/observed');
      // WebView2 reports fetch() with its XML_HTTP_REQUEST resource context.
      check(<BrowserRequestContext>[BrowserRequestContext.fetch, BrowserRequestContext.xhr]).contains(observed.context);
      check(observed.headers.keys.map((String k) => k.toLowerCase())).contains('sec-ch-ua');

      check(
        await s.setRequestReplacer(
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

    /// Fetches [path] from the page with [method] and [body]; completes with
    /// `<status> <text>`, or `fetch-failed` on a network error.
    Future<String?> fetchFrom(DesktopBrowserSession s, String path, {String method = 'GET', String? body}) async =>
        jsonDecode(
          (await s.evaluate(
            'fetch(${jsonEncode(path)}, {method: ${jsonEncode(method)}'
            '${body == null ? '' : ', body: ${jsonEncode(body)}'}})'
            '.then(function (r) { return r.text().then(function (t) { return r.status + " " + t; }); },'
            ' function () { return "fetch-failed"; })',
          )).valueOrNull!,
        ) as String?;

    test('request bodies reach the replacer, and capture replay matches on the body hash', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      if (_lacks(s, BrowserFeature.replaceRequests) || _lacks(s, BrowserFeature.observeRequestBodies)) return;
      final Uri verify = server.url('/body-replay/verify');
      final manifest = CaptureManifest(
        ecosystem: 'browser',
        source: 'desktop-test',
        recordedAt: DateTime.utc(2026, 11, 20),
        exchanges: const <CaptureExchange>[],
      );
      final captures = CaptureSet(manifest, <CaptureKey, CapturedResponse>{
        manifest.keyFor('POST', verify, utf8.encode('answer=1')): CapturedResponse(
          status: 200,
          headers: const <String, String>{'content-type': 'text/plain'},
          body: utf8.encode('verified'),
        ),
        manifest.keyFor('GET', verify, null): CapturedResponse(
          status: 200,
          headers: const <String, String>{'content-type': 'text/plain'},
          body: utf8.encode('plain get'),
        ),
        manifest.keyFor('PUT', verify, null): CapturedResponse(
          status: 200,
          headers: const <String, String>{'content-type': 'text/plain'},
          body: utf8.encode('bodiless put'),
        ),
      });
      final replay = BrowserCaptureReplay(captures);
      final List<CaptureKey> misses = replay.misses;
      final seen = <BrowserRequest>[];
      check(
        await s.setRequestReplacer((BrowserRequest r) {
          seen.add(r);
          return replay.serve(r) ?? BrowserReplacement(status: 599, reason: 'No committed capture');
        }),
      ).isA<BrowserCompleted<void>>();
      check(await fetchFrom(s, verify.path, method: 'POST', body: 'answer=1')).equals('200 verified');
      check(await fetchFrom(s, verify.path, method: 'POST', body: 'answer=2')).equals('599 ');
      // A GET has no body (not an empty one), so it matches a bodiless capture.
      check(await fetchFrom(s, verify.path)).equals('200 plain get');
      // A bodiless request that still sends a Content-Type has no body (not
      // an omitted one), so it matches a bodiless capture too.
      check(
        (await s.evaluate(
          'fetch(${jsonEncode(verify.path)}, {method: "PUT", headers: {"Content-Type": "text/plain"}}) '
          '.then(function (r) { return r.text(); })',
        )).valueOrNull,
      ).equals('"bodiless put"');
      final BrowserRequest post = seen.firstWhere((BrowserRequest r) => r.method == 'POST');
      check(post.body).isNotNull().deepEquals(utf8.encode('answer=1'));
      check(post.bodyOmitted).isFalse();
      // Only the test's own requests count: WebView2 fetches /favicon.ico on
      // its own, and that request can reach the replacer after it is set.
      check(misses.where((CaptureKey k) => Uri.parse(k.url).path.startsWith('/body-replay'))).length.equals(1);
      check(server.seen.where(((String, Map<String, String>) e) => e.$1.startsWith('/body-replay'))).isEmpty();
    });

    test('a body over 1 MiB is omitted whole and still uploaded unchanged', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      if (_lacks(s, BrowserFeature.observeRequestBodies)) return;
      final seen = <BrowserRequest>[];
      check(await s.setRequestObserver(seen.add)).isA<BrowserCompleted<void>>();
      final String reply = (await fetchFrom(s, '/echo', method: 'POST', body: 'x' * (1024 * 1024 + 1)))!;
      check(reply.length).equals('200 POST '.length + 1024 * 1024 + 1);
      final BrowserRequest big = seen.firstWhere((BrowserRequest r) => r.url.path == '/echo');
      check(big.body).isNull();
      check(big.bodyOmitted).isTrue();
      // A small body is forwarded, and the upload is unchanged by reading it.
      check(await fetchFrom(s, '/echo', method: 'POST', body: 'small')).equals('200 POST small');
      check(seen.last.body).isNotNull().deepEquals(utf8.encode('small'));
    });

    test('mainFrame marks the top-level document, not a same-origin child frame', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      if (_lacks(s, BrowserFeature.observeSubresources)) return;
      final seen = <BrowserRequest>[];
      check(await s.setRequestObserver(seen.add)).isA<BrowserCompleted<void>>();
      // `/same-framed` embeds `/page`, the URL the session just loaded.
      check(await s.loadUrl(server.url('/same-framed'))).isA<BrowserCompleted<BrowserPage>>();
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!seen.any((BrowserRequest r) => r.url.path == '/page') && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final List<BrowserRequest> docs = seen
          .where((BrowserRequest r) => r.context == BrowserRequestContext.document)
          .toList();
      check(docs.where((BrowserRequest r) => r.url.path == '/same-framed').single.mainFrame).isTrue();
      check(docs.where((BrowserRequest r) => r.url.path == '/page').single.mainFrame).isFalse();
      check(await fetchFrom(s, '/echo')).equals('200 GET ');
      check(seen.lastWhere((BrowserRequest r) => r.url.path == '/echo').mainFrame).isFalse();
    });

    test('a refused or throwing replacement fails the request without sending it', () async {
      final log = <String>[];
      final DesktopBrowserPort port = await newPort(log: log);
      final DesktopBrowserSession s = await open(port, 'a');
      if (_lacks(s, BrowserFeature.replaceRequests)) return;
      final seenUrls = <Uri>[];
      check(
        await s.setRequestReplacer((BrowserRequest r) {
          seenUrls.add(r.url);
          return switch (r.url.path) {
            '/fail/redirect' => BrowserReplacement(
              status: 302,
              headers: const <String, String>{'Location': 'file:///C:/Windows/win.ini'},
            ),
            '/fail/status' => BrowserReplacement(status: 99),
            '/fail/throw' || '/fail/document' => throw StateError('replacer bug'),
            _ => null,
          };
        }),
      ).isA<BrowserCompleted<void>>();
      check(await fetchFrom(s, '/fail/redirect')).equals('fetch-failed');
      check(await fetchFrom(s, '/fail/status')).equals('fetch-failed');
      check(await fetchFrom(s, '/fail/throw')).equals('fetch-failed');
      // A failed main-frame document settles the load instead of hanging.
      check(await s.loadUrl(server.url('/fail/document'))).isA<BrowserNavigationFailed<BrowserPage>>();
      check(server.seen.where(((String, Map<String, String>) e) => e.$1.startsWith('/fail'))).isEmpty();
      // The rewritten request (port 1) is refused by the network stack and
      // never comes back through the replacer.
      check(seenUrls.where((Uri u) => u.port == 1)).isEmpty();
      check(log.where((String l) => l.contains('replacer bug'))).isNotEmpty();
      // Requests the replacer lets through still work.
      check(await s.loadUrl(server.url('/page'))).isA<BrowserCompleted<BrowserPage>>();
      check(await fetchFrom(s, '/echo')).equals('200 GET ');
    });

    test('offline mode sees and blocks a cross-origin iframe request', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      if (_lacks(s, BrowserFeature.observeSubresources)) return;
      final seen = <BrowserRequest>[];
      check(await s.setRequestObserver(seen.add)).isA<BrowserCompleted<void>>();
      check(
        await s.loadData(
          '<html><body><iframe src="https://frame-probe.invalid/x"></iframe></body></html>',
          baseUrl: Uri.parse('https://offline-probe.invalid/'),
        ),
      ).isA<BrowserCompleted<BrowserPage>>();
      check(seen.map((BrowserRequest r) => r.url.host)).contains('frame-probe.invalid');
    });

    // Without request observation, blocking is shown on a host that would
    // reach the fixture server: the IPv4-mapped IPv6 form of 127.0.0.1 is not
    // on the loopback allow list. A control port without offline mode proves
    // the address does reach the server here, so no request leaves the host
    // either way.
    test(
      'offline mode blocks a non-allow-listed host for fetches, frames and navigations',
      skip: Platform.isMacOS ? null : 'measured on macOS (WKWebView content rules) only',
      () async {
        Uri mapped(String path) => server.url(path).replace(host: '::ffff:127.0.0.1');
        int hits(String path) => server.seen.where(((String, Map<String, String>) e) => e.$1 == path).length;
        Future<String?> noCors(DesktopBrowserSession s, Uri url) async => jsonDecode(
          (await s.evaluate(
            'fetch(${jsonEncode(url.toString())}, {mode: "no-cors"}) '
            '.then(function () { return "fetched"; }, function () { return "fetch-failed"; })',
          )).valueOrNull!,
        ) as String?;

        final control = DesktopBrowserPort(testConfig(helper, dataRoot, offline: false));
        addTearDown(control.dispose);
        final DesktopBrowserSession c = await open(control, 'c');
        if (await noCors(c, mapped('/offline-control')) != 'fetched' || hits('/offline-control') != 1) {
          markTestSkipped('the IPv4-mapped loopback address does not reach the fixture server on this host');
          return;
        }
        await control.dispose();

        final DesktopBrowserPort port = await newPort();
        final DesktopBrowserSession s = await open(port, 'a');
        check(await noCors(s, mapped('/offline-fetch'))).equals('fetch-failed');
        await s.evaluate(
          'new Promise(function (r) { var f = document.createElement("iframe"); f.onload = r; '
          'setTimeout(r, 2000); f.src = ${jsonEncode(mapped('/offline-frame').toString())}; '
          'document.body.appendChild(f); })',
        );
        check(await s.loadUrl(mapped('/offline-document'))).isA<BrowserNavigationFailed<BrowserPage>>();
        check(<int>[hits('/offline-fetch'), hits('/offline-frame'), hits('/offline-document')])
            .deepEquals(<int>[0, 0, 0]);
        // Loopback itself stays reachable.
        check(await fetchFrom(s, '/echo')).equals('200 GET ');
      },
    );

    test('a load reports the main document status, and a dropped connection fails the load', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      final HelperCapabilities caps = port.helperInfo!.capabilities;
      final BrowserOutcome<BrowserPage> missing = await s.loadUrl(server.url('/missing'));
      check(missing).isA<BrowserCompleted<BrowserPage>>();
      check(missing.valueOrNull!.statusCode).equals(caps.statusCodes ? 404 : null);
      if (caps.statusCodes) {
        check((await s.loadUrl(server.url('/page'))).valueOrNull!.statusCode).equals(200);
      }
      if (!caps.navigationFailures) {
        markTestSkipped('engine reports no failed navigations');
        return;
      }
      check(await s.loadUrl(server.url('/drop'))).isA<BrowserNavigationFailed<BrowserPage>>();
      check(await s.loadUrl(server.url('/page'))).isA<BrowserCompleted<BrowserPage>>();
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
      // A killed helper's WebView2 browser process can stay in termination
      // for 1-110 s (measured on WebView2 157), holding the directory; how long is up to the
      // OS, so wait until the directory can be released (the condition the
      // wipe needs) rather than racing it. The next test covers a wipe that
      // meets a directory still in use.
      await _waitUntilReleasable(killed, const Duration(seconds: 240));
      await open(port, 'a'); // starts a fresh helper, whose start-up wipe runs
      check(port.helperInfo!.wipeRemoved).equals(1);
      check(port.helperInfo!.wipeFailed).equals(0);
      check(killed.existsSync()).isFalse();
      check(await port.wipeAllSourceData()).isA<BrowserCompleted<void>>();
      final left = <String>[
        for (final FileSystemEntity e in root.listSync()) p.basename(e.path),
      ]..remove('h-${port.helperInfo!.pid}');
      check(left).isEmpty();
    }, timeout: const Timeout(Duration(minutes: 6)));

    test(
      'a directory still in use is left whole and reported; a later wipe removes it',
      skip: Platform.isWindows
          ? null
          : 'Windows file locking; POSIX hosts check the owning helper process instead (next test)',
      () async {
        final Directory root = await Directory.systemTemp.createTemp('dwv-wipe-');
        addTearDown(() async {
          try {
            await root.delete(recursive: true);
          } on FileSystemException {
            // Browser process still releasing the directory.
          }
        });
        final stale = Directory(p.join(root.path, 'h-999998'));
        final held = File(p.join(stale.path, 'EBWebView', 'lockfile'));
        await held.create(recursive: true);
        await held.writeAsString('held');
        // An open handle without delete sharing: the directory cannot be
        // renamed, as when a browser process still holds it.
        final RandomAccessFile handle = held.openSync(mode: FileMode.append);
        final port = DesktopBrowserPort(
          DesktopWebViewConfig(
            helperExecutable: helper,
            dataRoot: root,
            startupTimeout: const Duration(seconds: 60),
            shutdownGrace: const Duration(seconds: 10),
            allowVisibleWindows: false,
            offline: true,
            wipeRetry: const Duration(milliseconds: 400),
          ),
        );
        addTearDown(port.dispose);
        final BrowserOutcome<void> blocked = await port.wipeAllSourceData();
        check(port.helperInfo!.wipeFailed).equals(1);
        check(blocked).isA<BrowserCapabilityUnavailable<void>>().has((o) => o.reason, 'reason').contains('h-999998');
        check(held.readAsStringSync()).equals('held');
        await port.dispose();

        // Within a budget, one wipe keeps retrying until the directory is
        // released (here 500 ms in).
        final retrying = DesktopBrowserPort(
          DesktopWebViewConfig(
            helperExecutable: helper,
            dataRoot: root,
            startupTimeout: const Duration(seconds: 60),
            shutdownGrace: const Duration(seconds: 10),
            allowVisibleWindows: false,
            offline: true,
            wipeRetry: const Duration(seconds: 10),
          ),
        );
        addTearDown(retrying.dispose);
        // Start the helper first, so the wipe request is in flight when the
        // directory is released.
        check(
          await retrying.openSession(BrowserSessionRequest(source: _source('a'), generation: 1)),
        ).isA<BrowserCompleted<BrowserSession>>();
        check(retrying.helperInfo!.wipeFailed).equals(1);
        final Future<BrowserOutcome<void>> wiping = retrying.wipeAllSourceData();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        check(stale.existsSync()).isTrue();
        handle.closeSync();
        check(await wiping).isA<BrowserCompleted<void>>();
        check(stale.existsSync()).isFalse();
      },
    );

    // POSIX lets a directory in use be renamed and removed, so the helper
    // leaves `h-<pid>` alone while that process runs (two concurrent
    // conversions each start a helper over the same data root).
    test(
      'a running helper directory is left whole and reported; removed once its process ends',
      skip: Platform.isWindows ? 'POSIX process check; Windows uses file locking (previous test)' : null,
      () async {
        final Directory root = await Directory.systemTemp.createTemp('dwv-wipe-');
        addTearDown(() => root.delete(recursive: true));
        final Process owner = await Process.start('sleep', <String>['60']);
        addTearDown(owner.kill);
        final live = Directory(p.join(root.path, 'h-${owner.pid}'));
        final kept = File(p.join(live.path, 'content-rules', 'kept'));
        await kept.create(recursive: true);
        DesktopWebViewConfig config() => DesktopWebViewConfig(
          helperExecutable: helper,
          dataRoot: root,
          startupTimeout: const Duration(seconds: 60),
          shutdownGrace: const Duration(seconds: 10),
          allowVisibleWindows: false,
          offline: true,
          wipeRetry: const Duration(milliseconds: 400),
        );
        final first = DesktopBrowserPort(config());
        addTearDown(first.dispose);
        final BrowserOutcome<void> blocked = await first.wipeAllSourceData();
        check(first.helperInfo!.wipeFailed).equals(1);
        check(blocked)
            .isA<BrowserCapabilityUnavailable<void>>()
            .has((BrowserCapabilityUnavailable<void> o) => o.reason, 'reason')
            .contains('h-${owner.pid}');
        check(kept.existsSync()).isTrue();
        await first.dispose();

        owner.kill(ProcessSignal.sigkill);
        await owner.exitCode;
        final second = DesktopBrowserPort(config());
        addTearDown(second.dispose);
        check(
          await second.openSession(BrowserSessionRequest(source: _source('a'), generation: 1)),
        ).isA<BrowserCompleted<BrowserSession>>();
        check(second.helperInfo!.wipeFailed).equals(0);
        check(live.existsSync()).isFalse();
      },
    );
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

    test('an HTTP error page is a completed load carrying its status, not a navigation failure', () async {
      final DesktopBrowserPort port = await newPort();
      final DesktopBrowserSession s = await open(port, 'a');
      for (final code in <int>[403, 404, 503]) {
        final BrowserOutcome<BrowserPage> loaded = await s.loadUrl(server.url('/status/$code'));
        check(loaded).isA<BrowserCompleted<BrowserPage>>();
        if (port.helperInfo!.capabilities.statusCodes) check(loaded.valueOrNull!.statusCode).equals(code);
        check((await s.evaluate('document.title')).valueOrNull).equals('"status"');
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
