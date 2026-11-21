// Host tests of the Android BrowserPort's Dart adapter (U12) over a scripted
// stand-in for the Kotlin `AppBrowserHost`. The full BrowserPort contract
// suite runs against the real app-process WebView on a device or emulator
// (integration_test/android_u12_cases.dart); these cases pin the adapter's
// own decisions: start-up refusals, isolation-unavailable refusal, evaluate
// decoding (values, errors, awaited promises, CSP fallback), the origin
// rule, backgrounding, protocol 1.3 show outcomes, fencing of late native
// replies, and unconfirmed deletion.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_android/source_runtime_android.dart';
import 'package:test/scaffolding.dart';

typedef _Handler = FutureOr<(bool, Map<String, Object?>)?> Function(Map<String, Object?> args);

/// Scripted Kotlin host: answers each op through [handlers] (a `null`
/// answer holds the reply until [answer] is called), records every call.
final class _FakeNative implements AppBrowserNative {
  _FakeNative(this._onReply, this._onEvent, this.handlers);

  final void Function(int callId, bool ok, String payload) _onReply;
  final void Function(String session, String kind, String payload) _onEvent;
  final Map<String, _Handler> handlers;
  final List<(String, Map<String, Object?>)> calls = <(String, Map<String, Object?>)>[];
  final Map<int, String> held = <int, String>{};
  bool disposed = false;

  @override
  void call(int callId, String op, Map<String, Object?> args) {
    calls.add((op, args));
    final _Handler? h = handlers[op];
    scheduleMicrotask(() async {
      final (bool, Map<String, Object?>)? r = h == null ? (true, <String, Object?>{}) : await h(args);
      if (r == null) {
        held[callId] = op;
        return;
      }
      _onReply(callId, r.$1, jsonEncode(r.$2));
    });
  }

  /// Answers a held call of [op].
  void answer(String op, bool ok, Map<String, Object?> payload) {
    final int id = held.entries.firstWhere((MapEntry<int, String> e) => e.value == op).key;
    held.remove(id);
    _onReply(id, ok, jsonEncode(payload));
  }

  void event(String session, String kind, Map<String, Object?> payload) => _onEvent(session, kind, jsonEncode(payload));

  Iterable<String> get ops => calls.map(((String, Map<String, Object?>) c) => c.$1);

  @override
  void dispose() => disposed = true;
}

Map<String, _Handler> _defaults({bool multiProfile = true, Map<String, Object?>? features}) => <String, _Handler>{
  'init': (_) => (
    true,
    <String, Object?>{
      'multiProfile': multiProfile,
      'startedActivities': 1,
      'features':
          features ??
          <String, Object?>{'WEB_MESSAGE_LISTENER': true, 'DOCUMENT_START_SCRIPT': true, 'MULTI_PROFILE': multiProfile},
    },
  ),
  'open': (Map<String, Object?> a) => (true, <String, Object?>{'profile': multiProfile ? 'srt-${a['session']}' : null}),
  'loadUrl': (Map<String, Object?> a) => (true, <String, Object?>{'url': a['url'], 'status': 200}),
  'loadData': (Map<String, Object?> a) => (true, <String, Object?>{'url': a['baseUrl'], 'status': null}),
  'close': (_) => (true, <String, Object?>{}),
};

SourceIdentity _source(String id) => SourceIdentity(
  ecosystem: 'paperback',
  packageId: 'p.$id',
  sourceId: id,
  artifact: const ArtifactBinding(sha256: '00', kind: 'test', version: '1'),
);

Future<(AndroidWebViewBrowserPort, _FakeNative)> _start([
  Map<String, _Handler>? handlers,
  AndroidBrowserConfig? config,
]) async {
  late _FakeNative native;
  final SourceOutcome<AndroidWebViewBrowserPort> started = await AndroidWebViewBrowserPort.start(
    config: config ?? const AndroidBrowserConfig(),
    native: (onReply, onEvent) => native = _FakeNative(onReply, onEvent, handlers ?? _defaults()),
  );
  return (started.valueOrNull!, native);
}

Future<AndroidWebViewBrowserSession> _open(AndroidWebViewBrowserPort port, String id, {int generation = 1}) async =>
    (await port.openSession(BrowserSessionRequest(source: _source(id), generation: generation))).valueOrNull!
        as AndroidWebViewBrowserSession;

