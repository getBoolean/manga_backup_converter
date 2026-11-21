import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_testing/src/fake_browser_port.dart';
import 'package:test/scaffolding.dart';
import 'package:test/scaffolding.dart' as scaffolding show test;

/// Drives one `BrowserPort` implementation through the contract suite.
///
/// Implemented once per platform (fake, desktop helper, iOS, Android). The
/// harness owns the real resources: it serves pages, starts and kills the
/// helper or app process, and builds scripts in the platform's terms.
abstract interface class BrowserPortHarness {
  /// Starts (or restarts after [kill]) the implementation. Implementations
  /// with a persistent store must wipe source data during start-up.
  Future<BrowserPort> start();

  /// Terminates the implementation abruptly, without closing sessions.
  Future<void> kill();

  /// Normal teardown after each test.
  Future<void> stop();

  /// An http(s) page the harness serves; its title is `contract`.
  Uri get pageUrl;

  /// An http(s) URL that redirects to a `file:` URL.
  Uri get redirectToFileUrl;

  /// Whether a visible interaction can be shown in this environment.
  bool get canShowInteraction;

  /// A script that completes with [resultJson] only after [releaseHeld].
  String heldScript(String resultJson);

  /// Releases every evaluation started from a [heldScript].
  Future<void> releaseHeld();

  /// An http(s) page the harness serves that embeds one child frame from a
  /// different origin (another host or port).
  Uri get crossOriginFramePageUrl;

  /// A script, evaluated in the top frame of [crossOriginFramePageUrl], that
  /// makes its cross-origin child frame call
  /// `window.<name>.postMessage(message)`. It completes once the frame has
  /// made the call.
  String crossOriginFramePostScript(String name, String message);

  /// An http(s) page the harness serves that embeds one child frame,
  /// [sameOriginFrameUrl], from the same origin (protocol 1.2).
  Uri get sameOriginFramePageUrl;

  /// The child frame of [sameOriginFramePageUrl].
  Uri get sameOriginFrameUrl;

  /// An http(s) endpoint on the origin of [pageUrl] that answers every
  /// method with status 200 and the text `<METHOD> <request body>` (for a
  /// `GET`, `GET ` and an empty body), with
  /// `Access-Control-Allow-Origin: *` (protocol 1.2).
  Uri get echoUrl;
}

/// Page scripts the contract suite evaluates (protocol 1.2). Each is real
/// JavaScript; the fetch script also carries a comment the fake reads.
abstract final class BrowserContractScripts {
  /// Fetches [url] with [method] and [body] from the current page, then
  /// posts the response text on channel [channel], or `fetch-failed` when
  /// the fetch fails. Evaluates to a promise that settles after posting.
  static String fetchAndPost(String channel, Uri url, {String method = 'GET', String? body}) {
    final String spec = jsonEncode(<String, Object?>{
      'channel': channel,
      'url': url.toString(),
      'method': method,
      'body': body,
    }).replaceAll('*/', r'*\/');
    final String c = jsonEncode(channel);
    return <String>[
      '${FakeBrowserPort.fetchMarker}$spec*/ ',
      '(function(){var o={method:${jsonEncode(method)}};',
      if (body != null) 'o.body=${jsonEncode(body)};',
      'return fetch(${jsonEncode(url.toString())},o)',
      '.then(function(r){return r.text();})',
      '.then(function(t){window[$c].postMessage(t);},function(){window[$c].postMessage("fetch-failed");});})()',
    ].join();
  }

  /// Posts the frame's own `location.href` on channel [name]; as a
  /// page-start script it reports every frame it runs in.
  static String postLocation(String name) => 'window.$name.postMessage(location.href)';
}

/// Waits until [messages] contains [expected]; fails after a bound so a
/// platform that never delivers fails the test instead of hanging it.
Future<void> _waitFor(List<String> messages, String expected) =>
    _waitUntil(() => messages.contains(expected), () => 'Message "$expected" was not delivered; got $messages');

