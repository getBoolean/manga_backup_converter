import 'dart:async';

import 'package:meta/meta.dart';
import 'package:paperback_plugin_loader/src/runtime/quickjs_runtime.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_contracts.dart';

/// An asynchronous host call that JS awaits as a promise.
///
/// Receives the JS arguments converted to Dart data and returns JSON-like
/// data (`Uint8List` becomes a `Uint8Array`). Throwing rejects the promise;
/// throw [HostCallError] to attach structured context.
typedef AsyncHostFunction = Future<Object?> Function(List<Object?> args);

/// A failed host call. Its [details] reach JS as `error.details`, so source
/// code and the eventual operation error keep the context.
final class HostCallError implements Exception {
  const HostCallError(this.message, {this.details = const <String, Object?>{}});

  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'HostCallError: $message';
}

/// Promise plumbing for one [SourceJsRuntime] (KTD2, KTD6).
///
/// Every JS value, resolving function and pending job is owned by the
/// runtime's isolate. Host futures complete on the same isolate; their
/// results are converted and delivered only while the runtime is alive, so a
/// late completion after disposal never touches freed JS values.
final class PromiseBridge {
  PromiseBridge(this._runtime);

  final SourceJsRuntime _runtime;
  final Map<int, _PendingHostCall> _pending = <int, _PendingHostCall>{};
  int _nextCallId = 1;
  Completer<void>? _progress;
  PaperbackRuntimeException? _fatal;
  bool _closed = false;

  /// Host calls whose futures have not completed.
  int get pendingHostCalls => _pending.length;

  /// Installs [function] at `globalThis[name]` (dotted names create plain
  /// intermediate objects). JS calls return a promise.
  void registerAsync(String name, AsyncHostFunction function) {
    final JsContext context = _runtime.context;
    final JsValue fn = context.newHostFunction(name, (JsContext c, JsValue self, List<JsValue> args) {
      final dartArgs = <Object?>[for (final JsValue a in args) c.toDart(a)];
      return _start(c, function, dartArgs);
    });
    _runtime.installGlobal(name, fn);
  }

  JsValue _start(JsContext context, AsyncHostFunction function, List<Object?> args) {
    final JsPromiseCapability capability = context.newPromise();
    final int id = _nextCallId++;
    _pending[id] = _PendingHostCall(capability.resolve, capability.reject);
    final Future<Object?> future;
    try {
      future = function(args);
    } on Object catch (e) {
      _complete(id, error: e);
      return capability.promise;
    }
    future.then(
      (Object? value) => _complete(id, value: value),
      onError: (Object e, StackTrace _) => _complete(id, error: e),
    );
    return capability.promise;
  }

  void _complete(int id, {Object? value, Object? error}) {
    // Late completion after disposal: the entry is gone and nothing is
    // touched. The liveness check comes before any pointer use.
    if (_closed) return;
    final _PendingHostCall? call = _pending.remove(id);
    if (call == null) return;
    final JsContext context = _runtime.context;
    try {
      final JsValue argument = error == null ? context.fromDart(value) : _errorValue(context, error);
      try {
        context.call(error == null ? call.resolve : call.reject, args: <JsValue>[argument]).dispose();
      } finally {
        argument.dispose();
      }
    } on JsException catch (e) {
      // Converting a host result can exhaust the JS heap; that ends the
      // operation as a resource failure.
      _fatal ??= _runtime.failureFor(e);
    } finally {
      call.dispose();
      _signal();
    }
  }

  JsValue _errorValue(JsContext context, Object error) {
    final JsValue err = context.error(
      error is HostCallError ? error.message : error.toString(),
      name: 'HostCallError',
    );
    if (error is HostCallError && error.details.isNotEmpty) {
      err.setProperty('details', context.fromDart(error.details));
    }
    return err;
  }

  void _signal() {
    final Completer<void>? progress = _progress;
    _progress = null;
    if (progress != null && !progress.isCompleted) progress.complete();
  }

