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

const String weebCentral = 'eu.kanade.tachiyomi.extension.en.weebcentral';
const String mangaFireId = 'eu.kanade.tachiyomi.extension.all.mangafire';

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

    TachiRuntime newRuntime() => TachiRuntime(
      worker: () => scope.worker(WorkerKind.jvm),
      store: TachiArtifactStore(cache: ArtifactCache(Directory('${temp.path}/cache')), fetch: fetch.call),
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
      await deleteTestDirectory(temp);
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

    Future<SearchPage> search(TachiSourceSession session) async =>
        (await session.search(const SearchRequest(query: 'Onimai')) as SourceSuccess<SearchPage>).value;

    test('a verified JAR searches and fetches details by its durable reference', () async {
      final TachiSourcePackage package = await open(await prepared(await listing(weebCentral)));
      final TachiSourceSession session = package.sessions.single;
      check(session.identity.sourceId).equals('2131019126180322627');

      final SearchPage page = await search(session);
      check(page.hits).isNotEmpty();

      final SourceOutcome<MangaSnapshot> details = await session.fetchManga(page.hits.first.ref.withHandle(null));
      check((details as SourceSuccess<MangaSnapshot>).value.chapters).length.equals(114);
      check(launcher.launches).equals(1);
    });

    test('one download of a multi-source package supplies every enumerated source without conflating IDs', () async {
      final TachiPackageListing mangaFire = await listing(mangaFireId);
      final TachiSourcePackage package = await open(await prepared(mangaFire));

      final loaded = <String>[for (final TachiSourceSession s in package.sessions) s.identity.sourceId];
      check(loaded.toSet()).deepEquals(<String>{for (final TachiIndexSource s in mangaFire.sources) s.id.decimal});
      check(loaded).length.equals(mangaFire.sources.length);
      for (final TachiSourceSession s in package.sessions) {
        check(s.identity.packageId).equals(mangaFireId);
        check(s.identity.sourceId).not((Subject<String> it) => it.equals(mangaFireId));
      }
      check(fetch.countOf(mangaFire.jarUrl!)).equals(1);
      check(runtime.prepareCount).equals(1);
    });

    test('a package may open browser sessions only for its own sources', () async {
      final TachiSourcePackage package = await open(await prepared(await listing(weebCentral)));
      final SourceIdentity own = package.sessions.single.identity;
      check(runtime.browserIdentity(weebCentral, own.sourceId)).isNotNull()
        ..has((SourceIdentity i) => i.packageId, 'packageId').equals(weebCentral)
        ..has((SourceIdentity i) => i.artifact.sha256, 'artifact').equals(own.artifact.sha256);
      // Another package's or an unknown source, a missing package, or no package: refused.
      check(runtime.browserIdentity(weebCentral, '6084907896154116083')).isNull();
      check(runtime.browserIdentity(mangaFireId, own.sourceId)).isNull();
      check(runtime.browserIdentity(null, own.sourceId)).isNull();
    });

    test('three packages across two repositories share one worker, with one download and one prepare each', () async {
      final mirror = FixtureRepository(
        baseUrl: Uri.parse('https://mirror.example/tachi/repo'),
        name: 'Mirror',
        captures: <TachiCapture>[tachiCaptures()[1]],
      );
      keiyoushi = FixtureRepository(
        baseUrl: keiyoushiRepository,
        captures: <TachiCapture>[tachiCaptures()[0], tachiCaptures()[2]],
      );
      fetch = FixtureFetch(<FixtureRepository>[keiyoushi, mirror]);
      catalog = TachiCatalog(fetch.call);
      runtime = newRuntime();

      final opened = <TachiSourcePackage>[];
      for (final repo in <FixtureRepository>[keiyoushi, mirror]) {
        final TachiRepository repository = await catalog.fetchRepository(repo.baseUrl);
        final repoTrust = TachiTrustIdentity(repository: repository.baseUrl, fingerprint: repo.fingerprint);
        for (final TachiPackageListing l in await catalog.fetchPackages(repository)) {
          final TachiArtifactChoice choice = (runtime.policy.select(l) as SourceSuccess<TachiArtifactChoice>).value;
          final SourceOutcome<TachiPreparedArtifact> p = await runtime.prepare(l, choice, trust: repoTrust);
          opened.add(await open((p as SourceSuccess<TachiPreparedArtifact>).value));
          check(fetch.countOf(choice.url)).equals(1);
        }
      }

      check(opened.map((TachiSourcePackage p) => p.packageId).toSet()).length.equals(3);
      check(launcher.launches).equals(1);
      check(scope.supervisors.keys).deepEquals(<WorkerKind>[WorkerKind.jvm]);
      check(runtime.prepareCount).equals(3);
      check(runtime.hostedPackages.toSet()).length.equals(3);
      check(
        opened.firstWhere((TachiSourcePackage p) => p.packageId == weebCentral).artifact.trust.repository,
      ).equals(mirror.baseUrl);
    });

    test('the repository JAR and the APK via dex2jar yield the same sources under one shared trust identity', () async {
      final TachiPackageListing l = await listing(weebCentral);
      final TachiPreparedArtifact jar = await prepared(l, kind: TachiArtifactKind.jar);
      final TachiPreparedArtifact apk = await prepared(l, kind: TachiArtifactKind.apk);
      check(jar.sourceKind).equals(TachiArtifactKind.jar);
      check(apk.sourceKind).equals(TachiArtifactKind.apk);
      check(jar.trust).equals(apk.trust);
      check(jar.input.sha256).equals(tachiCaptures()[1].sha256Of(TachiArtifactKind.jar));
      check(apk.input.sha256).equals(tachiCaptures()[1].sha256Of(TachiArtifactKind.apk));

      Future<_Run> run(
        TachiPreparedArtifact artifact,
      ) async {
        final TachiSourcePackage package = await open(artifact);
        final TachiSourceSession session = package.sessions.single;
        final SearchPage page = await search(session);
        final MangaSnapshot snapshot =
            (await session.fetchManga(page.hits.first.ref.withHandle(null)) as SourceSuccess<MangaSnapshot>).value;
        final _Run result = (
          ids: <String>[for (final TachiSourceSession s in package.sessions) s.identity.sourceId],
          names: <String>[for (final TachiSourceSession s in package.sessions) s.displayName],
          title: page.hits.first.title,
          chapters: snapshot.chapters.length,
        );
        await package.close();
        return result;
      }

      final _Run jarRun = await run(jar);
      final _Run apkRun = await run(apk);
      check(apkRun.ids).deepEquals(jarRun.ids);
      check(apkRun.names).deepEquals(jarRun.names);
      check(apkRun.title).equals(jarRun.title);
      check(apkRun.chapters).equals(jarRun.chapters);
      // A trust identity is per repository and fingerprint: another
      // repository with the same signer is a different identity.
      check(
        TachiTrustIdentity(repository: Uri.parse('https://mirror.example/repo'), fingerprint: keiyoushiFingerprint),
      ).not((Subject<TachiTrustIdentity> it) => it.equals(jar.trust));
    });

    group('refusals fail before execution and do not poison the cache', () {
      late TachiPackageListing l;
      late TachiPreparedArtifact good;

      setUp(() async {
        l = await listing(weebCentral);
        good = await prepared(l);
      });

      Future<void> checkGoodStillLoads() async {
        check(await good.lease.readVerified()).isNotEmpty();
        final ArtifactLease? cached = await runtime.store.cache.lookup(
          binding: good.input,
          profile: TachiArtifactStore.downloadProfile,
          verifier: (Uint8List b, ArtifactBinding a) {},
        );
        check(cached).isNotNull();
        cached!.release();
        final TachiSourcePackage package = await open(good);
        check(package.sessions.single.identity.sourceId).equals('2131019126180322627');
      }

      void checkFailed<F extends SourceFailure>(SourceOutcome<Object?> outcome) =>
          check(outcome).isA<SourceFailed<Object?>>().has((SourceFailed<Object?> f) => f.failure, 'failure').isA<F>();

      test('a tampered artifact', () async {
        final tampered = Uint8List.fromList(tachiCaptures()[1].bytesOf(TachiArtifactKind.jar));
        tampered[tampered.length ~/ 2] ^= 0xff;
        checkFailed<ArtifactIncompatibleFailure>(
          await runtime.prepare(
            l,
            TachiArtifactChoice(kind: TachiArtifactKind.jar, url: l.jarUrl!),
            trust: trust,
            bytes: tampered,
          ),
        );
        await checkGoodStillLoads();
      });

      test('a changed signing identity', () async {
        checkFailed<ArtifactIncompatibleFailure>(
          await runtime.prepare(
            l,
            TachiArtifactChoice(kind: TachiArtifactKind.apk, url: l.apkUrl!),
            trust: TachiTrustIdentity(repository: keiyoushiRepository, fingerprint: 'ab' * 32),
          ),
        );
        await checkGoodStillLoads();
      });

      test('trust approved for another repository', () async {
        checkFailed<ArtifactIncompatibleFailure>(
          await runtime.prepare(
            l,
            TachiArtifactChoice(kind: TachiArtifactKind.jar, url: l.jarUrl!),
            trust: TachiTrustIdentity(
              repository: Uri.parse('https://mirror.example/repo'),
              fingerprint: keiyoushiFingerprint,
            ),
          ),
        );
        await checkGoodStillLoads();
      });

      test('an incompatible API range, before anything is downloaded or prepared', () async {
        fetch.repositories
          ..clear()
          ..add(
            FixtureRepository(
              baseUrl: keiyoushiRepository,
              captures: tachiCaptures(),
              entryOverrides: <String, Map<String, Object?>>{
                weebCentral: <String, Object?>{'extensionLib': '1.2'},
              },
            ),
          );
        final TachiPackageListing old = await listing(weebCentral);
        final int prepares = runtime.prepareCount;
        final int downloads = fetch.countOf(old.jarUrl!);
        checkFailed<UnsupportedApiFailure>(
          await runtime.prepare(
            old,
            TachiArtifactChoice(kind: TachiArtifactKind.jar, url: old.jarUrl!),
            trust: trust,
          ),
        );
        check(runtime.prepareCount).equals(prepares);
        check(fetch.countOf(old.jarUrl!)).equals(downloads);
        await checkGoodStillLoads();
      });

      test('a raw download handed straight to openPackage', () async {
        final SourceOutcome<ArtifactLease> admitted = await runtime.store.admit(
          tachiCaptures()[1].bytesOf(TachiArtifactKind.jar),
          kind: TachiArtifactKind.jar,
          version: '1.6.27',
        );
        final ArtifactLease raw = (admitted as SourceSuccess<ArtifactLease>).value;
        checkFailed<ArtifactIncompatibleFailure>(await runtime.openPackage(raw, SettingsSnapshot()));
        raw.release();
        await checkGoodStillLoads();
      });
    });

    test('the same URL serving a new digest replaces the package and makes earlier handles stale', () async {
      final TachiPackageListing l = await listing(weebCentral);
      final TachiSourcePackage first = await open(await prepared(l));
      final TachiSourceSession oldSession = first.sessions.single;
      final SearchHit oldHit = (await search(oldSession)).hits.first;

      // Same signed entries, different archive bytes: a ZIP comment changes
      // the file digest without touching any signed entry.
      fetch.overrides[l.jarUrl!] = withZipComment(tachiCaptures()[1].bytesOf(TachiArtifactKind.jar), 'rebuilt');
      final TachiPreparedArtifact replacement = await prepared(l);
      check(replacement.input.sha256).not((Subject<String> it) => it.equals(first.artifact.input.sha256));
      final TachiSourcePackage second = await open(replacement);
      final TachiSourceSession newSession = second.sessions.single;

      check(oldSession.isStale).isTrue();
      final SourceOutcome<SearchPage> staleSearch = await oldSession.search(const SearchRequest(query: 'Onimai'));
      check((staleSearch as SourceFailed<SearchPage>).failure).isA<StaleReferenceFailure>();
      check(newSession.identity.sourceId).equals(oldSession.identity.sourceId);
      check(newSession.identity).not((Subject<SourceIdentity> it) => it.equals(oldSession.identity));
      final SourceOutcome<MangaSnapshot> staleDetails = await newSession.fetchManga(oldHit.ref);
      check((staleDetails as SourceFailed<MangaSnapshot>).failure).isA<StaleReferenceFailure>();
      check(runtime.hostedPackages).deepEquals(<String>[weebCentral]);
    });

    test('the same APK prepared twice shares one hosted package, though conversion output may differ', () async {
      final TachiPackageListing wc = await listing(weebCentral);
      final TachiPreparedArtifact first = await prepared(wc, kind: TachiArtifactKind.apk);
      final TachiPreparedArtifact second = await prepared(wc, kind: TachiArtifactKind.apk);
      check(second.input).equals(first.input);
      final TachiSourcePackage a = await open(first);
      final TachiSourcePackage b = await open(second);
      check(a.sessions.single.isStale).isFalse();
      check(b.sessions.single.identity).equals(a.sessions.single.identity);
      check(runtime.hostedPackages).deepEquals(<String>[weebCentral]);
      check(runtime.prepareCount).equals(2);
    });

    test('disposing one selection unloads only its own package, once no selection uses it', () async {
      final TachiPackageListing wc = await listing(weebCentral);
      final TachiSourcePackage a = await open(await prepared(wc));
      final TachiSourcePackage b = await open(await prepared(wc));
      final TachiSourcePackage fire = await open(await prepared(await listing(mangaFireId)));
      check(runtime.hostedPackages.toSet()).deepEquals(<String>{weebCentral, mangaFireId});

      await a.close();
      check(runtime.hostedPackages.toSet()).deepEquals(<String>{weebCentral, mangaFireId});
      check(await b.sessions.single.search(const SearchRequest(query: 'Onimai'))).isA<SourceSuccess<SearchPage>>();

      await b.close();
      check(runtime.hostedPackages.toSet()).deepEquals(<String>{mangaFireId});
      check(scope.supervisors[WorkerKind.jvm]!.packageIds.toSet()).deepEquals(<String>{mangaFireId});
      final TachiSourceSession en = fire.sessions.firstWhere((TachiSourceSession s) => s.language == 'en');
      check(await en.search(const SearchRequest(query: 'Onimai'))).isA<SourceSuccess<SearchPage>>();
      check(launcher.launches).equals(1);
    });
  });
}

/// What one artifact path yields for the same query.
typedef _Run = ({List<String> ids, List<String> names, String title, int chapters});

/// [zip] with its (empty) end-of-central-directory comment set to [comment].
Uint8List withZipComment(Uint8List zip, String comment) {
  final int eocd = zip.length - 22;
  if (zip[eocd] != 0x50 || zip[eocd + 1] != 0x4b || zip[eocd + 2] != 0x05 || zip[eocd + 3] != 0x06) {
    throw StateError('Archive already has a comment');
  }
  final List<int> bytes = comment.codeUnits;
  final out = Uint8List(zip.length + bytes.length)
    ..setAll(0, zip)
    ..setAll(zip.length, bytes);
  out[zip.length - 2] = bytes.length & 0xff;
  out[zip.length - 1] = bytes.length >> 8;
  return out;
}
