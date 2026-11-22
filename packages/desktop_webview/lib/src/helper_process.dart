import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime/source_runtime.dart' show RedactingLineSink, Redactor;

/// Maximum encoded frame size in either direction (KTD4); the helper uses the
/// same bound.
const int helperMaxFrameBytes = 16 * 1024 * 1024;

/// Helper protocol version this client speaks.
const int helperProtocolVersion = 1;

/// Starts the helper process with [arguments]. Injected for tests.
typedef HelperLauncher = Future<Process> Function(String executable, List<String> arguments);

/// The helper's `ready` event.
@immutable
final class HelperInfo {
  const HelperInfo({
    required this.engine,
    required this.engineVersion,
    required this.helperVersion,
    required this.pid,
    required this.capabilities,
    required this.wipeRemoved,
    required this.wipeFailed,
  });

  factory HelperInfo.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> wipe = json['wipe'] as Map<String, Object?>? ?? const <String, Object?>{};
    return HelperInfo(
      engine: json['engine']! as String,
      engineVersion: json['engineVersion']! as String,
      helperVersion: json['helperVersion'] as String? ?? '',
      pid: json['pid'] as int? ?? 0,
      capabilities: HelperCapabilities.fromJson(json['capabilities']! as Map<String, Object?>),
      wipeRemoved: wipe['removed'] as int? ?? 0,
      wipeFailed: wipe['failed'] as int? ?? 0,
    );
  }

  /// `webview2`, `wkwebview` or `webkitgtk`.
  final String engine;
  final String engineVersion;
  final String helperVersion;
  final int pid;
  final HelperCapabilities capabilities;

  /// Stale data directories the start-up wipe removed / could not remove.
  final int wipeRemoved;
  final int wipeFailed;
}

/// What the helper's engine supports (reported, not assumed).
@immutable
final class HelperCapabilities {
  const HelperCapabilities({
    required this.requestObserve,
    required this.requestReplace,
    required this.statusCodes,
    required this.navigationFailures,
    required this.storage,
    required this.syncScriptInterface,
    required this.browser,
    this.record = false,
  });

  factory HelperCapabilities.fromJson(Map<String, Object?> json) => HelperCapabilities(
    requestObserve: json['requestObserve'] as String? ?? 'none',
    requestReplace: json['requestReplace'] as bool? ?? false,
    statusCodes: json['statusCodes'] as bool? ?? false,
    navigationFailures: json['navigationFailures'] as bool? ?? false,
    storage: json['storage'] as String? ?? '',
    syncScriptInterface: json['syncScriptInterface'] as bool? ?? false,
    record: json['record'] as bool? ?? false,
    browser: switch (json['browser']) {
      final Map<String, Object?> b => BrowserCapabilities.fromJson(b),
      _ => BrowserCapabilities.unreported(),
    },
  );

  /// `all`, `main-frame` or `none`.
  final String requestObserve;
  final bool requestReplace;
  final bool statusCodes;
  final bool navigationFailures;
  final String storage;
  final bool syncScriptInterface;

  /// Whether `--record` can report every response with its body (WebView2).
  final bool record;

  /// The protocol 1.2 features every session of this helper has, each
  /// missing one with the engine's reason (the helper's `browser` field).
  final BrowserCapabilities browser;
}

/// Reply to one helper request.
sealed class HelperReply {
  const HelperReply();
}

final class HelperOk extends HelperReply {
  const HelperOk(this.value);

  final Map<String, Object?> value;
}

final class HelperError extends HelperReply {
  const HelperError(this.code, this.message, {this.operation, this.url});

  /// `capability-unavailable`, `navigation-failed`, `interaction-required`,
  /// `script-error`, `session-closed`, `cancelled`, `invalid`.
  final String code;
  final String message;
  final String? operation;
  final String? url;

  @override
  String toString() => 'HelperError($code: $message)';
}

/// The helper exited (or broke the protocol) before replying.
final class HelperGone extends HelperReply {
  const HelperGone(this.reason);

  final String reason;
}

