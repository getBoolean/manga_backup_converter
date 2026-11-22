// Runs the reusable BrowserPort contract suite against the fake, once per
// engine profile, so both branches of every capability-dependent case run.
// Platform implementations (desktop helper, iOS, Android) run the same suite
// through their own BrowserPortHarness: see `package:source_runtime_testing`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_testing/source_runtime_testing.dart';
import 'package:test/scaffolding.dart';

void main() {
  runBrowserPortContractSuite('FakeBrowserPort (all features)', FakeBrowserPortHarness.new);
  runBrowserPortContractSuite(
    'FakeBrowserPort (degraded, WebKit-like observation)',
    () => FakeBrowserPortHarness(capabilities: FakeBrowserPort.degradedCapabilities),
  );
  runBrowserPortContractSuite(
    'FakeBrowserPort (nothing optional reported)',
    () => FakeBrowserPortHarness(capabilities: BrowserCapabilities.unreported()),
  );
  runBrowserPortContractSuite(
    'FakeBrowserPort (with a display and a user)',
    () => FakeBrowserPortHarness(interactive: true),
  );

  group('FakeBrowserPort specifics', () {
    const source = SourceIdentity(
      ecosystem: 'test',
      packageId: 'p',
      sourceId: 's',
      artifact: ArtifactBinding(sha256: '0', kind: 't', version: '1'),
    );

    Future<BrowserSession> open(FakeBrowserPort port) async =>
        (await port.openSession(const BrowserSessionRequest(source: source, generation: 1))).valueOrNull!;

    test('close fails the capability when storage deletion cannot be confirmed', () async {
      final store = FakeBrowserStore();
      final port = FakeBrowserPort(store: store);
      final BrowserSession s = await open(port);
      store.failDeletes = true;
      check(await s.close()).isA<BrowserCapabilityUnavailable<void>>();
    });

    test('start-up wipes storage a killed process left behind', () async {
      final store = FakeBrowserStore();
      final port = FakeBrowserPort(store: store, pages: (_) => const FakeWebPage());
      final BrowserSession s = await open(port);
      await s.loadUrl(Uri.parse('https://a.example/'));
      await s.evaluate('localStorage.setItem("k", "v")');
      check(store.isEmpty).isFalse();
      FakeBrowserPort(store: store);
      check(store.isEmpty).isTrue();
    });

    test('observed requests carry the session user agent and Chromium client hints', () async {
      final port = FakeBrowserPort(pages: (_) => const FakeWebPage());
      final BrowserSession s = await open(port);
      final observed = <BrowserRequest>[];
      await s.setUserAgent('Agent/1');
      await s.setRequestObserver(observed.add);
      await s.loadUrl(Uri.parse('https://a.example/'));
      check(observed.single.header('user-agent')).equals('Agent/1');
      check(observed.single.header('sec-ch-ua-platform')).equals('"Fake"');
    });

    group('replay', () {
      final Uri verify = Uri.parse('https://mangafire.example/@waf/verify');
      final Uri page = Uri.parse('https://mangafire.example/@waf/solver');
      final List<int> recordedBody = utf8.encode('{"answer":42}');

      CaptureSet captures() {
        final Uint8List pageBody = utf8.encode('<html><title>solver</title></html>');
        final Uint8List verifyBody = utf8.encode('verified');
        CaptureExchange exchange(CaptureKey key, Uint8List body) => CaptureExchange(
          key: key,
          status: 200,
          headers: const <String, String>{},
          bodyFile: 'bodies/${sha256Hex(body)}.bin',
          artifact: CaptureArtifact(
            sourceUrl: key.url,
            sha256: sha256Hex(body),
            size: body.length,
            licence: 'test',
          ),
        );
        final manifest = CaptureManifest(
          ecosystem: 'tachi',
          source: 'mangafire',
          recordedAt: DateTime.utc(2026, 11, 20),
          exchanges: <CaptureExchange>[
            exchange(CaptureKey.forRequest('GET', page, null), pageBody),
            exchange(CaptureKey.forRequest('POST', verify, recordedBody), verifyBody),
          ],
        );
        return CaptureSet.fromParts(manifest, <String, Uint8List>{
          'bodies/${sha256Hex(pageBody)}.bin': pageBody,
          'bodies/${sha256Hex(verifyBody)}.bin': verifyBody,
        });
      }

      Future<List<String>> post(FakeBrowserPort port, String body) async {
        final BrowserSession s = await open(port);
        check(await s.loadUrl(page)).isA<BrowserCompleted<BrowserPage>>();
        final messages = <String>[];
        await s.setMessageHandler('out', messages.add);
        await s.evaluate(BrowserContractScripts.fetchAndPost('out', verify, method: 'POST', body: body));
        await Future<void>.delayed(Duration.zero);
        return messages;
      }

      test('a POST matches its recorded body', () async {
        final port = FakeBrowserPort.replay(captures());
        check(await post(port, utf8.decode(recordedBody))).deepEquals(<String>['verified']);
        check(port.misses).isEmpty();
      });

      test('a POST with another body is a recorded miss', () async {
        final port = FakeBrowserPort.replay(captures());
        check(await post(port, '{"answer":7}')).deepEquals(<String>['fetch-failed']);
        check(port.misses.single.method).equals('POST');
        check(port.misses.single.bodySha256).equals(sha256Hex(utf8.encode('{"answer":7}')));
      });

      test('browserCaptureKey matches by body and refuses an omitted body', () {
        final CaptureSet set = captures();
        final CaptureKey? recorded = browserCaptureKey(
          set,
          BrowserRequest(url: verify, method: 'POST', body: Uint8List.fromList(recordedBody)),
        );
        check(set.contains(recorded!)).isTrue();
        check(utf8.decode(set.lookup(recorded).body)).equals('verified');
        check(browserCaptureKey(set, BrowserRequest(url: verify, method: 'POST', bodyOmitted: true))).isNull();
      });
    });
  });
}
