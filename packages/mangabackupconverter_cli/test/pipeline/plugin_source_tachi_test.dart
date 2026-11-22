/// The CLI's Tachi loader: repository trust through the core gate, the
/// rating policy, typed failures, and search → details through the real JVM
/// worker in replay mode (no request reaches a server).
@TestOn('vm')
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/plugin_cache.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_tachi.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';
import 'package:test/scaffolding.dart';

const String _weebCentral = 'eu.kanade.tachiyomi.extension.en.weebcentral';
const String _mangaFire = 'eu.kanade.tachiyomi.extension.all.mangafire';
const String _otherFingerprint = 'ab';

final ({TachiWorkerLocation? location, String? skip}) _worker = testWorkerLocation();

void main() {
  late Directory temp;
  late FixtureRepository keiyoushi;
  late FixtureFetch fetch;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('cli_tachi_');
    keiyoushi = FixtureRepository(baseUrl: keiyoushiRepository, captures: tachiCaptures());
    fetch = FixtureFetch(<FixtureRepository>[keiyoushi]);
  });

  tearDown(() => deleteTestDirectory(temp));

  DesktopTachiRuntime runtime({
    SourceOutcome<TachiWorkerLocation> Function()? locate,
    WorkerLauncher? launcher,
  }) => DesktopTachiRuntime(
    locate: locate ?? () => SourceSuccess<TachiWorkerLocation>(_worker.location!),
    cacheDirectory: Directory('${temp.path}/artifacts'),
    fetch: fetch.call,
    replay: <String>[for (final TachiCapture c in tachiCaptures()) c.directory.path],
    stateDirectory: (Directory('${temp.path}/state')..createSync(recursive: true)).path,
    launcher: launcher,
  );

  /// A gate as the pipeline builds it, deciding with [decide] (an
  /// unattended CLI run answers nothing, so nothing new is trusted).
  RepositoryTrustGate gate(TrustStore store, {Future<TrustDecision> Function(RepositoryTrustRequest)? decide}) {
    return RepositoryTrustGate(
      store: store,
      decide: (RepositoryTrustRequest r) async => await decide?.call(r) ?? TrustDecision.unanswered,
    );
  }

  group('repository trust', () {
    test('an unattended run refuses a first-seen repository: nothing is listed and the decision is recorded', () async {
      final loader = TachiPluginLoader(runtime: runtime());
      final warnings = <String>[];
      final RepositoryTrustGate g = gate(InMemoryTrustStore());
      final List<ExtensionEntry> entries = await loader.fetchExtensionLists(
        <String>['$keiyoushiRepository/index.min.json'],
        onWarning: warnings.add,
        trust: g,
      );
      check(entries).isEmpty();
      check(warnings.single)
        ..contains(keiyoushiFingerprint)
        ..contains('(first-seen)');
      check(g.decisions.single)
          .startsWith('First-seen signing fingerprint for $keiyoushiRepository (tachi): unanswered');
      check(fetch.requests).deepEquals(<Uri>[Uri.parse('$keiyoushiRepository/repo.json')]);
    });

    test('a pre-approved fingerprint (--trust-tachi-repo) admits the repository without asking', () async {
      final loader = TachiPluginLoader(runtime: runtime());
      final store = PinnedTrustStore(
        InMemoryTrustStore(),
        PinnedTrustStore.parsePins(<String>['$keiyoushiRepository/repo.json=${keiyoushiFingerprint.toUpperCase()}']),
      );
      final RepositoryTrustGate g = gate(store);
      final List<ExtensionEntry> entries = await loader.fetchExtensionLists(
        <String>[keiyoushiRepository.toString()],
        trust: g,
      );
      check(g.decisions).isEmpty();
      check(entries.map((ExtensionEntry e) => e.id)).deepEquals(<String>[
        'eu.kanade.tachiyomi.extension.all.mangadex',
        _weebCentral,
        _mangaFire,
      ]);
      final mangaFire = entries.last as TachiExtensionEntry;
      check(mangaFire.sourceIds).length.equals(7);
      check(mangaFire.sourceIds).not((Subject<Iterable<String>> it) => it.contains(mangaFire.id));
      check(mangaFire.artifactKind).equals('jar');
      check(mangaFire.repositoryUrl).equals(keiyoushiRepository.toString());
      check(mangaFire.cacheKey).equals('$_mangaFire-v106038-jar');
    });

    test('a changed fingerprint is blocked until the user approves it again', () async {
      final store = InMemoryTrustStore();
      await store.remember('tachi', keiyoushiRepository, keiyoushiFingerprint);
      keiyoushi.fingerprint = _otherFingerprint * 32;

      final RepositoryTrustGate refused = gate(store);
      final changedWarnings = <String>[];
      check(
        await TachiPluginLoader(
          runtime: runtime(),
        ).fetchExtensionLists(<String>[keiyoushiRepository.toString()], trust: refused, onWarning: changedWarnings.add),
      ).isEmpty();
      check(changedWarnings.single).contains('(changed)');
      check(refused.decisions.single).startsWith('Changed signing fingerprint');

      RepositoryTrustRequest? asked;
      final RepositoryTrustGate approved = gate(
        store,
        decide: (RepositoryTrustRequest r) async {
          asked = r;
          return TrustDecision.trustOnce;
        },
      );
      check(
        await TachiPluginLoader(runtime: runtime())
            .fetchExtensionLists(<String>[keiyoushiRepository.toString()], trust: approved),
      ).length.equals(3);
      check(asked!.isChange).isTrue();
      check(asked!.previousFingerprint).equals(keiyoushiFingerprint);
    });

    test('an entry this loader did not admit fails as a typed trust failure, never a stub source', () async {
      final failures = <PluginLoadFailure>[];
      final List<PluginSource> loaded = await TachiPluginLoader(runtime: runtime()).loadPlugins(<ExtensionEntry>[
        const TachiExtensionEntry(
          id: _weebCentral,
          name: 'Weeb Central',
          repositoryUrl: 'https://example.invalid/repo',
          versionName: '1.6.27',
          versionCode: 106027,
          artifactKind: 'jar',
        ),
      ], onFailure: failures.add);
      check(loaded).isEmpty();
      check(failures.single.failure)
          .isA<TrustFailure>()
          .has((TrustFailure f) => f.reason, 'reason')
          .equals(TrustFailureReason.firstSeen);
      check(fetch.requests).isEmpty();
    });
  });

  group('content rating', () {
    test('adult-rated packages follow SourceRatingPolicy', () async {
      keiyoushi = FixtureRepository(
        baseUrl: keiyoushiRepository,
        captures: tachiCaptures(),
        entryOverrides: <String, Map<String, Object?>>{
          _mangaFire: <String, Object?>{'contentWarning': 'CONTENT_WARNING_NSFW'},
        },
      );
      fetch = FixtureFetch(<FixtureRepository>[keiyoushi]);
      final List<ExtensionEntry> entries = await TachiPluginLoader(runtime: runtime()).fetchExtensionLists(
        <String>[keiyoushiRepository.toString()],
        trust: gate(InMemoryTrustStore(<String, String>{'tachi|$keiyoushiRepository': keiyoushiFingerprint})),
      );
      final ({int hidden, List<ExtensionEntry> visible}) byDefault = const SourceRatingPolicy().apply(entries);
      check(byDefault.hidden).equals(1);
      check(byDefault.visible.map((ExtensionEntry e) => e.id))
          .not((Subject<Iterable<String>> it) => it.contains(_mangaFire));
      check(const SourceRatingPolicy(adultContentConfirmed: true).apply(entries).visible).length.equals(3);
    });
  });

  test('a host without a configured handshake deadline fails each package with a typed runtime failure', () async {
    final failures = <PluginLoadFailure>[];
    final DesktopTachiRuntime tachi = runtime(
      locate: () =>
          TachiWorkerLocation.resolve(installDirectory: temp.path, javaHome: temp.path, environment: const {}),
    );
    final owner = ConversionOwner();
    await tachi.attach(owner);
    final loader = TachiPluginLoader(runtime: tachi);
    final List<PluginSource> loaded = await loader.loadPlugins(
      await loader.fetchExtensionLists(
        <String>[keiyoushiRepository.toString()],
        trust: gate(InMemoryTrustStore(<String, String>{'tachi|$keiyoushiRepository': keiyoushiFingerprint})),
      ),
      owner: owner,
      onFailure: failures.add,
    );
    check(loaded).isEmpty();
    check(failures).length.equals(3);
    check(failures.first.failure)
        .isA<RuntimeUnavailableFailure>()
        .has((f) => f.message, 'message')
        .contains(
          'handshakeDeadline',
        );
    check(tachi.scope).isNull();
    await owner.close();
  });

  group('end to end through the shared JVM worker', skip: _worker.skip, () {
    test('a refused download is never cached: the next load downloads again and succeeds', () async {
      final DesktopTachiRuntime tachi = runtime();
      final owner = ConversionOwner();
      addTearDown(owner.close);
      await tachi.attach(owner);
      final cache = PluginCache(cacheDir: Directory('${temp.path}/plugins'));
      final loader = TachiPluginLoader(runtime: tachi, cache: cache);
      final List<ExtensionEntry> entries = await loader.fetchExtensionLists(
        <String>[keiyoushiRepository.toString()],
        trust: gate(InMemoryTrustStore(<String, String>{'tachi|$keiyoushiRepository': keiyoushiFingerprint})),
      );
      final ExtensionEntry wc = entries.firstWhere((ExtensionEntry e) => e.id == _weebCentral);
      final Uri jarUrl = tachiCaptures()[1].urlOf(TachiArtifactKind.jar);

      final tampered = Uint8List.fromList(tachiCaptures()[1].bytesOf(TachiArtifactKind.jar));
      tampered[tampered.length ~/ 2] ^= 0xff;
      fetch.overrides[jarUrl] = tampered;
      final failures = <PluginLoadFailure>[];
      check(await loader.loadPlugins(<ExtensionEntry>[wc], owner: owner, onFailure: failures.add)).isEmpty();
      check(failures.single.failure).isA<ArtifactIncompatibleFailure>();
      check(cache.get(wc)).isNull();

      fetch.overrides.remove(jarUrl);
      final List<PluginSource> loaded = await loader.loadPlugins(<ExtensionEntry>[wc], owner: owner);
      check(loaded.single.sourceId).equals('2131019126180322627');
      check(cache.get(wc)).isNotNull();
      check(fetch.countOf(jarUrl)).equals(2);
      check(tachi.runtime().valueOrNull!.prepareCount).equals(2);
    });

    test('live search results reach PluginSource with native URLs and int64 IDs intact, then details', () async {
      final launcher = CountingLauncher();
      final DesktopTachiRuntime tachi = runtime(launcher: launcher.call);
      final owner = ConversionOwner();
      addTearDown(owner.close);
      await tachi.attach(owner);
      final loader = TachiPluginLoader(
        runtime: tachi,
        cache: PluginCache(cacheDir: Directory('${temp.path}/plugins')),
      );

      final List<ExtensionEntry> entries = await loader.fetchExtensionLists(
        <String>['$keiyoushiRepository/index.min.json'],
        trust: gate(PinnedTrustStore(InMemoryTrustStore(), <Uri, String>{keiyoushiRepository: keiyoushiFingerprint})),
      );
      final failures = <PluginLoadFailure>[];
      final List<PluginSource> plugins = await loader.loadPlugins(
        entries.where((ExtensionEntry e) => e.id == _weebCentral || e.id == _mangaFire).toList(),
        owner: owner,
        onFailure: failures.add,
      );
      check(failures).isEmpty();
      check(plugins).length.equals(1 + 7);
      check(launcher.launches).equals(1);
      // Each source carries its index language, so the pipeline can narrow a
      // multi-language package to the backup's languages.
      final List<String?> mangaFireLanguages = plugins
          .where((PluginSource p) => p.identity.packageId == _mangaFire)
          .map((PluginSource p) => p.language)
          .toList();
      check(mangaFireLanguages.every((String? l) => l != null && l.isNotEmpty)).isTrue();
      check(mangaFireLanguages.toSet().length).equals(7);
      check(plugins.firstWhere((PluginSource p) => p.identity.packageId == _weebCentral).language).equals('en');

      final PluginSource wc = plugins.firstWhere((PluginSource p) => p.identity.packageId == _weebCentral);
      check(wc.sourceId).equals('2131019126180322627');
      check(wc.identity.ecosystem).equals('tachi');

      final PluginSearchPageResult page = (await wc.search('Onimai')).valueOrNull!;
      final PluginSearchResult hit = page.results.first;
      check(hit.ref.source).equals(wc.identity);
      check(hit.ref.source.sourceId).equals('2131019126180322627');
      // The source's own SManga.url, unaltered.
      check(hit.mangaKey).equals('/series/01J76XYF0TGKQ7XJ4XVPV1C0BP/ONIMAI-Im-Now-Your-Sister');

      final DetailsOutcome details = await wc.fetchDetails(hit.ref);
      check(details).isA<DetailsFetched>();
      check(details.fetchedOrNull!.chapters).length.equals(114);

      await owner.close();
      check(tachi.scope!.supervisors[WorkerKind.jvm]!.state).equals(WorkerState.closed);
    });
  });
}
