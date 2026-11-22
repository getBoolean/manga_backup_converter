// Protocol 1.2 and 1.3 behaviour of BrowserReverseBridge: version gating,
// capabilities, script errors, page-start scripts, request interception, and
// interaction completion.
import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_testing/source_runtime_testing.dart';
import 'package:test/scaffolding.dart';

final Uri _page = Uri.parse('https://site.test/page');
final Uri _api = Uri.parse('https://site.test/api?token=secret');

SourceIdentity _identity(String? pkg, String sourceId) => SourceIdentity(
  ecosystem: 'test',
  packageId: pkg!,
  sourceId: sourceId,
  artifact: const ArtifactBinding(sha256: 'ab', kind: 'test', version: '1'),
);

/// One emitted worker event.
typedef _Event = ({String op, Map<String, Object?> payload, int generation});

final class _Rig {
  _Rig({
    BrowserCapabilities? capabilities,
    Duration? replacementTimeout,
    bool hasDisplay = false,
    Duration interactionTimeout = const Duration(seconds: 1),
  }) : port = FakeBrowserPort(
         capabilities: capabilities,
         hasDisplay: hasDisplay,
         userClosesInteraction: false,
         pages: (Uri url) => url == _page ? const FakeWebPage(html: '<title>page</title>') : null,
         requests: (BrowserRequest r) =>
             r.url.path == '/api' ? FakeWebPage(html: 'network ${utf8.decode(r.body ?? const <int>[])}') : null,
       ) {
    bridge = BrowserReverseBridge(
      port: port,
      resolveSource: _identity,
      interactionTimeout: interactionTimeout,
      replacementTimeout: replacementTimeout,
      emitEvent: (String op, Map<String, Object?> payload, {required int generation}) =>
          events.add((op: op, payload: payload, generation: generation)),
      onLog: log.add,
    );
  }

  final FakeBrowserPort port;
  late final BrowserReverseBridge bridge;
  final List<_Event> events = <_Event>[];
  final List<String> log = <String>[];

  Future<SourceOutcome<Map<String, Object?>>> call(
    String op,
    Map<String, Object?> payload, {
    int minor = 2,
    int generation = 1,
    CancellationToken? cancel,
  }) => bridge.handle(
    ReverseRequest(
      op: op,
      payload: payload,
      packageId: 'pkg',
      generation: generation,
      cancel: cancel ?? CancellationToken.none,
      protocolMinor: minor,
    ),
  );

  Future<Map<String, Object?>> ok(String op, Map<String, Object?> payload, {int minor = 2}) async {
    final SourceOutcome<Map<String, Object?>> out = await call(op, payload, minor: minor);
    check(out.failureOrNull).isNull();
    return out.valueOrNull!;
  }

  Future<String> open({int minor = 2}) async =>
      (await ok('host.browser.open', const <String, Object?>{'sourceId': '1'}, minor: minor))['session']! as String;

  List<Map<String, Object?>> eventsOf(String op) => <Map<String, Object?>>[
    for (final _Event e in events)
      if (e.op == op) e.payload,
  ];
}

