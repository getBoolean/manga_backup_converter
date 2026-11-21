import 'dart:async';

import 'package:paperback_plugin_loader/src/host/browser.dart';
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

/// Highest minor version of protocol 1 this worker implements: 1.1 adds
/// string-set settings and source scopes (`SettingsPayload.sources`), which
/// this worker passes to its adapter, and handshake `limits`. Kept local so a
/// newer `source_runtime` cannot make the worker claim a minor it does not
/// implement.
const int paperbackProtocolMinor = 1;

/// The limits this worker reports in its handshake (protocol 1.1, KTD25):
/// the QuickJS limits as runtime-specific fields, plus the standard limit
/// names the benchmark backs.
///
/// `operationDeadlineMs` is the deadline a supervisor should enforce: the
/// engine's operation deadline plus [deadlineHeadroom], the measured time an
/// operation can still take after the engine deadline fires (interrupt
/// overshoot, then converting and encoding the reply). Reporting the engine
/// deadline itself would let a supervisor that adopts it time out, and kill,
/// a worker that is already stopping the operation. The engine deadline
/// stays in `fields` as `operationDeadlineMicros`, with
/// `deadlineHeadroomMicros`.
///
/// `poolSize`, `cancelGraceMs`, `interactionTimeoutMs` and `shutdownGraceMs`
/// are not measured by the QuickJS benchmark, so they are left out rather
/// than invented.
WorkerReportedLimits reportedLimits(PaperbackRuntimeLimits limits, {Duration deadlineHeadroom = Duration.zero}) =>
    WorkerReportedLimits(
      operationDeadline: Duration(
        milliseconds: (limits.operationDeadline.inMicroseconds + deadlineHeadroom.inMicroseconds + 999) ~/ 1000,
      ),
      fields: <String, Object?>{...limits.toJson(), 'deadlineHeadroomMicros': deadlineHeadroom.inMicroseconds},
    );

