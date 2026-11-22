import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:source_runtime/src/backends/redaction.dart';
import 'package:source_runtime/src/capture/capture_format.dart';
import 'package:source_runtime/src/capture/capture_recorder.dart';

/// Loads committed captures from `<root>/<ecosystem>/<source>/`.
CaptureSet loadCaptureSet(Directory captureDir) {
  final manifestFile = File(p.join(captureDir.path, captureManifestFileName));
  final manifest = CaptureManifest.fromJson(
    jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>,
  );
  final bodies = <String, Uint8List>{
    for (final CaptureExchange e in manifest.exchanges)
      e.bodyFile: File(p.join(captureDir.path, e.bodyFile)).readAsBytesSync(),
  };
  return CaptureSet.fromParts(manifest, bodies);
}

/// Locates `fixtures/source_captures/<ecosystem>/<source>` by walking up from
/// [start] (default: the current directory). Returns `null` if not found.
Directory? findCaptureDir(String ecosystem, String source, {Directory? start}) {
  Directory dir = start ?? Directory.current;
  while (true) {
    final candidate = Directory(p.join(dir.path, 'fixtures', 'source_captures', ecosystem, source));
    if (candidate.existsSync()) return candidate;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// HTTP client that serves only committed captures (replay mode).
///
/// A request without a capture throws [CaptureMissException] and is recorded
/// in [misses]. Hosts that swallow transport errors would otherwise hide the
/// miss, so tests must also assert [misses] is empty.
class ReplayHttpClient extends http.BaseClient {
  ReplayHttpClient(this.captures);

  final CaptureSet captures;

  /// Requests that had no committed capture, in order.
  final List<CaptureKey> misses = <CaptureKey>[];

  /// Requests served from captures, in order.
  final List<CaptureKey> served = <CaptureKey>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final Uint8List body = await request.finalize().toBytes();
    final CaptureKey key = captures.manifest.keyFor(request.method, request.url, body);
    final CapturedResponse response;
    try {
      response = captures.lookup(key);
    } on CaptureMissException {
      misses.add(key);
      rethrow;
    }
    served.add(key);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.body),
      response.status,
      contentLength: response.body.length,
      request: request,
      headers: response.headers,
    );
  }
}

/// HTTP client that forwards to a real client and records exchanges (record
/// mode). Used only by `tool/capture_source_fixtures.dart`; no test uses it.
///
/// Requests are spaced at least [minInterval] apart. Request headers are not
/// recorded, only [recordedResponseHeaders] are kept, and a URL that would
/// need redaction aborts the recording rather than committing a credential.
///
/// Cookies: a `Set-Cookie` is recorded only for a name in
/// [setCookieAllowList] (empty by default), sanitised to name, value, `Path`
/// and `Domain` ([CapturedCookie]). A [CapturedCookieValue.redact] value is
/// written as [CapturedCookie.redactedValue] and registered with the
/// redactor, so a later request URL that carries it aborts the recording.
/// The live scenario still receives the real allow-listed values, so it can
/// keep using a site-issued token while recording; other cookies reach it
/// no more than they reach a replay.
class RecordingHttpClient extends http.BaseClient {
  RecordingHttpClient(
    this._inner, {
    required this.minInterval,
    required String licence,
    Set<String> volatileQueryParameters = const <String>{},
    Map<String, CapturedCookieValue> setCookieAllowList = const <String, CapturedCookieValue>{},
    Redactor? redactor,
  }) : recorder = CaptureRecorder(
         licence: licence,
         volatileQueryParameters: volatileQueryParameters,
         setCookieAllowList: setCookieAllowList,
         redactor: redactor,
       );

  final http.Client _inner;
  final Duration minInterval;

  /// What this client recorded (shared format with the browser recorder).
  final CaptureRecorder recorder;
  DateTime? _last;

  /// Licence or terms statement recorded for every artifact.
  String get licence => recorder.licence;

  /// Query parameters matched by name only (for example a current date).
  Set<String> get volatileQueryParameters => recorder.volatileQueryParameters;

  /// Cookie names whose `Set-Cookie` is recorded, and how.
  Map<String, CapturedCookieValue> get setCookieAllowList => recorder.setCookieAllowList;

  /// Number of distinct exchanges recorded.
  int get length => recorder.length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final Uint8List requestBody = await request.finalize().toBytes();
    recorder.checkUrl(request.url);
    RecordedExchange? recorded = recorder[recorder.keyFor(request.method, request.url, requestBody)];
    if (recorded == null) {
      final DateTime? last = _last;
      if (last != null) {
        final Duration wait = minInterval - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _last = DateTime.now();
      final forwarded = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..followRedirects = request.followRedirects
        ..bodyBytes = requestBody;
      final http.StreamedResponse live = await _inner.send(forwarded);
      recorded = recorder.record(
        method: request.method,
        url: request.url,
        requestBody: requestBody,
        status: live.statusCode,
        headers: <(String, String)>[for (final MapEntry<String, String> h in live.headers.entries) (h.key, h.value)],
        body: await live.stream.toBytes(),
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(recorded.body),
      recorded.exchange.status,
      contentLength: recorded.body.length,
      request: request,
      headers: recorded.liveHeaders,
    );
  }

  /// Writes `capture.json` and `bodies/` into [dir], replacing earlier files.
  void writeTo(Directory dir, {required String ecosystem, required String source, String notes = ''}) =>
      recorder.writeTo(dir, ecosystem: ecosystem, source: source, notes: notes);
}
