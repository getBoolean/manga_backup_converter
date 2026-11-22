import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';

/// Resolves the SDK's real `dart` executable. Under `flutter test`,
/// `Platform.resolvedExecutable` is `flutter_tester`, so walk up to the
/// Flutter cache's `dart-sdk`. The `dart.bat` shim is never used: killing a
/// shim would orphan the worker.
String resolveDartExecutable() {
  final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
  final String exe = Platform.resolvedExecutable;
  final String base = p.basenameWithoutExtension(exe);
  if (base == 'dart') return exe;
  final sibling = File(p.join(p.dirname(exe), exeName));
  if (sibling.existsSync()) return sibling.path;
  Directory dir = File(exe).parent;
  while (true) {
    final candidate = File(p.join(dir.path, 'dart-sdk', 'bin', exeName));
    if (candidate.existsSync()) return candidate.path;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final candidate = File(p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', exeName));
    if (candidate.existsSync()) return candidate.path;
  }
  throw StateError('Cannot locate the Dart SDK executable from $exe');
}

File _fakeWorkerSource() {
  for (final candidate in <String>[
    p.join('test', 'fixtures', 'fake_worker.dart'),
    p.join('packages', 'source_runtime', 'test', 'fixtures', 'fake_worker.dart'),
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file;
  }
  throw StateError('fake_worker.dart not found from ${Directory.current.path}');
}

Future<String>? _compiled;

/// Compiles the fake worker to a native executable once per source revision,
/// so the supervised PID is the worker itself (no launcher child process).
Future<String> compileFakeWorker() => _compiled ??= () async {
  final File source = _fakeWorkerSource();
  final String digest = sha256.convert(source.readAsBytesSync()).toString().substring(0, 16);
  final dir = Directory(p.join(Directory.systemTemp.path, 'source_runtime_fake_worker', digest));
  final out = File(p.join(dir.path, Platform.isWindows ? 'fake_worker.exe' : 'fake_worker'));
  if (out.existsSync()) return out.path;
  dir.createSync(recursive: true);
  final ProcessResult result = await Process.run(resolveDartExecutable(), <String>[
    'compile',
    'exe',
    source.absolute.path,
    '-o',
    out.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Compiling the fake worker failed:\n${result.stdout}\n${result.stderr}');
  }
  return out.path;
}();

/// A worker process observed by a [RecordingLauncher].
final class LaunchedWorker {
  LaunchedWorker(this.process) {
    unawaited(process.exitCode.then((int code) => exited = true));
  }

  final WorkerProcess process;
  bool exited = false;
}

/// Launches real fake-worker processes and records each one, so tests can
/// assert that no process outlives its owner. [gate], when set, delays the
/// launch result until completed (a startup that completes late).
class RecordingLauncher {
  RecordingLauncher();

  final List<LaunchedWorker> launched = <LaunchedWorker>[];
  Completer<void>? gate;

  Future<WorkerProcess> call(WorkerSpec spec) async {
    final WorkerProcess process = await launchWorkerProcess(spec);
    launched.add(LaunchedWorker(process));
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    return process;
  }

  /// Whether every launched process has exited.
  bool get allExited => launched.every((LaunchedWorker w) => w.exited);

  /// Waits (bounded) for every launched process to exit.
  Future<bool> waitAllExited({Duration timeout = const Duration(seconds: 10)}) async {
    try {
      await Future.wait(<Future<int>>[for (final LaunchedWorker w in launched) w.process.exitCode]).timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

/// Wraps a launcher so each worker's exit is reported [delay] late, leaving a
/// window in which the supervisor writes to a dead worker's stdin.
class DelayedExitLauncher {
  DelayedExitLauncher(this._inner, {required this.delay});

  final RecordingLauncher _inner;
  final Duration delay;

  Future<WorkerProcess> call(WorkerSpec spec) async => _DelayedExitProcess(await _inner.call(spec), delay);
}

final class _DelayedExitProcess implements WorkerProcess {
  _DelayedExitProcess(this._inner, Duration delay)
    : exitCode = _inner.exitCode.then((int code) => Future<int>.delayed(delay, () => code));

  final WorkerProcess _inner;

  @override
  final Future<int> exitCode;

  @override
  int get pid => _inner.pid;

  @override
  Stream<List<int>> get stdout => _inner.stdout;

  @override
  Stream<List<int>> get stderr => _inner.stderr;

  @override
  IOSink get stdin => _inner.stdin;

  @override
  bool kill() => _inner.kill();
}

/// Spec for the compiled fake worker with a scrubbed environment.
WorkerSpec fakeWorkerSpec(String executable, {List<String> arguments = const <String>[], String label = 'fake'}) =>
    WorkerSpec(label: label, executable: executable, arguments: arguments, environment: scrubbedEnvironment());

/// Small limits for contract tests (KTD25: overrides, not shipped values).
SupervisorLimits testLimits({
  int maxConcurrentPackages = 2,
  Duration operationDeadline = const Duration(seconds: 10),
  Duration cancelGrace = const Duration(milliseconds: 400),
  Duration interactionTimeout = const Duration(seconds: 5),
  Duration shutdownGrace = const Duration(seconds: 2),
  int maxFrameBytes = protocolMaxFrameBytes,
}) => SupervisorLimits(
  maxConcurrentPackages: maxConcurrentPackages,
  operationDeadline: operationDeadline,
  cancelGrace: cancelGrace,
  interactionTimeout: interactionTimeout,
  shutdownGrace: shutdownGrace,
  maxFrameBytes: maxFrameBytes,
);
