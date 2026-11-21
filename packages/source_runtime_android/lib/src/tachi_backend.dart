// Tachi on Android (U11; KTD17, KTD18, KTD23): the shared protocol worker
// runs in the private `:source_runtime` service process, and the app drives
// it with the same `WorkerSupervisor` the desktop uses for its JVM worker.
//
// The service is the worker process: `TachiWorkerConnection` (Kotlin, bound
// through JNIgen) binds it, reports the PID it can kill, carries frames
// one-way over Binder (read-only descriptors for large replies), and reports
// the binder death as the process exit. The supervisor therefore keeps its
// tested behaviour unchanged: per-operation deadlines, cooperative cancel,
// kill by PID when a call does not settle, restart with a new generation,
// reload of every hosted package from its re-verified artifact, and fencing
// of the old generation. No platform channel carries anything.
//
// KTD16: this file depends on `source_runtime` only. The composition root
// builds `TachiRuntime` (tachi_plugin_loader) over [AndroidTachiBackend], so
// the catalog, trust gate and artifact cache are the desktop ones, with the
// artifact policy forced to APK (Android loads original DEX; a JVM JAR is not
// DEX input).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';
import 'package:source_runtime/source_runtime.dart';

import 'package:source_runtime_android/src/bindings/source_runtime_bindings.g.dart' as jni;

/// One worker lifetime in the `:source_runtime` service, seen from Dart.
abstract interface class TachiServiceWorker {
  /// PID of the service process (the target of [kill]).
  int get pid;

  /// Frames from the worker, without their newline, in order.
  Stream<String> get frames;

  /// Diagnostics lines from the worker process.
  Stream<String> get logs;

  /// Completes once when the process is gone (binder death).
  Future<int> get exitCode;

  /// Sends one frame; false when the worker is no longer running.
  bool send(String frame);

  /// Kills the service process by its PID.
  bool kill();
}

/// Starts workers in the service. The JNI implementation is
/// [JniTachiServiceChannel]; tests substitute a fake.
abstract interface class TachiServiceChannel {
  /// Binds the service and starts a worker with [arguments]; fails with the
  /// service's message when it cannot start.
  Future<TachiServiceWorker> start(List<String> arguments);
}

/// The Tachi backend registered on Android.
final class AndroidTachiBackend {
  AndroidTachiBackend({
    TachiServiceChannel? channel,
    this.arguments = const <String>[],
    Duration? handshakeDeadline,
  }) : _channel = channel, // ignore: prefer_initializing_formals
       handshakeDeadline = handshakeDeadline ?? androidTachiHandshakeDeadline;

  /// Ecosystem name of the provider composed over this backend.
  static const String ecosystem = 'tachi';

  /// Worker label in logs and supervisor events.
  static const String label = 'tachi-android';

  /// Worker arguments (the desktop command-line shape): `--limit NAME=VALUE`,
  /// and in debug builds `--replay NAME`, `--challenge-once PATH`,
  /// `--offline-browser`.
  final List<String> arguments;

  /// Bound on the handshake reply (KTD25: the one limit the worker cannot
  /// report, because the supervisor needs it before the worker speaks).
  final Duration handshakeDeadline;

  TachiServiceChannel? _channel;

  /// The spec the supervisor launches. Only [WorkerSpec.arguments] reach the
  /// service; there is no executable or environment on Android.
  WorkerSpec get spec => WorkerSpec(label: label, executable: 'android-service:source_runtime', arguments: arguments);

  /// Limits: everything adopted from the worker's handshake (its sizing
  /// rule), except the handshake deadline.
  AdoptWorkerLimits get limits => AdoptWorkerLimits(handshakeDeadline: handshakeDeadline);

  /// Launcher for [WorkerSupervisor] / [ConversionRuntimeScope].
  WorkerLauncher get launcher => (WorkerSpec spec) async {
    final TachiServiceChannel channel = _channel ??= JniTachiServiceChannel(startTimeout: handshakeDeadline);
    return ServiceWorkerProcess(await channel.start(spec.arguments));
  };

  /// A conversion-scoped owner of the Tachi worker.
  ConversionRuntimeScope scope({void Function(String line)? onLog, Redactor? redactor}) => ConversionRuntimeScope(
    workers: <WorkerKind, WorkerSpec>{WorkerKind.jvm: spec},
    limits: limits,
    launcher: launcher,
    onLog: onLog,
    redactor: redactor,
  );

  /// A supervisor of the Tachi worker (for callers that own it directly).
  WorkerSupervisor supervisor({void Function(String line)? onLog, Redactor? redactor}) =>
      WorkerSupervisor(spec: spec, limits: limits, launcher: launcher, onLog: onLog, redactor: redactor);
}

/// Handshake deadline from the U11 emulator benchmark (provisional until the
/// physical-device benchmark): `ceil(maxStartupToHandshakeMs × handshakeFactor)`
/// of `tools/tachi-source-runner/android/src/main/resources/tachi-worker-sizing.json`.
const Duration androidTachiHandshakeDeadline = Duration(milliseconds: 13860);

/// A [TachiServiceWorker] as the [WorkerProcess] the supervisor expects:
/// stdin frames go out one by one, stdout is the frames with newlines.
final class ServiceWorkerProcess implements WorkerProcess {
  ServiceWorkerProcess(this._worker) : stdin = IOSink(_FrameConsumer(_worker));

