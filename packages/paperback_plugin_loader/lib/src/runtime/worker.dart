import 'dart:async';

import 'package:paperback_plugin_loader/src/runtime/quickjs_runtime.dart';
import 'package:paperback_plugin_loader/src/runtime/runtime_limits.dart';
import 'package:source_runtime/source_runtime.dart';

/// Hosts Paperback packages of one or more API families inside the worker.
///
/// U5 provides the runtime, promise bridge and protocol plumbing; the
/// versioned 0.8/0.9 adapters arrive in U6 and implement this seam. The
/// worker creates a fresh [SourceJsRuntime] per package and hands it over.
abstract interface class PaperbackPackageAdapter {
  /// API families advertised in the handshake, e.g. `paperback-0.8`.
  Set<String> get apiFamilies;

  /// Verifies and evaluates the staged artifact in [runtime] and enumerates
  /// its sources.
  Future<PackageLoadResponse> load(SourceJsRuntime runtime, PackageLoadRequest request, CancellationToken cancel);

  /// Serves a per-package operation other than load/unload.
  Future<ProtocolPayload> handle(
    SourceJsRuntime runtime,
    WorkerRequest<ProtocolPayload> request,
    CancellationToken cancel,
  );
}

/// The Paperback worker: speaks protocol v1 over `input`/`output` (KTD4) and
/// owns one QuickJS runtime per loaded package on this isolate (KTD2).
///
/// Cancellation: a `cancel` frame cancels the operation and requests the
/// runtime's interrupt. This isolate reads frames only between JS slices, so
/// JS that never yields is stopped by the operation deadline inside the
/// engine, and the supervisor's kill on cancel-grace expiry is the hard stop
/// (protocol v1, "Cancellation").
final class PaperbackSourceWorker {
  PaperbackSourceWorker({
    required this._input,
    required this._output,
    required this.limits,
    this.adapter,
    this.pid,
    this.workerVersion = '0.1.0',
    void Function(String line)? log,
    this.maxFrameBytes = protocolMaxFrameBytes,
  }) : _log = log ?? ((String _) {});

  final Stream<List<int>> _input;
  final StreamSink<List<int>> _output;
  final PaperbackRuntimeLimits limits;
  final PaperbackPackageAdapter? adapter;
  final int? pid;
  final String workerVersion;
  final int maxFrameBytes;
  final void Function(String line) _log;

  final Map<String, SourceJsRuntime> _packages = <String, SourceJsRuntime>{};
  final Map<String, _InFlight> _inFlight = <String, _InFlight>{};
  int _generation = 0;
  bool _shuttingDown = false;
  final Completer<void> _done = Completer<void>();

  /// Serves frames until `shutdown` or end of input.
  Future<void> run() async {
    final StreamSubscription<ProtocolFrame> sub = _input
        .transform(FrameDecoder(maxFrameBytes: maxFrameBytes))
        .listen(
          _onFrame,
          onError: (Object e) => _log('[paperback-worker] protocol error: $e'),
          onDone: () => unawaited(_finish()),
        );
    try {
      await _done.future;
    } finally {
      await sub.cancel();
    }
  }

  void _onFrame(ProtocolFrame frame) {
    switch (frame.type) {
      case FrameType.request:
        _onRequest(frame);
      case FrameType.cancel:
        final _InFlight? op = _inFlight[frame.id];
        if (op != null) {
          op.cancel.cancel('cancelled by supervisor');
          op.runtime?.requestInterrupt();
        }
      case FrameType.event || FrameType.reverseResponse:
        // No browser reverse requests are sent yet (KTD20 lands with U6/U8).
        _log('[paperback-worker] ignoring unexpected ${frame.type.wire} frame ${frame.id}');
      case FrameType.response || FrameType.reverseRequest:
        _log('[paperback-worker] protocol violation: ${frame.type.wire} sent to the worker');
    }
  }

  void _onRequest(ProtocolFrame frame) {
    final WorkerOperation? operation = WorkerOperation.fromWire(frame.op);
    if (operation == null) {
      _reply(frame, error: ProtocolViolationFailure('Unknown operation ${frame.op}').toWire());
      return;
    }
    final WorkerRequest<ProtocolPayload> request;
    try {
      request = WorkerRequest.fromWire(operation, frame.payload ?? const <String, Object?>{});
    } on FormatException catch (e) {
      _reply(frame, error: ProtocolViolationFailure('Malformed ${frame.op} payload: ${e.message}').toWire());
      return;
    }
    switch (request) {
      case HandshakeRequest():
        _generation = frame.generation;
        if (!request.protocolVersions.contains(protocolVersion)) {
          _reply(frame, error: const ProtocolViolationFailure('Worker speaks protocol $protocolVersion only').toWire());
          return;
        }
        final Map<String, Object?> ok = HandshakeResponse(
          protocolVersion: protocolVersion,
          worker: 'paperback',
          workerVersion: workerVersion,
          pid: pid,
          capabilities: WorkerCapabilities(apiFamilies: adapter?.apiFamilies ?? const <String>{}),
        ).toJson();
        // Readers ignore unknown fields; record the limits in effect (KTD25).
        ok['limits'] = limits.toJson();
        _reply(frame, ok: ok);
      case ShutdownRequest():
        _reply(frame, ok: const EmptyPayload().toJson());
        unawaited(_finish());
      default:
        unawaited(_servePackageOperation(frame, request));
    }
  }

