import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/src/runtime/promise_bridge.dart';
import 'package:paperback_plugin_loader/src/runtime/runtime_limits.dart' show PaperbackRuntimeLimits;

/// Reads [response]'s body, failing with a [HostCallError] once it exceeds
/// [maxBytes] (a declared `Content-Length` above it fails before reading).
/// The stream is cancelled at that point, so an endless or oversized body
/// never grows past the bound in Dart memory.
///
/// The bound comes from the source's KTD25 JS memory limit
/// ([PaperbackRuntimeLimits.memoryLimitBytes]): the body is handed to the
/// source inside its QuickJS heap, so a body larger than the heap could
/// never be materialised there anyway, and reading it whole in the host only
/// wastes memory. The limit is sized from the benchmarked peak heap of the
/// committed bundles, whose largest captured body (about 1 MiB) fits.
Future<Uint8List> readBoundedBody(http.StreamedResponse response, int maxBytes, {required String url}) async {
  final int? declared = response.contentLength;
  if (declared != null && declared > maxBytes) throw _tooLarge(maxBytes, url);
  final builder = BytesBuilder(copy: false);
  final done = Completer<Uint8List>();
  late final StreamSubscription<List<int>> sub;
  sub = response.stream.listen(
    (List<int> chunk) {
      if (builder.length + chunk.length > maxBytes) {
        unawaited(sub.cancel());
        if (!done.isCompleted) done.completeError(_tooLarge(maxBytes, url));
        return;
      }
      builder.add(chunk);
    },
    onError: (Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    },
    onDone: () {
      if (!done.isCompleted) done.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  return done.future;
}

HostCallError _tooLarge(int maxBytes, String url) => HostCallError(
  '[resource-limit] Response body exceeds $maxBytes bytes (the source JS memory limit)',
  details: <String, Object?>{'url': url, 'maxBytes': maxBytes},
);
