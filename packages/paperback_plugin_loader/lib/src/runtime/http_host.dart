import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/src/runtime/promise_bridge.dart';
import 'package:paperback_plugin_loader/src/runtime/quickjs_runtime.dart';

/// Installs `__paperbackHost.request(request)` on [runtime], backed by
/// [client]. This is the transport primitive the versioned Paperback API
/// adapters (U6) build `Application.scheduleRequest` and interceptors on.
///
/// `request` is `{url, method?, headers?, body?}` where `body` is a string or
/// bytes. The promise resolves to `{status, url, headers, body, text}`:
/// `body` is a `Uint8Array`, `text` its UTF-8 decoding. Any HTTP status
/// resolves; transport failures reject with a `HostCallError` whose
/// `details` carry the method and URL.
void installHttpHost(SourceJsRuntime runtime, http.Client client, {String name = '__paperbackHost.request'}) {
  runtime.bridge.registerAsync(name, (List<Object?> args) async {
    final Object? spec = args.isEmpty ? null : args.first;
    if (spec is! Map<String, Object?>) {
      throw const HostCallError('request expects an object argument');
    }
    final Object? url = spec['url'];
    if (url is! String) throw const HostCallError('request.url must be a string');
    final String method = (spec['method'] as String? ?? 'GET').toUpperCase();
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException catch (e) {
      throw HostCallError('Invalid URL: ${e.message}', details: <String, Object?>{'url': url, 'method': method});
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw HostCallError('Only http and https URLs are allowed', details: <String, Object?>{'url': url});
    }
    final request = http.Request(method, uri);
    final Object? headers = spec['headers'];
    if (headers is Map<String, Object?>) {
      headers.forEach((String k, Object? v) => request.headers[k] = '$v');
    }
    switch (spec['body']) {
      case final String text:
        request.body = text;
      case final Uint8List bytes:
        request.bodyBytes = bytes;
      case null:
        break;
      default:
        throw HostCallError('request.body must be a string or bytes', details: <String, Object?>{'url': url});
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(await client.send(request));
    } on Object catch (e) {
      throw HostCallError(
        'Request failed: $e',
        details: <String, Object?>{'url': url, 'method': method},
      );
    }
    return <String, Object?>{
      'status': response.statusCode,
      'url': response.request?.url.toString() ?? url,
      'headers': response.headers,
      'body': response.bodyBytes,
      'text': utf8.decode(response.bodyBytes, allowMalformed: true),
    };
  });
}