/// Outcome of starting the helper.
sealed class HelperStart {
  const HelperStart();
}

final class HelperStarted extends HelperStart {
  const HelperStarted(this.process);

  final HelperProcess process;
}

/// The helper reported why it cannot run: `runtime-missing` (no WebView
/// runtime installed), `no-display`, `init-failed`, `invalid-arguments`.
final class HelperFatal extends HelperStart {
  const HelperFatal(this.code, this.message);

  final String code;
  final String message;
}

/// The helper could not be launched, or did not become ready in time.
final class HelperLaunchFailed extends HelperStart {
  const HelperLaunchFailed(this.message);

  final String message;
}

/// One running helper process speaking the bounded JSON-lines protocol.
class HelperProcess {
  HelperProcess._(this._process, this.info, this._lines, this._onLog) {
    // A dead helper surfaces through [gone]; broken-pipe errors on stdin
    // must not become unhandled.
    unawaited(_process.stdin.done.then<void>((_) {}, onError: (Object _) {}));
  }

  final Process _process;
  final HelperInfo info;
  final StreamIterator<Map<String, Object?>> _lines;
  final void Function(String line)? _onLog;
  final Map<int, Completer<HelperReply>> _pending = <int, Completer<HelperReply>>{};
  final StreamController<Map<String, Object?>> _events = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final Completer<String> _gone = Completer<String>();
  int _nextId = 0;

  /// Launches the helper and waits up to [startupTimeout] for its `ready`
  /// (or `fatal`) event. [startupTimeout] has no default: it is a KTD25 limit.
  static Future<HelperStart> start({
    required String executable,
    required List<String> arguments,
    required Duration startupTimeout,
    HelperLauncher? launcher,
    void Function(String line)? onLog,
  }) async {
    final Process process;
    try {
      process = await (launcher ?? _defaultLaunch)(executable, arguments);
    } on ProcessException catch (e) {
      return HelperLaunchFailed('cannot launch $executable: ${e.message}');
    }
    // stderr lines are bounded like protocol frames (L2): a helper that
    // never writes a newline cannot grow this buffer past the sink's default
    // cap, the protocol frame cap (= [helperMaxFrameBytes]). A longer line is
    // cut, its head kept back to the last whitespace, and marked. The
    // caller's log redacts every line.
    final stderrLines = RedactingLineSink(Redactor(), (String l) => onLog?.call(l));
    process.stderr.listen(stderrLines.add, onDone: stderrLines.close, onError: (Object _) {});
    final lines = StreamIterator<Map<String, Object?>>(_frames(process.stdout));
    final Future<bool> first = lines.moveNext().timeout(startupTimeout, onTimeout: () => false);
    bool got;
    try {
      got = await first;
    } on FormatException catch (e) {
      process.kill();
      return HelperLaunchFailed('helper broke the protocol during start-up: ${e.message}');
    }
    if (!got) {
      process.kill();
      return HelperLaunchFailed('helper did not become ready within $startupTimeout');
    }
    final Map<String, Object?> frame = lines.current;
    switch (frame['ev']) {
      case 'ready':
        if (frame['protocol'] != helperProtocolVersion) {
          process.kill();
          return HelperLaunchFailed('helper speaks protocol ${frame['protocol']}, expected $helperProtocolVersion');
        }
        final helper = HelperProcess._(process, HelperInfo.fromJson(frame), lines, onLog);
        helper._pump();
        return HelperStarted(helper);
      case 'fatal':
        await process.exitCode.timeout(startupTimeout, onTimeout: () => -1);
        return HelperFatal(frame['code'] as String? ?? 'init-failed', frame['message'] as String? ?? '');
      default:
        process.kill();
        return HelperLaunchFailed('unexpected first frame from helper: $frame');
    }
  }

  static Future<Process> _defaultLaunch(String executable, List<String> arguments) =>
      Process.start(executable, arguments);

