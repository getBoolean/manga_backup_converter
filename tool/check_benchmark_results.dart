// Checks that the committed KTD25 benchmark results still describe the
// committed sizing rules and the current workers (plan U8: "the committed
// results match the current worker and sizing-rule versions").
//
//   dart run tool/check_benchmark_results.dart
//
// Exits 1 when a check fails and prints every finding. CI runs it as a
// non-gating report beside the benchmarks. Nothing is measured here: it only
// compares committed files.
//
// Tachi JVM worker:
// - the sizing rule (`tachi-worker-sizing.json`) names its results files and
//   their `recordedAt`; each must exist with that timestamp;
// - every coefficient of the rule must equal the rule derived by one of the
//   results it names (a hand-edited coefficient fails);
// - a result that records its worker (`worker.version`, written since U8b)
//   must name the current worker version and host compatibility; older
//   results that predate the field are reported, not failed.
// Paperback worker:
// - `worker_plan.dart` names its real-bundle result; it must exist, its
//   profile must equal the plan's constants, and its QuickJS engine must be
//   the vendored QuickJS-ng version.
import 'dart:convert';
import 'dart:io';

final List<String> _failures = <String>[];
final List<String> _notes = <String>[];

void _fail(String message) => _failures.add(message);

Map<String, Object?> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

String _constant(String source, String name) {
  final Match? m = RegExp('$name\\s*=\\s*"?([^"\\n;]+)"?').firstMatch(source);
  if (m == null) throw StateError('$name not found');
  return m.group(1)!.trim();
}

void _checkTachi() {
  const rulePath =
      'tools/tachi-source-runner/src/main/resources/tachi-worker-sizing.json';
  final Map<String, Object?> rule = _json(rulePath);
  final source = rule['source']! as String;
  final cited = <String, Map<String, Object?>>{};
  for (final Match m in RegExp(
    r'(docs/\S+\.json) \(([^,)]+)',
  ).allMatches(source)) {
    final String path = m.group(1)!;
    final String recordedAt = m.group(2)!;
    if (!File(path).existsSync()) {
      _fail('tachi: $rulePath cites $path, which does not exist');
      continue;
    }
    final Map<String, Object?> result = _json(path);
    if (result['recordedAt'] != recordedAt) {
      _fail(
        'tachi: $path was recorded at ${result['recordedAt']}, the rule cites $recordedAt',
      );
    }
    cited[path] = result;
  }
  if (cited.isEmpty) _fail('tachi: $rulePath cites no results file');
  for (final MapEntry<String, Object?> c in rule.entries) {
    if (c.key == 'source') continue;
    final from = <String>[
      for (final MapEntry<String, Map<String, Object?>> r in cited.entries)
        if ((r.value['rule'] as Map<String, Object?>?)?[c.key] == c.value)
          r.key,
    ];
    if (from.isEmpty) {
      _fail(
        'tachi: coefficient ${c.key} = ${c.value} is not derived by any cited result',
      );
    }
  }
  final String options = File(
    'tools/tachi-source-runner/src/main/kotlin/protocol/WorkerOptions.kt',
  ).readAsStringSync();
  final String version = _constant(options, 'WORKER_VERSION');
  final String compatibility = _constant(options, 'HOST_COMPATIBILITY');
  for (final MapEntry<String, Map<String, Object?>> r in cited.entries) {
    final worker = r.value['worker'] as Map<String, Object?>?;
    if (worker == null) {
      _notes.add(
        'tachi: ${r.key} predates the recorded worker identity; its worker version is not checked',
      );
      continue;
    }
    if (worker['version'] != version) {
      _fail(
        'tachi: ${r.key} measured worker ${worker['version']}, current is $version',
      );
    }
    if (worker['hostCompatibility'] != compatibility) {
      _fail(
        'tachi: ${r.key} measured host ${worker['hostCompatibility']}, current is $compatibility',
      );
    }
  }
  _notes.add('tachi: rule coefficients come from ${cited.keys.join(', ')}');
}

void _checkPaperback() {
  const planPath = 'packages/paperback_plugin_loader/lib/src/worker_plan.dart';
  final String plan = File(planPath).readAsStringSync();
  final Match? cite = RegExp(r'benchmark/results/(\S+\.json)').firstMatch(plan);
  if (cite == null) {
    _fail('paperback: $planPath cites no results file');
    return;
  }
  final path =
      'packages/paperback_plugin_loader/benchmark/results/${cite.group(1)}';
  if (!File(path).existsSync()) {
    _fail('paperback: $planPath cites $path, which does not exist');
    return;
  }
  final Map<String, Object?> result = _json(path);
  final profile = result['profile']! as Map<String, Object?>;
  for (final (String key, String constant) in const <(String, String)>[
    ('peakHeapBytes', '_peakHeapBytes'),
    ('peakStackBytes', '_peakStackBytes'),
    ('slowestOperationMicros', '_slowestOperationMicros'),
    ('referenceCalibrationMicros', '_referenceCalibrationMicros'),
  ]) {
    final int planned = int.parse(_constant(plan, constant));
    if (profile[key] != planned) {
      _fail('paperback: $path $key = ${profile[key]}, $planPath has $planned');
    }
  }
  final String header = File('packages/quickjs/vendor/quickjs/quickjs.h')
      .readAsStringSync();
  String part(String name) =>
      RegExp('#define QJS_VERSION_$name (\\d+)').firstMatch(header)!.group(1)!;
  final engine = '${part('MAJOR')}.${part('MINOR')}.${part('PATCH')}';
  if (result['engine'] != engine) {
    _fail(
      'paperback: $path measured QuickJS ${result['engine']}, vendored is $engine',
    );
  }
  _notes.add('paperback: profile and engine match $path');
}

void main() {
  for (final check in <void Function()>[
    _checkTachi,
    _checkPaperback,
  ]) {
    try {
      check();
    } on Object catch (e) {
      _fail('$e');
    }
  }
  _notes.forEach(stdout.writeln);
  for (final String f in _failures) {
    stderr.writeln('FAIL $f');
  }
  stdout.writeln(
    _failures.isEmpty
        ? 'benchmark results match the current rules and workers'
        : '${_failures.length} failure(s)',
  );
  if (_failures.isNotEmpty) exitCode = 1;
}
