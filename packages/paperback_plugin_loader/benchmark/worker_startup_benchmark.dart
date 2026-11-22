// Paperback worker start-up benchmark (KTD25): launch → handshake reply, the
// one bound the supervisor needs before the worker has reported anything.
// Measures both launchers the hosts use, as they launch them:
//
// - desktop: the built CLI executable re-launched with its hidden worker
//   subcommand and the plan's limit arguments;
// - in-app: the worker isolate (`isolatePaperbackLauncher`).
//
// Built and run as an AOT executable, like the bundle benchmark:
//
//   dart build cli -t benchmark/worker_startup_benchmark.dart -o <dir>   (from packages/paperback_plugin_loader)
//   <dir>/bundle/bin/worker_startup_benchmark <cli-exe> <worker-subcommand> [runs] [out.json]
//
// The CLI executable is `dart build cli` of packages/mangabackupconverter_cli;
// its worker subcommand is `__paperback-worker`. Nothing contacts a server.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

http.Client _noNetwork() => http.Client();

Future<List<double>> _measure(int runs, WorkerSupervisor Function() create) async {
  final samples = <double>[];
  for (var i = 0; i < runs; i++) {
    final WorkerSupervisor supervisor = create();
    final watch = Stopwatch()..start();
    final SourceOutcome<void> started = await supervisor.start();
    watch.stop();
    await supervisor.close();
    if (started case SourceFailed<void>(:final SourceFailure failure)) {
      throw StateError('run $i did not start: $failure');
    }
    samples.add(watch.elapsedMicroseconds / 1000);
  }
  return samples;
}

Map<String, Object?> _summary(List<double> samples) {
  final sorted = List<double>.of(samples)..sort();
  return <String, Object?>{
    'runs': samples.length,
    'medianMs': sorted[sorted.length ~/ 2],
    'maxMs': sorted.last,
    'samplesMs': samples,
  };
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: worker_startup_benchmark <cli-exe> <worker-subcommand> [runs] [out.json]');
    exitCode = 64;
    return;
  }
  final String exe = args[0];
  final String subcommand = args[1];
  final int runs = args.length > 2 ? int.parse(args[2]) : 15;
  final PaperbackWorkerPlan plan = planPaperbackWorker();
  // The plan's limits, with a handshake bound generous only for the
  // measurement (the result sizes the real one).
  final limits = AdoptWorkerLimits(
    handshakeDeadline: const Duration(minutes: 2),
    maxConcurrentPackages: 1,
    cancelGrace: plan.cancelGrace,
    interactionTimeout: const Duration(minutes: 5),
    shutdownGrace: plan.cancelGrace,
  );

  final List<double> desktop = await _measure(
    runs,
    () => WorkerSupervisor(
      spec: WorkerSpec(
        label: 'paperback',
        executable: exe,
        arguments: <String>[subcommand, ...plan.arguments],
        environment: scrubbedEnvironment(),
      ),
      limits: limits,
    ),
  );
  final List<double> isolate = await _measure(
    runs,
    () => WorkerSupervisor(
      spec: const WorkerSpec(label: 'paperback', executable: 'in-app isolate'),
      limits: limits,
      launcher: isolatePaperbackLauncher(
        PaperbackIsolateWorkerConfig(
          limits: plan.sizing.limits,
          deadlineHeadroom: plan.deadlineHeadroom,
          clientFactory: _noNetwork,
          browserEnabled: false,
        ),
      ),
    ),
  );
  final report = <String, Object?>{
    'measuredAt': DateTime.now().toUtc().toIso8601String(),
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'processors': Platform.numberOfProcessors,
    'calibrationMicros': plan.sizing.device.calibration.inMicroseconds,
    'desktopProcess': _summary(desktop),
    'inAppIsolate': _summary(isolate),
  };
  final String json = const JsonEncoder.withIndent('  ').convert(report);
  stdout.writeln(json);
  if (args.length > 3) File(args[3]).writeAsStringSync('$json\n');
}