/// The value `evaluateJavascript` reports for the wrapper's return object.
(bool, Map<String, Object?>) _evaluated(Map<String, Object?> returned) => (
  true,
  <String, Object?>{'value': jsonEncode(returned)},
);

void main() {
  group('start-up', () {
    test('runs init, then the start-up wipe, before any session', () async {
      final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start();
      check(native.ops.take(2).toList()).deepEquals(<String>['init', 'wipeAll']);
      check(port.sourceIsolationAvailable).isTrue();
      await port.dispose();
      check(native.disposed).isTrue();
    });

    test('refuses to start without an origin-attested message listener', () async {
      late _FakeNative native;
      final SourceOutcome<AndroidWebViewBrowserPort> started = await AndroidWebViewBrowserPort.start(
        native: (r, e) => native = _FakeNative(
          r,
          e,
          _defaults(features: <String, Object?>{'WEB_MESSAGE_LISTENER': false, 'DOCUMENT_START_SCRIPT': true}),
        ),
      );
      check(started)
          .isA<SourceFailed<AndroidWebViewBrowserPort>>()
          .has((SourceFailed<AndroidWebViewBrowserPort> f) => f.failure.message, 'message')
          .contains('WEB_MESSAGE_LISTENER');
      check(native.disposed).isTrue();
    });

    test('refuses to start when the replay proxy or the start-up wipe is not confirmed', () async {
      for (final failing in <String>['init', 'wipeAll']) {
        final Map<String, _Handler> handlers = _defaults()
          ..[failing] = (_) => (false, <String, Object?>{'code': 'unconfirmed', 'message': '$failing failed'});
        final SourceOutcome<AndroidWebViewBrowserPort> started = await AndroidWebViewBrowserPort.start(
          config: const AndroidBrowserConfig(offline: true),
          native: (r, e) => _FakeNative(r, e, handlers),
        );
        check(started).isA<SourceFailed<AndroidWebViewBrowserPort>>();
      }
    });

    test('off Android with no injected host it reports the runtime unavailable', () async {
      check(await AndroidWebViewBrowserPort.start()).isA<SourceFailed<AndroidWebViewBrowserPort>>();
    });
  });

  test('without multi-profile a second open source is refused by name, never shares the store', () async {
    final (AndroidWebViewBrowserPort port, _) = await _start(_defaults(multiProfile: false));
    final AndroidWebViewBrowserSession a = await _open(port, 'a');
    check(a.profile).isNull();
    check(port.isolationReport['sourceBrowserIsolation']).equals('unavailable');
    check(await port.openSession(BrowserSessionRequest(source: _source('a'), generation: 1)))
        .isA<BrowserCompleted<BrowserSession>>();
    check(await port.openSession(BrowserSessionRequest(source: _source('b'), generation: 1)))
        .isA<BrowserCapabilityUnavailable<BrowserSession>>()
        .has((BrowserCapabilityUnavailable<BrowserSession> f) => f.reason, 'reason')
        .contains('isolation unavailable');
    await port.dispose();
  });

  group('evaluate', () {
    test('decodes values and script errors from the wrapper', () async {
      var reply = <String, Object?>{'ok': '2'};
      final (AndroidWebViewBrowserPort port, _) = await _start(_defaults()..['evaluate'] = (_) => _evaluated(reply));
      final AndroidWebViewBrowserSession s = await _open(port, 'a');
      check((await s.evaluate('1 + 1')).valueOrNull).equals('2');
      reply = <String, Object?>{'e': 'Error: boom'};
      check(await s.evaluate('throw 1')).isA<BrowserScriptError<String>>();
      await port.dispose();
    });

    test('awaits a promise through the top-frame bridge and ignores child frames', () async {
      final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start(
        _defaults()..['evaluate'] = (_) => _evaluated(<String, Object?>{'p': 1}),
      );
      final AndroidWebViewBrowserSession s = await _open(port, 'a');
      final Future<BrowserOutcome<String>> pending = s.evaluate('Promise.resolve(42)');
      await Future<void>.delayed(Duration.zero);
      final wrapped =
          native.calls.lastWhere(((String, Map<String, Object?>) c) => c.$1 == 'evaluate').$2['script']! as String;
      final String id = RegExp('I = "([^"]+)"').firstMatch(wrapped)!.group(1)!;
      native.event(s.id, 'bridge', <String, Object?>{
        'data': jsonEncode(<String, Object?>{'k': 'e', 'id': id, 'ok': '"forged"'}),
        'mainFrame': false,
        'origin': 'http://evil.test',
        'document': 'http://a.test/',
      });
      native.event(s.id, 'bridge', <String, Object?>{
        'data': jsonEncode(<String, Object?>{'k': 'e', 'id': id, 'ok': '42'}),
        'mainFrame': true,
        'origin': 'http://a.test',
        'document': 'http://a.test/',
      });
      check((await pending).valueOrNull).equals('42');
      await port.dispose();
    });

    test('a page CSP that forbids eval falls back to the unwrapped script', () async {
      var first = true;
      final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start(
        _defaults()
          ..['evaluate'] = (Map<String, Object?> a) {
            if (first) {
              first = false;
              return _evaluated(<String, Object?>{'csp': 'EvalError: unsafe-eval'});
            }
            return (true, <String, Object?>{'value': '"raw"'});
          },
      );
      final AndroidWebViewBrowserSession s = await _open(port, 'a');
      check((await s.evaluate('document.title')).valueOrNull).equals('"raw"');
      check(native.calls.last.$2['script']).equals('document.title');
      await port.dispose();
    });
  });

  test('channel messages follow the origin rule on the engine-attested origin', () async {
    final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start();
    final AndroidWebViewBrowserSession s = await _open(port, 'a');
    final got = <String>[];
    await s.setMessageHandler('bridge', got.add);
    void post(String message, String origin, String document) => native.event(s.id, 'bridge', <String, Object?>{
      'data': jsonEncode(<String, Object?>{'k': 'm', 'c': 'bridge', 'm': message}),
      'mainFrame': true,
      'origin': origin,
      'document': document,
    });
    post('cross', 'http://other.test', 'http://a.test/page');
    post('blank', 'null', 'about:blank');
    post('same', 'http://a.test', 'http://a.test/page');
    check(got).deepEquals(<String>['same']);
    // Channel objects are installed first, page-start scripts after.
    await s.addPageStartScript('window.x = 1');
    final scripts =
        native.calls.lastWhere(((String, Map<String, Object?>) c) => c.$1 == 'setStartScripts').$2['scripts']!
            as List<Object?>;
    check(scripts).length.equals(2);
    check(scripts.last).equals('window.x = 1');
    await port.dispose();
  });

  test('backgrounding ends pending work as interaction-required and refuses new work and shows', () async {
    final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start(_defaults()..['loadUrl'] = (_) => null);
    final AndroidWebViewBrowserSession s = await _open(port, 'a');
    final Future<BrowserOutcome<BrowserPage>> pending = s.loadUrl(Uri.parse('https://a.test/'));
    await Future<void>.delayed(Duration.zero);
    native.event('', 'foreground', <String, Object?>{'started': 0});
    check(port.isBackgrounded).isTrue();
    check(await pending).isA<BrowserInteractionRequired<BrowserPage>>();
    check(native.ops).contains('stop');
    check(await s.evaluate('1')).isA<BrowserInteractionRequired<String>>();
    check(await s.showForInteraction(timeout: const Duration(seconds: 1))).isA<BrowserInteractionRequired<void>>();
    // The late native reply for the abandoned load changes nothing.
    native.answer('loadUrl', true, <String, Object?>{'url': 'https://a.test/'});
    check(await pending).isA<BrowserInteractionRequired<BrowserPage>>();
    native.event('', 'foreground', <String, Object?>{'started': 1});
    check(port.isBackgrounded).isFalse();
    await port.dispose();
  });

  group('protocol 1.3 show', () {
    test('the user closing the Activity completes; timeout and cancel hide it', () async {
      final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start(
        _defaults()..['show'] = (_) => null,
      );
      final AndroidWebViewBrowserSession s = await _open(port, 'a');
      final Future<BrowserOutcome<void>> closed = s.showForInteraction(timeout: const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      native.answer('show', true, <String, Object?>{'end': 'closed'});
      check(await closed).isA<BrowserCompleted<void>>();

      final BrowserOutcome<void> timedOut = await s.showForInteraction(timeout: const Duration(milliseconds: 50));
      check(timedOut).isA<BrowserInteractionRequired<void>>();
      check(native.ops.last).equals('hide');
      native.answer('show', true, <String, Object?>{'end': 'hidden'});

      final cancel = CancellationSource();
      final Future<BrowserOutcome<void>> cancelled = s.showForInteraction(
        timeout: const Duration(seconds: 10),
        cancel: cancel.token,
      );
      await Future<void>.delayed(Duration.zero);
      cancel.cancel('deadline');
      check(await cancelled).isA<BrowserCancelled<void>>();
      check(native.ops.last).equals('hide');
      await port.dispose();
    });

    test('unattended runs answer interaction-required without showing', () async {
      final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start(
        null,
        const AndroidBrowserConfig(allowInteraction: false),
      );
      final AndroidWebViewBrowserSession s = await _open(port, 'a');
      check(await s.showForInteraction(timeout: const Duration(seconds: 1))).isA<BrowserInteractionRequired<void>>();
      check(native.ops.contains('show')).isFalse();
      await port.dispose();
    });
  });

  test('a fenced generation cancels pending work and discards the late native reply', () async {
    final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start(_defaults()..['evaluate'] = (_) => null);
    final AndroidWebViewBrowserSession s = await _open(port, 'a');
    final Future<BrowserOutcome<String>> pending = s.evaluate('1');
    await Future<void>.delayed(Duration.zero);
    await port.fence(2);
    check(await pending).isA<BrowserCancelled<String>>();
    check(s.isClosed).isTrue();
    native.answer('evaluate', true, _evaluated(<String, Object?>{'ok': '1'}).$2);
    check(await pending).isA<BrowserCancelled<String>>();
    check(await port.openSession(BrowserSessionRequest(source: _source('a'), generation: 1)))
        .isA<BrowserCancelled<BrowserSession>>();
    await port.dispose();
  });

  test('close reports unconfirmed storage deletion as a capability failure', () async {
    final (AndroidWebViewBrowserPort port, _) = await _start(
      _defaults()..['close'] = (_) => (false, <String, Object?>{'code': 'unconfirmed', 'message': 'profile in use'}),
    );
    final AndroidWebViewBrowserSession s = await _open(port, 'a');
    check(await s.close())
        .isA<BrowserCapabilityUnavailable<void>>()
        .has((BrowserCapabilityUnavailable<void> f) => f.reason, 'reason')
        .contains('profile in use');
    await port.dispose();
  });

  test('setCookie sends one Set-Cookie line and refuses header injection', () async {
    final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start();
    final AndroidWebViewBrowserSession s = await _open(port, 'a');
    check(
      await s.setCookie(
        Uri.parse('https://a.test/'),
        BrowserCookie(
          name: 'k',
          value: 'v',
          domain: 'a.test',
          expires: DateTime.utc(2030),
          secure: true,
          httpOnly: true,
        ),
      ),
    ).isA<BrowserCompleted<void>>();
    check(native.calls.last.$2['header']).equals(
      'k=v; Domain=a.test; Path=/; Expires=Tue, 01 Jan 2030 00:00:00 GMT; Secure; HttpOnly',
    );
    check(
      await s.setCookie(Uri.parse('https://a.test/'), const BrowserCookie(name: 'k', value: 'v; Domain=evil.test')),
    ).isA<BrowserCapabilityUnavailable<void>>();
    check(
      await s.setCookie(Uri.parse('file:///x'), const BrowserCookie(name: 'k', value: 'v')),
    ).isA<BrowserCapabilityUnavailable<void>>();
    await port.dispose();
  });

  test('loads refuse non-web schemes before reaching the WebView', () async {
    final (AndroidWebViewBrowserPort port, _FakeNative native) = await _start();
    final AndroidWebViewBrowserSession s = await _open(port, 'a');
    check(await s.loadUrl(Uri.parse('file:///etc/passwd'))).isA<BrowserCapabilityUnavailable<BrowserPage>>();
    check(
      await s.loadData('<p>x</p>', baseUrl: Uri.parse('content://x/')),
    ).isA<BrowserCapabilityUnavailable<BrowserPage>>();
    check(native.ops.where((String o) => o.startsWith('load'))).isEmpty();
    check(s.capabilities.reasonFor(BrowserFeature.replaceRequests)).isNotNull();
    check(await s.setRequestReplacer((_) => null)).isA<BrowserCapabilityUnavailable<void>>();
    await port.dispose();
  });
}
