import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:source_runtime/src/backends/redaction.dart';
import 'package:source_runtime/src/capture/capture_format.dart';

/// The only response headers written to a capture: what replay needs.
/// Everything else is dropped, including credentials (`set-cookie`, except
/// the sanitised allow-listed cookies in [CaptureExchange.setCookies]),
/// transfer framing that no longer describes the stored decoded body, and
/// CDN/edge headers that identify the recording machine's network or region.
///
/// `cf-mitigated` is Cloudflare's header-based challenge signal
/// (`cf-mitigated: challenge`); replay keeps it so a source's challenge
/// detection sees the same response a live challenge produced.
const Set<String> recordedResponseHeaders = <String>{'content-type', 'location', 'retry-after', 'cf-mitigated'};

/// One recorded exchange: as written to the capture, its body, and the
/// headers a live caller receives (the recorded ones plus the real values of
/// allow-listed cookies).
typedef RecordedExchange = ({CaptureExchange exchange, Uint8List body, Map<String, String> liveHeaders});

/// Turns live exchanges into the capture format (record mode), whatever
/// produced them: `RecordingHttpClient` for host HTTP, and the desktop
/// browser recorder for a WebView's main-frame and subresource traffic.
///
/// The first exchange for a [CaptureKey] wins; a repeat returns it. Request
/// headers are never recorded, only [recordedResponseHeaders] are kept, and
/// a URL that would need redaction aborts the recording ([StateError])
/// rather than committing a credential.
///
/// Cookies: a `Set-Cookie` is recorded only for a name in
/// [setCookieAllowList] (empty by default), sanitised to name, value, `Path`
/// and `Domain` ([CapturedCookie]). A [CapturedCookieValue.redact] value is
/// written as [CapturedCookie.redactedValue] and registered with the
/// redactor, so a later request URL that carries it aborts the recording.
class CaptureRecorder {
  CaptureRecorder({
    required this.licence,
    this.volatileQueryParameters = const <String>{},
    Map<String, CapturedCookieValue> setCookieAllowList = const <String, CapturedCookieValue>{},
    Redactor? redactor,
  }) : setCookieAllowList = Map<String, CapturedCookieValue>.unmodifiable(setCookieAllowList),
       _redactor = redactor ?? Redactor();

  /// Licence or terms statement recorded for every artifact.
  final String licence;

  /// Query parameters matched by name only (for example a current date).
  final Set<String> volatileQueryParameters;

  /// Cookie names whose `Set-Cookie` is recorded, and how. Written to the
  /// manifest.
  final Map<String, CapturedCookieValue> setCookieAllowList;
  final Redactor _redactor;

  final Map<CaptureKey, RecordedExchange> _recorded = <CaptureKey, RecordedExchange>{};

  /// Number of distinct exchanges recorded.
  int get length => _recorded.length;

  /// The recorded exchanges, in recording order.
  Iterable<CaptureExchange> get exchanges => _recorded.values.map((RecordedExchange r) => r.exchange);

  /// The key [method], [url] and [body] record under.
  CaptureKey keyFor(String method, Uri url, Uint8List? body) =>
      CaptureKey.forRequest(method, url, body ?? Uint8List(0), volatile: volatileQueryParameters);

  /// The exchange already recorded for [key], if any.
  RecordedExchange? operator [](CaptureKey key) => _recorded[key];

  /// Fails when [url] carries a credential.
  void checkUrl(Uri url) {
    final String live = CaptureKey.canonicalUrl(url);
    if (_redactor.redact(live) != live) {
      throw StateError('Refusing to record a URL that carries credentials: ${_redactor.redact(live)}');
    }
  }

  /// Records one exchange (the first for its key wins) and returns what is
  /// recorded. [headers] are the live response headers in order; a repeated
  /// name (`Set-Cookie`) appears once per value or comma-joined.
  RecordedExchange record({
    required String method,
    required Uri url,
    required int status,
    required List<(String, String)> headers,
    required Uint8List body,
    Uint8List? requestBody,
  }) {
    checkUrl(url);
    final CaptureKey key = keyFor(method, url, requestBody);
    final RecordedExchange? existing = _recorded[key];
    if (existing != null) return existing;
    final String digest = sha256Hex(body);
    final kept = <String, String>{};
    for (final (String name, String value) in headers) {
      final String lower = name.toLowerCase();
      if (recordedResponseHeaders.contains(lower)) {
        kept[lower] = kept.containsKey(lower) ? '${kept[lower]}, $value' : value;
      }
    }
    final (List<CapturedCookie> recordedCookies, List<String> liveCookies) = _cookies(headers);
    return _recorded[key] = (
      exchange: CaptureExchange(
        key: key,
        status: status,
        headers: kept,
        bodyFile: '$captureBodiesDirName/$digest.bin',
        artifact: CaptureArtifact(
          sourceUrl: CaptureKey.canonicalUrl(url),
          sha256: digest,
          size: body.length,
          licence: licence,
        ),
        setCookies: recordedCookies,
      ),
      body: body,
      liveHeaders: <String, String>{...kept, if (liveCookies.isNotEmpty) 'set-cookie': liveCookies.join(', ')},
    );
  }

  /// The allow-listed cookies of a live response: as recorded (sanitised,
  /// redacted where configured) and as the live caller receives them.
  (List<CapturedCookie>, List<String>) _cookies(List<(String, String)> headers) {
    final recorded = <CapturedCookie>[];
    final live = <String>[];
    if (setCookieAllowList.isEmpty) return (recorded, live);
    for (final (String name, String value) in headers) {
      if (name.toLowerCase() != 'set-cookie') continue;
      for (final ParsedSetCookie c in parseSetCookieHeader(value)) {
        final CapturedCookieValue? mode = setCookieAllowList[c.name];
        if (mode == null) continue;
        final redact = mode == CapturedCookieValue.redact;
        if (redact) _redactor.addSecret(c.value);
        recorded.add(
          CapturedCookie(
            name: c.name,
            value: redact ? CapturedCookie.redactedValue : c.value,
            path: c.path,
            domain: c.domain,
            redacted: redact,
          ),
        );
        live.add(CapturedCookie(name: c.name, value: c.value, path: c.path, domain: c.domain).toHeader());
      }
    }
    return (recorded, live);
  }

  /// Writes `capture.json` and `bodies/` into [dir], replacing earlier files.
  void writeTo(Directory dir, {required String ecosystem, required String source, String notes = ''}) {
    final bodiesDir = Directory(p.join(dir.path, captureBodiesDirName));
    if (bodiesDir.existsSync()) bodiesDir.deleteSync(recursive: true);
    bodiesDir.createSync(recursive: true);
    for (final RecordedExchange r in _recorded.values) {
      File(p.join(dir.path, r.exchange.bodyFile)).writeAsBytesSync(r.body);
    }
    final manifest = CaptureManifest(
      ecosystem: ecosystem,
      source: source,
      recordedAt: DateTime.now().toUtc(),
      notes: notes,
      volatileQueryParameters: volatileQueryParameters,
      setCookieAllowList: setCookieAllowList,
      exchanges: exchanges.toList(),
    );
    File(p.join(dir.path, captureManifestFileName)).writeAsStringSync(manifest.encode());
  }
}
