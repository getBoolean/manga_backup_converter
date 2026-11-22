@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:quickjs/quickjs.dart';
import 'package:test/scaffolding.dart';

/// Resolves a path inside this package whether tests run from the package or
/// the workspace root.
File packageFile(String relative) {
  final local = File(relative);
  if (local.existsSync()) return local;
  return File('packages/quickjs/$relative');
}

/// A stack limit safely below what this thread really has.
int safeStackLimit() {
  final int? available = QuickJs.threadStackAvailable();
  check(available).isNotNull();
  return available! ~/ 2;
}

void main() {
  group('engine', () {
    test('loads the version compiled from the pinned submodule', () {
      final String header = packageFile('vendor/quickjs/quickjs.h').readAsStringSync();
      String part(String name) => RegExp('#define QJS_VERSION_$name (\\d+)').firstMatch(header)!.group(1)!;
      check(QuickJs.engineVersion).equals('${part('MAJOR')}.${part('MINOR')}.${part('PATCH')}');
    });

    test('reports device inputs for limit sizing', () {
      check(QuickJs.valueSize).isGreaterOrEqual(8);
      check(QuickJs.physicalMemory()).isNotNull().isGreaterThan(0);
      check(QuickJs.threadStackAvailable()).isNotNull().isGreaterThan(0);
      final int a = QuickJs.nowNanoseconds();
      final int b = QuickJs.nowNanoseconds();
      check(b).isGreaterOrEqual(a);
    });
  });

  group('evaluation', () {
    late JsRuntime runtime;
    late JsContext context;

    setUp(() {
      runtime = JsRuntime()..maxStackSize = safeStackLimit();
      context = runtime.newContext();
    });

    tearDown(() => runtime.dispose());

    test('evaluates expressions and keeps state', () {
      check(context.eval('1 + 1').toDartString()).equals('2');
      context.eval('var x = 40').dispose();
      check(context.toDart(context.eval('x + 2'))).equals(42);
      check(context.eval('"abc".toUpperCase()').toDartString()).equals('ABC');
    });

    test('exposes no std, os, require or process', () {
      check(
        context.eval('typeof std + typeof os + typeof require + typeof process').toDartString(),
      ).equals('undefinedundefinedundefinedundefined');
    });

    test('surfaces thrown errors with name, message and stack', () {
      try {
        context.eval('function f() { throw new TypeError("bad thing"); }\nf();', filename: 'src.js');
        throw StateError('expected a JsException');
      } on JsException catch (e) {
        check(e.name).equals('TypeError');
        check(e.message).equals('bad thing');
        check(e.kind).equals(JsErrorKind.thrown);
        check(e.stack).isNotNull().contains('src.js');
      }
    });

    test('round-trips JSON-like data and bytes', () {
      final JsValue value = context.fromDart(<String, Object?>{
        'n': 1,
        'f': 1.5,
        's': 'é',
        'b': true,
        'nil': null,
        'list': <Object?>[1, 'two'],
        'bytes': Uint8List.fromList(<int>[1, 2, 255]),
      });
      final Object? back = context.toDart(value);
      check(back).isA<Map<String, Object?>>()
        ..has((Map<String, Object?> m) => m['n'], 'n').equals(1)
        ..has((Map<String, Object?> m) => m['f'], 'f').equals(1.5)
        ..has((Map<String, Object?> m) => m['s'], 's').equals('é')
        ..has((Map<String, Object?> m) => m['b'], 'b').equals(true)
        ..has((Map<String, Object?> m) => m['nil'], 'nil').isNull()
        ..has((Map<String, Object?> m) => m['list'], 'list').isA<List<Object?>>().deepEquals(<Object?>[1, 'two'])
        ..has((Map<String, Object?> m) => m['bytes'], 'bytes').isA<Uint8List>().deepEquals(<int>[1, 2, 255]);
      check(context.stringifyJson(context.parseJson('{"a":[1,2]}'))).equals('{"a":[1,2]}');
    });

    test('toDart is bounded by a budget derived from the memory limit (L2)', () {
      // A sparse array: a huge length in a few bytes of heap.
      check(
        () => context.toDart(context.eval('const a = []; a.length = 1e9; a'), maxUnits: 1 << 20),
      ).throws<JsConversionBudgetExceeded>().has((JsConversionBudgetExceeded e) => e.limit, 'limit').equals(1 << 20);
      // Shared nodes: 2^40 paths through 40 tiny objects.
      const shared = 'let n = {}; for (let i = 0; i < 40; i++) n = {a: n, b: n}; n';
      check(() => context.toDart(context.eval(shared), maxUnits: 1 << 20)).throws<JsConversionBudgetExceeded>();
      // Without an explicit budget, the runtime's memory limit is the budget.
      runtime.memoryLimit = 64 * 1024 * 1024;
      check(() => context.toDart(context.eval('const b = []; b.length = 1e9; b'))).throws<JsConversionBudgetExceeded>();
      // A value the heap holds as a tree converts within the budget.
      check(context.toDart(context.eval('({k: "abc", l: [1, 2, 3]})'), maxUnits: 10)).isA<Map<String, Object?>>();
      check(() => context.toDart(context.eval('({k: "abc", l: [1, 2, 3]})'), maxUnits: 9))
          .throws<JsConversionException>();
    });

    test('calls host functions and turns Dart exceptions into JS errors', () {
      final JsValue global = context.global;
      global.setProperty(
        'add',
        context.newHostFunction(
          'add',
          (JsContext c, JsValue self, List<JsValue> args) => c.number(args[0].toDouble() + args[1].toDouble()),
          length: 2,
        ),
      );
      global.setProperty(
        'explode',
        context.newHostFunction('explode', (JsContext c, JsValue self, List<JsValue> args) {
          throw StateError('host failure');
        }),
      );
      check(context.toDart(context.eval('add(2, 3)'))).equals(5);
      check(context.eval('try { explode(); "no" } catch (e) { e.message }').toDartString()).contains('host failure');
    });

    test('runs pending jobs to settle promises', () {
      final JsValue promise = context.eval('Promise.resolve(1).then(v => v + 1).then(v => v * 10)');
      check(context.promiseState(promise)).equals(JsPromiseState.pending);
      final JsJobDrain drain = runtime.executePendingJobs();
      check(drain.executed).isGreaterThan(0);
      check(drain.morePending).isFalse();
      check(context.promiseState(promise)).equals(JsPromiseState.fulfilled);
      check(context.toDart(context.promiseResult(promise))).equals(20);
    });

    test('resolves a Dart-created promise from outside JS', () {
      final JsPromiseCapability cap = context.newPromise();
      context.global.setProperty('p', cap.promise.dup());
      final JsValue chained = context.eval('p.then(v => v.length)');
      context.call(cap.resolve, args: <JsValue>[context.string('hello')]).dispose();
      runtime.executePendingJobs();
      check(context.toDart(context.promiseResult(chained))).equals(5);
    });

    test('frees every value when the context is disposed', () {
      for (var i = 0; i < 100; i++) {
        context.string('value $i');
      }
      check(context.liveValueCount).isGreaterOrEqual(100);
      context.dispose();
      check(context.liveValueCount).equals(0);
    });
  });

  group('resource control', () {
    test('a deadline interrupts a busy loop, even inside try/catch', () {
      final runtime = JsRuntime()..maxStackSize = safeStackLimit();
      addTearDown(runtime.dispose);
      final JsContext context = runtime.newContext();
      final int start = QuickJs.nowNanoseconds();
      runtime.deadlineNanoseconds = start + 50 * 1000 * 1000;
      try {
        context.eval('for (;;) {}');
        throw StateError('expected an interrupt');
      } on JsException catch (e) {
        check(e.kind).equals(JsErrorKind.interrupted);
        check(e.interruptReason).equals(JsInterruptReason.deadline);
      }
      final int elapsedMs = (QuickJs.nowNanoseconds() - start) ~/ 1000000;
      check(elapsedMs).isLessThan(2000);
      runtime
        ..clearInterrupt()
        ..deadlineNanoseconds = QuickJs.nowNanoseconds() + 20 * 1000 * 1000;
      check(() => context.eval('try { for (;;) {} } catch (e) { "caught" }'))
          .throws<JsException>()
          .has((JsException e) => e.kind, 'kind')
          .equals(JsErrorKind.interrupted);
    });

    test('a token requested from another isolate interrupts running code', () async {
      final token = JsInterruptToken();
      final runtime = JsRuntime(interruptToken: token)..maxStackSize = safeStackLimit();
      final JsContext context = runtime.newContext();
      final int address = token.address;
      await Isolate.spawn(_requestAfterDelay, address);
      try {
        context.eval('for (;;) {}');
        throw StateError('expected an interrupt');
      } on JsException catch (e) {
        check(e.interruptReason).equals(JsInterruptReason.requested);
      }
      // The token outlives the runtime: releasing after dispose is safe.
      runtime.dispose();
      check(token.isRequested).isTrue();
      token.release();
    });

    test('the stack limit turns deep recursion into a RangeError', () {
      final runtime = JsRuntime()..maxStackSize = 64 * 1024;
      addTearDown(runtime.dispose);
      final JsContext context = runtime.newContext();
      check(() => context.eval('function r(n) { return r(n + 1) + 1; } r(0)'))
          .throws<JsException>()
          .has((JsException e) => e.kind, 'kind')
          .equals(JsErrorKind.stackOverflow);
      check(context.eval('1 + 1').toDartString()).equals('2');
    });

    test('the memory limit stops allocation without crashing', () {
      final runtime = JsRuntime()..maxStackSize = safeStackLimit();
      addTearDown(runtime.dispose);
      final JsContext context = runtime.newContext();
      final int baseline = runtime.allocatedBytes;
      final int limit = baseline + 2 * 1024 * 1024;
      runtime.memoryLimit = limit;
      check(() => context.eval('const a = []; for (;;) a.push(new Array(1000).fill(1));'))
          .throws<JsException>()
          .has((JsException e) => e.kind, 'kind')
          .equals(JsErrorKind.outOfMemory);
      check(runtime.memoryLimitHit).isTrue();
      check(runtime.peakAllocatedBytes).isLessOrEqual(limit);
      check(runtime.memoryUsage().mallocLimit).equals(limit);
      runtime.clearInterrupt();
      check(runtime.memoryLimitHit).isFalse();
    });

    test('memory exhausted inside a promise job is still reported as such', () {
      final runtime = JsRuntime()..maxStackSize = safeStackLimit();
      addTearDown(runtime.dispose);
      final JsContext context = runtime.newContext();
      runtime.memoryLimit = runtime.allocatedBytes + 1024 * 1024;
      // Each step chains a new promise; the engine eventually cannot even
      // allocate its error and rejects with `null`.
      final JsValue p = context.eval('(function spin(n) { return Promise.resolve(n + 1).then(spin); })(0)');
      while (runtime.executePendingJobs(maxJobs: 1000).morePending) {}
      check(context.promiseState(p)).equals(JsPromiseState.rejected);
      check(runtime.memoryLimitHit).isTrue();
    });

    test('limits are rejected when not positive', () {
      final runtime = JsRuntime();
      addTearDown(runtime.dispose);
      check(() => runtime.memoryLimit = 0).throws<ArgumentError>();
      check(() => runtime.maxStackSize = -1).throws<ArgumentError>();
    });
  });
}

void _requestAfterDelay(int address) {
  sleep(const Duration(milliseconds: 50));
  JsInterruptToken.fromAddress(address)
    ..request()
    ..release();
}
