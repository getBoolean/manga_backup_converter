// The client's side of the helper protocol, without a WebView (a scripted
// helper process).
@TestOn('vm')
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:desktop_webview/desktop_webview.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import 'support/fake_helper.dart';

const SourceIdentity _source = SourceIdentity(
  ecosystem: 'test',
  packageId: 'test.package',
  sourceId: 'source-1',
  artifact: ArtifactBinding(sha256: '00', kind: 'test', version: '1'),
);

DesktopBrowserPort _port(FakeHelper helper) => DesktopBrowserPort(
  DesktopWebViewConfig(
    helperExecutable: File('fake-helper'),
    dataRoot: Directory.systemTemp,
    startupTimeout: const Duration(seconds: 5),
    shutdownGrace: const Duration(seconds: 5),
    offline: true,
    launcher: helper.launch,
    wipeRetry: const Duration(seconds: 3),
  ),
);

Future<DesktopBrowserSession> _open(DesktopBrowserPort port, {String? userAgent}) async {
  final BrowserOutcome<BrowserSession> o = await port.openSession(
    BrowserSessionRequest(source: _source, generation: 1, userAgent: userAgent),
  );
  check(o).isA<BrowserCompleted<BrowserSession>>();
  return o.valueOrNull! as DesktopBrowserSession;
}

void main() {
  test('a refused page-start script reports the contract operation, not the helper name', () async {
    // Regression: the helper named this failure `addStartScript`, which the
    // port passed through as the BrowserCapabilityUnavailable operation.
    final helper = FakeHelper(
      reply: (Map<String, Object?> r) => r['op'] == 'startScript'
          ? const FakeHelperError('capability-unavailable', 'engine refused', operation: 'addStartScript')
          : null,
    );
    final DesktopBrowserPort port = _port(helper);
    addTearDown(port.dispose);
    final DesktopBrowserSession session = await _open(port);
    final BrowserOutcome<void> outcome = await session.addPageStartScript('window.x = 1;');
    check(outcome).isA<BrowserCapabilityUnavailable<void>>()
      ..has((o) => o.operation, 'operation').equals('addPageStartScript')
      ..has((o) => o.reason, 'reason').equals('engine refused');
    check(helper.withOp('startScript')).length.equals(1);
  });

  test('a refused open reports openSession whatever operation the helper names', () async {
    final helper = FakeHelper(
      reply: (Map<String, Object?> r) => r['op'] == 'open'
          ? const FakeHelperError('capability-unavailable', 'no replace tier', operation: 'interceptRequest.replace')
          : null,
    );
    final DesktopBrowserPort port = _port(helper);
    addTearDown(port.dispose);
    final BrowserOutcome<BrowserSession> o = await port.openSession(
      const BrowserSessionRequest(source: _source, generation: 1),
    );
    check(o)
        .isA<BrowserCapabilityUnavailable<BrowserSession>>()
        .has((o) => o.operation, 'operation')
        .equals('openSession');
  });
}