  /// Runs pending jobs until [promise] settles and returns its value.
  ///
  /// Jobs run in slices of `limits.jobSlice`, each followed by a timer turn
  /// so stdin, cancellation and host I/O are serviced. The JS interrupt
  /// handler enforces the runtime's deadline while jobs run; a Dart timer
  /// enforces it while waiting on host calls, re-armed whenever the deadline
  /// is paused or resumed (`SourceJsRuntime.pauseDeadline`). A promise that is pending with no queued
  /// jobs and no host calls can never settle and fails immediately.
  Future<JsValue> settle(JsValue promise, {required CancellationToken cancel}) async {
    final JsContext context = _runtime.context;
    while (true) {
      _runtime.checkAlive();
      _throwIfStopped(cancel);
      final JsJobDrain drain = _runtime.drainSlice();
      // An interrupt inside a promise job can surface as a rejection rather
      // than a job error; the runtime's sticky reason is authoritative.
      final PaperbackRuntimeException? interrupted = _runtime.interruptFailure();
      if (interrupted != null) throw interrupted;
      final JsException? error = drain.error;
      if (error != null) throw _runtime.failureFor(error);
      final PaperbackRuntimeException? fatal = _fatal;
      if (fatal != null) {
        _fatal = null;
        throw fatal;
      }
      switch (context.promiseState(promise)) {
        case JsPromiseState.fulfilled:
          return context.promiseResult(promise);
        case JsPromiseState.rejected:
          final JsValue reason = context.promiseResult(promise);
          try {
            throw _runtime.rejectionFailure(reason);
          } finally {
            reason.dispose();
          }
        case JsPromiseState.notAPromise:
          return promise.dup();
        case JsPromiseState.pending:
          break;
      }
      if (drain.morePending) {
        await _timerTurn();
        continue;
      }
      if (_pending.isEmpty) {
        throw const PaperbackRuntimeException(
          SourceErrorFailure('The source returned a promise that can never settle (no queued jobs or host calls)'),
          reason: PaperbackFailureReason.neverSettles,
        );
      }
      await _waitForProgress(cancel);
    }
  }

  void _throwIfStopped(CancellationToken cancel) {
    if (cancel.isCancelled) {
      throw PaperbackRuntimeException(
        CancelledFailure(cancel.reason ?? 'cancelled'),
        reason: PaperbackFailureReason.cancelled,
      );
    }
    if (!_runtime.deadlinePaused && QuickJs.nowNanoseconds() >= _runtime.currentDeadlineNs) {
      throw const PaperbackRuntimeException(
        TimeoutFailure('The operation exceeded its deadline'),
        reason: PaperbackFailureReason.deadline,
      );
    }
  }

  /// Waits for a host call to settle, the deadline to pass, cancellation,
  /// or a pause or resume of the deadline ([wake]). While the deadline is
  /// paused no timer runs.
  Future<void> _waitForProgress(CancellationToken cancel) async {
    final Completer<void> progress = _progress ??= Completer<void>();
    if (_runtime.deadlinePaused) {
      await Future.any(<Future<void>>[progress.future, cancel.whenCancelled]);
      return;
    }
    final int remainingUs = (_runtime.currentDeadlineNs - QuickJs.nowNanoseconds()) ~/ 1000;
    final timer = Completer<void>();
    final t = Timer(Duration(microseconds: remainingUs < 0 ? 0 : remainingUs), timer.complete);
    try {
      await Future.any(<Future<void>>[progress.future, timer.future, cancel.whenCancelled]);
    } finally {
      t.cancel();
    }
  }

  /// Wakes a waiting [settle] so it re-reads the deadline.
  @internal
  void wake() => _signal();

  /// One event-loop turn through the timer queue. A microtask yield would
  /// not let I/O run.
  static Future<void> _timerTurn() => Future<void>.delayed(Duration.zero);

  /// Ends the current operation: drops its pending host calls (their late
  /// results are ignored) and any unreported fatal failure, so nothing leaks
  /// into the next operation. Source code cannot keep background work alive
  /// between operations.
  @internal
  void endOperation() {
    for (final _PendingHostCall call in _pending.values) {
      call.dispose();
    }
    _pending.clear();
    _fatal = null;
    _signal();
  }

  /// Drops every pending call and wakes any waiter. Called by the runtime
  /// before it frees its JS values.
  @internal
  void close() {
    if (_closed) return;
    _closed = true;
    for (final _PendingHostCall call in _pending.values) {
      call.dispose();
    }
    _pending.clear();
    _signal();
  }
}

final class _PendingHostCall {
  _PendingHostCall(this.resolve, this.reject);

  final JsValue resolve;
  final JsValue reject;

  void dispose() {
    resolve.dispose();
    reject.dispose();
  }
}
