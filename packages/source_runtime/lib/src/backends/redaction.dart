import 'dart:async';
import 'dart:convert';

/// Placeholder written in place of every redacted value.
const String redactedPlaceholder = '[REDACTED]';

/// Strips credentials from worker/helper diagnostics before they reach any
/// user-visible log sink (KTD9).
///
/// Removes:
/// - `Cookie`, `Set-Cookie`, `Authorization` and `Proxy-Authorization` values,
///   in header (`Name: value`), assignment (`name=value`) and JSON
///   (`"name": "value"`) forms;
/// - credential URL components: user-info (`scheme://user:pass@host`) and the
///   values of credential-like query parameters;
/// - every registered session secret, verbatim and URL-encoded.
///
/// Redaction works on complete lines. Use [RedactingLineSink] for byte
/// streams so a secret split across chunks is still caught.
class Redactor {
  Redactor({Iterable<String> secrets = const <String>[]}) {
    secrets.forEach(addSecret);
  }

  final Set<String> _secrets = <String>{};

  static const List<String> _headerNames = <String>[
    'set-cookie',
    'cookie',
    'proxy-authorization',
    'authorization',
  ];

  static const List<String> _credentialParams = <String>[
    'access_token',
    'refresh_token',
    'id_token',
    'token',
    'auth',
    'password',
    'passwd',
    'pass',
    'secret',
    'api_key',
    'apikey',
    'key',
    'session',
    'sessionid',
    'session_id',
    'sid',
    'signature',
    'sig',
  ];

  static final RegExp _jsonHeader = RegExp(
    '("(?:${_headerNames.join('|')})"\\s*:\\s*)"(?:[^"\\\\]|\\\\.)*"',
    caseSensitive: false,
  );

  static final RegExp _headerLine = RegExp(
    '\\b(${_headerNames.join('|')})(\\s*[:=]\\s*)[^\\r\\n]*',
    caseSensitive: false,
  );

  static final RegExp _userInfo = RegExp(r'([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/\s@?#]+@');

  static final RegExp _queryCredential = RegExp(
    '([?&;](?:${_credentialParams.join('|')})=)[^&#\\s"\']*',
    caseSensitive: false,
  );

  /// Registers a session secret (password, token, cookie value) to redact.
  /// Empty strings are ignored.
  void addSecret(String secret) {
    if (secret.isEmpty) return;
    _secrets.add(secret);
  }

  /// Returns [line] with all credentials replaced by [redactedPlaceholder].
  String redact(String line) {
    var out = line;
    // Secrets first, longest first, so a secret containing another is removed whole.
    final List<String> ordered = _secrets.toList()..sort((String a, String b) => b.length.compareTo(a.length));
    for (final secret in ordered) {
      out = out.replaceAll(secret, redactedPlaceholder);
      final String encoded = Uri.encodeQueryComponent(secret);
      if (encoded != secret) out = out.replaceAll(encoded, redactedPlaceholder);
      final String encodedFull = Uri.encodeComponent(secret);
      if (encodedFull != secret && encodedFull != encoded) out = out.replaceAll(encodedFull, redactedPlaceholder);
    }
    out = out.replaceAllMapped(_jsonHeader, (Match m) => '${m[1]}"$redactedPlaceholder"');
    out = out.replaceAllMapped(_headerLine, (Match m) {
      // Leave JSON forms already handled above untouched.
      if (m[0]!.contains('"$redactedPlaceholder"')) return m[0]!;
      return '${m[1]}${m[2]}$redactedPlaceholder';
    });
    out = out.replaceAllMapped(_userInfo, (Match m) => '${m[1]}$redactedPlaceholder@');
    out = out.replaceAllMapped(_queryCredential, (Match m) => '${m[1]}$redactedPlaceholder');
    return out;
  }
}

/// Splits a byte stream (for example a worker's stderr) into complete UTF-8
/// lines, redacts each, and forwards it to the sink callback.
///
/// A trailing partial line is held until its newline arrives or [close] is
/// called, so a secret split across chunks is redacted as one line.
class RedactingLineSink {
  RedactingLineSink(this._redactor, this._sink);

  final Redactor _redactor;
  final void Function(String line) _sink;
  final List<int> _pending = <int>[];

  /// Adds raw bytes.
  void add(List<int> bytes) {
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0x0A) {
        _pending.addAll(bytes.sublist(start, i));
        _emit();
        start = i + 1;
      }
    }
    if (start < bytes.length) _pending.addAll(bytes.sublist(start));
  }

  /// Flushes any trailing partial line.
  void close() {
    if (_pending.isNotEmpty) _emit();
  }

  /// Consumes [stream] until done, returning when the last line is flushed.
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.forEach(add);
    close();
  }

  void _emit() {
    String line = utf8.decode(_pending, allowMalformed: true);
    _pending.clear();
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    _sink(_redactor.redact(line));
  }
}
