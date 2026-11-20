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

/// Generous bound on how far past the deadline termination may land; it
/// covers interrupt-check granularity and slow CI machines.
const Duration overshoot = Duration(milliseconds: 1500);

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
    check(took).isLessThan(deadline + overshoot);
    // The runtime remains usable after a deadline interrupt.
    check(await runtime.evaluate('1 + 1')).equals(2);
  });

  test('an endless promise chain stops at the deadline and never starves the event loop', () async {
    var ticks = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
    addTearDown(ticker.cancel);
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => runtime.evaluate('(async () => { for (;;) await null; })()'),
    );
    check(e.reason).equals(PaperbackFailureReason.deadline);
    check(took).isLessThan(deadline + overshoot);
    // Job slices yield timer turns, so the timer kept firing.
    check(ticks).isGreaterThan(5);
  });

  test('a promise chain that grows without bound stops at the memory limit', () async {
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => runtime.evaluate('(function spin(n) { return Promise.resolve(n + 1).then(spin); })(0)'),
    );
    // The engine rejects with `null` when it cannot allocate its error; the
    // allocator flag still identifies the cause.
    check(e.reason).equals(PaperbackFailureReason.memoryLimit);
    check(took).isLessThan(deadline + overshoot);
  });

  test('a promise that can never settle fails at once', () async {
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => runtime.evaluate('new Promise(() => {})'),
    );
    check(e.reason).equals(PaperbackFailureReason.neverSettles);
    check(took).isLessThan(deadline);
  });

  test('a promise waiting on a host call that never answers stops at the deadline', () async {
    final client = ControlledHttp();
    installHttpHost(runtime, client);
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => runtime.evaluate('__paperbackHost.request({ url: "https://example.test/hang" })'),
    );
    check(e.reason).equals(PaperbackFailureReason.deadline);
    check(took).isGreaterOrEqual(deadline - const Duration(milliseconds: 50));
    check(took).isLessThan(deadline + overshoot);
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
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => runtime.evaluate('const a = []; for (;;) a.push("x".repeat(1024) + a.length);'),
    );
    check(e.reason).equals(PaperbackFailureReason.memoryLimit);
    check(took).isLessThan(deadline + overshoot);
    check(runtime.isClosed).isTrue();
    check(await caught(runtime.evaluate('1')))
        .has(
          (PaperbackRuntimeException e) => e.failure,
          'failure',
        )
        .isA<RuntimeUnavailableFailure>();
  });

  test('cancellation while waiting on a host call ends the operation promptly', () async {
    installHttpHost(runtime, ControlledHttp());
    final source = CancellationSource();
    Timer(const Duration(milliseconds: 50), () => source.cancel('user aborted'));
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(
      () => runtime.evaluate('__paperbackHost.request({ url: "https://example.test/hang" })', cancel: source.token),
    );
    check(e.reason).equals(PaperbackFailureReason.cancelled);
    check(e.failure).isA<CancelledFailure>();
    check(took).isLessThan(deadline);
  });

  test('another isolate can interrupt a busy loop through the token address', () async {
    final long = SourceJsRuntime(
      limits: testLimits(operationDeadline: const Duration(seconds: 20)),
      name: 'long',
    );
    addTearDown(long.dispose);
    await Isolate.spawn(_interruptAfterDelay, long.interruptTokenAddress);
    final (PaperbackRuntimeException e, Duration took) = await expectFailure(() => long.evaluate('for (;;) {}'));
    check(e.reason).equals(PaperbackFailureReason.cancelled);
    check(took).isLessThan(const Duration(seconds: 5));
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
