/// End-to-end: the `source_runtime` supervisor speaking protocol 1.1 to the
/// Paperback worker as a real subprocess.
///
/// `setUpAll` builds each entrypoint once with `dart build cli` (the QuickJS
/// build hook compiles with the full environment), and the supervisor
/// launches the built executable with its scrubbed environment, so the
/// supervised PID is the worker itself.
///
/// The shipped worker (`bin/paperback_source_worker.dart`) hosts the
/// Paperback 0.8 and 0.9 adapters (U6). It runs the real pinned bundles in
/// `--replay` mode against the committed captures, so search and details go
/// through the built executable without contacting a server. Settings
/// plumbing is exercised through `settings_echo_worker.dart`: the same
/// `PaperbackSourceWorker` over stdio, wired to a test adapter that echoes
/// each source's effective settings.
@TestOn('vm')
@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import '../support/paperback_scenarios.dart';
import 'e2e_support.dart';

const List<String> _limitArgs = <String>[
  '--memory-limit-bytes=33554432',
  '--max-stack-bytes=262144',
  '--operation-deadline-ms=4000',
  '--job-slice-ms=5',
  '--deadline-headroom-ms=250',
];

const ArtifactBinding _bundle = ArtifactBinding(sha256: '', kind: 'paperback-bundle', version: '1.0.0');

/// Builds [entrypoint] (relative to the package) into [out] and returns the
/// executable.
Future<String> _build(String entrypoint, Directory out) async {
  final package = '${repoRoot().path}/packages/paperback_plugin_loader';
  final ProcessResult result = await Process.run(dartExecutable(), <String>[
    'build',
    'cli',
    '-t',
    entrypoint,
    '-o',
    out.path,
    '--verbosity=error',
  ], workingDirectory: package);
  if (result.exitCode != 0) {
    throw StateError('dart build cli $entrypoint failed:\n${result.stdout}\n${result.stderr}');
  }
  final List<File> exes = Directory('${out.path}/bundle/bin').listSync().whereType<File>().toList();
  if (exes.length != 1) throw StateError('Expected one executable in ${out.path}/bundle/bin, found $exes');
  return exes.single.path;
}

WorkerSupervisor _supervisor(String executable) {
  return WorkerSupervisor(
    spec: WorkerSpec(
      label: 'paperback',
      executable: executable,
      arguments: _limitArgs,
      environment: scrubbedEnvironment(),
    ),
    // The worker reports only operationDeadlineMs; the caller supplies the rest.
    limits: const AdoptWorkerLimits(
      handshakeDeadline: Duration(seconds: 30),
      maxConcurrentPackages: 1,
      cancelGrace: Duration(seconds: 2),
      interactionTimeout: Duration(seconds: 10),
      shutdownGrace: Duration(seconds: 5),
    ),
    onLog: (String line) => stderr.writeln('[paperback-e2e] $line'),
  );
}

