// Real-bundle QuickJS benchmark as an AOT executable (see bundle_benchmark.dart):
// stack and recursion are measured on the same kind of thread the built
// worker runs on.
//
//   dart build cli -t benchmark/bundle_benchmark_main.dart -o <dir>     (from packages/paperback_plugin_loader)
//   <dir>/bundle/bin/bundle_benchmark_main <repo>/fixtures/source_captures/paperback [out.json]
import 'dart:convert';
import 'dart:io';

import 'bundle_benchmark.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: bundle_benchmark_main <fixtures/source_captures/paperback> [out.json]');
    exitCode = 64;
    return;
  }
  final Map<String, Object?> report = await runBundleBenchmark(args.first, log: stderr.writeln);
  final String json = const JsonEncoder.withIndent('  ').convert(report);
  stdout.writeln(json);
  if (args.length > 1) File(args[1]).writeAsStringSync('$json\n');
}
