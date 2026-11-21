// Real-bundle QuickJS benchmark under `flutter test` (see bundle_benchmark.dart).
//
// Run from the repository root:
//   QJS_BENCH_OUT=packages/paperback_plugin_loader/benchmark/results/<date>-<os>-bundles-jit.json \
//     flutter test packages/paperback_plugin_loader/benchmark/paperback_bundles_benchmark_test.dart
// Non-gating: timing is never asserted.
@TestOn('vm')
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/scaffolding.dart';

import '../test/support/paperback_scenarios.dart';
import 'bundle_benchmark.dart';

void main() {
  test('Paperback real-bundle QuickJS benchmark', () async {
    final Map<String, Object?> report = await runBundleBenchmark(paperbackFixtures().path, log: stderr.writeln);
    final String json = const JsonEncoder.withIndent('  ').convert(report);
    stdout.writeln(json);
    final String? out = Platform.environment['QJS_BENCH_OUT'];
    if (out != null) File(out).writeAsStringSync('$json\n');
  });
}
