import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';

import 'package:source_runtime_android/src/bindings/source_runtime_bindings.g.dart';

/// Lifecycle notification from the `:source_runtime` service.
sealed class SourceRuntimeEvent {
  const SourceRuntimeEvent(this.generation);

  /// Bind generation the event belongs to.
  final int generation;
}

/// A bind completed; [pid] is the service process the client may kill.
final class SourceRuntimeBound extends SourceRuntimeEvent {
  const SourceRuntimeBound(super.generation, this.pid, this.sdkInt);

  final int pid;
  final int sdkInt;

  @override
  String toString() => 'SourceRuntimeBound(generation: $generation, pid: $pid, sdk: $sdkInt)';
}

/// A bind failed before the service connected.
final class SourceRuntimeBindFailed extends SourceRuntimeEvent {
  const SourceRuntimeBindFailed(super.generation, this.message);

  final String message;
}

/// The service process of [generation] died (binder death notification).
final class SourceRuntimeDied extends SourceRuntimeEvent {
  const SourceRuntimeDied(super.generation, this.pid);

  final int pid;

  @override
  String toString() => 'SourceRuntimeDied(generation: $generation, pid: $pid)';
}

/// A call failed inside the service, or could not be delivered.
final class SourceRuntimeCallException implements Exception {
  const SourceRuntimeCallException(this.op, this.payload);

  final String op;

  /// Error payload from the service (JSON) or the client (a short reason).
  final String payload;

  @override
  String toString() => 'SourceRuntimeCallException($op): $payload';
}

/// A call's service generation died before it replied.
final class SourceRuntimeDiedException implements Exception {
  const SourceRuntimeDiedException(this.op, this.generation, this.pid);

  final String op;
  final int generation;
  final int pid;

  @override
  String toString() => 'SourceRuntimeDiedException($op, generation: $generation, pid: $pid)';
}

/// Dart side of the Android source runtime boundary (KTD18, KTD23).
///
/// Every method here is a short synchronous JNIgen call that returns at once.
/// Service replies and death notifications arrive through a Java listener
/// whose methods are all registered as asynchronous listeners, so the Java
/// thread that delivers them never waits for this isolate.
///
/// Each [bind] opens a new generation. A death notification fails every call
/// still pending on its generation, and replies that arrive for an older
/// generation are dropped (fenced).
final class AndroidSourceRuntime {
  /// Creates the client facade for the application context.
  factory AndroidSourceRuntime() {
    final JObject context = androidApplicationContext;
    // The listener closures hold the runtime weakly so the Java proxy does
    // not keep the Dart object (and its JNI wrappers) alive (KTD23).
    final target = _ListenerTarget();
    final listener = SourceRuntimeListener.implement(
      $SourceRuntimeListener(
        onBound: target.onBound,
        onBound$async: true,
        onBindFailed: target.onBindFailed,
        onBindFailed$async: true,
        onReply: target.onReply,
        onReply$async: true,
        onDeath: target.onDeath,
        onDeath$async: true,
      ),
    );
    final client = SourceRuntimeClient(context, listener);
    final runtime = AndroidSourceRuntime._(context, client, listener);
    target.runtime = WeakReference<AndroidSourceRuntime>(runtime);
    return runtime;
  }
  AndroidSourceRuntime._(this._context, this._client, this._listener);

  final JObject _context;
  final SourceRuntimeClient _client;
  final SourceRuntimeListener _listener;
  final StreamController<SourceRuntimeEvent> _events = StreamController<SourceRuntimeEvent>.broadcast();
  final Map<int, _PendingCall> _pending = <int, _PendingCall>{};
  final Map<int, Completer<SourceRuntimeBound>> _binds = <int, Completer<SourceRuntimeBound>>{};
  AppWebViewProbe? _appWebView;
  int _generation = 0;
  int _pid = 0;
  bool _disposed = false;

  /// Lifecycle notifications, in arrival order.
  Stream<SourceRuntimeEvent> get events => _events.stream;

  /// Generation of the most recent bind, or 0.
  int get generation => _generation;

  /// PID reported by the current generation at bind time, or 0 when unbound.
  int get pid => _pid;

  /// Binds a new generation; completes when the service reports its PID.
  Future<SourceRuntimeBound> bind() {
    _checkLive();
    _pid = 0;
    final int generation = _client.bind();
    _generation = generation;
    return (_binds[generation] = Completer<SourceRuntimeBound>()).future;
  }

  /// Runs [op] in the service and completes with its JSON reply payload.
  ///
  /// Throws [SourceRuntimeCallException] when the service reports failure and
  /// [SourceRuntimeDiedException] when the generation dies first.
  Future<String> call(String op, [String argsJson = '{}']) {
    _checkLive();
    final JString jOp = op.toJString();
    final JString jArgs = argsJson.toJString();
    try {
      // Register before dispatching: the reply cannot overtake this frame
      // (listener callbacks are queued on this isolate), but keep it explicit.
      final int generation = _generation;
      final int callId = _client.dispatch(jOp, jArgs);
      final completer = Completer<String>();
      _pending[callId] = _PendingCall(op, generation, completer);
      return completer.future;
    } finally {
      jOp.release();
      jArgs.release();
    }
  }

  /// Kills the current generation's service process by its bind-time PID.
  /// Death is observed later as a [SourceRuntimeDied] event.
  bool kill() {
    _checkLive();
    return _client.kill();
  }

  /// Unbinds without killing the process. Pending calls are failed.
  void unbind() {
    _checkLive();
    _client.unbind();
    _failPending(_generation, 0);
    _pid = 0;
  }

  /// Directory holding staged artifacts.
  String get stagingDirectory => _withStaging((ArtifactStaging s) => s.stagingDirectory(_context));

