import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_ios/src/ios_jvm_runtime.dart';
import 'package:source_runtime_ios/src/runtime_bindings.g.dart' as native;

typedef _StreamFn = Void Function(Int64 workerId, Int32 stream, Pointer<Uint8> data, Int64 length);

/// The shared Tachi worker running inside the app's single VM, presented to
/// [WorkerSupervisor] as a [WorkerProcess] (U9; KTD12, KTD23).
///
/// There is no OS process. The worker (`mangabackup.tachi.ios.IosWorkerHost`)
/// runs on a dispatcher-owned native thread; [stdin] bytes go to it through
/// `srt_worker_write`, and its frames and diagnostics come back through one
/// process-wide `NativeCallable.listener`, so neither side ever blocks on the
/// other and no platform channel is involved.
///
/// [kill] maps the supervisor's restart onto what the embedded VM allows:
/// it closes the channel and fires every armed deadline of this worker, so
/// rewritten code stops at its next back-edge and host waits end; the worker
/// loop then returns and [exitCode] completes. The VM is never destroyed and no
/// thread is terminated; the next generation is a new worker in the same VM.
final class InVmWorkerProcess implements WorkerProcess {
  InVmWorkerProcess._(this.workerId) {
    stdin = IOSink(_ChannelConsumer(this));
  }

  /// Dispatcher worker id (positive); also reported as [pid], which is not an
  /// OS process id.
  final int workerId;

  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();

  @override
  late final IOSink stdin;

  @override
  int get pid => workerId;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  bool get exited => _exit.isCompleted;

  @override
  bool kill() {
    if (exited) return false;
    return native.srt_worker_kill(workerId) == native.SRT_OK;
  }

  void _deliver(int stream, Uint8List? bytes, int length) {
    switch (stream) {
      case native.SRT_STREAM_STDOUT:
        if (!_stdout.isClosed && bytes != null) _stdout.add(bytes);
      case native.SRT_STREAM_STDERR:
        if (!_stderr.isClosed && bytes != null) _stderr.add(bytes);
      case native.SRT_STREAM_EXIT:
        unawaited(_stdout.close());
        unawaited(_stderr.close());
        if (!_exit.isCompleted) _exit.complete(length);
        _hub.remove(workerId);
    }
  }

  // ---------------------------------------------------------------------------
  // Process-wide channel hub.

  static final Map<int, InVmWorkerProcess> _hub = <int, InVmWorkerProcess>{};
  static NativeCallable<_StreamFn>? _callback;
  static int _nextId = 1;

  /// Workers whose run loop has not returned (native count).
  static int get liveWorkers => native.srt_worker_count();

  /// Operation deadlines currently armed in the dispatcher.
  static int get armedDeadlines => native.srt_armed_deadlines();

  /// Deadlines fired since start.
  static int get firedDeadlines => native.srt_fired_deadlines();

  static void _onStream(int workerId, int stream, Pointer<Uint8> data, int length) {
    Uint8List? bytes;
    if (data != nullptr) {
      bytes = Uint8List.fromList(data.asTypedList(length));
      native.srt_free(data.cast());
    }
    _hub[workerId]?._deliver(stream, bytes, length);
  }

  /// Starts a worker in [runtime] with IosWorkerHost [options].
  static InVmWorkerProcess start(IosJvmRuntime runtime, String options) {
    _callback ??= () {
      final c = NativeCallable<_StreamFn>.listener(_onStream);
      final int rc = native.srt_worker_set_callback(c.nativeFunction);
      if (rc != native.SRT_OK) {
        c.close();
        throw IosJvmRuntimeException('srt_worker_set_callback failed', rc);
      }
      return c;
    }();
    final process = InVmWorkerProcess._(_nextId++);
    _hub[process.workerId] = process;
    final int rc = using(
      (Arena arena) => native.srt_worker_start(process.workerId, options.toNativeUtf8(allocator: arena).cast()),
    );
    if (rc != native.SRT_OK) {
      _hub.remove(process.workerId);
      throw IosJvmRuntimeException('srt_worker_start failed', rc);
    }
    return process;
  }
}

/// Writes [IOSink] data into the worker's native input queue.
final class _ChannelConsumer implements StreamConsumer<List<int>> {
  _ChannelConsumer(this._process);

  final InVmWorkerProcess _process;

  void _write(List<int> chunk) {
    if (chunk.isEmpty) return;
    final int rc = using((Arena arena) {
      final Pointer<Uint8> buffer = arena<Uint8>(chunk.length);
      buffer.asTypedList(chunk.length).setAll(0, chunk);
      return native.srt_worker_write(_process.workerId, buffer, chunk.length);
    });
    if (rc != native.SRT_OK) throw StateError('in-VM worker ${_process.workerId} input is closed ($rc)');
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final List<int> chunk in stream) {
      _write(chunk);
    }
  }

  @override
  Future<void> close() async {
    native.srt_worker_close_input(_process.workerId);
  }
}

/// A [WorkerLauncher] that starts the Tachi worker inside [runtime]. [options]
/// builds IosWorkerHost's option lines for each generation (a fresh state
/// directory per generation, for example).
WorkerLauncher inVmWorkerLauncher(IosJvmRuntime runtime, String Function() options) =>
    (WorkerSpec spec) async => InVmWorkerProcess.start(runtime, options());
