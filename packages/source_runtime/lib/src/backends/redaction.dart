import 'dart:async';
import 'dart:convert';

import 'package:source_runtime/src/backends/protocol.dart' show protocolMaxFrameBytes;

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

  /// Redacts the kept head of a line that was cut at a size cap (the rest
  /// was dropped). A secret straddling the cut would leave its first part
  /// in the head, where no whole-value match can find it, so the head is
  /// first cut back to its last whitespace (a token, user-info or
  /// credential value never spans one) and then any tail that begins a
  /// registered secret (verbatim or URL-encoded) is dropped as well.
  String redactTruncated(String head) {
    var out = head;
    final int space = out.lastIndexOf(RegExp(r'\s'));
    if (space >= 0) out = out.substring(0, space);
    out = redact(out);
    for (final String secret in _secrets) {
      for (final form in <String>{secret, Uri.encodeQueryComponent(secret), Uri.encodeComponent(secret)}) {
        for (int k = form.length - 1; k > 0; k--) {
          if (out.endsWith(form.substring(0, k))) {
            out = out.substring(0, out.length - k);
            break;
          }
        }
      }
    }
    return out.trimRight();
  }
}

/// Marker appended to a diagnostic line cut at [RedactingLineSink.maxLineBytes].
const String truncatedLineMarker = ' [line truncated]';

/// Splits a byte stream (for example a worker's stderr) into complete UTF-8
/// lines, redacts each, and forwards it to the sink callback.
///
/// A trailing partial line is held until its newline arrives or [close] is
/// called, so a secret split across chunks is redacted as one line.
///
/// A line is held up to [maxLineBytes]. Beyond that its head is emitted
/// once, redacted with [Redactor.redactTruncated] and marked with
/// [truncatedLineMarker], and the rest of the line is dropped until its
/// newline, so a peer that never writes a newline cannot grow the buffer
/// without bound. The default is the worker protocol's frame cap
/// ([protocolMaxFrameBytes], KTD4): the same peer may send nothing larger as
/// one protocol record, so no legitimate diagnostic line exceeds it.
class RedactingLineSink {
  RedactingLineSink(this._redactor, this._sink, {this.maxLineBytes = protocolMaxFrameBytes})
    : assert(maxLineBytes > 0, 'maxLineBytes must be positive');

  final Redactor _redactor;
  final void Function(String line) _sink;
  final List<int> _pending = <int>[];

  /// Largest line held before it is cut.
  final int maxLineBytes;

  /// Whether the current line was cut and its rest is being dropped.
  bool _dropping = false;

  /// Adds raw bytes.
  void add(List<int> bytes) {
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0x0A) {
        _append(bytes, start, i);
        if (_dropping) {
          _dropping = false;
        } else {
          _emit();
        }
        start = i + 1;
      }
    }
    if (start < bytes.length) _append(bytes, start, bytes.length);
  }

  void _append(List<int> bytes, int start, int end) {
    if (_dropping) return;
    final int room = maxLineBytes - _pending.length;
    if (end - start <= room) {
      _pending.addAll(bytes.sublist(start, end));
      return;
    }
    _pending.addAll(bytes.sublist(start, start + room));
    String head = utf8.decode(_pending, allowMalformed: true);
    _pending.clear();
    _dropping = true;
    // A multi-byte character cut at the cap decodes as U+FFFD; drop it.
    if (head.endsWith('\uFFFD')) head = head.substring(0, head.length - 1);
    _sink('${_redactor.redactTruncated(head)}$truncatedLineMarker');
  }

  /// Flushes any trailing partial line.
  void close() {
    if (_pending.isNotEmpty) _emit();
    _dropping = false;
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