  /// Stages the debug asset [assetName] read-only; fails on a digest mismatch.
  String stageAsset(String assetName, String sha256) => _withStaging((ArtifactStaging s) {
    final JString name = assetName.toJString();
    final JString digest = sha256.toJString();
    try {
      return s.stageAsset(_context, name, digest);
    } finally {
      name.release();
      digest.release();
    }
  });

  /// Stages [bytes] read-only as [name] without a digest check.
  String stageBytes(String name, Uint8List bytes) => _withStaging((ArtifactStaging s) {
    final JString jName = name.toJString();
    final array = JByteArray(bytes.length)..setRange(0, bytes.length, bytes);
    try {
      return s.stageBytes(_context, jName, array);
    } finally {
      jName.release();
      array.release();
    }
  });

  /// Creates a WebView in the app process and reads a JavaScript result.
  Future<String> probeAppWebView() => _probe((AppWebViewProbe p, ProbeListener l) => p.probe(l));

  /// Destroys the app-process WebViews created by [probeAppWebView].
  Future<String> destroyAppWebViews() => _probe((AppWebViewProbe p, ProbeListener l) => p.destroyAll(l));

  /// This process's JNI global reference table after a Java GC:
  /// `{"total": n, "classes": {"<class>": count}}`, or `{"total": -1}` when
  /// the runtime does not expose it.
  static Map<String, Object?> jniGlobalReferenceSummary() {
    final RuntimeDiagnostics diagnostics = RuntimeDiagnostics.INSTANCE;
    try {
      final String json = diagnostics.jniGlobalReferenceSummary().toDartString(releaseOriginal: true);
      return jsonDecode(json) as Map<String, Object?>;
    } finally {
      diagnostics.release();
    }
  }

  /// Unbinds and releases every JNI reference this object owns.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _client.dispose();
    _failPending(_generation, 0);
    for (final Completer<SourceRuntimeBound> c in _binds.values) {
      if (!c.isCompleted) c.completeError(StateError('disposed'));
    }
    _binds.clear();
    _client.release();
    _listener.release();
    _appWebView?.release();
    _appWebView = null;
    _context.release();
    unawaited(_events.close());
  }

  void _onBound(int generation, int pid, int sdkInt) {
    final event = SourceRuntimeBound(generation, pid, sdkInt);
    if (generation == _generation) _pid = pid;
    _binds.remove(generation)?.complete(event);
    _emit(event);
  }

  void _onBindFailed(int generation, String message) {
    final event = SourceRuntimeBindFailed(generation, message);
    _binds.remove(generation)?.completeError(StateError('bind failed: $message'));
    _emit(event);
  }

  void _onReply(int callId, int generation, bool ok, String payload) {
    final _PendingCall? call = _pending[callId];
    // Fence: a reply only completes the call made on the same generation.
    if (call == null || call.generation != generation) return;
    _pending.remove(callId);
    if (ok) {
      call.completer.complete(payload);
    } else {
      call.completer.completeError(SourceRuntimeCallException(call.op, payload));
    }
  }

  void _onDeath(int generation, int pid) {
    if (generation == _generation) _pid = 0;
    _failPending(generation, pid);
    _emit(SourceRuntimeDied(generation, pid));
  }

  void _failPending(int generation, int pid) {
    final dead = <int>[
      for (final MapEntry<int, _PendingCall> e in _pending.entries)
        if (e.value.generation == generation) e.key,
    ];
    for (final id in dead) {
      final _PendingCall call = _pending.remove(id)!;
      call.completer.completeError(SourceRuntimeDiedException(call.op, generation, pid));
    }
  }

  void _emit(SourceRuntimeEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  String _withStaging(JString Function(ArtifactStaging s) body) {
    _checkLive();
    final ArtifactStaging staging = ArtifactStaging.INSTANCE;
    try {
      return body(staging).toDartString(releaseOriginal: true);
    } finally {
      staging.release();
    }
  }

  Future<String> _probe(void Function(AppWebViewProbe probe, ProbeListener listener) start) {
    _checkLive();
    final AppWebViewProbe probe = _appWebView ??= AppWebViewProbe(_context);
    final completer = Completer<String>();
    late final ProbeListener listener;
    listener = ProbeListener.implement(
      $ProbeListener(
        onResult: (bool ok, JString payload) {
          final String text = payload.toDartString(releaseOriginal: true);
          listener.release();
          if (ok) {
            completer.complete(text);
          } else {
            completer.completeError(SourceRuntimeCallException('appWebView', text));
          }
        },
        onResult$async: true,
      ),
    );
    start(probe, listener);
    return completer.future;
  }

  void _checkLive() {
    if (_disposed) throw StateError('AndroidSourceRuntime is disposed');
  }
}

final class _PendingCall {
  _PendingCall(this.op, this.generation, this.completer);

  final String op;
  final int generation;
  final Completer<String> completer;
}

/// Routes listener callbacks to the runtime through a weak reference.
final class _ListenerTarget {
  WeakReference<AndroidSourceRuntime>? runtime;

  void onBound(int generation, int pid, int sdkInt) => runtime?.target?._onBound(generation, pid, sdkInt);

  void onBindFailed(int generation, JString message) {
    final String text = message.toDartString(releaseOriginal: true);
    runtime?.target?._onBindFailed(generation, text);
  }

  void onReply(int callId, int generation, bool ok, JString payload) {
    final String text = payload.toDartString(releaseOriginal: true);
    runtime?.target?._onReply(callId, generation, ok, text);
  }

  void onDeath(int generation, int pid) => runtime?.target?._onDeath(generation, pid);
}