Future<void> _waitUntil(bool Function() condition, String Function() failure) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError(failure());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Checks that [outcome] is a capability failure naming [operation] with a
/// non-empty reason, and that [capabilities] name a reason for [feature].
void _checkUnavailable(
  BrowserOutcome<Object?> outcome,
  String operation,
  BrowserCapabilities capabilities,
  BrowserFeature feature,
) {
  check(outcome).isA<BrowserCapabilityUnavailable<Object?>>()
    ..has((BrowserCapabilityUnavailable<Object?> o) => o.operation, 'operation').equals(operation)
    ..has((BrowserCapabilityUnavailable<Object?> o) => o.reason.trim(), 'reason').isNotEmpty();
  check(capabilities.reasonFor(feature)).isNotNull().isNotEmpty();
}

SourceIdentity _source(String id) => SourceIdentity(
  ecosystem: 'contract',
  packageId: 'contract.package',
  sourceId: id,
  artifact: const ArtifactBinding(sha256: '00', kind: 'test', version: '1'),
);

/// Registers the reusable `BrowserPort` contract tests, creating a fresh
/// harness with [createHarness] for every test.
///
/// [knownFailures] maps a contract test's own description (without its
/// group names) to the reason that implementation cannot pass it yet; those
/// tests are skipped with that reason. Use it only for a documented
/// follow-up, never to weaken the contract. A key that names no contract
/// test fails the suite, so a stale entry cannot linger.
void runBrowserPortContractSuite(
  String name,
  BrowserPortHarness Function() createHarness, {
  Map<String, String> knownFailures = const <String, String>{},
}) {
  final registered = <String>{};
  void test(String description, FutureOr<void> Function() body) {
    registered.add(description);
    scaffolding.test(description, body, skip: knownFailures[description]);
  }

  group('BrowserPort contract: $name', () {
    late BrowserPortHarness harness;
    late BrowserPort port;
    final SourceIdentity sourceA = _source('a');
    final SourceIdentity sourceB = _source('b');

    Future<BrowserSession> open(SourceIdentity source, {int generation = 1}) async {
      final BrowserOutcome<BrowserSession> opened = await port.openSession(
        BrowserSessionRequest(source: source, generation: generation),
      );
      check(opened).isA<BrowserCompleted<BrowserSession>>();
      return opened.valueOrNull!;
    }

    Future<void> seedStorage(BrowserSession s) async {
      check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
      check(
        await s.setCookie(harness.pageUrl, const BrowserCookie(name: 'token', value: 'secret-cookie')),
      ).isA<BrowserCompleted<void>>();
      check(await s.evaluate('document.cookie = "js=1"')).isA<BrowserCompleted<String>>();
      check(await s.evaluate('localStorage.setItem("k", "v")')).isA<BrowserCompleted<String>>();
      check((await s.getCookies(harness.pageUrl)).valueOrNull!).isNotEmpty();
    }

    Future<void> expectNoStorage(BrowserSession s) async {
      check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
      check((await s.getCookies(harness.pageUrl)).valueOrNull!).isEmpty();
      check((await s.evaluate('localStorage.getItem("k")')).valueOrNull).equals('null');
    }

    setUp(() async {
      harness = createHarness();
      port = await harness.start();
    });

    tearDown(() => harness.stop());

    group('allowed schemes', () {
      test('loads an http(s) page', () async {
        final BrowserSession s = await open(sourceA);
        final BrowserOutcome<BrowserPage> loaded = await s.loadUrl(harness.pageUrl);
        check(loaded).isA<BrowserCompleted<BrowserPage>>();
        check(loaded.valueOrNull!.finalUrl).equals(harness.pageUrl);
        check((await s.evaluate('document.title')).valueOrNull).equals(jsonEncode('contract'));
      });

      test('loads about:blank', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(Uri.parse('about:blank'))).isA<BrowserCompleted<BrowserPage>>();
      });

      test('loads data with an http(s) base URL', () async {
        final BrowserSession s = await open(sourceA);
        check(
          await s.loadData('<html><title>t</title></html>', baseUrl: Uri.parse('https://example.org/')),
        ).isA<BrowserCompleted<BrowserPage>>();
      });

      for (final url in <String>[
        'file:///etc/passwd',
        'file:///C:/Windows/win.ini',
        'content://com.example/data',
        'app://local/index.html',
        'javascript:alert(1)',
        'data:text/html,<p>x</p>',
      ]) {
        test('refuses loading $url', () async {
          final BrowserSession s = await open(sourceA);
          check(await s.loadUrl(Uri.parse(url))).isA<BrowserCapabilityUnavailable<BrowserPage>>();
        });
      }

      test('refuses a redirect to file://', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.redirectToFileUrl)).isA<BrowserCapabilityUnavailable<BrowserPage>>();
      });

      for (final base in <String>['file:///tmp/', 'about:blank', 'app://local/']) {
        test('refuses loadData with base URL $base', () async {
          final BrowserSession s = await open(sourceA);
          check(
            await s.loadData('<p>x</p>', baseUrl: Uri.parse(base)),
          ).isA<BrowserCapabilityUnavailable<BrowserPage>>();
        });
      }
    });

    group('storage', () {
      test('leaves no cookies or web storage after a session closes', () async {
        final BrowserSession first = await open(sourceA);
        await seedStorage(first);
        check(await first.close()).isA<BrowserCompleted<void>>();
        await expectNoStorage(await open(sourceA));
      });

      test('leaves no cookies or web storage after a mid-session kill and restart', () async {
        final BrowserSession first = await open(sourceA);
        await seedStorage(first);
        await harness.kill();
        port = await harness.start();
        await expectNoStorage(await open(sourceA));
      });

      test('scopes cookies and web storage to the source', () async {
        final BrowserSession a = await open(sourceA);
        await seedStorage(a);
        await expectNoStorage(await open(sourceB));
      });

      test('operations on a closed session are cancelled', () async {
        final BrowserSession s = await open(sourceA);
        await s.close();
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCancelled<BrowserPage>>();
        check(await s.evaluate('1 + 1')).isA<BrowserCancelled<String>>();
      });
    });

    group('generation fencing and cancellation', () {
      test('a late callback after a generation change never resolves a newer request', () async {
        final BrowserSession old = await open(sourceA);
        check(await old.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final Future<BrowserOutcome<String>> stale = old.evaluate(harness.heldScript('"old"'));
        await port.fence(2);
        final BrowserSession current = await open(sourceA, generation: 2);
        check(await current.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final Future<BrowserOutcome<String>> fresh = current.evaluate(harness.heldScript('"new"'));
        await harness.releaseHeld();
        check(await stale).isA<BrowserCancelled<String>>();
        check((await fresh).valueOrNull).equals('"new"');
      });

      test('refuses to open a session for a fenced generation', () async {
        await port.fence(5);
        final BrowserOutcome<BrowserSession> opened = await port.openSession(
          BrowserSessionRequest(source: sourceA, generation: 4),
        );
        check(opened).isA<BrowserCancelled<BrowserSession>>();
      });

      test('a cancelled operation resolves as cancelled', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final cancel = CancellationSource();
        final Future<BrowserOutcome<String>> pending = s.evaluate(harness.heldScript('1'), cancel: cancel.token);
        cancel.cancel('user cancelled');
        check(await pending).isA<BrowserCancelled<String>>();
        await harness.releaseHeld();
      });
    });

    group('scripts, messages and interaction', () {
      test('evaluates a script and returns its JSON result', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        check((await s.evaluate('1 + 1')).valueOrNull).equals('2');
      });

      test('delivers window.<name>.postMessage(string) to the registered handler', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final messages = <String>[];
        check(await s.setMessageHandler('bridge', messages.add)).isA<BrowserCompleted<void>>();
        check(
          await s.evaluate(BrowserMessageChannel.postScript('bridge', 'hello')),
        ).isA<BrowserCompleted<String>>();
        await _waitFor(messages, 'hello');
        check(messages).deepEquals(<String>['hello']);
      });

      test('delivers messages from loadData content with an http(s) base URL', () async {
        final BrowserSession s = await open(sourceA);
        final messages = <String>[];
        check(await s.setMessageHandler('bridge', messages.add)).isA<BrowserCompleted<void>>();
        check(
          await s.loadData('<html><title>challenge</title></html>', baseUrl: Uri.parse('https://example.org/')),
        ).isA<BrowserCompleted<BrowserPage>>();
        await s.evaluate(BrowserMessageChannel.postScript('bridge', 'solved'));
        await _waitFor(messages, 'solved');
        check(messages).deepEquals(<String>['solved']);
      });

      test('a channel registered before a load is present in the loaded page', () async {
        final BrowserSession s = await open(sourceA);
        final messages = <String>[];
        check(await s.setMessageHandler('bridge', messages.add)).isA<BrowserCompleted<void>>();
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        await s.evaluate(BrowserMessageChannel.postScript('bridge', 'after load'));
        await _waitFor(messages, 'after load');
        check(messages).deepEquals(<String>['after load']);
      });

      test('a removed channel delivers nothing', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final removed = <String>[];
        final kept = <String>[];
        check(await s.setMessageHandler('gone', removed.add)).isA<BrowserCompleted<void>>();
        check(await s.setMessageHandler('kept', kept.add)).isA<BrowserCompleted<void>>();
        check(await s.setMessageHandler('gone', null)).isA<BrowserCompleted<void>>();
        // The page may throw once the object is gone; only delivery matters.
        await s.evaluate(BrowserMessageChannel.postScript('gone', 'x'));
        await s.evaluate(BrowserMessageChannel.postScript('kept', 'marker'));
        await _waitFor(kept, 'marker');
        check(removed).isEmpty();
      });

      test('drops messages from a frame whose origin differs from the loaded page', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.crossOriginFramePageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final messages = <String>[];
        check(await s.setMessageHandler('bridge', messages.add)).isA<BrowserCompleted<void>>();
        check(
          await s.evaluate(harness.crossOriginFramePostScript('bridge', 'cross-origin')),
        ).isA<BrowserCompleted<String>>();
        // Same-origin marker posted afterwards: once it arrives, any delivery
        // of the cross-origin message would have happened.
        await s.evaluate(BrowserMessageChannel.postScript('bridge', 'same-origin'));
        await _waitFor(messages, 'same-origin');
        check(messages).deepEquals(<String>['same-origin']);
      });

      test('drops messages posted from about:blank', () async {
        final BrowserSession s = await open(sourceA);
        final blank = <String>[];
        check(await s.setMessageHandler('bridge', blank.add)).isA<BrowserCompleted<void>>();
        check(await s.loadUrl(Uri.parse('about:blank'))).isA<BrowserCompleted<BrowserPage>>();
        await s.evaluate(BrowserMessageChannel.postScript('bridge', 'blank'));
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        await s.evaluate(BrowserMessageChannel.postScript('bridge', 'page'));
        await _waitFor(blank, 'page');
        check(blank).deepEquals(<String>['page']);
      });

      for (final name in <String>['', '1bridge', 'a.b', 'a-b', 'a b', 'x;alert(1)']) {
        test('refuses channel name "$name"', () async {
          final BrowserSession s = await open(sourceA);
          check(await s.setMessageHandler(name, (_) {})).isA<BrowserCapabilityUnavailable<void>>();
        });
      }

      test('showForInteraction reports interaction-required without a display', () async {
        final BrowserSession s = await open(sourceA);
        final BrowserOutcome<void> shown = await s.showForInteraction(timeout: const Duration(seconds: 1));
        if (harness.canShowInteraction) {
          check(shown).isA<BrowserCompleted<void>>();
        } else {
          check(shown).isA<BrowserInteractionRequired<void>>();
        }
      });

      test('accepts "ipc" as a channel name without breaking evaluation or other channels', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final ipc = <String>[];
        final other = <String>[];
        check(await s.setMessageHandler('ipc', ipc.add)).isA<BrowserCompleted<void>>();
        check(await s.setMessageHandler('bridge', other.add)).isA<BrowserCompleted<void>>();
        await s.evaluate(BrowserMessageChannel.postScript('ipc', 'via ipc'));
        await _waitFor(ipc, 'via ipc');
        check((await s.evaluate('1 + 1')).valueOrNull).equals('2');
        await s.evaluate(BrowserMessageChannel.postScript('bridge', 'via bridge'));
        await _waitFor(other, 'via bridge');
        // Still delivered after a navigation re-installs the channels.
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        await s.evaluate(BrowserMessageChannel.postScript('ipc', 'after load'));
        await _waitFor(ipc, 'after load');
        check(ipc).deepEquals(<String>['via ipc', 'after load']);
      });
    });

    group('protocol 1.2 capabilities', () {
      test('names a reason for every unavailable feature', () async {
        final BrowserSession s = await open(sourceA);
        final BrowserCapabilities caps = s.capabilities;
        for (final BrowserFeature f in BrowserFeature.values) {
          if (caps.supports(f)) {
            check(caps.reasonFor(f)).isNull();
          } else {
            check(caps.reasonFor(f)).isNotNull().isNotEmpty();
          }
        }
        if (caps.supports(BrowserFeature.replaceRequests)) {
          check(caps.interceptionTier).equals(BrowserInterceptionTier.replace);
        }
      });

      test('evaluate reports a throwing script as a script error, or null without the feature', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final BrowserOutcome<String> thrown = await s.evaluate('throw new Error("contract-boom")');
        if (s.capabilities.supports(BrowserFeature.scriptErrors)) {
          check(thrown)
              .isA<BrowserScriptError<String>>()
              .has((BrowserScriptError<String> e) => e.message, 'message')
              .contains('contract-boom');
        } else {
          check(thrown)
              .isA<BrowserCompleted<String>>()
              .has((BrowserCompleted<String> c) => c.value, 'value')
              .equals('null');
          check(s.capabilities.reasonFor(BrowserFeature.scriptErrors)).isNotNull().isNotEmpty();
        }
        check(thrown.androidCompatible.valueOrNull).equals('null');
        // A script that returns null is still a completed null.
        check(await s.evaluate('localStorage.getItem("absent")')).isA<BrowserCompleted<String>>();
      });
    });

    group('protocol 1.2 page-start scripts', () {
      test('run at document start in the top frame and a same-origin child frame', () async {
        final BrowserSession s = await open(sourceA);
        final messages = <String>[];
        check(await s.setMessageHandler('probe', messages.add)).isA<BrowserCompleted<void>>();
        final BrowserOutcome<void> added = await s.addPageStartScript(BrowserContractScripts.postLocation('probe'));
        if (!s.capabilities.supports(BrowserFeature.pageStartScripts)) {
          _checkUnavailable(added, 'addPageStartScript', s.capabilities, BrowserFeature.pageStartScripts);
          return;
        }
        check(added).isA<BrowserCompleted<void>>();
        check(await s.loadUrl(harness.sameOriginFramePageUrl)).isA<BrowserCompleted<BrowserPage>>();
        await _waitFor(messages, harness.sameOriginFramePageUrl.toString());
        await _waitFor(messages, harness.sameOriginFrameUrl.toString());
      });

      test('apply to later documents, including loadData content, but not the current one', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final BrowserOutcome<void> added = await s.addPageStartScript('window.__contractStart = "ran"');
        if (!s.capabilities.supports(BrowserFeature.pageStartScripts)) {
          _checkUnavailable(added, 'addPageStartScript', s.capabilities, BrowserFeature.pageStartScripts);
          return;
        }
        check((await s.evaluate('window.__contractStart')).valueOrNull).equals('null');
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        check((await s.evaluate('window.__contractStart')).valueOrNull).equals('"ran"');
        check(
          await s.loadData('<html><title>t</title></html>', baseUrl: Uri.parse('https://example.org/')),
        ).isA<BrowserCompleted<BrowserPage>>();
        check((await s.evaluate('window.__contractStart')).valueOrNull).equals('"ran"');
      });

      test('messages a page-start script posts from a cross-origin frame are dropped', () async {
        final BrowserSession s = await open(sourceA);
        final messages = <String>[];
        check(await s.setMessageHandler('probe', messages.add)).isA<BrowserCompleted<void>>();
        final BrowserOutcome<void> added = await s.addPageStartScript(BrowserContractScripts.postLocation('probe'));
        if (!s.capabilities.supports(BrowserFeature.pageStartScripts)) {
          _checkUnavailable(added, 'addPageStartScript', s.capabilities, BrowserFeature.pageStartScripts);
          return;
        }
        check(await s.loadUrl(harness.crossOriginFramePageUrl)).isA<BrowserCompleted<BrowserPage>>();
        await _waitFor(messages, harness.crossOriginFramePageUrl.toString());
        await s.evaluate(BrowserMessageChannel.postScript('probe', 'marker'));
        await _waitFor(messages, 'marker');
        check(messages).deepEquals(<String>[harness.crossOriginFramePageUrl.toString(), 'marker']);
      });
    });

    group('protocol 1.2 request interception', () {
      Future<List<String>> fetchEcho(BrowserSession s, {String method = 'GET', String? body}) async {
        final messages = <String>[];
        check(await s.setMessageHandler('fetched', messages.add)).isA<BrowserCompleted<void>>();
        await s.evaluate(BrowserContractScripts.fetchAndPost('fetched', harness.echoUrl, method: method, body: body));
        await _waitUntil(() => messages.isNotEmpty, () => 'fetch of ${harness.echoUrl} posted nothing');
        return messages;
      }

      test('the observer sees a main-frame navigation with its headers', () async {
        final BrowserSession s = await open(sourceA);
        final BrowserCapabilities caps = s.capabilities;
        final observed = <BrowserRequest>[];
        final BrowserOutcome<void> set = await s.setRequestObserver(observed.add);
        if (caps.interceptionTier == BrowserInterceptionTier.none) {
          _checkUnavailable(set, 'setRequestObserver', caps, BrowserFeature.observeNavigations);
          return;
        }
        check(set).isA<BrowserCompleted<void>>();
        check(
          await s.loadUrl(harness.pageUrl, headers: const <String, String>{'X-Contract': 'yes'}),
        ).isA<BrowserCompleted<BrowserPage>>();
        final List<BrowserRequest> main = observed.where((BrowserRequest r) => r.url == harness.pageUrl).toList();
        if (!caps.supports(BrowserFeature.observeNavigations)) {
          check(caps.reasonFor(BrowserFeature.observeNavigations)).isNotNull().isNotEmpty();
          return;
        }
        check(main).isNotEmpty();
        check(main.first)
          ..has((BrowserRequest r) => r.method, 'method').equals('GET')
          ..has((BrowserRequest r) => r.mainFrame, 'mainFrame').isTrue();
        if (caps.supports(BrowserFeature.observeRequestHeaders)) {
          check(main.first.header('x-contract')).equals('yes');
        }
        if (caps.supports(BrowserFeature.observeClientHints)) {
          check(main.first.header('sec-ch-ua')).isNotNull();
        } else {
          check(caps.reasonFor(BrowserFeature.observeClientHints)).isNotNull().isNotEmpty();
        }
      });

      test('a POST subresource proceeds, and is observed with its body where the engine allows', () async {
        final BrowserSession s = await open(sourceA);
        final BrowserCapabilities caps = s.capabilities;
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final observed = <BrowserRequest>[];
        final BrowserOutcome<void> set = await s.setRequestObserver(observed.add);
        if (caps.interceptionTier == BrowserInterceptionTier.none) {
          _checkUnavailable(set, 'setRequestObserver', caps, BrowserFeature.observeNavigations);
        }
        check(await fetchEcho(s, method: 'POST', body: 'contract-body')).deepEquals(<String>['POST contract-body']);
        final List<BrowserRequest> posts = observed
            .where((BrowserRequest r) => r.url == harness.echoUrl && r.method == 'POST')
            .toList();
        if (!caps.supports(BrowserFeature.observeSubresources) || set is! BrowserCompleted<void>) {
          check(posts).isEmpty();
          check(caps.reasonFor(BrowserFeature.observeSubresources)).isNotNull().isNotEmpty();
          return;
        }
        check(posts).length.equals(1);
        check(posts.single.mainFrame).isFalse();
        if (caps.supports(BrowserFeature.observeRequestBodies)) {
          check(posts.single.body).isNotNull().deepEquals(utf8.encode('contract-body'));
        } else {
          check(posts.single.body).isNull();
          check(posts.single.bodyOmitted).isTrue();
          check(caps.reasonFor(BrowserFeature.observeRequestBodies)).isNotNull().isNotEmpty();
        }
      });

      test('a removed observer sees nothing, and none is called after close', () async {
        final BrowserSession s = await open(sourceA);
        final observed = <BrowserRequest>[];
        if (await s.setRequestObserver(observed.add) is! BrowserCompleted<void>) return;
        check(await s.setRequestObserver(null)).isA<BrowserCompleted<void>>();
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        check(observed).isEmpty();
        check(await s.setRequestObserver(observed.add)).isA<BrowserCompleted<void>>();
        await s.close();
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCancelled<BrowserPage>>();
        check(observed).isEmpty();
      });

      test('the replacer supplies a response, or the replace tier is refused with a named reason', () async {
        final BrowserSession s = await open(sourceA);
        final BrowserCapabilities caps = s.capabilities;
        final seen = <BrowserRequest>[];
        final BrowserOutcome<void> set = await s.setRequestReplacer((BrowserRequest r) {
          seen.add(r);
          return r.url == harness.echoUrl ? BrowserReplacement(status: 200, body: utf8.encode('replaced')) : null;
        });
        if (!caps.supports(BrowserFeature.replaceRequests)) {
          _checkUnavailable(set, 'setRequestReplacer', caps, BrowserFeature.replaceRequests);
          check(await s.setRequestReplacer(null)).isA<BrowserCompleted<void>>();
          return;
        }
        check(set).isA<BrowserCompleted<void>>();
        // A null answer lets the page load unchanged.
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        check((await s.evaluate('document.title')).valueOrNull).equals(jsonEncode('contract'));
        check(await fetchEcho(s, method: 'POST', body: 'original')).deepEquals(<String>['replaced']);
        final BrowserRequest post = seen.lastWhere((BrowserRequest r) => r.url == harness.echoUrl);
        check(post.method).equals('POST');
        if (caps.supports(BrowserFeature.observeRequestBodies)) {
          check(post.body).isNotNull().deepEquals(utf8.encode('original'));
        }
        check(await s.setRequestReplacer(null)).isA<BrowserCompleted<void>>();
        check(await fetchEcho(s)).deepEquals(<String>['GET ']);
      });

      test('a redirect replacement is refused and the request fails', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final BrowserOutcome<void> set = await s.setRequestReplacer(
          (BrowserRequest r) => r.url == harness.echoUrl
              ? BrowserReplacement(
                  status: 302,
                  reason: 'Found',
                  headers: const <String, String>{'Location': 'file:///etc/passwd'},
                )
              : null,
        );
        if (set is! BrowserCompleted<void>) return;
        check(await fetchEcho(s)).deepEquals(<String>['fetch-failed']);
      });

      test('interception never widens the scheme policy', () async {
        final BrowserSession s = await open(sourceA);
        final seen = <Uri>[];
        // A pass-through interceptor at the highest tier the engine has.
        if (await s.setRequestReplacer((BrowserRequest r) {
          seen.add(r.url);
          return null;
        }) is! BrowserCompleted<void>) {
          if (await s.setRequestObserver((BrowserRequest r) => seen.add(r.url)) is! BrowserCompleted<void>) return;
        }
        check(await s.loadUrl(harness.redirectToFileUrl)).isA<BrowserCapabilityUnavailable<BrowserPage>>();
        check(await s.loadUrl(Uri.parse('file:///etc/passwd'))).isA<BrowserCapabilityUnavailable<BrowserPage>>();
        check(seen.where((Uri u) => !BrowserUrlPolicy.isAllowedBaseUrl(u))).isEmpty();
      });

      test('setting a replacer removes the observer', () async {
        final BrowserSession s = await open(sourceA);
        final observed = <BrowserRequest>[];
        if (await s.setRequestObserver(observed.add) is! BrowserCompleted<void>) return;
        if (await s.setRequestReplacer((_) => null) is! BrowserCompleted<void>) return;
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        check(observed).isEmpty();
      });
    });

    test('every known failure names a contract test', () {
      check(knownFailures.keys.where((String k) => !registered.contains(k))).isEmpty();
    });
  });
}

