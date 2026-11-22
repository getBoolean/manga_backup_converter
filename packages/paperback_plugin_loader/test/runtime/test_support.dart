import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';

/// Small explicit limits for tests (KTD25: tests never rely on defaults).
///
/// The default deadline is long on purpose: a test that is not about the
/// deadline must not fail because a loaded machine ran it slowly. Tests about
/// the deadline pass a short one and assert the termination reason.
PaperbackRuntimeLimits testLimits({
  int memoryLimitBytes = 16 * 1024 * 1024,
  int maxStackBytes = 256 * 1024,
  Duration operationDeadline = const Duration(seconds: 30),
  Duration jobSlice = const Duration(milliseconds: 5),
}) => PaperbackRuntimeLimits(
  memoryLimitBytes: memoryLimitBytes,
  maxStackBytes: maxStackBytes,
  operationDeadline: operationDeadline,
  jobSlice: jobSlice,
);

/// A fake HTTP client serving canned responses after [delay]. No request
/// leaves the process.
MockClient fakeHttp({
  Duration delay = const Duration(milliseconds: 30),
  Map<String, Object?> json = const <String, Object?>{'title': 'Onimai', 'chapters': 3},
  List<http.Request>? seen,
}) => MockClient((http.Request request) async {
  seen?.add(request);
  await Future<void>.delayed(delay);
  if (request.url.path.endsWith('/missing')) return http.Response('not found', 404);
  if (request.url.path.endsWith('/bytes')) {
    return http.Response.bytes(<int>[0, 1, 2, 250, 255], 200, headers: <String, String>{'content-type': 'image/png'});
  }
  return http.Response(jsonEncode(json), 200, headers: <String, String>{'content-type': 'application/json'});
});

/// A client whose responses complete only when the test says so.
final class ControlledHttp extends http.BaseClient {
  final List<Completer<http.StreamedResponse>> pending = <Completer<http.StreamedResponse>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final completer = Completer<http.StreamedResponse>();
    pending.add(completer);
    return completer.future;
  }

  void completeAll(String body) {
    for (final Completer<http.StreamedResponse> c in pending) {
      if (!c.isCompleted) {
        c.complete(http.StreamedResponse(Stream<List<int>>.value(utf8.encode(body)), 200));
      }
    }
  }
}

/// Measures how long [body] takes.
Future<(T, Duration)> timed<T>(Future<T> Function() body) async {
  final watch = Stopwatch()..start();
  final T result = await body();
  return (result, watch.elapsed);
}

/// The [PaperbackRuntimeException] that [op] fails with.
Future<PaperbackRuntimeException> caught(Future<Object?> op) async {
  try {
    await op;
  } on PaperbackRuntimeException catch (e) {
    return e;
  }
  throw StateError('expected the operation to fail');
}