  Future<void> _servePackageOperation(ProtocolFrame frame, WorkerRequest<ProtocolPayload> request) async {
    final String? packageId = frame.packageId;
    if (packageId == null) {
      _reply(frame, error: ProtocolViolationFailure('${frame.op} requires pkg').toWire());
      return;
    }
    final cancel = CancellationSource();
    final op = _InFlight(cancel, _packages[packageId]);
    _inFlight[frame.id] = op;
    try {
      final ProtocolPayload ok = await _dispatch(packageId, request, op);
      _reply(frame, ok: ok.toJson());
    } on PaperbackRuntimeException catch (e) {
      _reply(frame, error: e.failure.toWire());
    } on _WorkerFailure catch (e) {
      _reply(frame, error: e.failure.toWire());
    } on Object catch (e) {
      _log('[paperback-worker] ${frame.op} failed: $e');
      _reply(frame, error: SourceErrorFailure('$e').toWire());
    } finally {
      _inFlight.remove(frame.id);
    }
  }

  Future<ProtocolPayload> _dispatch(String packageId, WorkerRequest<ProtocolPayload> request, _InFlight op) async {
    final PaperbackPackageAdapter? adapter = this.adapter;
    switch (request) {
      case PackageLoadRequest():
        if (adapter == null) {
          throw const _WorkerFailure(UnsupportedApiFailure('This worker has no Paperback API adapter yet'));
        }
        _packages.remove(packageId)?.dispose();
        final runtime = SourceJsRuntime(limits: limits, name: packageId, log: _log);
        op.runtime = runtime;
        try {
          final PackageLoadResponse response = await adapter.load(runtime, request, op.cancel.token);
          _packages[packageId] = runtime;
          return response;
        } on Object {
          runtime.dispose();
          rethrow;
        }
      case PackageUnloadRequest():
        _packages.remove(packageId)?.dispose();
        return const EmptyPayload();
      default:
        if (adapter == null) {
          throw const _WorkerFailure(UnsupportedApiFailure('This worker has no Paperback API adapter yet'));
        }
        final SourceJsRuntime? runtime = _packages[packageId];
        if (runtime == null || runtime.isClosed) {
          _packages.remove(packageId);
          throw _WorkerFailure(RuntimeUnavailableFailure('Package $packageId is not loaded'));
        }
        op.runtime = runtime;
        return adapter.handle(runtime, request, op.cancel.token);
    }
  }

  void _reply(ProtocolFrame request, {Map<String, Object?>? ok, Map<String, Object?>? error}) {
    if (_shuttingDown && request.op != WorkerOperation.shutdown.wire) return;
    final frame = ProtocolFrame(
      type: FrameType.response,
      id: request.id,
      generation: _generation == 0 ? request.generation : _generation,
      ok: error == null ? (ok ?? const <String, Object?>{}) : null,
      error: error,
    );
    try {
      _output.add(encodeFrame(frame, maxFrameBytes: maxFrameBytes));
    } on ProtocolException catch (e) {
      // An oversized reply fails visibly as an error reply, never truncated.
      _output.add(
        encodeFrame(
          ProtocolFrame(
            type: FrameType.response,
            id: request.id,
            generation: frame.generation,
            error: SourceErrorFailure('Reply could not be encoded: ${e.message}').toWire(),
          ),
          maxFrameBytes: maxFrameBytes,
        ),
      );
    }
  }

  Future<void> _finish() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    for (final _InFlight op in _inFlight.values) {
      op.cancel.cancel('worker shutting down');
    }
    for (final SourceJsRuntime runtime in _packages.values) {
      runtime.dispose();
    }
    _packages.clear();
    try {
      await _output.close();
    } on Object catch (e) {
      _log('[paperback-worker] closing output failed: $e');
    }
    if (!_done.isCompleted) _done.complete();
  }
}

final class _InFlight {
  _InFlight(this.cancel, this.runtime);

  final CancellationSource cancel;
  SourceJsRuntime? runtime;
}

/// A protocol failure raised by the worker itself.
final class _WorkerFailure implements Exception {
  const _WorkerFailure(this.failure);

  final SourceFailure failure;
}
