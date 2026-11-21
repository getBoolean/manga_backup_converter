/// Worker protocol version 1.1 (KTD4): UTF-8 JSON lines on stdin/stdout.
///
/// Every frame is one JSON object followed by `\n`:
///
/// ```json
/// {"v":1,"t":"req","id":"3-7","gen":3,"op":"search","pkg":"eu.kanade.x","payload":{...}}
/// ```
///
/// | `t` | Direction | Fields |
/// |---|---|---|
/// | `req` | supervisor → worker | `id`, `gen`, `op`, `pkg` (optional), `payload` |
/// | `res` | worker → supervisor | `id` of the request, `gen`, `ok` *or* `err` (`code`, `message`, `operation`) |
/// | `cancel` | supervisor → worker | `id` of the request to cancel cooperatively |
/// | `rreq` | worker → supervisor | `id` (worker-chosen), `gen`, `op` (`host.browser.*`), `of` (originating request id), `payload` |
/// | `rres` | supervisor → worker | `id` of the reverse request, `gen`, `ok` *or* `err` |
/// | `event` | supervisor → worker | `op` (for example `host.browser.message`), `gen`, `payload` |
///
/// Operations: `handshake`, `artifact.prepare`, `package.load`,
/// `package.unload`, `settings.update`, `search`, `details`, `dispose`,
/// `shutdown`. Their `payload` and `ok` shapes are the typed classes in
/// `protocol_payloads.dart` ([WorkerRequest] and [HostBrowserRequest]
/// subclasses), re-exported here; `doc/protocol-v1.md` documents them for
/// worker authors. Logs go to stderr only; any other stdout text is a
/// violation. Frames larger than the limit fail visibly; they are never
/// truncated.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:source_runtime/src/backends/protocol_payloads.dart';

export 'package:source_runtime/src/backends/protocol_payloads.dart';

/// Protocol major version spoken by this supervisor: the envelope's `v`.
const int protocolVersion = 1;

/// Highest minor version of [protocolVersion] this supervisor speaks,
/// negotiated in the handshake (`protocolMinor`). Minor versions only add
/// optional fields, so the envelope's `v` stays [protocolVersion].
const int protocolMinorVersion = 3;

/// Maximum encoded frame size, newline excluded (KTD4: 16 MiB). This is a
/// protocol rule, not a benchmarked limit; tests may pass a smaller value.
const int protocolMaxFrameBytes = 16 * 1024 * 1024;

/// Frame kinds.
enum FrameType {
  request('req'),
  response('res'),
  cancel('cancel'),
  reverseRequest('rreq'),
  reverseResponse('rres'),
  event('event');

  const FrameType(this.wire);

  final String wire;

  static FrameType? fromWire(Object? wire) {
    for (final FrameType t in values) {
      if (t.wire == wire) return t;
    }
    return null;
  }
}

/// Categories of protocol violation. Each fails the worker session visibly.
enum ProtocolViolationKind {
  malformed,
  oversized,
  unknownVersion,
  unexpectedText,
  wrongGeneration,
  unknownReply,
  orphanedReverseRequest,
  unexpectedFrame,
}

/// A protocol violation, raised by the codec or the supervisor.
final class ProtocolException implements Exception {
  const ProtocolException(this.kind, this.message);

  final ProtocolViolationKind kind;
  final String message;

  @override
  String toString() => 'ProtocolException(${kind.name}): $message';
}

/// One decoded frame.
final class ProtocolFrame {
  const ProtocolFrame({
    required this.type,
    required this.id,
    required this.generation,
    this.op,
    this.packageId,
    this.originId,
    this.payload,
    this.ok,
    this.error,
  });

  /// Validates and decodes a frame object.
  factory ProtocolFrame.fromJson(Map<String, Object?> json) {
    final Object? version = json['v'];
    if (version != protocolVersion) {
      throw ProtocolException(ProtocolViolationKind.unknownVersion, 'Unsupported protocol version $version');
    }
    final FrameType? type = FrameType.fromWire(json['t']);
    final Object? id = json['id'];
    final Object? gen = json['gen'];
    if (type == null || id is! String || gen is! int) {
      throw const ProtocolException(ProtocolViolationKind.malformed, 'Frame is missing t, id or gen');
    }
    final Object? payload = json['payload'];
    final Object? ok = json['ok'];
    final Object? error = json['err'];
    if ((payload != null && payload is! Map) || (ok != null && ok is! Map) || (error != null && error is! Map)) {
      throw const ProtocolException(ProtocolViolationKind.malformed, 'payload, ok and err must be objects');
    }
    return ProtocolFrame(
      type: type,
      id: id,
      generation: gen,
      op: json['op'] as String?,
      packageId: json['pkg'] as String?,
      originId: json['of'] as String?,
      payload: (payload as Map<Object?, Object?>?)?.cast<String, Object?>(),
      ok: (ok as Map<Object?, Object?>?)?.cast<String, Object?>(),
      error: (error as Map<Object?, Object?>?)?.cast<String, Object?>(),
    );
  }

