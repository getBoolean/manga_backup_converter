import 'dart:async';
import 'dart:io';

import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';

/// Paperback desktop worker process (protocol v1 over stdin/stdout).
///
/// Every QuickJS limit is a required argument (KTD25); the supervisor derives
/// them from the sizing rule for this device:
///
///     paperback_source_worker --memory-limit-bytes=N --max-stack-bytes=N
///         --operation-deadline-ms=N --job-slice-ms=N
///
/// stdout carries protocol frames only; logs and `print` go to stderr.
Future<void> main(List<String> args) async {
  final PaperbackRuntimeLimits limits;
  try {
    limits = parseLimitArguments(args);
  } on FormatException catch (e) {
    stderr.writeln('paperback_source_worker: ${e.message}');
    exitCode = 64;
    return;
  }
  await runZoned(
    () => PaperbackSourceWorker(
      input: stdin,
      output: stdout,
      limits: limits,
      pid: pid,
      log: stderr.writeln,
    ).run(),
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) => stderr.writeln(line),
    ),
  );
}

/// Parses `--name=value` limit arguments; all four are required.
PaperbackRuntimeLimits parseLimitArguments(List<String> args) {
  final values = <String, int>{};
  for (final arg in args) {
    final Match? m = RegExp(r'^--([a-z-]+)=(\d+)$').firstMatch(arg);
    if (m == null) throw FormatException('Unrecognized argument "$arg"');
    values[m.group(1)!] = int.parse(m.group(2)!);
  }
  int required(String name) {
    final int? value = values[name];
    if (value == null) throw FormatException('Missing required --$name');
    if (value <= 0) throw FormatException('--$name must be positive');
    return value;
  }

  return PaperbackRuntimeLimits(
    memoryLimitBytes: required('memory-limit-bytes'),
    maxStackBytes: required('max-stack-bytes'),
    operationDeadline: Duration(milliseconds: required('operation-deadline-ms')),
    jobSlice: Duration(milliseconds: required('job-slice-ms')),
  );
}
