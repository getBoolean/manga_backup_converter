// Runs the reusable BrowserPort contract suite against the fake. Platform
// implementations (desktop helper, iOS, Android) run the same suite through
// their own BrowserPortHarness: see `package:source_runtime_testing`.
import 'package:checks/checks.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_testing/source_runtime_testing.dart';
import 'package:test/scaffolding.dart';

void main() {
  runBrowserPortContractSuite('FakeBrowserPort', FakeBrowserPortHarness.new);

  group('FakeBrowserPort specifics', () {
    const source = SourceIdentity(
      ecosystem: 'test',
      packageId: 'p',
      sourceId: 's',
      artifact: ArtifactBinding(sha256: '0', kind: 't', version: '1'),
    );

    test('close fails the capability when storage deletion cannot be confirmed', () async {
      final store = FakeBrowserStore();
      final port = FakeBrowserPort(store: store);
      final BrowserSession s = (await port.openSession(
        const BrowserSessionRequest(source: source, generation: 1),
      )).valueOrNull!;
      store.failDeletes = true;
      check(await s.close()).isA<BrowserCapabilityUnavailable<void>>();
    });

    test('start-up wipes storage a killed process left behind', () async {
      final store = FakeBrowserStore();
      final port = FakeBrowserPort(store: store, pages: (_) => const FakeWebPage());
      final BrowserSession s = (await port.openSession(
        const BrowserSessionRequest(source: source, generation: 1),
      )).valueOrNull!;
      await s.loadUrl(Uri.parse('https://a.example/'));
      await s.evaluate('localStorage.setItem("k", "v")');
      check(store.isEmpty).isFalse();
      FakeBrowserPort(store: store);
      check(store.isEmpty).isTrue();
    });
  });
}
