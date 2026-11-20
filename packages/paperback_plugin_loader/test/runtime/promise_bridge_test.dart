@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import 'test_support.dart';

void main() {
  late SourceJsRuntime runtime;

  setUp(() {
    runtime = SourceJsRuntime(limits: testLimits(), name: 'bridge-test');
  });

  tearDown(() => runtime.dispose());

  test('a promise awaits a delayed HTTP response through chained microtasks', () async {
    final seen = <http.Request>[];
    installHttpHost(runtime, fakeHttp(seen: seen));
    final Object? result = await runtime.evaluate('''
      (async () => {
        const res = await __paperbackHost.request({ url: 'https://example.test/manga', headers: { 'x-a': '1' } });
        const json = await Promise.resolve(res.text).then(t => JSON.parse(t)).then(o => ({ ...o, chained: true }));
        const img = await __paperbackHost.request({ url: 'https://example.test/bytes' });
        return { status: res.status, json, bytes: new Uint8Array(img.body), type: img.headers['content-type'] };
      })()
    ''');
    check(result).isA<Map<String, Object?>>()
      ..has((Map<String, Object?> m) => m['status'], 'status').equals(200)
      ..has((Map<String, Object?> m) => m['json'], 'json').isA<Map<String, Object?>>().deepEquals(<String, Object?>{
        'title': 'Onimai',
        'chapters': 3,
        'chained': true,
      })
      ..has((Map<String, Object?> m) => m['bytes'], 'bytes').isA<Uint8List>().deepEquals(<int>[0, 1, 2, 250, 255])
      ..has((Map<String, Object?> m) => m['type'], 'type').equals('image/png');
    check(seen.map((http.Request r) => r.headers['x-a'])).deepEquals(<String?>['1', null]);
    check(runtime.bridge.pendingHostCalls).equals(0);
  });

  test('an HTTP error status resolves; source code decides what it means', () async {
    installHttpHost(runtime, fakeHttp());
    final Object? status = await runtime.evaluate(
      '__paperbackHost.request({ url: "https://example.test/missing" }).then(r => r.status)',
    );
    check(status).equals(404);
  });

  test('a rejected host request keeps its context and settles the operation', () async {
    installHttpHost(runtime, MockClient((http.Request _) async => throw const SocketLikeException('connection reset')));
    final Future<Object?> op = runtime.evaluate(
      '__paperbackHost.request({ url: "https://example.test/x", method: "post" })',
    );
    check(await caught(op))
      ..has((PaperbackRuntimeException e) => e.reason, 'reason').equals(PaperbackFailureReason.sourceError)
      ..has((PaperbackRuntimeException e) => e.failure.message, 'message').which(
        (Subject<String> it) => it
          ..contains('HostCallError')
          ..contains('connection reset')
          ..contains('https://example.test/x')
          ..contains('POST'),
      );
  });

  test('source code can catch a rejection and read its details', () async {
    installHttpHost(runtime, MockClient((http.Request _) async => throw const SocketLikeException('offline')));
    final Object? result = await runtime.evaluate('''
      __paperbackHost.request({ url: "https://example.test/y" })
        .then(() => 'no', e => e.name + ' ' + e.details.url)
    ''');
    check(result).equals('HostCallError https://example.test/y');
  });

  test('invalid requests reject synchronously-started promises without hanging', () async {
    installHttpHost(runtime, fakeHttp());
    check(await caught(runtime.evaluate('__paperbackHost.request({ url: "file:///etc/passwd" })')))
        .has((PaperbackRuntimeException e) => e.failure.message, 'message')
        .contains('Only http and https');
  });

  test('a late completion after disposal never touches freed JS values', () async {
    final client = ControlledHttp();
    installHttpHost(runtime, client);
    final Future<Object?> op = runtime.evaluate('__paperbackHost.request({ url: "https://example.test/slow" })');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    check(client.pending).length.equals(1);
    runtime.dispose();
    check(await caught(op))
        .has(
          (PaperbackRuntimeException e) => e.reason,
          'reason',
        )
        .equals(PaperbackFailureReason.runtimeClosed);
    // The response arrives after the runtime is gone.
    client.completeAll('late');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // A second runtime still works on the same isolate.
    final other = SourceJsRuntime(limits: testLimits(), name: 'after');
    addTearDown(other.dispose);
    check(await other.evaluate('Promise.resolve(41).then(v => v + 1)')).equals(42);
  });

  test('two sources do not share globals', () async {
    final other = SourceJsRuntime(limits: testLimits(), name: 'other');
    addTearDown(other.dispose);
    await runtime.evaluate('globalThis.secret = "a"; Array.prototype.polluted = 1;');
    check(await other.evaluate('typeof secret + "," + typeof [].polluted')).equals('undefined,undefined');
    check(await runtime.evaluate('secret')).equals('a');
  });

  test('calls a global function with Dart arguments', () async {
    await runtime.evaluate(
      'function search(q, page) { return Promise.resolve({ q, page, hits: [q.toUpperCase()] }); }',
    );
    check(await runtime.call('search', <Object?>['onimai', 2]))
        .isA<Map<String, Object?>>()
        .deepEquals(<String, Object?>{
          'q': 'onimai',
          'page': 2,
          'hits': <Object?>['ONIMAI'],
        });
    await caught(runtime.call('missing', const <Object?>[]));
  });

  test('a host result larger than the memory limit fails the operation and closes the runtime', () async {
    final small = SourceJsRuntime(
      limits: testLimits(memoryLimitBytes: 2 * 1024 * 1024),
      name: 'small',
    );
    addTearDown(small.dispose);
    small.bridge.registerAsync('bigPayload', (List<Object?> _) async => Uint8List(8 * 1024 * 1024));
    check(await caught(small.evaluate('bigPayload()')))
        .has(
          (PaperbackRuntimeException e) => e.reason,
          'reason',
        )
        .equals(PaperbackFailureReason.memoryLimit);
    check(small.isClosed).isTrue();
  });

  test('a cancelled token fails before running', () async {
    final source = CancellationSource()..cancel('stop');
    check(await caught(runtime.evaluate('1', cancel: source.token)))
        .has(
          (PaperbackRuntimeException e) => e.reason,
          'reason',
        )
        .equals(PaperbackFailureReason.cancelled);
  });
}

final class SocketLikeException implements Exception {
  const SocketLikeException(this.message);

  final String message;

  @override
  String toString() => 'SocketLikeException: $message';
}
