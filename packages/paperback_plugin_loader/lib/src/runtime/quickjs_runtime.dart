import 'dart:async';

import 'package:paperback_plugin_loader/src/runtime/promise_bridge.dart';
import 'package:paperback_plugin_loader/src/runtime/runtime_limits.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_contracts.dart';

/// Why a source runtime operation failed.
enum PaperbackFailureReason {
  /// Source code threw or a promise rejected.
  sourceError,

  /// The operation deadline passed (inside JS or while waiting on the host).
  deadline,

  /// The operation was cancelled.
  cancelled,

  /// The JS heap limit was reached. The runtime is closed afterwards.
  memoryLimit,

  /// The JS stack limit was reached.
  stackLimit,

  /// The result promise could never settle.
  neverSettles,

  /// The runtime was disposed or closed by an earlier fatal failure.
  runtimeClosed,
}

/// A failed runtime operation, carrying the protocol failure to report.
final class PaperbackRuntimeException implements Exception {
  const PaperbackRuntimeException(this.failure, {required this.reason, this.stack});

  final SourceFailure failure;
  final PaperbackFailureReason reason;

  /// The JS stack, when the failure came from source code.
  final String? stack;

  @override
  String toString() => 'PaperbackRuntimeException(${reason.name}): $failure';
}

/// One Paperback source's QuickJS runtime: its own heap, global object,
/// limits, interrupt token and promise bridge (KTD2).
///
/// Sources never share a runtime, so they never share globals. Every method
/// runs on the creating isolate. One operation runs at a time.
final class SourceJsRuntime {
  SourceJsRuntime({required this.limits, this.name = 'source', this._log}) : _token = JsInterruptToken() {
    final int? available = QuickJs.threadStackAvailable();
    if (available != null && limits.maxStackBytes >= available) {
      _token.release();
      throw ArgumentError.value(
        limits.maxStackBytes,
        'limits.maxStackBytes',
        'must be below the $available bytes of native stack left on this thread',
      );
    }
    _runtime = JsRuntime(interruptToken: _token)
      ..memoryLimit = limits.memoryLimitBytes
      ..maxStackSize = limits.maxStackBytes;
    try {
      context = _runtime.newContext();
      bridge = PromiseBridge(this);
      _installConsole();
    } on Object catch (e) {
      // A memory limit too small for the realm itself.
      _runtime.dispose();
      _token.release();
      _closed = true;
      throw PaperbackRuntimeException(
        RuntimeUnavailableFailure('$name could not start within its limits: $e'),
        reason: PaperbackFailureReason.memoryLimit,
      );
    }
  }

  final PaperbackRuntimeLimits limits;
  final String name;
  final void Function(String line)? _log;
  final JsInterruptToken _token;
  late final JsRuntime _runtime;
  late final JsContext context;
  late final PromiseBridge bridge;
  bool _busy = false;
  bool _closed = false;
  String? _closedReason;

  bool get isClosed => _closed;

  /// The underlying engine runtime, for memory accounting.
  JsRuntime get engine => _runtime;

  /// Native address of the interrupt token. Another isolate may adopt it with
  /// `JsInterruptToken.fromAddress` and request an interrupt while this
  /// isolate is blocked inside JS.
  int get interruptTokenAddress => _token.address;

  /// Interrupts JS running now or next on this runtime. The current
  /// operation then fails as cancelled.
  void requestInterrupt() {
    if (!_token.isReleased) _token.request();
  }

  /// Evaluates script code under the operation deadline. A promise result is
  /// awaited through the bridge. Returns the result as Dart data.
  Future<Object?> evaluate(String code, {String filename = '<source>', CancellationToken? cancel}) =>
      _operation(cancel, (int deadlineNs) => context.eval(code, filename: filename));

  /// Calls the global function [function] with [args] (Dart data) and awaits
  /// its result.
  Future<Object?> call(String function, List<Object?> args, {CancellationToken? cancel}) =>
      _operation(cancel, (int deadlineNs) {
        final JsValue global = context.global;
        try {
          final JsValue fn = global.getProperty(function);
          try {
            if (fn.kind != JsValueKind.function) {
              throw PaperbackRuntimeException(
                SourceErrorFailure('$name does not define a function named "$function"'),
                reason: PaperbackFailureReason.sourceError,
              );
            }
            final jsArgs = <JsValue>[for (final Object? a in args) context.fromDart(a)];
            try {
              return context.call(fn, thisValue: global, args: jsArgs);
            } finally {
              for (final a in jsArgs) {
                a.dispose();
              }
            }
          } finally {
            fn.dispose();
          }
        } finally {
          global.dispose();
        }
      });

