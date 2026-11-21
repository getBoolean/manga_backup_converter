/// Package-level Tachi loading through the real JVM worker in replay mode:
/// every site response and artifact comes from `fixtures/source_captures/`,
/// and the worker fails any uncaptured request, so no test contacts a server.
///
/// Prerequisites: `./gradlew installDist` in `tools/tachi-source-runner` and
/// Corretto 21.0.13.1+ (`TACHI_JAVA_HOME`, the default Corretto path, or
/// `JAVA_HOME`); otherwise the group is skipped with the reason.
@TestOn('vm')
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';
import 'package:test/scaffolding.dart';

final ({TachiWorkerLocation? location, String? skip}) _worker = testWorkerLocation();

void main() {
  group('TachiRuntime over the shared JVM worker', skip: _worker.skip, () {
    late Directory temp;
    late ConversionRuntimeScope scope;
    late CountingLauncher launcher;
    late FixtureRepository keiyoushi;
    late FixtureFetch fetch;
    late TachiRuntime runtime;
    late TachiCatalog catalog;
    final trust = TachiTrustIdentity(repository: keiyoushiRepository, fingerprint: keiyoushiFingerprint);

    TachiRuntime newRuntime({TachiArtifactPolicy policy = const TachiArtifactPolicy()}) => TachiRuntime(
      worker: () => scope.worker(WorkerKind.jvm),
      store: TachiArtifactStore(cache: ArtifactCache(Directory('${temp.path}/cache')), fetch: fetch.call),
      catalog: catalog,
      policy: policy,
    );

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tachi_runtime_');
      launcher = CountingLauncher();
      scope = replayScope(
        _worker.location!,
        state: Directory('${temp.path}/state')..createSync(),
        launcher: launcher.call,
        onLog: (String line) => stderr.writeln('[tachi-runtime-test] $line'),
      );
      keiyoushi = FixtureRepository(baseUrl: keiyoushiRepository, captures: tachiCaptures());
      fetch = FixtureFetch(<FixtureRepository>[keiyoushi]);
      catalog = TachiCatalog(fetch.call);
      runtime = newRuntime();
    });

    tearDown(() async {
      await scope.close();
      temp.deleteSync(recursive: true);
    });

    Future<TachiPackageListing> listing(String packageId) async =>
        (await catalog.fetchPackages(await catalog.fetchRepository(keiyoushiRepository))).firstWhere(
          (TachiPackageListing l) => l.packageId == packageId,
        );

    Future<TachiPreparedArtifact> prepared(TachiPackageListing l, {TachiArtifactKind? kind}) async {
      final TachiArtifactChoice choice = kind == null
          ? (runtime.policy.select(l) as SourceSuccess<TachiArtifactChoice>).value
          : TachiArtifactChoice(kind: kind, url: l.urlFor(kind)!);
      final SourceOutcome<TachiPreparedArtifact> outcome = await runtime.prepare(l, choice, trust: trust);
      return (outcome as SourceSuccess<TachiPreparedArtifact>).value;
    }

    Future<TachiSourcePackage> open(TachiPreparedArtifact artifact) async {
      final SourceOutcome<SourcePackage> outcome = await runtime.openPackage(artifact, SettingsSnapshot());
      return (outcome as SourceSuccess<SourcePackage>).value as TachiSourcePackage;
    }

    const weebCentral = 'eu.kanade.tachiyomi.extension.en.weebcentral';

    test('a verified JAR searches and fetches details by its durable reference', () async {
      final TachiSourcePackage package = await open(await prepared(await listing(weebCentral)));
      final TachiSourceSession session = package.sessions.single;
      check(session.identity.sourceId).equals('2131019126180322627');

      final SourceOutcome<SearchPage> search = await session.search(const SearchRequest(query: 'Onimai'));
      final SearchPage page = (search as SourceSuccess<SearchPage>).value;
      check(page.hits).isNotEmpty();
      final SearchHit hit = page.hits.first;

      final SourceOutcome<MangaSnapshot> details = await session.fetchManga(hit.ref.withHandle(null));
      final MangaSnapshot snapshot = (details as SourceSuccess<MangaSnapshot>).value;
      check(snapshot.chapters).length.equals(114);
      check(launcher.launches).equals(1);
    });
  });
}

// Silence unused-import analysis until the scenario tests use these.
// ignore: unused_element
Uint8List _unused = Uint8List(0);