/// [BrowserPortHarness] for [FakeBrowserPort]. Its store outlives a killed
/// port, so the kill-and-restart test exercises start-up wiping.
///
/// [capabilities] selects the engine profile the fake reports, so the suite
/// can run against both the full feature set and degraded ones.
class FakeBrowserPortHarness implements BrowserPortHarness {
  FakeBrowserPortHarness({this.capabilities});

  final BrowserCapabilities? capabilities;

  final FakeBrowserStore store = FakeBrowserStore();
  FakeBrowserPort? _port;

  @override
  final Uri pageUrl = Uri.parse('https://contract.test/page');

  @override
  final Uri redirectToFileUrl = Uri.parse('https://contract.test/to-file');

  @override
  final Uri crossOriginFramePageUrl = Uri.parse('https://contract.test/framed');

  /// The cross-origin child frame of [crossOriginFramePageUrl].
  final Uri crossOriginFrameUrl = Uri.parse('https://other-origin.test/frame');

  @override
  final Uri sameOriginFramePageUrl = Uri.parse('https://contract.test/same-framed');

  @override
  final Uri sameOriginFrameUrl = Uri.parse('https://contract.test/frame');

  @override
  final Uri echoUrl = Uri.parse('https://contract.test/echo');

  @override
  bool get canShowInteraction => false;