  Future<Object?> _operation(CancellationToken? cancel, JsValue Function(int deadlineNs) start) async {
    checkAlive();
    if (_busy) throw StateError('$name is already running an operation');
    _busy = true;
    final CancellationToken token = cancel ?? CancellationToken.none;
    final int deadlineNs = QuickJs.nowNanoseconds() + limits.operationDeadline.inMicroseconds * 1000;
    _token.reset();
    _runtime.clearInterrupt();
    bridge.endOperation();
    // Cancellation while this isolate waits interrupts JS on resumption.
    final StreamSubscription<void> onCancel = token.whenCancelled.asStream().listen((_) => requestInterrupt());
    try {
      if (token.isCancelled) {
        throw PaperbackRuntimeException(
          CancelledFailure(token.reason ?? 'cancelled'),
          reason: PaperbackFailureReason.cancelled,
        );
      }
      final JsValue result = _runJs(deadlineNs, () => start(deadlineNs));
      try {
        final JsValue settled = await bridge.settle(result, deadlineNs: deadlineNs, cancel: token);
        try {
          return context.toDart(settled);
        } on JsConversionException catch (e) {
          throw PaperbackRuntimeException(
            SourceErrorFailure('$name returned a value that is not data: ${e.message}'),
            reason: PaperbackFailureReason.sourceError,
          );
        } finally {
          settled.dispose();
        }
      } finally {
        if (!_closed) result.dispose();
      }
    } on PaperbackRuntimeException catch (e) {
      if (e.reason == PaperbackFailureReason.memoryLimit) _close('memory limit exceeded');
      rethrow;
    } finally {
      if (!_closed) bridge.endOperation();
      await onCancel.cancel();
      _busy = false;
    }
  }

  T _runJs<T>(int deadlineNs, T Function() body) {
    _runtime.deadlineNanoseconds = deadlineNs;
    try {
      return body();
    } on JsException catch (e) {
      throw failureFor(e);
    } finally {
      if (!_closed) _runtime.deadlineNanoseconds = null;
    }
  }

  /// Runs pending jobs for at most one `limits.jobSlice`, under [deadlineNs].
  JsJobDrain drainSlice(int deadlineNs) {
    final int sliceEnd = QuickJs.nowNanoseconds() + limits.jobSlice.inMicroseconds * 1000;
    _runtime.deadlineNanoseconds = deadlineNs;
    try {
      return _runtime.executePendingJobs(untilNanoseconds: sliceEnd < deadlineNs ? sliceEnd : deadlineNs);
    } finally {
      _runtime.deadlineNanoseconds = null;
    }
  }

  /// The failure for an interrupt or refused allocation during this
  /// operation, if any. These engine flags are authoritative: an interrupt or
  /// out-of-memory inside a promise job can surface as an ordinary rejection.
  PaperbackRuntimeException? interruptFailure() {
    if (_runtime.memoryLimitHit) {
      return PaperbackRuntimeException(
        SourceErrorFailure('$name exceeded its JS memory limit of ${limits.memoryLimitBytes} bytes'),
        reason: PaperbackFailureReason.memoryLimit,
      );
    }
    return _interruptReasonFailure();
  }

  PaperbackRuntimeException? _interruptReasonFailure() => switch (_runtime.interruptReason) {
    JsInterruptReason.none => null,
    JsInterruptReason.requested => const PaperbackRuntimeException(
      CancelledFailure('The operation was cancelled while JS was running'),
      reason: PaperbackFailureReason.cancelled,
    ),
    JsInterruptReason.deadline => const PaperbackRuntimeException(
      TimeoutFailure('JS execution exceeded the operation deadline'),
      reason: PaperbackFailureReason.deadline,
    ),
  };

