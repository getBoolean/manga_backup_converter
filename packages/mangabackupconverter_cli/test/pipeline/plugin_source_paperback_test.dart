// The CLI's Paperback path — PaperbackPluginLoader → PaperbackSourceProvider
// → supervisor → worker → SessionPluginSource — against the pinned
// catalogs/bundles and committed site captures, with the core
// RepositoryTrustGate deciding bundle trust. No network: catalogs and
// bundles are served from fixtures, site requests from captures.
@TestOn('vm')
@Timeout(Duration(minutes: 30))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_loader.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

Directory _fixtures() {
  Directory dir = Directory.current.absolute;
  while (!Directory('${dir.path}/fixtures/source_captures/paperback').existsSync()) {
    if (dir.parent.path == dir.path) throw StateError('fixtures not found');
    dir = dir.parent;
  }
  return Directory('${dir.path}/fixtures/source_captures/paperback');
}

/// Serves `<repository>/...` from the pinned repository directories.
http.Client _catalogClient(Directory fixtures) {
  const repos = <String, String>{
    'https://inkdex.github.io/extensions/0.9/stable/': 'inkdex-0.9',
    'https://g2asell2019.github.io/numby-extensions/0.8/': 'numby-0.8',
    'https://thenetsky.github.io/netskys-extensions/0.8/': 'netsky-0.8',
  };
  return MockClient((http.Request r) async {
    final url = r.url.toString();
    for (final MapEntry<String, String> e in repos.entries) {
      if (url.startsWith(e.key)) {
        final file = File('${fixtures.path}/${e.value}/${url.substring(e.key.length)}');
        if (file.existsSync()) return http.Response.bytes(file.readAsBytesSync(), 200);
      }
    }
    return http.Response('not found', 404);
  });
}

