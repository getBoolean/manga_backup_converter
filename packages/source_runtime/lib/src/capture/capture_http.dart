import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:source_runtime/src/backends/redaction.dart';
import 'package:source_runtime/src/capture/capture_format.dart';

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

/// The only response headers written to a capture: what replay needs.
/// Everything else is dropped, including credentials (`set-cookie`), transfer
/// framing that no longer describes the stored decoded body, and CDN/edge
/// headers that identify the recording machine's network or region.
const Set<String> recordedResponseHeaders = <String>{'content-type', 'location', 'retry-after'};

/// HTTP client that forwards to a real client and records exchanges (record
/// mode). Used only by `tool/capture_source_fixtures.dart`; no test uses it.
///
/// Requests are spaced at least [minInterval] apart. Request headers are not
/// recorded, only [recordedResponseHeaders] are kept, and a URL that would
/// need redaction aborts the recording rather than committing a credential.
class RecordingHttpClient extends http.BaseClient {
  RecordingHttpClient(
    this._inner, {
    required this.minInterval,
    required this.licence,
    this.volatileQueryParameters = const <String>{},
    Redactor? redactor,
  }) : _redactor = redactor ?? Redactor();

  final http.Client _inner;
  final Duration minInterval;

  /// Licence or terms statement recorded for every artifact.
  final String licence;

  /// Query parameters matched by name only (for example a current date).
  final Set<String> volatileQueryParameters;
  final Redactor _redactor;
  final Map<CaptureKey, (CaptureExchange, Uint8List)> _recorded = <CaptureKey, (CaptureExchange, Uint8List)>{};
  DateTime? _last;

  /// Number of distinct exchanges recorded.
  int get length => _recorded.length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final Uint8List requestBody = await request.finalize().toBytes();
    final String liveUrl = CaptureKey.canonicalUrl(request.url);
    if (_redactor.redact(liveUrl) != liveUrl) {
      throw StateError('Refusing to record a URL that carries credentials: ${_redactor.redact(liveUrl)}');
    }
    final key = CaptureKey.forRequest(request.method, request.url, requestBody, volatile: volatileQueryParameters);
    final (CaptureExchange, Uint8List)? existing = _recorded[key];
    if (existing == null) {
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
      final Uint8List body = await live.stream.toBytes();
      final String digest = sha256Hex(body);
      final headers = <String, String>{
        for (final MapEntry<String, String> h in live.headers.entries)
          if (recordedResponseHeaders.contains(h.key.toLowerCase())) h.key.toLowerCase(): h.value,
      };
      _recorded[key] = (
        CaptureExchange(
          key: key,
          status: live.statusCode,
          headers: headers,
          bodyFile: '$captureBodiesDirName/$digest.bin',
          artifact: CaptureArtifact(sourceUrl: liveUrl, sha256: digest, size: body.length, licence: licence),
        ),
        body,
      );
    }
    final (CaptureExchange exchange, Uint8List body) = _recorded[key]!;
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      exchange.status,
      contentLength: body.length,
      request: request,
      headers: exchange.headers,
    );
  }

  /// Writes `capture.json` and `bodies/` into [dir], replacing earlier files.
  void writeTo(Directory dir, {required String ecosystem, required String source, String notes = ''}) {
    final bodiesDir = Directory(p.join(dir.path, captureBodiesDirName));
    if (bodiesDir.existsSync()) bodiesDir.deleteSync(recursive: true);
    bodiesDir.createSync(recursive: true);
    for (final (CaptureExchange e, Uint8List body) in _recorded.values) {
      File(p.join(dir.path, e.bodyFile)).writeAsBytesSync(body);
    }
    final manifest = CaptureManifest(
      ecosystem: ecosystem,
      source: source,
      recordedAt: DateTime.now().toUtc(),
      notes: notes,
      volatileQueryParameters: volatileQueryParameters,
      exchanges: <CaptureExchange>[for (final (CaptureExchange e, Uint8List _) in _recorded.values) e],
    );
    File(p.join(dir.path, captureManifestFileName)).writeAsStringSync(manifest.encode());
  }
}
