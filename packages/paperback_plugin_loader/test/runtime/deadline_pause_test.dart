// Protocol 1.3 "Deadline pause" at the runtime: `pauseDeadline` /
// `resumeDeadline` stop and restart the QuickJS operation deadline, the
// remaining budget carries over, and JS that runs while paused is still
// bounded.
@TestOn('vm')
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import 'test_support.dart';

void main() {
  const deadline = Duration(milliseconds: 400);
  late SourceJsRuntime runtime;
  late Completer<Object?> gate;

  setUp(() {
    runtime = SourceJsRuntime(limits: testLimits(operationDeadline: deadline));
    gate = Completer<Object?>();
    runtime.bridge.registerAsync('gate', (_) => gate.future);
    runtime.bridge.registerAsync('paused', (List<Object?> args) async {
      runtime.pauseDeadline();
      try {
        await Future<void>.delayed(Duration(milliseconds: args.single! as int));
      } finally {
        runtime.resumeDeadline();
      }
      return 'done';
    });
    runtime.bridge.registerAsync('unpaused', (List<Object?> args) async {
      await Future<void>.delayed(Duration(milliseconds: args.single! as int));
      return 'done';
    });
    runtime.bridge.registerAsync('pauseOnly', (_) async {
      runtime.pauseDeadline();
      return null;
    });
  });
  tearDown(() => runtime.dispose());

  test('a host wait longer than the deadline succeeds while paused', () async {
    await runtime.evaluate('globalThis.op = () => paused(1200); void 0;');
    check(await runtime.call('op', const <Object?>[])).equals('done');
  });

  test('the same wait unpaused times out (control)', () async {
    await runtime.evaluate('globalThis.op = () => unpaused(1200); void 0;');
    check((await caught(runtime.call('op', const <Object?>[]))).failure).isA<TimeoutFailure>();
  });

  test('after resuming, the time left before the pause still runs out', () async {
    await runtime.evaluate('globalThis.op = async () => { await paused(800); await gate(); }; void 0;');
    final (PaperbackRuntimeException e, Duration took) = await timed(
      () => caught(runtime.call('op', const <Object?>[])),
    );
    check(e.failure).isA<TimeoutFailure>();
    // 800 ms paused plus at most the 400 ms budget, not a fresh deadline.
    check(took).isGreaterThan(const Duration(milliseconds: 800));
    check(took).isLessThan(const Duration(milliseconds: 1800));
  });

  test('JS that loops while paused is still interrupted', () async {
    await runtime.evaluate(
      'globalThis.op = async () => { await pauseOnly(); for (;;) {} }; void 0;',
    );
    check((await caught(runtime.call('op', const <Object?>[]))).failure).isA<TimeoutFailure>();
  });

  test('a pause does not outlive its operation', () async {
    await runtime.evaluate('globalThis.leak = () => pauseOnly(); globalThis.wait = () => gate(); void 0;');
    await runtime.call('leak', const <Object?>[]);
    check(runtime.deadlinePaused).isFalse();
    check((await caught(runtime.call('wait', const <Object?>[]))).failure).isA<TimeoutFailure>();
  });

  test('pausing between operations has no effect', () {
    runtime
      ..pauseDeadline()
      ..resumeDeadline();
    check(runtime.deadlinePaused).isFalse();
  });
}