void main() {
  final Directory fixtures = _fixtures();
  late Directory temp;
  late List<RepositoryTrustRequest> asked;
  late TrustDecision answer;
  late InMemoryTrustStore store;
  late WorkerSupervisor supervisor;

  RepositoryTrustGate gate() => RepositoryTrustGate(
    store: store,
    decide: (RepositoryTrustRequest request) async {
      asked.add(request);
      return answer;
    },
  );

  PaperbackPluginLoader loader() => PaperbackPluginLoader(
    client: _catalogClient(fixtures),
    artifacts: ArtifactCache(Directory('${temp.path}/cache')),
    worker: (ConversionOwner? owner) async => (await supervisor.start()).map((_) => supervisor),
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('cli_paperback_');
    asked = <RepositoryTrustRequest>[];
    answer = TrustDecision.trustAndRemember;
    store = InMemoryTrustStore();
    supervisor = WorkerSupervisor(
      spec: const WorkerSpec(label: 'paperback', executable: 'in-process'),
      limits: const SupervisorLimits(
        maxConcurrentPackages: 1,
        operationDeadline: Duration(minutes: 15),
        cancelGrace: Duration(seconds: 5),
        interactionTimeout: Duration(seconds: 5),
        shutdownGrace: Duration(seconds: 5),
      ),
      launcher: inProcessPaperbackLauncher(
        client: MultiReplayHttpClient.load(<Directory>[Directory('${fixtures.path}/weebcentral')]),
        limits: PaperbackRuntimeLimits(
          memoryLimitBytes: 256 << 20,
          maxStackBytes: 512 << 10,
          operationDeadline: const Duration(minutes: 15),
          jobSlice: const Duration(milliseconds: 20),
        ),
      ),
    );
  });
  tearDown(() async {
    await supervisor.close();
    temp.deleteSync(recursive: true);
  });

  test('lists both API families as Paperback entries; adult sources stay hidden by default', () async {
    final List<ExtensionEntry> entries = await loader().fetchExtensionLists(<String>[
      'https://inkdex.github.io/extensions/0.9/stable/',
      'https://thenetsky.github.io/netskys-extensions/0.8/',
    ], trust: gate());
    final List<PaperbackExtensionEntry> pb = entries.cast<PaperbackExtensionEntry>();
    final PaperbackExtensionEntry wc = pb.firstWhere((PaperbackExtensionEntry e) => e.sourceId == 'WeebCentral');
    check(wc.id).equals('https://inkdex.github.io/extensions/0.9/stable/#WeebCentral');
    check(wc.apiFamily).equals('paperback-0.9');
    check(wc.bundleUrl).equals('https://inkdex.github.io/extensions/0.9/stable/WeebCentral/index.js');
    check(
      pb
          .firstWhere((PaperbackExtensionEntry e) => e.id.startsWith('https://thenetsky') && e.sourceId == 'MangaFox')
          .apiFamily,
    ).equals('paperback-0.8');
    // Listing consults no trust decision: Paperback trust is per bundle.
    check(asked).isEmpty();

    final ({List<ExtensionEntry> visible, int hidden}) shown = const SourceRatingPolicy().apply(entries);
    check(shown.hidden).isGreaterThan(0);
    check(shown.visible.every((ExtensionEntry e) => e.contentRating <= SourceRatingPolicy.suggestive)).isTrue();
    check(shown.visible.any((ExtensionEntry e) => e.id.endsWith('#DynastyScans'))).isFalse();
    check(
      const SourceRatingPolicy(adultContentConfirmed: true)
          .apply(entries)
          .visible
          .any((ExtensionEntry e) => e.id.endsWith('#DynastyScans')),
    ).isTrue();
  });

  test('loads 0.9 and 0.8 bundles behind the trust gate and searches and fetches through them', () async {
    final PaperbackPluginLoader l = loader();
    final List<ExtensionEntry> entries = await l.fetchExtensionLists(<String>[
      'https://inkdex.github.io/extensions/0.9/stable/',
      'https://g2asell2019.github.io/numby-extensions/0.8/',
    ], trust: gate());
    final List<ExtensionEntry> selected = entries.where((ExtensionEntry e) => e.id.endsWith('#WeebCentral')).toList();
    check(selected).length.equals(2);
    final owner = ConversionOwner();
    final failures = <PluginLoadFailure>[];
    final List<PluginSource> plugins = await l.loadPlugins(selected, owner: owner, onFailure: failures.add);
    try {
      check(failures).isEmpty();
      check(plugins).length.equals(2);
      check(asked.map((RepositoryTrustRequest r) => r.fingerprint.split(':sha256:').first).toList())
          .deepEquals(<String>[
            'paperback-0.9',
            'paperback-0.8',
          ]);
      check(asked.every((RepositoryTrustRequest r) => !r.isChange)).isTrue();
      for (final plugin in plugins) {
        check(plugin.identity.ecosystem).equals('paperback');
        final PluginSearchPageResult page =
            (await plugin.search('Onimai') as SourceSuccess<PluginSearchPageResult>).value;
        final PluginSearchResult hit = page.results.single;
        check(hit.title).equals("ONIMAI - I'm Now Your Sister!");
        final DetailsOutcome details = await plugin.fetchDetails(hit.ref);
        check(details).isA<DetailsFetched>().has((DetailsFetched d) => d.manga.chapters.length, 'chapters').equals(114);
      }
      // Remembered decisions are not asked again by a new run.
      asked.clear();
      final PaperbackPluginLoader again = loader();
      await again.fetchExtensionLists(<String>['https://inkdex.github.io/extensions/0.9/stable/'], trust: gate());
      final SourceOutcome<List<PluginSource>> reloaded = await again.loadPluginFromBytes(
        selected.first,
        File('${fixtures.path}/inkdex-0.9/WeebCentral/index.js').readAsBytesSync(),
        owner: owner,
      );
      check(reloaded).isA<SourceSuccess<List<PluginSource>>>();
      check(asked).isEmpty();
    } finally {
      await owner.close();
    }
  });

  test('two bundles from one repository keep separate remembered decisions', () async {
    final PaperbackPluginLoader l = loader();
    final List<ExtensionEntry> entries = await l.fetchExtensionLists(<String>[
      'https://inkdex.github.io/extensions/0.9/stable/',
    ], trust: gate());
    final owner = ConversionOwner();
    try {
      for (final id in <String>['WeebCentral', 'MangaDex']) {
        final ExtensionEntry e = entries.firstWhere((ExtensionEntry x) => x.id.endsWith('#$id'));
        final Uint8List bytes = File('${fixtures.path}/inkdex-0.9/$id/index.js').readAsBytesSync();
        check(await l.loadPluginFromBytes(e, bytes, owner: owner)).isA<SourceSuccess<List<PluginSource>>>();
      }
      check(asked.map((RepositoryTrustRequest r) => r.repository.fragment).toList()).deepEquals(<String>[
        'WeebCentral',
        'MangaDex',
      ]);
      check(asked.any((RepositoryTrustRequest r) => r.isChange)).isFalse();
      check(store.fingerprints).length.equals(2);
    } finally {
      await owner.close();
    }
  });

  test('a rejected or changed bundle never opens; changed cached bytes ask again and can be refused', () async {
    final PaperbackPluginLoader l = loader();
    final List<ExtensionEntry> entries = await l.fetchExtensionLists(<String>[
      'https://inkdex.github.io/extensions/0.9/stable/',
    ], trust: gate());
    final ExtensionEntry wc = entries.firstWhere((ExtensionEntry e) => e.id.endsWith('#WeebCentral'));
    final Uint8List pinned = File('${fixtures.path}/inkdex-0.9/WeebCentral/index.js').readAsBytesSync();

    answer = TrustDecision.reject;
    final SourceOutcome<List<PluginSource>> rejected = await l.loadPluginFromBytes(wc, pinned);
    check(rejected)
        .isA<SourceFailed<List<PluginSource>>>()
        .has((SourceFailed<List<PluginSource>> f) => f.failure, 'failure')
        .isA<TrustFailure>()
        .has((TrustFailure f) => f.reason, 'reason')
        .equals(TrustFailureReason.refused);
    check(supervisor.state).equals(WorkerState.idle);

    answer = TrustDecision.trustAndRemember;
    final owner = ConversionOwner();
    try {
      check(await l.loadPluginFromBytes(wc, pinned, owner: owner)).isA<SourceSuccess<List<PluginSource>>>();
      // The cache now hands back different bytes for the same entry (a
      // tampered PluginCache file): the gate sees a changed fingerprint.
      final changed = Uint8List.fromList(pinned)..[pinned.length - 10] ^= 1;
      asked.clear();
      answer = TrustDecision.reject;
      final SourceOutcome<List<PluginSource>> refused = await l.loadPluginFromBytes(wc, changed, owner: owner);
      check(refused).isA<SourceFailed<List<PluginSource>>>();
      check(asked.single.isChange).isTrue();
      check(asked.single.repository.fragment).equals('WeebCentral');
      // Nobody can answer (an unattended run): the reason is the change.
      answer = TrustDecision.unanswered;
      final changedAgain = Uint8List.fromList(pinned)..[pinned.length - 11] ^= 1;
      check(await l.loadPluginFromBytes(wc, changedAgain, owner: owner))
          .isA<SourceFailed<List<PluginSource>>>()
          .has((SourceFailed<List<PluginSource>> f) => f.failure, 'failure')
          .isA<TrustFailure>()
          .has((TrustFailure f) => f.reason, 'reason')
          .equals(TrustFailureReason.changed);
    } finally {
      await owner.close();
    }
  });
}