  final FrameType type;
  final String id;
  final int generation;
  final String? op;
  final String? packageId;
  final String? originId;
  final Map<String, Object?>? payload;
  final Map<String, Object?>? ok;
  final Map<String, Object?>? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': protocolVersion,
    't': type.wire,
    'id': id,
    'gen': generation,
    'op': ?op,
    'pkg': ?packageId,
    'of': ?originId,
    'payload': ?payload,
    'ok': ?ok,
    'err': ?error,
  };
}

/// Encodes [frame] as one line, failing visibly if it exceeds [maxFrameBytes].
Uint8List encodeFrame(ProtocolFrame frame, {int maxFrameBytes = protocolMaxFrameBytes}) {
  final Uint8List body = utf8.encode(jsonEncode(frame.toJson()));
  if (body.length > maxFrameBytes) {
    throw ProtocolException(
      ProtocolViolationKind.oversized,
      'Frame of ${body.length} bytes exceeds the $maxFrameBytes-byte limit',
    );
  }
  return Uint8List(body.length + 1)
    ..setRange(0, body.length, body)
    ..[body.length] = 0x0A;
}

/// Splits a byte stream into frames.
///
/// Splits on the newline byte before decoding UTF-8, so a multi-byte
/// character split across reads is reassembled; several frames in one read
/// are all emitted. The limit is enforced while buffering. Violations are
/// emitted as [ProtocolException] stream errors.
final class FrameDecoder extends StreamTransformerBase<List<int>, ProtocolFrame> {
  const FrameDecoder({this.maxFrameBytes = protocolMaxFrameBytes});

  final int maxFrameBytes;

  @override
  Stream<ProtocolFrame> bind(Stream<List<int>> stream) {
    final buffer = BytesBuilder(copy: false);
    var discarding = false;
    return stream.transform(
      StreamTransformer<List<int>, ProtocolFrame>.fromHandlers(
        handleData: (List<int> chunk, EventSink<ProtocolFrame> sink) {
          var start = 0;
          for (var i = 0; i < chunk.length; i++) {
            if (chunk[i] != 0x0A) continue;
            if (!discarding) {
              buffer.add(chunk.sublist(start, i));
              _emitLine(buffer.takeBytes(), sink);
            } else {
              buffer.clear();
            }
            discarding = false;
            start = i + 1;
          }
          if (start < chunk.length && !discarding) {
            buffer.add(chunk.sublist(start));
            if (buffer.length > maxFrameBytes) {
              buffer.clear();
              discarding = true;
              sink.addError(
                ProtocolException(ProtocolViolationKind.oversized, 'Frame exceeds the $maxFrameBytes-byte limit'),
              );
            }
          }
        },
        handleDone: (EventSink<ProtocolFrame> sink) {
          if (buffer.isNotEmpty && !discarding) {
            sink.addError(
              const ProtocolException(ProtocolViolationKind.malformed, 'Stream ended inside an unterminated frame'),
            );
          }
          sink.close();
        },
      ),
    );
  }

  void _emitLine(Uint8List line, EventSink<ProtocolFrame> sink) {
    int length = line.length;
    if (length > 0 && line[length - 1] == 0x0D) length--; // tolerate CRLF
    if (length > maxFrameBytes) {
      sink.addError(ProtocolException(ProtocolViolationKind.oversized, 'Frame exceeds the $maxFrameBytes-byte limit'));
      return;
    }
    final String text;
    try {
      text = utf8.decode(Uint8List.sublistView(line, 0, length));
    } on FormatException {
      sink.addError(const ProtocolException(ProtocolViolationKind.malformed, 'Frame is not valid UTF-8'));
      return;
    }
    if (!text.startsWith('{')) {
      final preview = text.length > 80 ? '${text.substring(0, 80)}…' : text;
      sink.addError(ProtocolException(ProtocolViolationKind.unexpectedText, 'Unexpected stdout text: "$preview"'));
      return;
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      sink.addError(ProtocolException(ProtocolViolationKind.malformed, 'Frame is not valid JSON: ${e.message}'));
      return;
    }
    if (json is! Map<String, Object?>) {
      sink.addError(const ProtocolException(ProtocolViolationKind.malformed, 'Frame is not a JSON object'));
      return;
    }
    try {
      sink.add(ProtocolFrame.fromJson(json));
    } on ProtocolException catch (e) {
      sink.addError(e);
    }
  }
}