  final TachiServiceWorker _worker;

  @override
  final IOSink stdin;

  @override
  int get pid => _worker.pid;

  @override
  Stream<List<int>> get stdout => _worker.frames.map((String frame) => utf8.encode('$frame\n'));

  @override
  Stream<List<int>> get stderr => _worker.logs.map((String line) => utf8.encode('$line\n'));

  @override
  Future<int> get exitCode => _worker.exitCode;

  @override
  bool kill() => _worker.kill();
}

/// Splits stdin bytes into newline-terminated frames and sends each.
final class _FrameConsumer implements StreamConsumer<List<int>> {
  _FrameConsumer(this._worker);

  final TachiServiceWorker _worker;
  final BytesBuilder _pending = BytesBuilder(copy: false);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final List<int> chunk in stream) {
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 0x0A) continue;
        _pending.add(chunk.sublist(start, i));
        final String frame = utf8.decode(_pending.takeBytes());
        if (frame.isNotEmpty && !_worker.send(frame)) {
          throw const SocketException('Tachi worker is not running');
        }
        start = i + 1;
      }
      if (start < chunk.length) _pending.add(chunk.sublist(start));
    }
  }

  @override
  Future<void> close() async {}
}

/// [TachiServiceChannel] over the JNIgen-bound `TachiWorkerConnection`.
final class JniTachiServiceChannel implements TachiServiceChannel {
  JniTachiServiceChannel({this.startTimeout = androidTachiHandshakeDeadline});

  /// Bound on binding the service and starting the worker: the supervisor's
  /// handshake deadline only starts once the launcher returns.
  final Duration startTimeout;

  @override
  Future<TachiServiceWorker> start(List<String> arguments) => _JniServiceWorker().start(arguments, startTimeout);
}

final class _JniServiceWorker implements TachiServiceWorker {
  final StreamController<String> _frames = StreamController<String>();
  final StreamController<String> _logs = StreamController<String>();
  final Completer<int> _exit = Completer<int>();
  final Completer<TachiServiceWorker> _started = Completer<TachiServiceWorker>();
  late final jni.TachiWorkerConnection _connection;
  late final jni.TachiWorkerListener _listener;
  int _pid = 0;
  bool _released = false;

  Future<TachiServiceWorker> start(List<String> arguments, Duration timeout) {
    // The listener reaches this object weakly so the Java proxy does not keep
    // it (and its JNI wrappers) alive (KTD23).
    final target = WeakReference<_JniServiceWorker>(this);
    _listener = jni.TachiWorkerListener.implement(
      jni.$TachiWorkerListener(
        onStarted: (int pid, int sdkInt) => target.target?._onStarted(pid),
        onStarted$async: true,
        onStartFailed: (JString message) {
          final String text = message.toDartString(releaseOriginal: true);
          target.target?._onStartFailed(text);
        },
        onStartFailed$async: true,
        onFrame: (JString frame) {
          final String text = frame.toDartString(releaseOriginal: true);
          target.target?._frames.add(text);
        },
        onFrame$async: true,
        onLog: (JString line) {
          final String text = line.toDartString(releaseOriginal: true);
          target.target?._logs.add(text);
        },
        onLog$async: true,
        onExit: (int code) => target.target?._onExit(code),
        onExit$async: true,
      ),
    );
    final JObject context = androidApplicationContext;
    try {
      _connection = jni.TachiWorkerConnection(context, _listener);
    } finally {
      context.release();
    }
    final JString args = jsonEncode(arguments).toJString();
    try {
      _connection.start(args);
    } finally {
      args.release();
    }
    return _started.future.timeout(
      timeout,
      onTimeout: () {
        // Never leave a half-started worker behind: end its process and unbind.
        _connection.kill();
        _release();
        throw TimeoutException('Tachi worker did not start', timeout);
      },
    );
  }

  void _onStarted(int pid) {
    _pid = pid;
    if (!_started.isCompleted) _started.complete(this);
  }

  void _onStartFailed(String message) {
    if (!_started.isCompleted) _started.completeError(StateError('Tachi worker did not start: $message'));
  }

  void _onExit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
    if (!_started.isCompleted) _started.completeError(StateError('Tachi worker exited with $code before starting'));
    unawaited(_frames.close());
    unawaited(_logs.close());
    _release();
  }

  void _release() {
    if (_released) return;
    _released = true;
    _connection
      ..close()
      ..release();
    _listener.release();
  }

  @override
  int get pid => _pid;

  @override
  Stream<String> get frames => _frames.stream;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool send(String frame) {
    if (_released) return false;
    final JString text = frame.toJString();
    try {
      return _connection.send(text);
    } finally {
      text.release();
    }
  }

  @override
  bool kill() => !_released && _connection.kill();
}

/// Debug fixture access for integration tests: copies an asset directory of
/// the plugin's debug-only fixture folder (`fixtures/source_captures/tachi/`)
/// into the app cache and returns its path. Release builds carry no fixtures.
String copyFixtureAssetDirectory(String assetDir) {
  final JObject context = androidApplicationContext;
  final jni.FixtureAssets assets = jni.FixtureAssets.INSTANCE;
  final JString dir = assetDir.toJString();
  try {
    return assets.copyDirectory(context, dir).toDartString(releaseOriginal: true);
  } finally {
    dir.release();
    assets.release();
    context.release();
  }
}
