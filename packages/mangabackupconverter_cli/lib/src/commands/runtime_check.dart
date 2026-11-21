import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview/desktop_webview.dart';
import 'package:mangabackupconverter_cli/src/commands/desktop_runtime.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_paperback.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart' show planPaperbackWorker, PaperbackWorkerPlan;
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart' show TachiWorkerLocation;

/// The hidden subcommand the packaging smoke test runs
/// (`scripts/smoke_packaged_cli.dart`).
const String runtimeCheckCommand = '__runtime-check';

/// Starts every bundled runtime the way a conversion does, without any
/// source, repository or network access, and prints one JSON line:
/// the JVM worker (handshake: Java version, pid), the Paperback worker (this
/// executable re-launched; QuickJS loads), and the desktop WebView helper
/// (offline; one session loads local HTML and evaluates a script).
///
/// Then it closes them all, as a conversion's owner does, and exits; with
/// `--hold` it first waits until stdin closes (a smoke test can instead kill
/// this process to check that nothing it owns outlives it).
Future<void> runRuntimeCheck(List<String> args) async {
  final bool hold = args.contains('--hold');
  final report = <String, Object?>{'executable': Platform.resolvedExecutable};
  final Directory? runtime = packagedRuntimeDirectory();
  report['runtimeDirectory'] = runtime?.path;
  final scopes = <ConversionRuntimeScope>[];
  DesktopBrowserPort? browser;
  var ok = true;
  try {
    // JVM worker.
    final String? tachiManifest = packagedTachiManifest();
    final SourceOutcome<TachiWorkerLocation> located = TachiWorkerLocation.resolve(
      manifestPath: tachiManifest,
      searchFrom: File(Platform.script.toFilePath()).parent,
    );
    switch (located) {
      case SourceFailed<TachiWorkerLocation>(:final SourceFailure failure):
        ok = false;
        report['tachi'] = <String, Object?>{'error': failure.toString()};
      case SourceSuccess<TachiWorkerLocation>(value: final TachiWorkerLocation location):
        final scope = ConversionRuntimeScope(
          workers: <WorkerKind, WorkerSpec>{WorkerKind.jvm: location.spec(browser: false)},
          limits: location.limits,
        );
        scopes.add(scope);
        final SourceOutcome<WorkerSupervisor> started = await scope.worker(WorkerKind.jvm);
        report['tachi'] = switch (started) {
          SourceSuccess<WorkerSupervisor>(value: final WorkerSupervisor s) => <String, Object?>{
            'java': location.java,
            'pid': s.handshake?.pid,
            'protocol': '${s.handshake?.protocolVersion}.${s.handshake?.protocolMinor}',
          },
          SourceFailed<WorkerSupervisor>(:final SourceFailure failure) => <String, Object?>{'error': '$failure'},
        };
        ok = ok && started is SourceSuccess<WorkerSupervisor>;
    }

    // Paperback worker: this executable re-launched.
    final PaperbackWorkerPlan plan = planPaperbackWorker();
    final paperback = ConversionRuntimeScope(
      workers: <WorkerKind, WorkerSpec>{
        WorkerKind.paperback: WorkerSpec(
          label: 'paperback',
          executable: Platform.resolvedExecutable,
          arguments: <String>[paperbackWorkerCommand, ...plan.arguments],
          environment: scrubbedEnvironment(),
        ),
      },
      limits: AdoptWorkerLimits(
        handshakeDeadline: plan.handshakeDeadline,
        maxConcurrentPackages: 1,
        cancelGrace: plan.cancelGrace,
        interactionTimeout: CliBrowserPolicy.interactionTimeout,
        shutdownGrace: plan.cancelGrace,
      ),
    );
    scopes.add(paperback);
    final SourceOutcome<WorkerSupervisor> pb = await paperback.worker(WorkerKind.paperback);
    report['paperback'] = switch (pb) {
      SourceSuccess<WorkerSupervisor>(value: final WorkerSupervisor s) => <String, Object?>{
        'pid': s.handshake?.pid,
        'protocol': '${s.handshake?.protocolVersion}.${s.handshake?.protocolMinor}',
      },
      SourceFailed<WorkerSupervisor>(:final SourceFailure failure) => <String, Object?>{'error': '$failure'},
    };
    ok = ok && pb is SourceSuccess<WorkerSupervisor>;

    // Desktop WebView helper, offline.
    final Directory dataRoot = await Directory.systemTemp.createTemp('mbc-runtime-check-');
    final (DesktopBrowserPort? port, String? why) = createCliBrowserPort(
      interactive: false,
      dataRoot: dataRoot,
      manifest: locateWebViewHelperManifest(searchFrom: File(Platform.script.toFilePath()).parent),
      offline: true,
    );
    browser = port;
    if (port == null) {
      ok = false;
      report['helper'] = <String, Object?>{'error': why};
    } else {
      const source = SourceIdentity(
        ecosystem: 'runtime-check',
        packageId: 'runtime-check',
        sourceId: 'runtime-check',
        artifact: ArtifactBinding(sha256: '00', kind: 'none', version: '0'),
      );
      final BrowserOutcome<BrowserSession> opened = await port.openSession(
        const BrowserSessionRequest(source: source, generation: 1),
      );
      String? title;
      if (opened case BrowserCompleted<BrowserSession>(value: final BrowserSession s)) {
        await s.loadData(
          '<html><head><title>ok</title></head></html>',
          baseUrl: Uri.parse('https://runtime-check.invalid/'),
        );
        title = (await s.evaluate('document.title')).valueOrNull;
        await s.close();
      }
      report['helper'] = <String, Object?>{
        'pid': port.helperInfo?.pid,
        'engine': port.helperInfo?.engine,
        'engineVersion': port.helperInfo?.engineVersion,
        'title': title,
      };
      ok = ok && title == '"ok"';
    }
    report['ok'] = ok;
    stdout.writeln(jsonEncode(report));
    await stdout.flush();
    if (hold) await stdin.drain<void>();
  } finally {
    for (final s in scopes) {
      await s.close();
    }
    await browser?.dispose();
  }
  exitCode = ok ? 0 : 1;
}
