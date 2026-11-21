// The built CLI executable hosts the Paperback worker through its hidden
// subcommand, with limits from the KTD25 plan, and a pinned bundle searches
// and fetches details over the committed captures (`--replay`; no server).
//
// It builds the CLI with `dart build cli` (AOT), which also guards against
// the Dart 3.14 AOT compiler crash worked around in the Paperback loader.
@TestOn('vm')
@Timeout(Duration(minutes: 15))
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_paperback.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

Directory _repoRoot() {
  Directory dir = Directory.current.absolute;
  while (!Directory('${dir.path}/fixtures/source_captures/paperback').existsSync()) {
    if (dir.parent.path == dir.path) throw StateError('repository root not found');
    dir = dir.parent;
  }
  return dir;
}

/// The SDK's `dart` (never the `dart.bat` shim). Under `flutter test` the
/// resolved executable is `flutter_tester`, so walk up to the Flutter cache.
String _dart() {
  final exe = Platform.isWindows ? 'dart.exe' : 'dart';
  if (Platform.resolvedExecutable.endsWith(exe)) return Platform.resolvedExecutable;
  Directory dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    final candidate = File('${dir.path}/dart-sdk/bin/$exe');
    if (candidate.existsSync()) return candidate.path;
    dir = dir.parent;
  }
  throw StateError('Dart SDK not found from ${Platform.resolvedExecutable}');
}

void main() {
  test("search and details through the CLI executable's __paperback-worker subcommand", () async {
    final Directory root = _repoRoot();
    final Directory build = Directory.systemTemp.createTempSync('cli_build_');
    final Directory cache = Directory.systemTemp.createTempSync('cli_paperback_cache_');
    try {
      final ProcessResult built = await Process.run(_dart(), <String>[
        'build',
        'cli',
        '-o',
        build.path,
        '--verbosity=error',
      ], workingDirectory: '${root.path}/packages/mangabackupconverter_cli');
      check(built.exitCode, because: '${built.stdout}${built.stderr}').equals(0);
      final String exe = Directory('${build.path}/bundle/bin').listSync().whereType<File>().single.path;

      final fixtures = Directory('${root.path}/fixtures/source_captures/paperback');
      final PaperbackWorkerPlan plan = planPaperbackWorker();
      final supervisor = WorkerSupervisor(
        spec: WorkerSpec(
          label: 'paperback',
          executable: exe,
          arguments: <String>[paperbackWorkerCommand, ...plan.arguments, '--replay=${fixtures.path}/weebcentral'],
          environment: scrubbedEnvironment(),
        ),
        limits: AdoptWorkerLimits(
          handshakeDeadline: plan.handshakeDeadline,
          maxConcurrentPackages: 1,
          cancelGrace: plan.cancelGrace,
          interactionTimeout: const Duration(minutes: 5),
          shutdownGrace: plan.cancelGrace,
        ),
      );
      final PaperbackCatalog catalog = PaperbackCatalog.parse(
        Uri.parse('https://inkdex.github.io/extensions/0.9/stable/'),
        File('${fixtures.path}/inkdex-0.9/versioning.json').readAsStringSync(),
      );
      final PaperbackCatalogEntry entry = catalog.entries.firstWhere(
        (PaperbackCatalogEntry e) => e.sourceId == 'WeebCentral',
      );
      const pinned = 'bd62583ec530eec19d4e742626eee3c5f2bebda405c76a3f339f6681c2aeb966';
      final provider = PaperbackSourceProvider(
        client: http.Client(),
        cache: ArtifactCache(cache),
        // A trusted pinned artifact digest (KTD6).
        trust: (Uri key, String fingerprint) async => fingerprint == 'paperback-0.9:sha256:$pinned',
        worker: () async => (await supervisor.start()).map((_) => supervisor),
      );
      try {
        final ArtifactLease lease = (await provider.admit(
          entry,
          File('${fixtures.path}/inkdex-0.9/WeebCentral/index.js').readAsBytesSync(),
        ) as SourceSuccess<ArtifactLease>).value;
        final SourcePackage package =
            (await provider.openPackage(lease, SettingsSnapshot()) as SourceSuccess<SourcePackage>).value;
        // The supervisor adopted the worker's supervisor-side deadline:
        // engine deadline plus measured headroom.
        final WorkerArguments launched = parseWorkerArguments(plan.arguments);
        check(supervisor.limits!.operationDeadline)
            .equals(launched.limits.operationDeadline + launched.deadlineHeadroom);
        final SourceSession session = package.sessions.single;
        final SearchPage page =
            (await session.search(const SearchRequest(query: 'Onimai')) as SourceSuccess<SearchPage>).value;
        check(page.hits.single.ref.mangaId).equals('01J76XYF0TGKQ7XJ4XVPV1C0BP');
        final MangaSnapshot snapshot =
            (await session.fetchManga(page.hits.single.ref) as SourceSuccess<MangaSnapshot>).value;
        check(snapshot.chapters).length.equals(114);
        await package.close();
        lease.release();
      } finally {
        await supervisor.close();
      }
    } finally {
      build.deleteSync(recursive: true);
      cache.deleteSync(recursive: true);
    }
  });
}