  /// Splits stdout into bounded JSON frames; an oversized or malformed frame
  /// is a protocol error.
  static Stream<Map<String, Object?>> _frames(Stream<List<int>> bytes) async* {
    final buffer = BytesBuilder(copy: false);
    await for (final List<int> chunk in bytes) {
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 0x0A) continue;
        buffer.add(chunk.sublist(start, i));
        start = i + 1;
        final List<int> line = buffer.takeBytes();
        if (line.isEmpty) continue;
        final Object? decoded = jsonDecode(utf8.decode(line));
        if (decoded is! Map<String, Object?>) throw const FormatException('frame is not a JSON object');
        yield decoded;
      }
      buffer.add(chunk.sublist(start));
      if (buffer.length > helperMaxFrameBytes) {
        throw const FormatException('frame exceeds $helperMaxFrameBytes bytes');
      }
    }
  }

  void _pump() {
    unawaited(() async {
      var reason = 'helper closed its output';
      try {
        while (await _lines.moveNext()) {
          _dispatch(_lines.current);
        }
      } on FormatException catch (e) {
        reason = 'helper broke the protocol: ${e.message}';
        _process.kill();
      }
      final int code = await _process.exitCode;
      _finish('$reason (exit code $code)');
    }());
  }

  void _dispatch(Map<String, Object?> frame) {
    final Object? id = frame['id'];
    if (id is int) {
      final Completer<HelperReply>? c = _pending.remove(id);
      if (c == null) return; // Late reply for a request nobody waits for.
      final Object? ok = frame['ok'];
      if (ok is Map<String, Object?>) {
        c.complete(HelperOk(ok));
      } else {
        final Map<String, Object?> err = frame['err'] as Map<String, Object?>? ?? const <String, Object?>{};
        c.complete(
          HelperError(
            err['code'] as String? ?? 'invalid',
            err['message'] as String? ?? '',
            operation: err['operation'] as String?,
            url: err['url'] as String?,
          ),
        );
      }
      return;
    }
    if (frame['ev'] == 'protocolError') _onLog?.call('[desktop_webview] helper protocol error: ${frame['message']}');
    _events.add(frame);
  }

  void _finish(String reason) {
    if (_gone.isCompleted) return;
    _gone.complete(reason);
    final List<Completer<HelperReply>> waiting = _pending.values.toList();
    _pending.clear();
    for (final c in waiting) {
      c.complete(HelperGone(reason));
    }
    unawaited(_events.close());
  }

  /// Helper events (`message`, `request`, `interactionEnded`, ...).
  Stream<Map<String, Object?>> get events => _events.stream;

  /// Completes with the reason once the helper has exited.
  Future<String> get gone => _gone.future;

  bool get isAlive => !_gone.isCompleted;

  /// Sends one request. Never throws: failures are [HelperError] or
  /// [HelperGone].
  Future<HelperReply> request(String op, [Map<String, Object?> params = const <String, Object?>{}]) {
    if (_gone.isCompleted) return Future<HelperReply>.value(const HelperGone('helper is not running'));
    final int id = ++_nextId;
    final String line = jsonEncode(<String, Object?>{...params, 'id': id, 'op': op});
    if (utf8.encode(line).length > helperMaxFrameBytes) {
      return Future<HelperReply>.value(HelperError('invalid', '$op request exceeds $helperMaxFrameBytes bytes'));
    }
    final c = Completer<HelperReply>();
    _pending[id] = c;
    try {
      _process.stdin.writeln(line);
    } on Object catch (e) {
      _pending.remove(id);
      return Future<HelperReply>.value(HelperGone('cannot write to helper: $e'));
    }
    return c.future;
  }

  /// Asks the helper to close every session and exit; kills it if it has not
  /// exited within [grace] (a KTD25 bound supplied by the caller).
  Future<void> shutdown({required Duration grace}) async {
    if (!isAlive) return;
    unawaited(request('shutdown'));
    try {
      await _process.stdin.close();
    } on Object {
      // Already closed.
    }
    final bool exited = await gone.then((_) => true).timeout(grace, onTimeout: () => false);
    if (!exited) {
      _process.kill();
      await gone;
    }
  }

  /// Terminates the helper abruptly.
  Future<void> kill() async {
    _process.kill();
    await gone;
  }
}