void main() {
  group('version gating', () {
    test('a worker on 1.1 may not send 1.2 operations', () async {
      final rig = _Rig();
      final String session = await rig.open(minor: 1);
      for (final (String op, Map<String, Object?> payload) in <(String, Map<String, Object?>)>[
        ('host.browser.addPageStartScript', <String, Object?>{'session': session, 'script': 'x'}),
        ('host.browser.setRequestInterception', <String, Object?>{'session': session, 'mode': 'observe'}),
        ('host.browser.respond', <String, Object?>{'session': session, 'requestId': 'q1'}),
      ]) {
        check((await rig.call(op, payload, minor: 1)).failureOrNull)
            .isA<ProtocolViolationFailure>()
            .has((ProtocolViolationFailure f) => f.message, 'message')
            .contains('1.2');
      }
    });

    test('capabilities reach only a 1.2 worker', () async {
      final rig = _Rig(capabilities: FakeBrowserPort.degradedCapabilities);
      final Map<String, Object?> legacy = await rig.ok('host.browser.open', const <String, Object?>{
        'sourceId': '1',
      }, minor: 1);
      check(legacy.containsKey('capabilities')).isFalse();
      final Map<String, Object?> current = await rig.ok('host.browser.open', const <String, Object?>{'sourceId': '1'});
      check(HostBrowserOpened.fromJson(current).effectiveCapabilities).equals(FakeBrowserPort.degradedCapabilities);
    });

    test('a script error reaches a 1.2 worker as scriptError and a 1.1 worker as null', () async {
      final rig = _Rig();
      final String s2 = await rig.open();
      final Map<String, Object?> v2 = await rig.ok('host.browser.evaluate', <String, Object?>{
        'session': s2,
        'script': 'throw new Error("boom")',
      });
      check(v2).deepEquals(<String, Object?>{'result': 'null', 'scriptError': 'Error: boom'});
      final String s1 = await rig.open(minor: 1);
      final Map<String, Object?> v1 = await rig.ok('host.browser.evaluate', <String, Object?>{
        'session': s1,
        'script': 'throw new Error("boom")',
      }, minor: 1);
      check(v1).deepEquals(<String, Object?>{'result': 'null'});
    });
  });

  group('page-start scripts', () {
    test('run in later documents and may post on a channel', () async {
      final rig = _Rig();
      final String session = await rig.open();
      await rig.ok('host.browser.setMessageHandler', <String, Object?>{
        'session': session,
        'name': 'ipc',
        'enabled': true,
      });
      await rig.ok('host.browser.addPageStartScript', <String, Object?>{
        'session': session,
        'script': BrowserContractScripts.postLocation('ipc'),
      });
      await rig.ok('host.browser.load', <String, Object?>{'session': session, 'url': '$_page'});
      await Future<void>.delayed(Duration.zero);
      check(rig.eventsOf(HostBrowserMessage.op).single).deepEquals(<String, Object?>{
        'session': session,
        'name': 'ipc',
        'message': '$_page',
      });
    });

    test('are refused with a named reason where the engine lacks them', () async {
      final rig = _Rig(capabilities: BrowserCapabilities.unreported());
      final String session = await rig.open();
      check(
            (await rig.call('host.browser.addPageStartScript', <String, Object?>{
              'session': session,
              'script': 'x',
            })).failureOrNull,
          )
          .isA<CapabilityUnavailableFailure>()
          .has((CapabilityUnavailableFailure f) => f.operation, 'operation')
          .equals(
            'addPageStartScript',
          );
    });
  });

  group('request interception', () {
    Future<void> fetch(_Rig rig, String session, {String method = 'POST', String? body}) => rig.ok(
      'host.browser.evaluate',
      <String, Object?>{
        'session': session,
        'script': BrowserContractScripts.fetchAndPost('out', _api, method: method, body: body),
      },
    );

    Future<String> loaded(_Rig rig) async {
      final String session = await rig.open();
      await rig.ok('host.browser.load', <String, Object?>{'session': session, 'url': '$_page'});
      await rig.ok('host.browser.setMessageHandler', <String, Object?>{
        'session': session,
        'name': 'out',
        'enabled': true,
      });
      return session;
    }

    List<String> posted(_Rig rig) => <String>[
      for (final Map<String, Object?> m in rig.eventsOf(HostBrowserMessage.op)) m['message']! as String,
    ];

    test('observe forwards each request with headers and body as an event without requestId', () async {
      final rig = _Rig();
      final String session = await loaded(rig);
      await rig.ok('host.browser.setRequestInterception', <String, Object?>{'session': session, 'mode': 'observe'});
      await fetch(rig, session, body: '{"answer":42}');
      await Future<void>.delayed(Duration.zero);
      final observed = HostBrowserRequestEvent.fromJson(
        rig.eventsOf(HostBrowserRequestEvent.op).single,
      );
      check(observed.requestId).isNull();
      check(observed.request.method).equals('POST');
      check(observed.request.header('sec-ch-ua')).isNotNull();
      check(utf8.decode(observed.request.body!)).equals('{"answer":42}');
      check(posted(rig)).deepEquals(<String>['network {"answer":42}']);
      // Turning it off stops the events.
      await rig.ok('host.browser.setRequestInterception', <String, Object?>{'session': session, 'mode': 'none'});
      await fetch(rig, session);
      check(rig.eventsOf(HostBrowserRequestEvent.op)).length.equals(1);
    });

    test('replace needs a configured timeout', () async {
      final rig = _Rig();
      final String session = await rig.open();
      check(
        (await rig.call('host.browser.setRequestInterception', <String, Object?>{
          'session': session,
          'mode': 'replace',
        })).failureOrNull,
      ).isA<CapabilityUnavailableFailure>();
    });

    test('replace is refused with a named reason on an engine without it', () async {
      final rig = _Rig(
        capabilities: FakeBrowserPort.degradedCapabilities,
        replacementTimeout: const Duration(seconds: 5),
      );
      final String session = await rig.open();
      check(
          (await rig.call('host.browser.setRequestInterception', <String, Object?>{
            'session': session,
            'mode': 'replace',
          })).failureOrNull,
        ).isA<CapabilityUnavailableFailure>()
        ..has((CapabilityUnavailableFailure f) => f.operation, 'operation').equals('setRequestReplacer')
        ..has((CapabilityUnavailableFailure f) => f.message, 'message').contains('replaceRequests');
    });

    test('a held request is answered by host.browser.respond', () async {
      final rig = _Rig(replacementTimeout: const Duration(seconds: 5));
      final String session = await loaded(rig);
      await rig.ok('host.browser.setRequestInterception', <String, Object?>{'session': session, 'mode': 'replace'});
      final Future<void> pending = fetch(rig, session, body: 'q');
      await Future<void>.delayed(Duration.zero);
      final held = HostBrowserRequestEvent.fromJson(rig.eventsOf(HostBrowserRequestEvent.op).single);
      check(held.requestId).isNotNull();
      check(rig.bridge.heldRequests).equals(1);
      await rig.ok('host.browser.respond', <String, Object?>{
        'session': session,
        'requestId': held.requestId,
        'response': browserReplacementToJson(BrowserReplacement(status: 200, body: utf8.encode('replaced'))),
      });
      await pending;
      await Future<void>.delayed(Duration.zero);
      check(posted(rig)).deepEquals(<String>['replaced']);
      check(rig.bridge.heldRequests).equals(0);
      // A second answer for the same request is late.
      check(
        (await rig.call('host.browser.respond', <String, Object?>{
          'session': session,
          'requestId': held.requestId,
        })).failureOrNull,
      ).isA<CancelledFailure>();
    });

    test('a null answer lets the request proceed', () async {
      final rig = _Rig(replacementTimeout: const Duration(seconds: 5));
      final String session = await loaded(rig);
      await rig.ok('host.browser.setRequestInterception', <String, Object?>{'session': session, 'mode': 'replace'});
      final Future<void> pending = fetch(rig, session, body: 'b');
      await Future<void>.delayed(Duration.zero);
      final id = rig.eventsOf(HostBrowserRequestEvent.op).single['requestId']! as String;
      await rig.ok('host.browser.respond', <String, Object?>{'session': session, 'requestId': id});
      await pending;
      await Future<void>.delayed(Duration.zero);
      check(posted(rig)).deepEquals(<String>['network b']);
    });

    test('an unanswered request proceeds after the timeout and the log omits the query', () async {
      final rig = _Rig(replacementTimeout: const Duration(milliseconds: 20));
      final String session = await loaded(rig);
      await rig.ok('host.browser.setRequestInterception', <String, Object?>{'session': session, 'mode': 'replace'});
      await fetch(rig, session, body: 't');
      await Future<void>.delayed(Duration.zero);
      check(posted(rig)).deepEquals(<String>['network t']);
      check(rig.log.single)
        ..contains('https://site.test/api')
        ..not((Subject<String> it) => it.contains('secret'));
    });

    test('a fence lets held requests proceed and closes the session', () async {
      final rig = _Rig(replacementTimeout: const Duration(seconds: 30));
      final String session = await loaded(rig);
      await rig.ok('host.browser.setRequestInterception', <String, Object?>{'session': session, 'mode': 'replace'});
      // The evaluation that triggered the held request is cancelled with
      // its session.
      final Future<SourceOutcome<Map<String, Object?>>> pending = rig.call('host.browser.evaluate', <String, Object?>{
        'session': session,
        'script': BrowserContractScripts.fetchAndPost('out', _api, method: 'POST'),
      });
      await Future<void>.delayed(Duration.zero);
      check(rig.bridge.heldRequests).equals(1);
      await rig.bridge.fence(2);
      check((await pending).failureOrNull).isA<CancelledFailure>();
      check(rig.bridge.heldRequests).equals(0);
      check(rig.bridge.openSessionIds).isEmpty();
      check(
        (await rig.call('host.browser.respond', <String, Object?>{
          'session': session,
          'requestId': 'q1',
        })).failureOrNull,
      ).isA<CancelledFailure>();
    });
  });

  group('protocol 1.3: replace tier without a replacement timeout', () {
    test('an engine without the replace tier names its own reason first', () async {
      final rig = _Rig(capabilities: FakeBrowserPort.degradedCapabilities);
      final String session = await rig.open();
      check(
          (await rig.call('host.browser.setRequestInterception', <String, Object?>{
            'session': session,
            'mode': 'replace',
          })).failureOrNull,
        ).isA<CapabilityUnavailableFailure>()
        ..has((CapabilityUnavailableFailure f) => f.operation, 'operation').equals('setRequestReplacer')
        ..has(
          (CapabilityUnavailableFailure f) => f.message,
          'message',
        ).equals('replaceRequests: The engine cannot substitute http(s) responses');
    });

    test('a capable engine names the missing timeout and keeps its observer', () async {
      final rig = _Rig();
      final String session = await rig.open();
      await rig.ok('host.browser.setRequestInterception', <String, Object?>{'session': session, 'mode': 'observe'});
      check(
          (await rig.call('host.browser.setRequestInterception', <String, Object?>{
            'session': session,
            'mode': 'replace',
          })).failureOrNull,
        ).isA<CapabilityUnavailableFailure>()
        ..has((CapabilityUnavailableFailure f) => f.operation, 'operation').equals('setRequestReplacer')
        ..has((CapabilityUnavailableFailure f) => f.message, 'message').contains('replacement timeout');
      await rig.ok('host.browser.load', <String, Object?>{'session': session, 'url': '$_page'});
      check(rig.eventsOf(HostBrowserRequestEvent.op)).length.equals(1);
    });
  });

  group('protocol 1.3: host.browser.show completion', () {
    Future<SourceOutcome<Map<String, Object?>>> show(
      _Rig rig,
      String session, {
      int minor = 3,
      CancellationToken? cancel,
    }) => rig.call('host.browser.show', <String, Object?>{'session': session}, minor: minor, cancel: cancel);

    Future<void> shown(_Rig rig) async {
      while (rig.port.shownInteractions == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('the user closing the window answers outcome closed', () async {
      final rig = _Rig(hasDisplay: true, interactionTimeout: const Duration(seconds: 10));
      final String session = await rig.open(minor: 3);
      final Future<SourceOutcome<Map<String, Object?>>> pending = show(rig, session);
      await shown(rig);
      rig.port.closeInteraction();
      check((await pending).valueOrNull).isNotNull().deepEquals(<String, Object?>{'outcome': 'closed'});
    });

    test('a 1.2 worker gets the empty reply it always got', () async {
      final rig = _Rig(hasDisplay: true, interactionTimeout: const Duration(seconds: 10));
      final String session = await rig.open();
      final Future<SourceOutcome<Map<String, Object?>>> pending = show(rig, session, minor: 2);
      await shown(rig);
      rig.port.closeInteraction();
      check((await pending).valueOrNull).isNotNull().isEmpty();
    });

    test('endInteraction ends the show as completed, hides the window and leaves the session usable', () async {
      final rig = _Rig(hasDisplay: true, interactionTimeout: const Duration(seconds: 10));
      final String session = await rig.open(minor: 3);
      final Future<SourceOutcome<Map<String, Object?>>> pending = show(rig, session);
      await shown(rig);
      await rig.ok('host.browser.endInteraction', <String, Object?>{'session': session}, minor: 3);
      check((await pending).valueOrNull).isNotNull().deepEquals(<String, Object?>{'outcome': 'completed'});
      check(rig.port.shownInteractions).equals(0);
      check(
        (await rig.ok('host.browser.evaluate', <String, Object?>{
          'session': session,
          'script': '1 + 1',
        }, minor: 3))['result'],
      ).equals('2');
    });

    test('the interaction bound answers interaction-required', () async {
      final rig = _Rig(hasDisplay: true, interactionTimeout: const Duration(milliseconds: 100));
      final String session = await rig.open(minor: 3);
      check((await show(rig, session)).failureOrNull)
          .isA<InteractionRequiredFailure>()
          .has((InteractionRequiredFailure f) => f.message, 'message')
          .contains('not completed within');
      check(rig.port.shownInteractions).equals(0);
    });

    test('cancelling the operation answers cancelled', () async {
      final rig = _Rig(hasDisplay: true, interactionTimeout: const Duration(seconds: 10));
      final String session = await rig.open(minor: 3);
      final cancel = CancellationSource();
      final Future<SourceOutcome<Map<String, Object?>>> pending = show(rig, session, cancel: cancel.token);
      await shown(rig);
      cancel.cancel('deadline');
      check((await pending).failureOrNull).isA<CancelledFailure>();
    });

    test('endInteraction with nothing shown is cancelled, and needs 1.3', () async {
      final rig = _Rig(hasDisplay: true);
      final String session = await rig.open(minor: 3);
      check(
        (await rig.call('host.browser.endInteraction', <String, Object?>{'session': session}, minor: 3)).failureOrNull,
      ).isA<CancelledFailure>();
      check(
        (await rig.call('host.browser.endInteraction', <String, Object?>{'session': session})).failureOrNull,
      ).isA<ProtocolViolationFailure>();
    });

    test('without a display the show is interaction-required at once', () async {
      final rig = _Rig();
      final String session = await rig.open(minor: 3);
      check((await show(rig, session)).failureOrNull).isA<InteractionRequiredFailure>();
    });
  });
}
