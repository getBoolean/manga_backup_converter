// Records Paperback qualification captures through the worker's record mode.
//
// MANUAL TOOL. No test runs it, and CI must never run it: it is the only
// Paperback code path allowed to reach a live source server. Tests replay
// the committed captures through the same worker in `--replay` mode.
//
// Usage (from packages/paperback_plugin_loader):
//   dart run tool/capture_paperback_sources.dart <site>...      (mangadex, weebcentral, mangafire, mangahub)
//
// Re-recording one bundle without touching the other bundles' exchanges:
//   dart run tool/capture_paperback_sources.dart <site> --only=<repo>/<id> --out=<empty dir>
//   (inspect <empty dir>, then)
//   dart run tool/capture_paperback_sources.dart <site> --only=<repo>/<id> --merge=<that dir>
// `--out` records and sanitises into a directory outside the fixtures.
// `--merge` replaces the committed exchanges the new recording also holds,
// and the redirect chains they started, with the new ones; drops orphaned
// bodies; replaces that bundle's entry in `scenario.json`; and notes the
// second session in `capture.json`. A bundle new to the site has its
// `scenario.json` entry appended.
//
// Retiring a bundle from a site's capture (after removing it from
// `captureSites`):
//   dart run tool/capture_paperback_sources.dart <site> --drop=<repo>/<id> --prune
// `--drop` removes that bundle's `scenario.json` entry; `--prune` replays
// the site's scenario offline against the committed capture and deletes the
// exchanges (and bodies) no remaining bundle requested. Neither contacts a
// server.
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
  String? flag(String name) =>
      args.where((String a) => a.startsWith('--$name=')).map((String a) => a.substring(name.length + 3)).firstOrNull;
  final List<String> sites = args.where((String a) => !a.startsWith('--')).toList();
  final String? only = flag('only');
  final String? out = flag('out');
  final String? merge = flag('merge');
  final String? drop = flag('drop');
  final bool prune = args.contains('--prune');
  final bool usage =
      sites.isEmpty ||
      sites.any((String s) => !captureSites.containsKey(s)) ||
      (only != null && (sites.length != 1 || !captureSites[sites.single]!.any((PinnedBundle b) => b.label == only))) ||
      ((out != null || merge != null) && only == null) ||
      (out != null && merge != null) ||
      ((drop != null || prune) && (sites.length != 1 || only != null || out != null || merge != null));
  if (usage) {
    stderr.writeln(
      'usage: capture_paperback_sources.dart <${captureSites.keys.join('|')}>... '
      '[--only=<repo>/<id> (--out=<dir> | --merge=<dir>)] | <site> [--drop=<repo>/<id>] [--prune]',
    );
    exitCode = 64;
    return;
  }
  if (drop != null || prune) {
    final dir = Directory('${paperbackFixtures().path}/${sites.single}');
    if (drop != null) _drop(dir, drop);
    if (prune) await _prune(dir, sites.single);
    return;
  }
  if (merge != null) {
    _merge(Directory('${paperbackFixtures().path}/${sites.single}'), Directory(merge), only!);
    return;
  }
  final Directory build = Directory.systemTemp.createTempSync('paperback_worker_build');
  final String exe = await _buildWorker(build);
  try {
    for (final site in sites) {
      await _capture(site, exe, only: only, out: out == null ? null : Directory(out));
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

Future<void> _capture(String site, String exe, {String? only, Directory? out}) async {
  final Directory dir = out ?? Directory('${paperbackFixtures().path}/$site');
  if (out != null && out.existsSync() && out.listSync().isNotEmpty) throw StateError('${out.path} is not empty');
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
  final repos = <PinnedRepository>[
    for (final PinnedBundle b in captureSites[site]!)
      if (only == null || b.label == only) PinnedRepository.load(b.repoDir),
  ];
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
    final List<BundleRun> runs = await runSiteScenario(provider, site, only: only);
    final String report = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'site': site,
      'query': queryFor(site),
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

/// Merges the single-bundle recording in [from] (made with `--only=[only]
/// --out`) into the committed capture [into].
void _merge(Directory into, Directory from, String only) {
  final intoFile = File('${into.path}/$captureManifestFileName');
  final CaptureManifest committed = _readManifest(intoFile);
  final CaptureManifest fresh = _readManifest(File('${from.path}/$captureManifestFileName'));
  final freshKeys = <CaptureKey>{for (final CaptureExchange e in fresh.exchanges) e.key};
  // Committed exchanges the new session re-requested, and every hop their
  // redirects led to (the old challenge pages), are replaced.
  final byKey = <CaptureKey, CaptureExchange>{
    for (final CaptureExchange e in committed.exchanges) e.key: e,
  };
  final dropped = <CaptureKey>{};
  final pending = <CaptureKey>[...freshKeys.where(byKey.containsKey)];
  while (pending.isNotEmpty) {
    final CaptureKey k = pending.removeLast();
    if (!dropped.add(k)) continue;
    final CaptureExchange e = byKey[k]!;
    final String? location = e.headers['location'];
    if (e.status >= 300 && e.status < 400 && location != null) {
      final CaptureKey next = committed.keyFor('GET', Uri.parse(e.key.url).resolve(location), null);
      if (byKey.containsKey(next)) pending.add(next);
    }
  }
  final exchanges = <CaptureExchange>[
    ...committed.exchanges.where((CaptureExchange e) => !dropped.contains(e.key)),
    ...fresh.exchanges,
  ];
  for (final CaptureExchange e in fresh.exchanges) {
    File('${from.path}/${e.bodyFile}').copySync('${into.path}/${e.bodyFile}');
  }
  final kept = <String>{for (final CaptureExchange e in exchanges) e.bodyFile};
  for (final CaptureExchange e in committed.exchanges) {
    final body = File('${into.path}/${e.bodyFile}');
    if (!kept.contains(e.bodyFile) && body.existsSync()) body.deleteSync();
  }
  intoFile.writeAsStringSync(
    CaptureManifest(
      ecosystem: committed.ecosystem,
      source: committed.source,
      recordedAt: committed.recordedAt,
      notes:
          '${committed.notes}; exchanges of $only re-recorded in a second session at '
          '${fresh.recordedAt.toUtc().toIso8601String()} (${fresh.exchanges.length} exchanges, replacing '
          '${dropped.length}), sanitized',
      volatileQueryParameters: committed.volatileQueryParameters,
      exchanges: exchanges,
    ).encode(),
  );
  final scenarioFile = File('${into.path}/scenario.json');
  final scenario = jsonDecode(scenarioFile.readAsStringSync()) as Map<String, Object?>;
  final freshScenario = jsonDecode(File('${from.path}/scenario.json').readAsStringSync()) as Map<String, Object?>;
  final Object? freshRun = (freshScenario['runs']! as List<Object?>).single;
  final runs = scenario['runs']! as List<Object?>;
  final bool known = runs.any((Object? r) => (r! as Map<String, Object?>)['bundle'] == only);
  scenario['runs'] = <Object?>[
    for (final Object? r in runs)
      if ((r! as Map<String, Object?>)['bundle'] == only) freshRun else r,
    if (!known) freshRun,
  ];
  scenario['rerecorded'] = <String, Object?>{
    ...?(scenario['rerecorded'] as Map<String, Object?>?),
    only: freshScenario['recordedAt'],
  };
  const encoder = JsonEncoder.withIndent('  ');
  scenarioFile.writeAsStringSync('${encoder.convert(scenario)}\n');
  stdout.writeln('merged ${fresh.exchanges.length} exchanges into ${into.path}, replaced ${dropped.length}');
}

/// Removes [label]'s run (and re-recording note) from [dir]'s `scenario.json`.
void _drop(Directory dir, String label) {
  final scenarioFile = File('${dir.path}/scenario.json');
  final scenario = jsonDecode(scenarioFile.readAsStringSync()) as Map<String, Object?>;
  final runs = scenario['runs']! as List<Object?>;
  scenario['runs'] = <Object?>[
    for (final Object? r in runs)
      if ((r! as Map<String, Object?>)['bundle'] != label) r,
  ];
  final rerecorded = scenario['rerecorded'] as Map<String, Object?>?;
  rerecorded?.remove(label);
  if (rerecorded != null && rerecorded.isEmpty) scenario.remove('rerecorded');
  const encoder = JsonEncoder.withIndent('  ');
  scenarioFile.writeAsStringSync('${encoder.convert(scenario)}\n');
  stdout.writeln('dropped ${runs.length - (scenario['runs']! as List<Object?>).length} run(s) of $label');
}

/// Replays [site]'s scenario offline (in-process worker, committed capture
/// only) and deletes the exchanges and bodies it never requested.
Future<void> _prune(Directory dir, String site) async {
  final client = MultiReplayHttpClient.load(<Directory>[dir]);
  final repos = <PinnedRepository>[for (final PinnedBundle b in captureSites[site]!) PinnedRepository.load(b.repoDir)];
  final supervisor = WorkerSupervisor(
    spec: const WorkerSpec(label: 'paperback-prune', executable: 'in-process'),
    limits: const SupervisorLimits(
      maxConcurrentPackages: 1,
      operationDeadline: Duration(minutes: 15),
      cancelGrace: Duration(seconds: 5),
      interactionTimeout: Duration(seconds: 5),
      shutdownGrace: Duration(seconds: 5),
    ),
    launcher: inProcessPaperbackLauncher(
      client: client,
      limits: PaperbackRuntimeLimits(
        memoryLimitBytes: 256 << 20,
        maxStackBytes: 512 << 10,
        operationDeadline: const Duration(minutes: 15),
        jobSlice: const Duration(milliseconds: 20),
      ),
    ),
  );
  final Directory cache = Directory.systemTemp.createTempSync('paperback_prune');
  try {
    await runSiteScenario(
      PaperbackSourceProvider(
        client: client,
        cache: ArtifactCache(cache),
        trust: PinnedRepository.pinnedTrust(repos),
        worker: () async => (await supervisor.start()).map((_) => supervisor),
      ),
      site,
    );
  } finally {
    await supervisor.close();
    cache.deleteSync(recursive: true);
  }
  if (client.misses.isNotEmpty) throw StateError('Replay missed ${client.misses}; not pruning');
  final Set<CaptureKey> served = client.served.toSet();
  final manifestFile = File('${dir.path}/$captureManifestFileName');
  final CaptureManifest committed = _readManifest(manifestFile);
  final kept = <CaptureExchange>[
    for (final CaptureExchange e in committed.exchanges)
      if (served.contains(e.key)) e,
  ];
  final keptBodies = <String>{for (final CaptureExchange e in kept) e.bodyFile};
  for (final CaptureExchange e in committed.exchanges) {
    final body = File('${dir.path}/${e.bodyFile}');
    if (!keptBodies.contains(e.bodyFile) && body.existsSync()) body.deleteSync();
  }
  manifestFile.writeAsStringSync(
    CaptureManifest(
      ecosystem: committed.ecosystem,
      source: committed.source,
      recordedAt: committed.recordedAt,
      notes:
          '${committed.notes}; pruned to the exchanges the current bundles request '
          '(${committed.exchanges.length - kept.length} removed)',
      volatileQueryParameters: committed.volatileQueryParameters,
      exchanges: kept,
    ).encode(),
  );
  stdout.writeln('pruned ${committed.exchanges.length - kept.length} of ${committed.exchanges.length} exchanges');
}

CaptureManifest _readManifest(File f) =>
    CaptureManifest.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, Object?>);
