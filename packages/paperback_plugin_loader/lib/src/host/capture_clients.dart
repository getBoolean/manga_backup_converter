import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:source_runtime/source_runtime.dart';

/// Serves requests from several committed capture sets (one per site), and
/// nothing else: a request no set holds throws [CaptureMissException] and is
/// recorded in [misses]. Replay mode of the worker (`--replay=<dir>`).
final class MultiReplayHttpClient extends http.BaseClient {
  MultiReplayHttpClient(this.sets);

  /// Loads each capture directory.
  factory MultiReplayHttpClient.load(List<Directory> dirs) =>
      MultiReplayHttpClient(<CaptureSet>[for (final Directory d in dirs) loadCaptureSet(d)]);

  final List<CaptureSet> sets;
  final List<CaptureKey> misses = <CaptureKey>[];
  final List<CaptureKey> served = <CaptureKey>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final Uint8List body = await request.finalize().toBytes();
    CaptureKey? firstKey;
    for (final CaptureSet set in sets) {
      final CaptureKey key = set.manifest.keyFor(request.method, request.url, body);
      firstKey ??= key;
      if (!set.contains(key)) continue;
      final CapturedResponse r = set.lookup(key);
      served.add(key);
      return http.StreamedResponse(
        Stream<List<int>>.value(r.body),
        r.status,
        contentLength: r.body.length,
        request: request,
        headers: r.headers,
      );
    }
    final CaptureKey key = firstKey ?? CaptureKey.forRequest(request.method, request.url, body);
    misses.add(key);
    throw CaptureMissException(key);
  }
}

/// How the worker reaches the network, chosen by its flags.
sealed class PaperbackNetworkMode {
  const PaperbackNetworkMode();
}

/// The real network (production).
final class LiveNetwork extends PaperbackNetworkMode {
  const LiveNetwork();
}

/// Committed captures only (tests, CI and the e2e suite).
final class ReplayNetwork extends PaperbackNetworkMode {
  const ReplayNetwork(this.dirs);

  final List<Directory> dirs;
}

/// The manual capture run: forward to the network and record every
/// exchange into [dir] when the worker shuts down. Never used by a test.
final class RecordNetwork extends PaperbackNetworkMode {
  const RecordNetwork({
    required this.dir,
    required this.source,
    required this.minInterval,
    required this.licence,
    this.volatileQueryParameters = const <String>{},
    this.setCookieAllowList = const <String, CapturedCookieValue>{},
  });

  final Directory dir;

  /// Capture name, for example `mangadex`.
  final String source;
  final Duration minInterval;
  final String licence;
  final Set<String> volatileQueryParameters;

  /// Cookies whose `Set-Cookie` the capture keeps (protocol 1.3), and
  /// whether each value is kept or redacted. Empty unless the site's
  /// scenario names one.
  final Map<String, CapturedCookieValue> setCookieAllowList;
}
