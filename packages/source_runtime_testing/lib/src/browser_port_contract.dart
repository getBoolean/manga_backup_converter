import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_testing/src/fake_browser_port.dart';
import 'package:test/scaffolding.dart';

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

  /// A script that posts [message] to the handler registered as [name].
  String postMessageScript(String name, String message);
}

SourceIdentity _source(String id) => SourceIdentity(
  ecosystem: 'contract',
  packageId: 'contract.package',
  sourceId: id,
  artifact: const ArtifactBinding(sha256: '00', kind: 'test', version: '1'),
);

/// Registers the reusable `BrowserPort` contract tests, creating a fresh
/// harness with [createHarness] for every test.
void runBrowserPortContractSuite(String name, BrowserPortHarness Function() createHarness) {
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

      test('delivers page messages to the registered handler', () async {
        final BrowserSession s = await open(sourceA);
        check(await s.loadUrl(harness.pageUrl)).isA<BrowserCompleted<BrowserPage>>();
        final messages = <String>[];
        check(await s.setMessageHandler('bridge', messages.add)).isA<BrowserCompleted<void>>();
        check(await s.evaluate(harness.postMessageScript('bridge', 'hello'))).isA<BrowserCompleted<String>>();
        await Future<void>.delayed(Duration.zero);
        check(messages).deepEquals(<String>['hello']);
      });

      test('showForInteraction reports interaction-required without a display', () async {
        final BrowserSession s = await open(sourceA);
        final BrowserOutcome<void> shown = await s.showForInteraction(timeout: const Duration(seconds: 1));
        if (harness.canShowInteraction) {
          check(shown).isA<BrowserCompleted<void>>();
        } else {
          check(shown).isA<BrowserInteractionRequired<void>>();
        }
      });
    });
  });
}

/// [BrowserPortHarness] for [FakeBrowserPort]. Its store outlives a killed
/// port, so the kill-and-restart test exercises start-up wiping.
class FakeBrowserPortHarness implements BrowserPortHarness {
  FakeBrowserPortHarness();

  final FakeBrowserStore store = FakeBrowserStore();
  FakeBrowserPort? _port;

  @override
  final Uri pageUrl = Uri.parse('https://contract.test/page');

  @override
  final Uri redirectToFileUrl = Uri.parse('https://contract.test/to-file');

  @override
  bool get canShowInteraction => false;

  FakeWebPage? _resolve(Uri url) {
    if (url == pageUrl) return const FakeWebPage(html: '<html><head><title>contract</title></head></html>');
    if (url == redirectToFileUrl) return FakeWebPage(status: 302, redirectTo: Uri.parse('file:///etc/passwd'));
    return null;
  }

  @override
  Future<BrowserPort> start() async => _port = FakeBrowserPort(pages: _resolve, store: store);

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
  String postMessageScript(String name, String message) => FakeBrowserPort.postMessageScript(name, message);
}
