import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/src/runtime/bounded_body.dart';
import 'package:paperback_plugin_loader/src/runtime/promise_bridge.dart';
import 'package:source_runtime/source_runtime.dart' show CaptureMissException;

/// One HTTP exchange for the Paperback host (`__pbHost.fetch`).
///
/// The JS adapters own interceptors, redirect policy and cookie stores; this
/// class sends exactly one request and never follows redirects itself, so
/// each hop passes through the source's redirect handler and the capture
/// recorder sees every hop. Only http and https are allowed.
///
/// Wire request: `{url, method, headers, cookies?: {name: value}, body?,
/// timeoutMs?}`, where `body` is a string, bytes, or `{__form: {k: v}}`
/// (sent as `multipart/form-data`, as the 0.9 reference host's `FormData`).
///
/// Wire response: `{url, status, headers, setCookie: [..], body: bytes,
/// redirectUrl?}`. `headers` have lower-case names; `setCookie` keeps each
/// `Set-Cookie` value separate; `redirectUrl` is the absolute `Location` of
/// a 3xx response.
final class PaperbackHttp {
  PaperbackHttp(this.client, {this.defaultTimeout = const Duration(seconds: 30)});

  final http.Client client;

  /// Timeout when a request names none (0.9 requests never do).
  final Duration defaultTimeout;

  /// Requests that had no committed capture in replay mode. A source may
  /// catch the rejection, so the adapter checks this after every operation
  /// and fails the operation rather than let a miss look like source data.
  final List<String> captureMisses = <String>[];

  /// Sends one request. The response body is bounded by [maxBodyBytes]
  /// (the source's JS memory limit, see [readBoundedBody]); a larger body
  /// rejects with a `[resource-limit]` [HostCallError].
  Future<Map<String, Object?>> exchange(Map<String, Object?> wire, {required int maxBodyBytes}) async {
    final Object? url = wire['url'];
    if (url is! String) throw const HostCallError('fetch: url must be a string');
    final String method = (wire['method'] as String? ?? 'GET').toUpperCase();
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException catch (e) {
      throw HostCallError('Invalid URL: ${e.message}', details: <String, Object?>{'url': url});
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw HostCallError(
        '[capability-unavailable] Only http and https URLs are allowed',
        details: <String, Object?>{
          'url': url,
        },
      );
    }
    final http.BaseRequest request = _request(method, uri, wire);
    request.followRedirects = false;
    final Object? headers = wire['headers'];
    if (headers is Map<String, Object?>) {
      headers.forEach((String k, Object? v) {
        if (v != null) request.headers[k] = '$v';
      });
    }
    final Object? cookies = wire['cookies'];
    if (cookies is Map<String, Object?> && cookies.isNotEmpty) {
      // The 0.9 reference host's format: " a=1; b=2;" trimmed. Header names
      // are case-insensitive, so a source's own `cookie` header is extended
      // rather than replaced.
      final String pairs = cookies.entries.map((MapEntry<String, Object?> e) => '${e.key}=${e.value};').join(' ');
      final String? existing = request.headers['cookie'];
      request.headers['Cookie'] = existing == null || existing.isEmpty ? pairs : '${existing.trimRight()} $pairs';
    }
    final Object? timeoutMs = wire['timeoutMs'];
    final Duration timeout = timeoutMs is num && timeoutMs > 0
        ? Duration(milliseconds: timeoutMs.round())
        : defaultTimeout;
    final http.StreamedResponse streamed;
    final Uint8List body;
    try {
      streamed = await client.send(request).timeout(timeout);
      body = await readBoundedBody(streamed, maxBodyBytes, url: url).timeout(timeout);
    } on CaptureMissException catch (e) {
      captureMisses.add(e.key.toString());
      throw HostCallError('[capture-miss] No committed capture for ${e.key}', details: <String, Object?>{'url': url});
    } on TimeoutException {
      throw HostCallError(
        'Request timed out after ${timeout.inMilliseconds} ms',
        details: <String, Object?>{
          'url': url,
          'method': method,
        },
      );
    } on HostCallError {
      rethrow;
    } on Object catch (e) {
      throw HostCallError('Request failed: $e', details: <String, Object?>{'url': url, 'method': method});
    }
    final Map<String, List<String>> split = streamed.headersSplitValues;
    final String? location = streamed.headers['location'];
    final bool isRedirect = streamed.statusCode >= 300 && streamed.statusCode < 400 && location != null;
    return <String, Object?>{
      'url': uri.toString(),
      'status': streamed.statusCode,
      'headers': <String, Object?>{
        for (final MapEntry<String, String> h in streamed.headers.entries)
          if (h.key.toLowerCase() != 'set-cookie') h.key.toLowerCase(): h.value,
      },
      'setCookie': split['set-cookie'] ?? const <String>[],
      'body': body,
      if (isRedirect) 'redirectUrl': uri.resolve(location).toString(),
    };
  }

  http.BaseRequest _request(String method, Uri uri, Map<String, Object?> wire) {
    switch (wire['body']) {
      case null:
        return http.Request(method, uri);
      case final String text:
        return http.Request(method, uri)..bodyBytes = utf8.encode(text);
      case final Uint8List bytes:
        return http.Request(method, uri)..bodyBytes = bytes;
      case {'__form': final Map<String, Object?> form}:
        return http.MultipartRequest(
          method,
          uri,
        )..fields.addAll(<String, String>{for (final MapEntry<String, Object?> e in form.entries) e.key: '${e.value}'});
      default:
        throw HostCallError('fetch: unsupported body type', details: <String, Object?>{'url': uri.toString()});
    }
  }
}
