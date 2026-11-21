// Records Paperback qualification captures through the worker's record mode.
//
// MANUAL TOOL. No test runs it, and CI must never run it: it is the only
// Paperback code path allowed to reach a live source server. Tests replay
// the committed captures through the same worker in `--replay` mode.
//
// Usage (from packages/paperback_plugin_loader):
//   dart run tool/capture_paperback_sources.dart <site>...      (mangadex, weebcentral, mangafire)
//
// For each site it builds the worker executable once (`dart build cli`),
// starts it with `--record=fixtures/source_captures/paperback/<site>`, and
// runs `runSiteScenario` for every pinned bundle of that site, from both API
// families, in that one worker session: search, the next page when the
// source returned pagination metadata, then details with chapters. Requests
// are spaced at least 1.5 s apart. The worker writes `capture.json` and
// `bodies/` when it shuts down; this tool also writes `scenario.json` with
// what each bundle returned, and `tool/sanitize_captures.dart` strips
// client-identifying data (challenge tokens, ray IDs) from the bodies.
// Bundles come from the committed fixtures and are admitted against their
// pinned SHA-256; nothing else is downloaded.
//
// No browser port is attached, so a source that needs `executeInWebView`
// records only the requests it makes before that call.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

import '../test/support/paperback_scenarios.dart';
import 'sanitize_captures.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.any((String s) => !captureSites.containsKey(s))) {
    stderr.writeln('usage: capture_paperback_sources.dart <${captureSites.keys.join('|')}>...');
    exitCode = 64;
    return;
  }
  final Directory build = Directory.systemTemp.createTempSync('paperback_worker_build');
  final String exe = await _buildWorker(build);
  try {
    for (final site in args) {
      await _capture(site, exe);
    }
  } finally {
    build.deleteSync(recursive: true);
  }
}

Future<String> _buildWorker(Directory out) async {
  final ProcessResult r = await Process.run(Platform.resolvedExecutable, <String>[
    'build',
    'cli',
    '-t',
    'bin/paperback_source_worker.dart',
    '-o',
    out.path,
    '--verbosity=error',
  ]);
  if (r.exitCode != 0) throw StateError('dart build cli failed:\n${r.stdout}\n${r.stderr}');
  return Directory('${out.path}/bundle/bin').listSync().whereType<File>().single.path;
}

Future<void> _capture(String site, String exe) async {
  final dir = Directory('${paperbackFixtures().path}/$site');
  stdout.writeln('== $site -> ${dir.path}');
  final supervisor = WorkerSupervisor(
    spec: WorkerSpec(
      label: 'paperback-capture',
      executable: exe,
      arguments: <String>[
        '--memory-limit-bytes=${256 << 20}',
        '--max-stack-bytes=${512 << 10}',
        '--operation-deadline-ms=600000',
        '--job-slice-ms=20',
        '--deadline-headroom-ms=1000',
        '--record=${dir.path}',
        '--record-source=$site',
        '--record-min-interval-ms=1500',
        '--record-licence=${captureTerms[site]}',
      ],
      environment: scrubbedEnvironment(),
    ),
    limits: const SupervisorLimits(
      maxConcurrentPackages: 1,
      operationDeadline: Duration(minutes: 11),
      cancelGrace: Duration(seconds: 10),
      interactionTimeout: Duration(seconds: 10),
      shutdownGrace: Duration(minutes: 1),
    ),
    onLog: stderr.writeln,
  );
  final Directory cacheDir = Directory.systemTemp.createTempSync('paperback_capture_cache');
  final repos = <PinnedRepository>[for (final PinnedBundle b in captureSites[site]!) PinnedRepository.load(b.repoDir)];
  final client = http.Client();
  final provider = PaperbackSourceProvider(
    // Catalogs and bundles come from the fixtures; this client is never used
    // by the scenario.
    client: client,
    cache: ArtifactCache(cacheDir),
    trust: PinnedRepository.pinnedTrust(repos),
    worker: () async => (await supervisor.start()).map((_) => supervisor),
  );
  try {
    final List<BundleRun> runs = await runSiteScenario(provider, site);
    final String report = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'site': site,
      'query': qualificationQuery,
      'recordedAt': DateTime.now().toUtc().toIso8601String(),
      'runs': <Object?>[for (final BundleRun r in runs) r.toJson()],
    });
    stdout.writeln(report);
    // The worker writes the capture on shutdown; strip client-identifying
    // data before anything is committed.
    await supervisor.close();
    sanitizeCaptureDir(dir);
    File('${dir.path}/scenario.json').writeAsStringSync('$report\n');
  } finally {
    await supervisor.close();
    client.close();
    cacheDir.deleteSync(recursive: true);
  }
}