  FakeWebPage? _resolve(Uri url) {
    if (url == pageUrl) return const FakeWebPage(html: '<html><head><title>contract</title></head></html>');
    if (url == redirectToFileUrl) return FakeWebPage(status: 302, redirectTo: Uri.parse('file:///etc/passwd'));
    if (url == crossOriginFramePageUrl) {
      return FakeWebPage(html: '<html><head><title>framed</title></head></html>', frames: <Uri>[crossOriginFrameUrl]);
    }
    if (url == sameOriginFramePageUrl) {
      return FakeWebPage(html: '<html><head><title>framed</title></head></html>', frames: <Uri>[sameOriginFrameUrl]);
    }
    return null;
  }

  FakeWebPage? _resolveRequest(BrowserRequest request) {
    if (request.url == echoUrl) {
      return FakeWebPage(html: '${request.method} ${utf8.decode(request.body ?? const <int>[])}');
    }
    return request.method == 'GET' ? _resolve(request.url) : null;
  }

  @override
  Future<BrowserPort> start() async => _port = FakeBrowserPort(
    pages: _resolve,
    requests: _resolveRequest,
    store: store,
    capabilities: capabilities,
  );

  @override
  Future<void> kill() async => _port = null;

  @override
  Future<void> stop() async {
    _port?.releaseHeld();
    _port = null;
  }

  @override
  String heldScript(String resultJson) => FakeBrowserPort.heldScript(resultJson);

  @override
  Future<void> releaseHeld() async => _port?.releaseHeld();

  @override
  String crossOriginFramePostScript(String name, String message) =>
      FakeBrowserPort.frameScript(crossOriginFrameUrl, BrowserMessageChannel.postScript(name, message));
}
