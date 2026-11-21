import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:path/path.dart' as p;
import 'package:source_loaders/source_loaders.dart';
import 'package:source_runtime/source_runtime.dart';

export 'package:source_loaders/source_loaders.dart' show PaperbackPluginLoader;

/// The hidden subcommand under which the CLI executable runs the Paperback
/// worker, so the desktop build ships one binary (`dart build cli` bundles the
/// QuickJS native asset for it).
const String paperbackWorkerCommand = '__paperback-worker';

/// Why this process cannot run the Paperback worker, or `null` when it can:
/// the worker is this executable re-launched, and under `dart run` (or the
/// Flutter test runner) the resolved executable has no such command.
SourceFailure? paperbackWorkerUnavailable() {
  final String exe = p.basenameWithoutExtension(Platform.resolvedExecutable).toLowerCase();
  return exe == 'dart' || exe == 'flutter_tester'
      ? const RuntimeUnavailableFailure(
          'Paperback sources need the built CLI executable (dart build cli); they cannot run under dart run',
        )
      : null;
}

/// The desktop composition: the CLI executable re-launched as the worker
/// ([paperbackWorkerCommand]) with limits from the KTD25 sizing rule, an
/// artifact cache under [cacheRoot], and the live network.
PaperbackPluginLoader desktopPaperbackLoader({
  required String cacheRoot,
  void Function(SettingsSnapshot settings)? onSettings,
  void Function(String line)? onLog,
  ExtensionSettingsProvider settingsFor = noExtensionSettings,
}) {
  final client = http.Client();
  WorkerSupervisor? supervisor;
  return PaperbackPluginLoader(
    client: client,
    cache: ArtifactCache(Directory(p.join(cacheRoot, 'paperback_artifacts'))),
    onSettings: onSettings,
    settingsFor: settingsFor,
    worker: (ConversionOwner? owner) async {
      if (supervisor == null) {
        final SourceFailure? unavailable = paperbackWorkerUnavailable();
        if (unavailable != null) return SourceFailed<WorkerSupervisor>(unavailable);
        final PaperbackWorkerPlan plan = planPaperbackWorker();
        // KTD25: record the rule, its inputs and the derived limits, and any
        // cap that left a limit below the measured need.
        onLog?.call('[paperback] sizing ${jsonEncode(plan.sizing.toJson())}');
        for (final String warning in plan.sizing.warnings) {
          onLog?.call('[paperback] sizing warning: $warning');
        }
        final created = WorkerSupervisor(
          spec: WorkerSpec(
            label: 'paperback',
            executable: Platform.resolvedExecutable,
            arguments: <String>[paperbackWorkerCommand, ...plan.arguments],
            environment: scrubbedEnvironment(),
          ),
          // The worker reports its supervisor-side deadline (engine
          // deadline plus measured headroom); the rest are not QuickJS
          // limits and come from the desktop policy (KTD4).
          limits: AdoptWorkerLimits(
            handshakeDeadline: plan.handshakeDeadline,
            maxConcurrentPackages: 1,
            cancelGrace: plan.cancelGrace,
            interactionTimeout: const Duration(minutes: 5),
            shutdownGrace: plan.cancelGrace,
          ),
          onLog: onLog,
        );
        supervisor = created;
        await owner?.adopt(() async {
          await created.close();
          client.close();
        });
      }
      final WorkerSupervisor s = supervisor!;
      return (await s.start()).map((_) => s);
    },
  );
}