void main() {
  late Directory builds;
  late String shippedWorker;
  late String echoWorker;
  late Directory temp;
  late ArtifactCache cache;

  setUpAll(() async {
    builds = Directory.systemTemp.createTempSync('pb_e2e_build_');
    shippedWorker = await _build('bin/paperback_source_worker.dart', Directory('${builds.path}/shipped'));
    echoWorker = await _build('test/e2e/settings_echo_worker.dart', Directory('${builds.path}/echo'));
  });
  tearDownAll(() => builds.deleteSync(recursive: true));

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pb_e2e_');
    cache = ArtifactCache(Directory('${temp.path}/cache'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<ArtifactLease> bundleLease() async {
    final bytes = Uint8List.fromList(utf8.encode('// echo bundle'));
    final binding = ArtifactBinding(
      sha256: sha256Hex(bytes),
      kind: _bundle.kind,
      version: _bundle.version,
    );
    return cache.admit(
      bytes,
      binding: binding,
      profile: const ArtifactProfile(producer: 'test', converterVersion: '1', hostCompatibility: 'test'),
      verifier: (Uint8List b, ArtifactBinding a) {},
    );
  }

  test('the shipped worker negotiates 1.1, reports its benchmarked limit, and refuses an absent package', () async {
    final WorkerSupervisor supervisor = _supervisor(shippedWorker);
    try {
      final SourceOutcome<HandshakeResponse> started = await supervisor.start();
      final HandshakeResponse handshake = (started as SourceSuccess<HandshakeResponse>).value;
      check(handshake.worker).equals('paperback');
      check(handshake.protocolMinor).equals(1);
      check(supervisor.protocolMinor).equals(1);
      // The supervisor-side deadline: engine deadline plus headroom.
      check(handshake.limits!.operationDeadline).equals(const Duration(milliseconds: 4250));
      check(handshake.limits!.fields['operationDeadlineMicros']).equals(4000000);
      check(handshake.limits!.fields['deadlineHeadroomMicros']).equals(250000);
      check(handshake.limits!.fields['memoryLimitBytes']).equals(33554432);
      check(handshake.limits!.poolSize).isNull();
      check(handshake.capabilities.apiFamilies).deepEquals(<String>{'paperback-0.8', 'paperback-0.9'});
      check(handshake.capabilities.browser).isTrue();
      // Adopted from the worker: the caller supplied no operation deadline.
      check(supervisor.limits!.operationDeadline).equals(const Duration(milliseconds: 4250));

      final SourceOutcome<EmptyPayload> unload = await supervisor.send('pkg.none', const PackageUnloadRequest());
      check((unload as SourceFailed<EmptyPayload>).failure).isA<RuntimeUnavailableFailure>();

      // An artifact kind that names no supported API family is refused.
      final SourceOutcome<PackageLoadResponse> load = await supervisor.loadPackage(
        WorkerPackage(packageId: 'pkg.test', artifact: await bundleLease(), settings: SettingsSnapshot()),
      );
      check((load as SourceFailed<PackageLoadResponse>).failure).isA<UnsupportedApiFailure>();
    } finally {
      await supervisor.close();
    }
  });

  test('string-set and source-scoped settings reach the worker on load and settings.update', () async {
    final WorkerSupervisor supervisor = _supervisor(echoWorker);
    try {
      final settings = SettingsSnapshot(
        values: const <String, Object>{
          'lang': 'en',
          'tags': <String>['b', 'a', 'b'],
        },
        sources: <String, SourceScopedSettings>{
          'two': SourceScopedSettings(
            values: const <String, Object>{
              'tags': <String>['z'],
            },
            secrets: const <String, String>{'token': 'secret-token'},
          ),
        },
      );
      final ArtifactLease lease = await bundleLease();
      final SourceOutcome<PackageLoadResponse> load = await supervisor.loadPackage(
        WorkerPackage(packageId: 'pkg.test', artifact: lease, settings: settings),
      );
      check(load).isA<SourceSuccess<PackageLoadResponse>>();

      Future<List<String>> echo(String sourceId, String revision) async {
        final SourceOutcome<WorkerSearchResponse> reply = await supervisor.send(
          'pkg.test',
          WorkerSearchRequest(
            source: SourceIdentity(
              ecosystem: 'paperback',
              packageId: 'pkg.test',
              sourceId: sourceId,
              artifact: lease.binding,
            ),
            settingsRevision: revision,
            request: const SearchRequest(query: 'q'),
          ),
        );
        return (reply as SourceSuccess<WorkerSearchResponse>).value.warnings;
      }

      check(await echo('one', settings.revision)).deepEquals(<String>[
        'values={"lang":"en","tags":["a","b"]}',
        'secrets=',
      ]);
      check(await echo('two', settings.revision)).deepEquals(<String>[
        'values={"lang":"en","tags":["z"]}',
        'secrets=token',
      ]);

      final updated = SettingsSnapshot(
        values: const <String, Object>{
          'tags': <String>['y', 'x'],
        },
        sources: <String, SourceScopedSettings>{
          'one': SourceScopedSettings(values: const <String, Object>{'lang': 'ja'}),
        },
      );
      check(await supervisor.updateSettings('pkg.test', updated)).isA<SourceSuccess<EmptyPayload>>();
      check(await echo('one', updated.revision)).deepEquals(<String>[
        'values={"tags":["x","y"],"lang":"ja"}',
        'secrets=',
      ]);
      check(await echo('two', updated.revision)).deepEquals(<String>['values={"tags":["x","y"]}', 'secrets=']);
    } finally {
      await supervisor.close();
    }
  });

  test('search -> details through the built worker executable, replaying both API families', () async {
    Future<List<BundleRun>> run(String site) async {
      final supervisor = WorkerSupervisor(
        spec: WorkerSpec(
          label: 'paperback',
          executable: shippedWorker,
          arguments: <String>[
            '--memory-limit-bytes=${256 << 20}',
            '--max-stack-bytes=${512 << 10}',
            '--operation-deadline-ms=60000',
            '--job-slice-ms=20',
            '--deadline-headroom-ms=250',
            '--replay=${paperbackFixtures().path}/$site',
          ],
          environment: scrubbedEnvironment(),
        ),
        limits: const SupervisorLimits(
          maxConcurrentPackages: 1,
          operationDeadline: Duration(seconds: 90),
          cancelGrace: Duration(seconds: 5),
          interactionTimeout: Duration(seconds: 5),
          shutdownGrace: Duration(seconds: 10),
        ),
        onLog: (String line) => stderr.writeln('[paperback-e2e] $line'),
      );
      final repos = <PinnedRepository>[
        for (final PinnedBundle b in captureSites[site]!) PinnedRepository.load(b.repoDir),
      ];
      final provider = PaperbackSourceProvider(
        client: http.Client(),
        cache: ArtifactCache(Directory('${temp.path}/$site-cache')),
        trust: PinnedRepository.pinnedTrust(repos),
        worker: () async => (await supervisor.start()).map((_) => supervisor),
      );
      try {
        return await runSiteScenario(provider, site);
      } finally {
        await supervisor.close();
      }
    }

    final List<BundleRun> weebcentral = await run('weebcentral');
    for (final r in weebcentral) {
      final MangaSnapshot s = (r.details! as SourceSuccess<MangaSnapshot>).value;
      check(s.chapters).length.equals(114);
      check(s.chapters.first.chapterId).equals('01KWM07QYFJMAP46S1A3ZVDWYG');
    }
    check(weebcentral.map((BundleRun r) => r.family.wire).toSet())
        .deepEquals(<String>{'paperback-0.8', 'paperback-0.9'});
    final BundleRun mangadex = (await run('mangadex')).firstWhere((BundleRun r) => r.family.wire == 'paperback-0.9');
    check((mangadex.details! as SourceSuccess<MangaSnapshot>).value.chapters).length.equals(223);
  });
}