/// The Paperback worker: speaks protocol 1.1 over `input`/`output` (KTD4) and
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
    this.deadlineHeadroom = Duration.zero,
    PaperbackPackageAdapter? adapter,
    PaperbackPackageAdapter Function(PaperbackBrowserChannel browser)? adapterFactory,
    this.browserEnabled = false,
    this.onShutdown,
    this.pid,
    this.workerVersion = '0.1.0',
    void Function(String line)? log,
    this.maxFrameBytes = protocolMaxFrameBytes,
    this.onRuntimeCreated,
  }) : _log = log ?? ((String _) {}) {
    this.adapter = adapter ?? adapterFactory?.call(_browser);
  }

  final Stream<List<int>> _input;
  final StreamSink<List<int>> _output;
  final PaperbackRuntimeLimits limits;

  /// Added to the engine deadline in the handshake's `operationDeadlineMs`
  /// (see [reportedLimits]); from the sizing rule.
  final Duration deadlineHeadroom;

  /// The API adapter; built by `adapterFactory` when that is given, so it
  /// can send browser reverse requests through this worker.
  late final PaperbackPackageAdapter? adapter;

  /// Whether the handshake advertises `capabilities.browser`, so the
  /// supervisor serves this worker's `host.browser.*` reverse requests.
  final bool browserEnabled;

  /// Runs once before the worker closes its output, for example to write a
  /// recorded capture.
  final FutureOr<void> Function()? onShutdown;
  final int? pid;
  final String workerVersion;
  final int maxFrameBytes;
  final void Function(String line) _log;

  /// Called with each package runtime as soon as it exists, before any JS
  /// runs. The in-app isolate launcher uses it to publish the runtime's
  /// interrupt token to the owning isolate, which can then stop JS while
  /// this isolate is blocked inside the engine
  /// (`isolatePaperbackLauncher`).
  final void Function(SourceJsRuntime runtime)? onRuntimeCreated;

  final Map<String, SourceJsRuntime> _packages = <String, SourceJsRuntime>{};
  final Map<String, _InFlight> _inFlight = <String, _InFlight>{};
  int _generation = 0;
  bool _shuttingDown = false;
  late final _WorkerBrowserChannel _browser = _WorkerBrowserChannel(this);
  final Map<String, _PendingReverse> _reverse = <String, _PendingReverse>{};
  int _nextReverseId = 1;
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
      case FrameType.reverseResponse:
        final _PendingReverse? pending = _reverse.remove(frame.id);
        if (pending == null) {
          _log('[paperback-worker] ignoring late reverse response ${frame.id}');
          return;
        }
        final Map<String, Object?>? error = frame.error;
        pending.completer.complete(
          error == null
              ? SourceSuccess<Map<String, Object?>>(frame.ok ?? const <String, Object?>{})
              : SourceFailed<Map<String, Object?>>(
                  SourceFailure.fromWire(
                    error['code'] as String? ?? 'source-error',
                    error['message'] as String? ?? '',
                    operation: error['operation'] as String?,
                  ),
                ),
        );
      case FrameType.event:
        final Map<String, Object?>? payload = frame.payload;
        if (frame.op == HostBrowserMessage.op && payload != null) {
          try {
            _browser.deliver(HostBrowserMessage.fromJson(payload));
          } on FormatException catch (e) {
            _log('[paperback-worker] malformed browser message: ${e.message}');
          }
        } else {
          _log('[paperback-worker] ignoring event ${frame.op}');
        }
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
        _reply(
          frame,
          ok: HandshakeResponse(
            protocolVersion: protocolVersion,
            protocolMinor: request.protocolMinor < paperbackProtocolMinor
                ? request.protocolMinor
                : paperbackProtocolMinor,
            worker: 'paperback',
            workerVersion: workerVersion,
            pid: pid,
            capabilities: WorkerCapabilities(
              apiFamilies: adapter?.apiFamilies ?? const <String>{},
              browser: browserEnabled,
            ),
            limits: reportedLimits(limits, deadlineHeadroom: deadlineHeadroom),
          ).toJson(),
        );
      case ShutdownRequest():
        _reply(frame, ok: const EmptyPayload().toJson());
        unawaited(_finish());
      default:
        unawaited(_servePackageOperation(frame, request));
    }
  }

  Future<void> _servePackageOperation(ProtocolFrame frame, WorkerRequest<ProtocolPayload> request) async {
    final SourceFailure? refused = request.admissionFailure(packageId: frame.packageId, isLoaded: _isLoaded);
    if (refused != null) {
      _reply(frame, error: refused.toWire());
      return;
    }
    final String packageId = frame.packageId!;
    final cancel = CancellationSource();
    final op = _InFlight(cancel, _packages[packageId]);
    _inFlight[frame.id] = op;
    try {
      final ProtocolPayload ok = await runZoned(
        () => _dispatch(packageId, request, op),
        zoneValues: <Object, Object>{_originKey: frame.id},
      );
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
      _cancelReverse(frame.id);
    }
  }

  /// Sends a `host.browser.*` reverse request for the operation running in
  /// the calling zone. None is sent once that operation has replied, and its
  /// pending ones are cancelled when it does (protocol v1, "Reverse
  /// requests").
  Future<SourceOutcome<Map<String, Object?>>> _sendReverse(
    HostBrowserRequest<ProtocolPayload> request,
    CancellationToken cancel,
  ) async {
    final Object? origin = Zone.current[_originKey];
    if (origin is! String || !_inFlight.containsKey(origin) || _shuttingDown) {
      return const SourceFailed<Map<String, Object?>>(CancelledFailure('Browser request outside a running operation'));
    }
    if (!browserEnabled) {
      return SourceFailed<Map<String, Object?>>(
        CapabilityUnavailableFailure(request.operation.wire, 'This worker was started without a browser port'),
      );
    }
    final id = 'r${_nextReverseId++}';
    final pending = _PendingReverse(origin);
    _reverse[id] = pending;
    _output.add(
      encodeFrame(
        ProtocolFrame(
          type: FrameType.reverseRequest,
          id: id,
          generation: _generation,
          op: request.operation.wire,
          originId: origin,
          payload: request.toJson(),
        ),
        maxFrameBytes: maxFrameBytes,
      ),
    );
    final StreamSubscription<void> onCancel = cancel.whenCancelled.asStream().listen((_) {
      if (_reverse.remove(id) != null) {
        pending.completer.complete(SourceFailed<Map<String, Object?>>(CancelledFailure(cancel.reason ?? 'cancelled')));
      }
    });
    try {
      return await pending.completer.future;
    } finally {
      await onCancel.cancel();
    }
  }

  void _cancelReverse(String originId) {
    final ids = <String>[
      for (final MapEntry<String, _PendingReverse> e in _reverse.entries)
        if (e.value.originId == originId) e.key,
    ];
    for (final id in ids) {
      _reverse
          .remove(id)
          ?.completer
          .complete(const SourceFailed<Map<String, Object?>>(CancelledFailure('The originating operation finished')));
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
        onRuntimeCreated?.call(runtime);
        op.runtime = runtime;
        try {
          final PackageLoadResponse response = await adapter.load(runtime, request, op.cancel.token);
          _packages[packageId] = runtime;
          return response;
        } on Object {
          runtime.dispose();
          rethrow;
        }
      case ArtifactPrepareRequest():
        // Paperback bundles are verified by the adapter at load; there is no
        // prepare step (KTD5 covers Tachi artifacts).
        throw const _WorkerFailure(UnsupportedApiFailure('The Paperback worker has no artifact.prepare step'));
      case PackageUnloadRequest():
        _packages.remove(packageId)?.dispose();
        return const EmptyPayload();
      default:
        if (adapter == null) {
          throw const _WorkerFailure(UnsupportedApiFailure('This worker has no Paperback API adapter yet'));
        }
        // Admission already refused a package that is absent or closed.
        final SourceJsRuntime runtime = _packages[packageId]!;
        op.runtime = runtime;
        return adapter.handle(runtime, request, op.cancel.token);
    }
  }

  /// Whether [packageId] holds a live runtime; a closed one is dropped.
  bool _isLoaded(String packageId) {
    final SourceJsRuntime? runtime = _packages[packageId];
    if (runtime != null && runtime.isClosed) _packages.remove(packageId);
    return runtime != null && !runtime.isClosed;
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
      await onShutdown?.call();
    } on Object catch (e) {
      _log('[paperback-worker] shutdown hook failed: $e');
    }
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

/// Zone key holding the request ID of the operation a reverse request
/// belongs to.
final Object _originKey = Object();

final class _PendingReverse {
  _PendingReverse(this.originId);

  final String originId;
  final Completer<SourceOutcome<Map<String, Object?>>> completer = Completer<SourceOutcome<Map<String, Object?>>>();
}

/// The worker's [PaperbackBrowserChannel]: requests become `rreq` frames tied
/// to the operation running in the calling zone; page messages arrive as
/// `host.browser.message` events.
final class _WorkerBrowserChannel implements PaperbackBrowserChannel {
  _WorkerBrowserChannel(this._worker);

  final PaperbackSourceWorker _worker;
  final StreamController<HostBrowserMessage> _messages = StreamController<HostBrowserMessage>.broadcast();

  void deliver(HostBrowserMessage message) => _messages.add(message);

  @override
  Stream<HostBrowserMessage> get messages => _messages.stream;

  @override
  Future<SourceOutcome<Map<String, Object?>>> send(
    HostBrowserRequest<ProtocolPayload> request,
    CancellationToken cancel,
  ) => _worker._sendReverse(request, cancel);
}
