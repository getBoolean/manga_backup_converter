@TestOn('vm')
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:test/scaffolding.dart';

import 'test_support.dart';

/// L2: response bodies are bounded by the source's JS memory limit and the
/// stream is cancelled at the bound; no request leaves the process.
void main() {
  /// A client whose body never ends (no Content-Length), counting the chunks
  /// it was asked for and whether the reader cancelled it.
  ({MockClient client, int Function() chunks, bool Function() cancelled}) endless() {
    var chunks = 0;
    var cancelled = false;
    final client = MockClient.streaming((http.BaseRequest request, http.ByteStream body) async {
      late final StreamController<List<int>> out;
      out = StreamController<List<int>>(
        onListen: () async {
          while (!cancelled) {
            chunks++;
            out.add(List<int>.filled(1024, 0x61));
            await Future<void>.delayed(Duration.zero);
          }
        },
        onCancel: () => cancelled = true,
      );
      return http.StreamedResponse(out.stream, 200);
    });
    return (client: client, chunks: () => chunks, cancelled: () => cancelled);
  }

  test('PaperbackHttp fails an endless body at the bound and cancels it', () async {
    final ({MockClient client, int Function() chunks, bool Function() cancelled}) e = endless();
    final Object? error = await PaperbackHttp(e.client)
        .exchange(const <String, Object?>{'url': 'https://example.test/endless'}, maxBodyBytes: 64 * 1024)
        .then<Object?>((_) => null, onError: (Object err) => err);
    check(error).isA<HostCallError>().has((HostCallError h) => h.message, 'message').contains('[resource-limit]');
    check(e.cancelled()).isTrue();
    check(e.chunks()).isLessOrEqual(66);
  });

  test('PaperbackHttp fails a declared Content-Length above the bound before reading', () async {
    final client = MockClient((http.Request _) async => http.Response('x' * 2048, 200));
    await check(
      PaperbackHttp(client).exchange(const <String, Object?>{'url': 'https://example.test/big'}, maxBodyBytes: 1024),
    ).throws<HostCallError>();
    final Map<String, Object?> ok = await PaperbackHttp(
      client,
    ).exchange(const <String, Object?>{'url': 'https://example.test/big'}, maxBodyBytes: 2048);
    check(ok['body']).isA<List<int>>().length.equals(2048);
  });

  test('the runtime HTTP host bounds the body by half the JS memory limit', () async {
    final runtime = SourceJsRuntime(
      limits: testLimits(memoryLimitBytes: 256 * 1024),
      name: 'body-limit',
    );
    addTearDown(runtime.dispose);
    final ({MockClient client, int Function() chunks, bool Function() cancelled}) e = endless();
    installHttpHost(runtime, e.client);
    Object? failure;
    try {
      await runtime.evaluate('__paperbackHost.request({ url: "https://example.test/endless" })');
    } on PaperbackRuntimeException catch (err) {
      failure = err;
    }
    check(failure)
        .isA<PaperbackRuntimeException>()
        .has((PaperbackRuntimeException x) => '$x', 'text')
        .contains(
          'resource-limit',
        );
    check(e.cancelled()).isTrue();
    check(e.chunks()).isLessOrEqual(130);
  });
}
