import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

/// How to start a worker process.
@immutable
final class WorkerSpec {
  const WorkerSpec({
    required this.label,
    required this.executable,
    this.arguments = const <String>[],
    this.environment = const <String, String>{},
    this.workingDirectory,
  });

  /// Short name used in logs, for example `jvm` or `paperback`.
  final String label;
  final String executable;
  final List<String> arguments;

  /// The complete environment. The parent environment is never inherited
  /// (KTD9); build this with [scrubbedEnvironment].
  final Map<String, String> environment;
  final String? workingDirectory;
}

/// A running worker process. Implemented over `dart:io` by
/// [launchWorkerProcess]; tests may wrap it to observe launches.
abstract interface class WorkerProcess {
  int get pid;

  Stream<List<int>> get stdout;

  Stream<List<int>> get stderr;

  IOSink get stdin;

  Future<int> get exitCode;

  /// Terminates the process. Returns whether a signal was sent.
  bool kill();
}

/// Starts a worker. Injected into the supervisor so tests and platforms can
/// control process creation.
typedef WorkerLauncher = Future<WorkerProcess> Function(WorkerSpec spec);

/// Variables a worker may inherit from the parent environment. Everything
/// else (tokens, home and backup paths, proxies with credentials) is dropped.
/// `SystemRoot` and `windir` are required for Windows processes to start.
const List<String> defaultEnvironmentAllowlist = <String>[
  'SystemRoot',
  'windir',
  'TEMP',
  'TMP',
  'TMPDIR',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'TZ',
];

/// Builds a scrubbed worker environment: allowlisted parent variables plus
/// [extra]. Lookups are case-insensitive on Windows, like the OS.
Map<String, String> scrubbedEnvironment({
  Map<String, String> extra = const <String, String>{},
  Iterable<String> allow = defaultEnvironmentAllowlist,
  Map<String, String>? parent,
}) {
  final Map<String, String> source = parent ?? Platform.environment;
  final byUpper = <String, String>{
    for (final MapEntry<String, String> e in source.entries) e.key.toUpperCase(): e.value,
  };
  return <String, String>{
    for (final String name in allow)
      if (Platform.isWindows ? byUpper[name.toUpperCase()] : source[name] case final String value) name: value,
    ...extra,
  };
}

/// Launches [spec] with `dart:io`, never inheriting the parent environment.
Future<WorkerProcess> launchWorkerProcess(WorkerSpec spec) async {
  final Process process = await Process.start(
    spec.executable,
    spec.arguments,
    environment: spec.environment,
    includeParentEnvironment: false,
    workingDirectory: spec.workingDirectory,
  );
  return _IoWorkerProcess(process);
}

final class _IoWorkerProcess implements WorkerProcess {
  _IoWorkerProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  IOSink get stdin => _process.stdin;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill() => _process.kill(ProcessSignal.sigkill);
}
