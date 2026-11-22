@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/src/aidoku/imports/js_imports.dart';
import 'package:aidoku_plugin_loader/src/aidoku/libs/host_store.dart';
import 'package:aidoku_plugin_loader/src/aidoku/libs/import_context.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:wasm3/wasm3.dart';

/// One page of exported memory (same module as js_imports_test.dart).
final Uint8List _memoryModule = Uint8List.fromList([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, //
  0x01, 0x0b, 0x02, 0x60, 0x02, 0x7f, 0x7f, 0x00, 0x60, 0x01, 0x7f, 0x01, 0x7f,
  0x03, 0x03, 0x02, 0x00, 0x01,
  0x05, 0x03, 0x01, 0x00, 0x01,
  0x07, 0x1b, 0x03,
  0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
  0x06, 0x73, 0x74, 0x6f, 0x72, 0x65, 0x38, 0x00, 0x00,
  0x05, 0x6c, 0x6f, 0x61, 0x64, 0x38, 0x00, 0x01,
  0x0a, 0x13, 0x02,
  0x09, 0x00, 0x20, 0x00, 0x20, 0x01, 0x3a, 0x00, 0x00, 0x0b,
  0x07, 0x00, 0x20, 0x00, 0x2d, 0x00, 0x00, 0x0b,
]);

/// Behaviour the former quickjs-dart engine provided beyond
/// js_imports_test.dart: `console` and `setTimeout` globals, and recursion
/// that throws instead of crashing.
void main() {
  late HostStore store;
  late Wasm3Runner runner;
  late int Function(int, int, int) evalFn;
  late int ctxRid;
  final logs = <String>[];

  setUp(() async {
    logs.clear();
    store = HostStore();
    runner = await Wasm3Runner.fromBytes(_memoryModule);
    final ctx = ImportContext(runner: runner, store: store, sourceId: 'parity', onLog: logs.add);
    final Map<String, Function> imports = buildJsImports(ctx);
    evalFn = imports['context_eval']! as int Function(int, int, int);
    ctxRid = (imports['context_create']! as int Function())();
  });

  tearDown(() {
    store.dispose();
    runner.dispose();
  });

  String? evalJs(String code) {
    final List<int> bytes = utf8.encode(code);
    runner.writeMemory(0, Uint8List.fromList(bytes));
    final int rid = evalFn(ctxRid, 0, bytes.length);
    if (rid <= 0) return null;
    return utf8.decode(store.get<BytesResource>(rid)!.bytes);
  }

  test('console methods exist and forward to the plugin log', () {
    check(evalJs('console.log("hi", 1); typeof console.warn')).equals('function');
    check(logs).any((Subject<String> it) => it.contains('hi 1'));
  });

  test('setTimeout runs its callback later on the event loop', () async {
    check(evalJs('var fired = "no"; setTimeout(function () { fired = "yes"; }, 0); typeof setTimeout')).equals(
      'function',
    );
    check(evalJs('fired')).equals('no');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    check(evalJs('fired')).equals('yes');
  });

  test('a timer pending at disposal never runs', () async {
    evalJs('setTimeout(function () { throw new Error("must not run"); }, 10)');
    store.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    check(logs).not((Subject<List<String>> it) => it.any((Subject<String> l) => l.contains('must not run')));
  });

  test('unbounded recursion returns MissingResult instead of crashing', () {
    check(evalJs('function r() { return r() + 1; } r()')).isNull();
    check(evalJs('"alive"')).equals('alive');
  });
}
