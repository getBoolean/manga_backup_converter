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

/// This executable re-launched as the Paperback worker with [plan]'s limit
/// arguments (plus [extra]), in a scrubbed environment.
WorkerSpec desktopPaperbackWorkerSpec(PaperbackWorkerPlan plan, [List<String> extra = const <String>[]]) => WorkerSpec(
  label: 'paperback',
  executable: Platform.resolvedExecutable,
  arguments: <String>[paperbackWorkerCommand, ...plan.arguments, ...extra],
  environment: scrubbedEnvironment(),
);

/// The desktop composition: the CLI executable re-launched as the worker
/// ([paperbackWorkerCommand]) with limits from the KTD25 sizing rule, an
/// artifact cache under [cacheRoot], and the live network.
///
/// The worker runs in its own [ConversionRuntimeScope], so with a
/// [browserPort] its `host.browser.*` reverse requests (`executeInWebView`,
/// Cloudflare bypass) are served through a [BrowserReverseBridge]; each
/// bundle may open sessions only for its own sources
/// ([PaperbackPluginLoader.browserIdentity]). Closing the conversion owner
/// closes the worker, then the bridge's sessions.
///
/// Tests inject [client] (catalogs and bundles), [launcher] (for example an
/// in-process worker over replayed captures) and [workerArguments]; with a
/// [launcher] the built-executable check is skipped.
PaperbackPluginLoader desktopPaperbackLoader({
  required String cacheRoot,
  required Duration interactionTimeout,
  PluginByteCache? cache,
  void Function(SettingsSnapshot settings)? onSettings,
  void Function(String line)? onLog,
  ExtensionSettingsProvider settingsFor = noExtensionSettings,
  BrowserPort? browserPort,
  Duration? browserReplacementTimeout,
  http.Client? client,
  WorkerLauncher? launcher,
  List<String> workerArguments = const <String>[],
  Redactor? redactor,
}) {
  final http.Client httpClient = client ?? http.Client();
  ConversionRuntimeScope? scope;
  late final PaperbackPluginLoader loader;
  return loader = PaperbackPluginLoader(
    client: httpClient,
    artifacts: ArtifactCache(Directory(p.join(cacheRoot, 'paperback_artifacts'))),
    cache: cache,
    onSettings: onSettings,
    settingsFor: settingsFor,
    worker: (ConversionOwner? owner) async {
      if (scope == null) {
        if (launcher == null) {
          final SourceFailure? unavailable = paperbackWorkerUnavailable();
          if (unavailable != null) return SourceFailed<WorkerSupervisor>(unavailable);
        }
        final PaperbackWorkerPlan plan = planPaperbackWorker();
        // KTD25: record the rule, its inputs and the derived limits, and any
        // cap that left a limit below the measured need.
        onLog?.call('[paperback] sizing ${jsonEncode(plan.sizing.toJson())}');
        for (final String warning in plan.sizing.warnings) {
          onLog?.call('[paperback] sizing warning: $warning');
        }
        final created = ConversionRuntimeScope(
          workers: <WorkerKind, WorkerSpec>{
            WorkerKind.paperback: desktopPaperbackWorkerSpec(plan, workerArguments),
          },
          limits: plan.adoptLimits(interactionTimeout: interactionTimeout),
          launcher: launcher,
          browserPort: browserPort,
          resolveBrowserSource: (WorkerKind kind, String? packageId, String sourceId) =>
              kind == WorkerKind.paperback ? loader.browserIdentity(packageId, sourceId) : null,
          browserReplacementTimeout: browserReplacementTimeout,
          onLog: onLog,
          redactor: redactor,
        );
        scope = created;
        await owner?.adopt(() async {
          await created.close();
          httpClient.close();
        });
      }
      return scope!.worker(WorkerKind.paperback);
    },
  );
}
