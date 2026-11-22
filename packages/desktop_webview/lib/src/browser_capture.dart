import 'dart:typed_data';

import 'package:source_runtime/source_runtime.dart';

/// A response the helper received, with its request (`--record`): every
/// main-frame and subresource exchange of a session, page scripts, XHR and
/// fetch included. Only manual capture runs record.
final class BrowserExchange {
  const BrowserExchange({
    required this.source,
    required this.method,
    required this.url,
    required this.status,
    required this.headers,
    this.requestBody,
    this.requestBodyOmitted = false,
    this.body,
    this.bodyOmitted = false,
  });

  /// The source whose session made the request.
  final SourceIdentity source;
  final String method;
  final Uri url;

  /// The request body, when the request had one the engine exposed.
  final Uint8List? requestBody;

  /// The request had a body the exchange does not carry (over 1 MiB or
  /// unreadable), so it cannot be keyed for replay.
  final bool requestBodyOmitted;
  final int status;

  /// Every response header in order; a repeated name (`Set-Cookie`) appears
  /// once per value. They may carry credentials: never log them.
  final List<(String, String)> headers;

  /// The decoded body; `null` when the engine kept none (a redirect hop).
  final Uint8List? body;

  /// The response had a body the exchange does not carry (over 10 MiB or
  /// unreadable).
  final bool bodyOmitted;
}

/// Records a desktop browser's exchanges into the capture format (manual
/// capture runs only; no test records).
///
/// Exchanges go through the same [CaptureRecorder] rules as host HTTP:
/// request headers are never recorded, only [recordedResponseHeaders] and
/// allow-listed sanitised cookies are kept, and a credential-bearing URL
/// aborts the recording. Only hosts [include] accepts are recorded, so
/// third-party hosts (analytics, ads, region-specific CDNs) never enter a
/// capture; replay fails them closed. An exchange that cannot be keyed or
/// stored whole (omitted request or response body) is listed in [skipped]
/// rather than recorded truncated.
final class BrowserCaptureRecorder {
  BrowserCaptureRecorder(this.recorder, {required this.include});

  final CaptureRecorder recorder;

  /// Whether a request URL is recorded.
  final bool Function(Uri url) include;

  /// Requests to hosts [include] rejected (`METHOD url`).
  final List<String> dropped = <String>[];

  /// Requests that could not be recorded whole, with the reason.
  final List<String> skipped = <String>[];

  /// Records [exchange]; pass it as `DesktopWebViewConfig.onExchange`.
  void call(BrowserExchange exchange) {
    final label = '${exchange.method} ${CaptureKey.canonicalUrl(exchange.url)}';
    if (!include(exchange.url)) {
      dropped.add(label);
      return;
    }
    if (exchange.requestBodyOmitted) {
      skipped.add('$label: request body unavailable for capture matching');
      return;
    }
    // WebView2 keeps no body for a redirect hop, and the page never sees
    // one: a redirect is recorded with an empty body.
    final bool redirect = exchange.status >= 300 && exchange.status <= 399;
    if (exchange.bodyOmitted && !redirect) {
      skipped.add('$label: response body unavailable');
      return;
    }
    recorder.record(
      method: exchange.method,
      url: exchange.url,
      requestBody: exchange.requestBody,
      status: exchange.status,
      headers: exchange.headers,
      body: redirect ? Uint8List(0) : exchange.body ?? Uint8List(0),
    );
  }
}

/// Serves committed captures to every session of a `DesktopBrowserPort`
/// (replay mode). The helper runs offline, so a request is answered only from
/// here: a request without a capture (or whose body could not be matched)
/// fails as a network error, is listed in [misses], and never reaches a
/// server. DNS is blocked by the helper as a backstop.
///
/// A worker's own interception runs first: its replacement wins, and its
/// observer sees every request. Cross-origin requests get permissive CORS
/// headers at serve time, because captures keep only content-type,
/// location, retry-after and cf-mitigated.
final class BrowserCaptureReplay {
  BrowserCaptureReplay(this.captures);

  final CaptureSet captures;

  /// Requests that had no capture, in order. Tests assert it is empty (or
  /// holds only expected misses).
  final List<CaptureKey> misses = <CaptureKey>[];

  /// Requests served from captures, in order.
  final List<CaptureKey> served = <CaptureKey>[];

  /// The replacement for [request], or `null` for a miss. A captured
  /// redirect is served as recorded (with its `Location` resolved to an
  /// absolute URL): only this host-side replay may substitute one, never a
  /// worker, and the helper admits only http(s) targets.
  BrowserReplacement? serve(BrowserRequest request) {
    final String? origin = _header(request.headers, 'origin');
    if (request.method == 'OPTIONS' &&
        origin != null &&
        _header(request.headers, 'access-control-request-method') != null) {
      // A CORS preflight: the browser asks before a cross-origin request with
      // custom headers. Allow what it asks for; the request itself must still
      // be captured.
      return BrowserReplacement(
        status: 204,
        reason: 'No Content',
        headers: <String, String>{
          'access-control-allow-origin': origin,
          'access-control-allow-credentials': 'true',
          'access-control-allow-methods': _header(request.headers, 'access-control-request-method')!,
          'access-control-allow-headers': ?_header(request.headers, 'access-control-request-headers'),
        },
      );
    }
    final CaptureKey? key = browserCaptureKey(captures, request);
    if (key == null || !captures.contains(key)) {
      misses.add(key ?? captures.manifest.keyFor(request.method, request.url, null));
      return null;
    }
    final CapturedResponse r = captures.lookup(key);
    served.add(key);
    final String? location = r.headers['location'];
    return BrowserReplacement(
      status: r.status,
      reason: _reason(r.status),
      headers: <String, String>{
        ...r.headers,
        if (location != null) 'location': request.url.resolve(location).toString(),
        if (origin != null) ...<String, String>{
          'access-control-allow-origin': origin,
          'access-control-allow-credentials': 'true',
        },
      },
      body: r.body,
    );
  }

  static String? _header(Map<String, String> headers, String name) {
    for (final MapEntry<String, String> h in headers.entries) {
      if (h.key.toLowerCase() == name) return h.value;
    }
    return null;
  }

  static String _reason(int status) => switch (status) {
    200 => 'OK',
    301 => 'Moved Permanently',
    302 => 'Found',
    303 => 'See Other',
    307 => 'Temporary Redirect',
    308 => 'Permanent Redirect',
    204 => 'No Content',
    403 => 'Forbidden',
    404 => 'Not Found',
    429 => 'Too Many Requests',
    503 => 'Service Unavailable',
    _ => 'Replayed',
  };
}