  /// Maps an engine exception to the operation failure it causes.
  PaperbackRuntimeException failureFor(JsException e) {
    final PaperbackRuntimeException? interrupted = interruptFailure();
    if (interrupted != null) return interrupted;
    switch (e.kind) {
      case JsErrorKind.interrupted:
        return const PaperbackRuntimeException(
          TimeoutFailure('JS execution was interrupted'),
          reason: PaperbackFailureReason.deadline,
        );
      case JsErrorKind.outOfMemory:
        return PaperbackRuntimeException(
          SourceErrorFailure('$name exceeded its JS memory limit of ${limits.memoryLimitBytes} bytes'),
          reason: PaperbackFailureReason.memoryLimit,
        );
      case JsErrorKind.stackOverflow:
        return PaperbackRuntimeException(
          SourceErrorFailure('$name exceeded its JS stack limit of ${limits.maxStackBytes} bytes'),
          reason: PaperbackFailureReason.stackLimit,
        );
      case JsErrorKind.thrown:
        return PaperbackRuntimeException(
          SourceErrorFailure('${e.name}: ${e.message}'),
          reason: PaperbackFailureReason.sourceError,
          stack: e.stack,
        );
    }
  }

  /// The failure for a rejected result promise, keeping host error details.
  PaperbackRuntimeException rejectionFailure(JsValue reason) {
    Object? data;
    try {
      data = context.toDart(reason, maxDepth: 4);
    } on Object {
      data = null;
    }
    if (data is Map<String, Object?>) {
      final String errorName = data['name'] as String? ?? 'Error';
      final String message = data['message']?.toString() ?? data.toString();
      final JsValue details = reason.kind == JsValueKind.error ? reason.getProperty('details') : context.undefined();
      Object? detailData;
      try {
        detailData = context.toDart(details);
      } on Object {
        detailData = null;
      } finally {
        details.dispose();
      }
      final suffix = detailData == null ? '' : ' $detailData';
      return PaperbackRuntimeException(
        SourceErrorFailure('$errorName: $message$suffix'),
        reason: PaperbackFailureReason.sourceError,
        stack: data['stack'] as String?,
      );
    }
    String text;
    try {
      text = reason.toDartString();
    } on JsException {
      text = '<unprintable rejection>';
    }
    return PaperbackRuntimeException(
      SourceErrorFailure('Promise rejected: $text'),
      reason: PaperbackFailureReason.sourceError,
    );
  }

  /// Sets `globalThis[path]`, creating intermediate objects; consumes [value].
  void installGlobal(String path, JsValue value) {
    final List<String> parts = path.split('.');
    JsValue target = context.global;
    try {
      for (final String part in parts.take(parts.length - 1)) {
        JsValue next = target.getProperty(part);
        if (next.kind != JsValueKind.object) {
          next.dispose();
          target.setProperty(part, context.object());
          next = target.getProperty(part);
        }
        target.dispose();
        target = next;
      }
      target.setProperty(parts.last, value);
    } finally {
      target.dispose();
    }
  }

  void _installConsole() {
    for (final level in const <String>['log', 'info', 'warn', 'error', 'debug']) {
      installGlobal(
        'console.$level',
        context.newHostFunction(level, (JsContext c, JsValue self, List<JsValue> args) {
          final void Function(String)? log = _log;
          if (log != null) {
            final String line = args
                .map((JsValue a) {
                  try {
                    return a.toDartString();
                  } on JsException {
                    return '<unprintable>';
                  }
                })
                .join(' ');
            log('[$name] console.$level: $line');
          }
          return null;
        }),
      );
    }
  }

  /// Throws if the runtime is disposed or closed.
  void checkAlive() {
    if (_closed) {
      throw PaperbackRuntimeException(
        RuntimeUnavailableFailure('$name is closed: ${_closedReason ?? 'disposed'}'),
        reason: PaperbackFailureReason.runtimeClosed,
      );
    }
  }

  void _close(String reason) {
    if (_closed) return;
    _closed = true;
    _closedReason = reason;
    bridge.close();
    _runtime.dispose();
    _token.release();
  }

  /// Frees the runtime. Pending host calls are dropped; their late results
  /// are ignored. Idempotent.
  void dispose() => _close('disposed');
}
