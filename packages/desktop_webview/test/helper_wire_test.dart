// The client's side of the helper protocol, without a WebView: the requests
// DesktopBrowserPort writes and the events it reads, recorded as the golden
// vectors `fixtures/wire_vectors/helper_protocol.json` that the Rust helper's
// tests decode (`helper/src/wire.rs`). Regenerate with
// `UPDATE_WIRE_VECTORS=1 flutter test packages/desktop_webview/test/helper_wire_test.dart`.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:desktop_webview/desktop_webview.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_testing/wire_vectors.dart';
import 'package:test/scaffolding.dart';

import 'support/fake_helper.dart';

const SourceIdentity _source = SourceIdentity(
  ecosystem: 'test',
  packageId: 'test.package',
  sourceId: 'source-1',
  artifact: ArtifactBinding(sha256: '00', kind: 'test', version: '1'),
);

DesktopBrowserPort _port(FakeHelper helper, {List<String>? log}) => DesktopBrowserPort(
  DesktopWebViewConfig(
    helperExecutable: File('fake-helper'),
    dataRoot: Directory.systemTemp,
    startupTimeout: const Duration(seconds: 5),
    shutdownGrace: const Duration(seconds: 5),
    offline: true,
    launcher: helper.launch,
    onLog: log?.add,
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

/// Lets queued helper lines and event handlers run.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

/// Events the helper writes (`doc/helper-protocol.md` › Events), one per kind
/// the client reads. The Rust helper's `Event` encodes each of them exactly.
final List<({String name, Map<String, Object?> frame})> _events = <({String name, Map<String, Object?> frame})>[
  (name: 'ready', frame: FakeHelper.readyFrame()),
  (name: 'fatal', frame: <String, Object?>{'ev': 'fatal', 'code': 'runtime-missing', 'message': 'no WebView2 runtime'}),
  (
    name: 'message',
    frame: <String, Object?>{'ev': 'message', 'session': 's1', 'name': 'ipc', 'message': '{"done":true}'},
  ),
  (
    name: 'request observed',
    frame: <String, Object?>{
      'ev': 'request',
      'session': 's1',
      'rid': null,
      'url': 'https://example.test/api?q=1',
      'method': 'POST',
      'headers': <String, Object?>{'content-type': 'application/json', 'sec-ch-ua': '"Chromium"'},
      'bodyBase64': base64Encode(utf8.encode('{"a":1}')),
      'bodyOmitted': false,
      'mainFrame': false,
      'redirect': false,
      'context': 'fetch',
    },
  ),
  (
    name: 'request held',
    frame: <String, Object?>{
      'ev': 'request',
      'session': 's1',
      'rid': 7,
      'url': 'https://example.test/',
      'method': 'GET',
      'headers': <String, Object?>{},
      'bodyBase64': null,
      'bodyOmitted': true,
      'mainFrame': true,
      'redirect': false,
      'context': 'document',
    },
  ),
  (
    name: 'interactionEnded closed',
    frame: <String, Object?>{'ev': 'interactionEnded', 'session': 's1', 'reason': 'closed'},
  ),
  (
    name: 'interactionEnded session-closed',
    frame: <String, Object?>{'ev': 'interactionEnded', 'session': 's1', 'reason': 'session-closed'},
  ),
  (
    name: 'exchange',
    frame: <String, Object?>{
      'ev': 'exchange',
      'session': 's1',
      'method': 'GET',
      'url': 'https://example.test/page',
      'requestBodyBase64': null,
      'requestBodyOmitted': false,
      'status': 200,
      'headers': <Object?>[
        <String>['Content-Type', 'text/html'],
        <String>['Set-Cookie', 'a=1'],
        <String>['Set-Cookie', 'b=2'],
      ],
      'bodyBase64': base64Encode(utf8.encode('<p>hi</p>')),
      'bodyOmitted': false,
    },
  ),
  (name: 'protocolError', frame: <String, Object?>{'ev': 'protocolError', 'message': 'frame exceeds 16777216 bytes'}),
];

Map<String, Object?> _event(String name) => _events.firstWhere((e) => e.name == name).frame;

/// Names the recorded requests: `op`, plus what distinguishes repeats.
String _commandName(Map<String, Object?> r) => switch (r) {
  {'op': 'intercept', 'mode': final String mode} => 'intercept $mode',
  {'op': 'respond', 'fail': String()} => 'respond fail',
  {'op': 'respond', 'response': null} => 'respond proceed',
  {'op': 'respond'} => 'respond replace',
  {'op': 'channel', 'enabled': false} => 'channel disabled',
  {'op': final String op} => op,
  _ => throw StateError('request without op: $r'),
};

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

  test('records every request the port writes as the helper golden vectors', () async {
    final helper = FakeHelper(
      reply: (Map<String, Object?> r) => r['op'] == 'load' && '${r['url']}'.contains('slow') ? fakeHelperNoReply : null,
    );
    final DesktopBrowserPort port = _port(helper);
    check(await port.wipeAllSourceData()).isA<BrowserCompleted<void>>();
    final DesktopBrowserSession s = await _open(port, userAgent: 'TestAgent/1.0');
    check(
      await s.loadUrl(
        Uri.parse('https://example.test/page'),
        headers: const <String, String>{'Referer': 'https://example.test/'},
      ),
    ).isA<BrowserCompleted<BrowserPage>>();
    check(await s.loadData('<p>x</p>', baseUrl: Uri.parse('https://example.test/base')))
        .isA<BrowserCompleted<BrowserPage>>();
    final cancel = CancellationSource();
    final Future<BrowserOutcome<BrowserPage>> slow = s.loadUrl(
      Uri.parse('https://example.test/slow'),
      cancel: cancel.token,
    );
    await _settle();
    cancel.cancel('test');
    check(await slow).isA<BrowserCancelled<BrowserPage>>();
    await _settle();
    check(await s.evaluate('document.title'))
        .isA<BrowserCompleted<String>>()
        .has((o) => o.value, 'value')
        .equals('"fake"');
    final messages = <String>[];
    check(await s.setMessageHandler('ipc', messages.add)).isA<BrowserCompleted<void>>();
    check(await s.addPageStartScript('window.x = 1;')).isA<BrowserCompleted<void>>();
    final observed = <BrowserRequest>[];
    check(await s.setRequestObserver(observed.add)).isA<BrowserCompleted<void>>();

    // Events the port reads (the Rust helper writes these shapes).
    helper.emit(_event('message'));
    helper.emit(_event('request observed'));
    await _settle();
    check(messages).deepEquals(<String>['{"done":true}']);
    check(observed).length.equals(1);
    check(observed.single)
      ..has((r) => r.url, 'url').equals(Uri.parse('https://example.test/api?q=1'))
      ..has((r) => r.method, 'method').equals('POST')
      ..has((r) => r.headers, 'headers').deepEquals(<String, String>{
        'content-type': 'application/json',
        'sec-ch-ua': '"Chromium"',
      })
      ..has((r) => r.body, 'body').isNotNull().deepEquals(Uint8List.fromList(utf8.encode('{"a":1}')))
      ..has((r) => r.mainFrame, 'mainFrame').isFalse()
      ..has((r) => r.context, 'context').equals(BrowserRequestContext.fromWire('fetch'));

    // Held requests: replaced, let through, and failed.
    final replies = <BrowserReplacement? Function()>[
      () => BrowserReplacement(
        status: 200,
        headers: const <String, String>{'content-type': 'text/plain'},
        body: utf8.encode('ok'),
      ),
      () => null,
      () => throw StateError('handler failed'),
    ];
    check(await s.setRequestReplacer((BrowserRequest _) => replies.removeAt(0)())).isA<BrowserCompleted<void>>();
    for (var i = 0; i < 3; i++) {
      helper.emit(_event('request held'));
      await _settle();
    }
    check(helper.withOp('respond')).length.equals(3);

    final List<BrowserCookie> cookies = (await s.getCookies(Uri.parse('https://example.test/'))).valueOrNull!;
    check(cookies.single.name).equals('a');
    check(
      await s.setCookie(
        Uri.parse('https://example.test/'),
        BrowserCookie(
          name: 'cf_clearance',
          value: 'v',
          domain: 'example.test',
          path: '/',
          expires: DateTime.utc(2030),
          secure: true,
          httpOnly: true,
        ),
      ),
    ).isA<BrowserCompleted<void>>();
    check(await s.setUserAgent('Other/2.0')).isA<BrowserCompleted<void>>();
    final Future<BrowserOutcome<void>> shown = s.showForInteraction(timeout: const Duration(seconds: 5));
    await _settle();
    helper.emit(_event('interactionEnded closed'));
    check(await shown).isA<BrowserCompleted<void>>();
    check(await s.hide()).isA<BrowserCompleted<void>>();
    check(await s.setMessageHandler('ipc', null)).isA<BrowserCompleted<void>>();
    check(await s.close()).isA<BrowserCompleted<void>>();
    await port.dispose();

    final commands = <Map<String, Object?>>[
      for (final Map<String, Object?> r in helper.requests) <String, Object?>{'name': _commandName(r), 'frame': r},
    ];
    await checkWireVectors('helper_protocol.json', <String, Object?>{
      'comment':
          'Written by packages/desktop_webview/test/helper_wire_test.dart from what DesktopBrowserPort sends and '
          'reads; decoded by packages/desktop_webview/helper/src/wire.rs. See README.md for the rules.',
      'constants': <String, Object?>{
        'helperMaxFrameBytes': helperMaxFrameBytes,
        'helperProtocolVersion': helperProtocolVersion,
      },
      'commands': commands,
      'events': <Object?>[
        for (final e in _events) <String, Object?>{'name': e.name, 'frame': e.frame},
      ],
    });
  });

  test('reads the remaining helper events as the vectors describe them', () async {
    final exchanges = <BrowserExchange>[];
    final helper = FakeHelper();
    final port = DesktopBrowserPort(
      DesktopWebViewConfig(
        helperExecutable: File('fake-helper'),
        dataRoot: Directory.systemTemp,
        startupTimeout: const Duration(seconds: 5),
        shutdownGrace: const Duration(seconds: 5),
        launcher: helper.launch,
        onExchange: exchanges.add,
      ),
    );
    addTearDown(port.dispose);
    final DesktopBrowserSession s = await _open(port);
    check(port.helperInfo!)
      ..has((i) => i.engine, 'engine').equals('webview2')
      ..has((i) => i.pid, 'pid').equals(4242);
    helper.emit(_event('exchange'));
    await _settle();
    check(exchanges.single)
      ..has((x) => x.status, 'status').equals(200)
      ..has((x) => x.headers, 'headers').deepEquals(<(String, String)>[
        ('Content-Type', 'text/html'),
        ('Set-Cookie', 'a=1'),
        ('Set-Cookie', 'b=2'),
      ])
      ..has((x) => x.body, 'body').isNotNull().deepEquals(Uint8List.fromList(utf8.encode('<p>hi</p>')));
    final Future<BrowserOutcome<void>> shown = s.showForInteraction(timeout: const Duration(seconds: 5));
    await _settle();
    helper.emit(_event('interactionEnded session-closed'));
    check(await shown).isA<BrowserCancelled<void>>();
  });
}
