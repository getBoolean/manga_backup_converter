@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:checks/checks.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import 'test_support.dart';

const Duration deadline = Duration(milliseconds: 400);

/// Upper bound that only proves termination is bounded (no hang). These
/// tests run on loaded CI machines, so they assert the termination reason
/// and a lower bound, never a tight wall-clock ceiling: the reason already
/// shows which limit fired (a deadline is a `TimeoutFailure`, a cancel a
/// `CancelledFailure`, a never-settling promise `neverSettles`).
const Duration bounded = Duration(seconds: 25);

/// Long deadline for cases about other limits, so the deadline can never win
/// the race against the memory limit or a cancellation.
const Duration noDeadline = Duration(seconds: 30);

Future<(PaperbackRuntimeException, Duration)> expectFailure(Future<Object?> Function() op) async {
  final watch = Stopwatch()..start();
  try {
    await op();
  } on PaperbackRuntimeException catch (e) {
    return (e, watch.elapsed);
  }
  throw StateError('expected the operation to fail');
}

void main() {
  late SourceJsRuntime runtime;

  /// A runtime whose deadline cannot fire within the test, with a small heap
  /// so memory cases reach their limit quickly even on a loaded machine.
  SourceJsRuntime undeadlined(String name) {
    final r = SourceJsRuntime(
      limits: testLimits(memoryLimitBytes: 4 * 1024 * 1024),
      name: name,
    );
    addTearDown(r.dispose);
    return r;
  }

  setUp(() {
    runtime = SourceJsRuntime(
      limits: testLimits(operationDeadline: deadline),
      name: 'limits-test',
    );
  });

  tearDown(() => runtime.dispose());

  test('a busy loop stops at the deadline', () async {
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(() => runtime.evaluate('for (;;) {}'));
    check(e.reason).equals(PaperbackFailureReason.deadline);
    check(e.failure).isA<TimeoutFailure>();
    check(took).isGreaterOrEqual(deadline - const Duration(milliseconds: 50));
    check(took).isLessThan(bounded);
    // The runtime remains usable after a deadline interrupt.
    check(await runtime.evaluate('1 + 1')).equals(2);
  });

  test('an endless promise chain stops at the deadline and never starves the event loop', () async {
    // Counts timer turns that ran while the operation was still in progress.
    // A starved event loop runs none until the operation ends; how many run
    // depends on machine load, so only "at least one" is asserted.
    var running = true;
    var ticksWhileRunning = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (running) ticksWhileRunning++;
    });
    addTearDown(ticker.cancel);
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => runtime.evaluate('(async () => { for (;;) await null; })()'),
    );
    running = false;
    check(e.reason).equals(PaperbackFailureReason.deadline);
    check(took).isLessThan(bounded);
    check(ticksWhileRunning).isGreaterThan(0);
  });

  test('a promise chain that grows without bound stops at the memory limit', () async {
    final SourceJsRuntime r = undeadlined('memory-chain');
    final (PaperbackRuntimeException e, _) = await expectFailure(
      () => r.evaluate('(function spin(n) { return Promise.resolve(n + 1).then(spin); })(0)'),
    );
    // The engine rejects with `null` when it cannot allocate its error; the
    // allocator flag still identifies the cause.
    // No deadline can fire, so the reason alone shows the memory limit
    // stopped it; the test timeout catches a hang.
    check(e.reason).equals(PaperbackFailureReason.memoryLimit);
  });

  test('a promise that can never settle fails at once', () async {
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => runtime.evaluate('new Promise(() => {})'),
    );
    // `neverSettles`, not `deadline`: it failed without waiting the deadline.
    check(e.reason).equals(PaperbackFailureReason.neverSettles);
    check(took).isLessThan(bounded);
  });

  test('a promise waiting on a host call that never answers stops at the deadline', () async {
    final client = ControlledHttp();
    installHttpHost(runtime, client);
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => runtime.evaluate('__paperbackHost.request({ url: "https://example.test/hang" })'),
    );
    check(e.reason).equals(PaperbackFailureReason.deadline);
    check(took).isGreaterOrEqual(deadline - const Duration(milliseconds: 50));
    check(took).isLessThan(bounded);
  });

  test('host calls left by a timed-out operation do not leak into the next one', () async {
    final client = ControlledHttp();
    installHttpHost(runtime, client);
    final (PaperbackRuntimeException first, _) = await expectFailure(
      () => runtime.evaluate(
        '__paperbackHost.request({ url: "https://example.test/hang" }).then(() => { globalThis.leaked = true; })',
      ),
    );
    check(first.reason).equals(PaperbackFailureReason.deadline);
    check(runtime.bridge.pendingHostCalls).equals(0);
    client.completeAll('late');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // The next operation sees no stale host call: a promise that can never
    // settle fails at once instead of waiting out the deadline.
    final (PaperbackRuntimeException second, Duration took) = await expectFailure(
      () => runtime.evaluate('new Promise(() => {})'),
    );
    check(second.reason).equals(PaperbackFailureReason.neverSettles);
    check(took).isLessThan(bounded);
    check(await runtime.evaluate('typeof leaked')).equals('undefined');
  });

  test('unbounded recursion stops at the stack limit', () async {
    final (PaperbackRuntimeException e, _) = await expectFailure(
      () => runtime.evaluate('function r(n) { return r(n + 1) + 1; } r(0)'),
    );
    check(e.reason).equals(PaperbackFailureReason.stackLimit);
    check(await runtime.evaluate('"still alive"')).equals('still alive');
  });

  test('recursion inside a promise job also stops at the stack limit', () async {
    final (PaperbackRuntimeException e, _) = await expectFailure(
      () => runtime.evaluate('Promise.resolve().then(() => { function r() { return r() + 1; } return r(); })'),
    );
    check(e.reason).equals(PaperbackFailureReason.sourceError);
    check(e.failure.message).contains('Maximum call stack size exceeded');
  });

  test('memory exhaustion stops at the memory limit and closes the runtime', () async {
    final SourceJsRuntime r = undeadlined('memory-exhaustion');
    final (PaperbackRuntimeException e, _) = await expectFailure(
      () => r.evaluate('const a = []; for (;;) a.push("x".repeat(1024) + a.length);'),
    );
    check(e.reason).equals(PaperbackFailureReason.memoryLimit);
    check(r.isClosed).isTrue();
    check(await caught(r.evaluate('1')))
        .has(
          (PaperbackRuntimeException e) => e.failure,
          'failure',
        )
        .isA<RuntimeUnavailableFailure>();
  });

  test('cancellation while waiting on a host call ends the operation', () async {
    // No deadline can fire, so `cancelled` proves the cancel ended it.
    final SourceJsRuntime r = undeadlined('cancel');
    installHttpHost(r, ControlledHttp());
    final source = CancellationSource();
    Timer(const Duration(milliseconds: 50), () => source.cancel('user aborted'));
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => r.evaluate('__paperbackHost.request({ url: "https://example.test/hang" })', cancel: source.token),
    );
    check(e.reason).equals(PaperbackFailureReason.cancelled);
    check(e.failure).isA<CancelledFailure>();
    check(took).isLessThan(bounded);
  });

  test('another isolate can interrupt a busy loop through the token address', () async {
    final SourceJsRuntime long = undeadlined('long');
    await Isolate.spawn(_interruptAfterDelay, long.interruptTokenAddress);
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(() => long.evaluate('for (;;) {}'));
    check(e.reason).equals(PaperbackFailureReason.cancelled);
    check(took).isLessThan(bounded);
    // A new operation resets the token.
    check(await long.evaluate('"next"')).equals('next');
  });

  test('limits must be explicit and positive', () {
    check(() => testLimits(memoryLimitBytes: 0)).throws<ArgumentError>();
    check(() => testLimits(maxStackBytes: 0)).throws<ArgumentError>();
    check(() => testLimits(operationDeadline: Duration.zero)).throws<ArgumentError>();
    check(() => testLimits(jobSlice: Duration.zero)).throws<ArgumentError>();
  });

  test('a memory limit too small for the realm fails cleanly', () {
    check(() => SourceJsRuntime(limits: testLimits(memoryLimitBytes: 16 * 1024)))
        .throws<PaperbackRuntimeException>()
        .has((PaperbackRuntimeException e) => e.reason, 'reason')
        .equals(PaperbackFailureReason.memoryLimit);
  });

  test('a stack limit at or above the real thread stack is refused', () {
    final int available = QuickJs.threadStackAvailable()!;
    check(() => SourceJsRuntime(limits: testLimits(maxStackBytes: available + 1))).throws<ArgumentError>();
  });

  group('sizing rule', () {
    const profile = QuickJsWorkloadProfile(
      source: 'test',
      peakHeapBytes: 10 * 1024 * 1024,
      peakStackBytes: 100 * 1024,
      slowestOperation: Duration(milliseconds: 200),
      referenceCalibration: Duration(milliseconds: 10),
    );
    const policy = QuickJsSizingPolicy(
      heapHeadroom: 2,
      stackHeadroom: 2,
      deadlineHeadroom: 3,
      maxMemoryShare: 0.25,
      maxThreadStackShare: 0.5,
      slicesPerDeadline: 50,
    );

    test('scales limits to the device', () {
      final QuickJsSizing sizing = deriveQuickJsLimits(
        device: const DeviceCapability(
          physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
          threadStackBytes: 1024 * 1024,
          processors: 8,
          calibration: Duration(milliseconds: 20),
        ),
        profile: profile,
        policy: policy,
        concurrentRuntimes: 4,
        hostWaitAllowance: const Duration(seconds: 10),
      );
      check(sizing.limits.memoryLimitBytes).equals(20 * 1024 * 1024);
      check(sizing.limits.maxStackBytes).equals(200 * 1024);
      // Twice as slow as the reference device: 200 ms × 2 × 3, plus host waits.
      check(sizing.limits.operationDeadline).equals(const Duration(milliseconds: 11200));
      check(sizing.limits.jobSlice).equals(const Duration(microseconds: 24000));
      check(sizing.warnings).isEmpty();
      check(sizing.toJson()).containsKey('rule');
    });

    test('caps at device resources and reports when the workload no longer fits', () {
      final QuickJsSizing sizing = deriveQuickJsLimits(
        device: const DeviceCapability(
          physicalMemoryBytes: 64 * 1024 * 1024,
          threadStackBytes: 128 * 1024,
          processors: 2,
          calibration: Duration(milliseconds: 10),
        ),
        profile: profile,
        policy: policy,
        concurrentRuntimes: 4,
        hostWaitAllowance: Duration.zero,
      );
      check(sizing.limits.memoryLimitBytes).equals(4 * 1024 * 1024);
      check(sizing.limits.maxStackBytes).equals(64 * 1024);
      check(sizing.warnings).length.equals(2);
    });
  });
}

void _interruptAfterDelay(int address) {
  sleep(const Duration(milliseconds: 100));
  JsInterruptToken.fromAddress(address)
    ..request()
    ..release();
}
