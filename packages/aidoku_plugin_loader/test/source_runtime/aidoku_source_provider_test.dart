// The Aidoku source-contract adapter over the existing loader, replaying the
// committed MangaDex captures (no network).
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/source_adapter.dart';
import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import '../support/replay.dart';

File _fixture(String relative) =>
    File(relative).existsSync() ? File(relative) : File('packages/aidoku_plugin_loader/$relative');

void main() {
  const mangaId = 'ed996855-70de-449f-bba2-e8e24224c14d';
  final File aix = _fixture('test/aidoku/fixtures/multi.mangadex-v12.aix');
  const profile = ArtifactProfile(producer: 'aidoku-aix', converterVersion: '1', hostCompatibility: '1');

  group('AidokuSourceProvider', skip: aix.existsSync() ? null : 'Missing multi.mangadex-v12.aix', () {
    late Directory temp;
    late ArtifactCache cache;
    late ArtifactLease lease;
    late ReplayHttpClient replay;
    late AidokuSourceProvider provider;
    late SourcePackage package;
    late SourceSession session;
    final settings = SettingsSnapshot(values: const <String, String>{'contentRating': 'safe'});

    setUpAll(() async {
      temp = Directory.systemTemp.createTempSync('aidoku_adapter_test');
      cache = ArtifactCache(Directory('${temp.path}/cache'));
      final Uint8List bytes = aix.readAsBytesSync();
      lease = await cache.admit(
        bytes,
        binding: ArtifactBinding(sha256: sha256Hex(bytes), kind: 'aix', version: '12'),
        profile: profile,
        verifier: (_, _) {},
      );
      replay = aidokuReplayClient('multi.mangadex');
      provider = AidokuSourceProvider(
        httpClient: replay,
        // Same seeded login default as aidoku_plugin_native_test.dart.
        defaultsFor: (_) => <String, dynamic>{
          'login': Uint8List.fromList(<int>[2, 0x7B, 0x7D]),
        },
      );
      package = (await provider.openPackage(lease, settings)).valueOrNull!;
      session = package.sessions.single;
    });

    tearDownAll(() async {
      await package.close();
      lease.release();
      temp.deleteSync(recursive: true);
    });

    tearDown(() => check(because: 'requests without a committed capture', replay.misses).isEmpty());

    test('exposes one source bound to the verified artifact and settings revision', () {
      check(package.sessions).length.equals(1);
      check(session.identity.ecosystem).equals('aidoku');
      check(session.identity.sourceId).equals('multi.mangadex');
      check(session.identity.artifact).equals(lease.binding);
      check(session.settingsRevision).equals(settings.revision);
      check(session.capabilities.supports(SourceOperation.search)).isTrue();
      check(session.capabilities.supports(SourceOperation.browser)).isFalse();
    });

    test('search returns durable references and an opaque page cursor', () async {
      final SourceOutcome<SearchPage> out = await session.search(const SearchRequest(query: 'Onimai'));
      final SearchPage page = out.valueOrNull!;
      final SearchHit hit = page.hits.firstWhere((SearchHit h) => h.ref.mangaId == mangaId);
      check(hit.title).isNotEmpty();
      check(hit.ref.source).equals(session.identity);
      check(hit.ref.settingsRevision).equals(settings.revision);
    });

    test('fetchManga returns a complete snapshot with every chapter', () async {
      final SearchHit hit = (await session.search(
        const SearchRequest(query: 'Onimai'),
      )).valueOrNull!.hits.firstWhere((SearchHit h) => h.ref.mangaId == mangaId);
      final MangaSnapshot snapshot = (await session.fetchManga(hit.ref)).valueOrNull!;
      check(snapshot.metadata.title).isNotEmpty();
      check(snapshot.metadata.contentRating).equals(ContentRatingLevel.suggestive);
      check(snapshot.chapters).isNotEmpty();
      check(snapshot.chapters.map((NativeChapter c) => c.sourceOrder)).deepEquals(<int>[
        for (var i = 0; i < snapshot.chapters.length; i++) i,
      ]);
    });

    test('missing details are a typed failure, not an empty snapshot', () async {
      final ref = NativeMangaRef(
        source: session.identity,
        mangaId: '00000000-0000-0000-0000-000000000000',
        settingsRevision: settings.revision,
      );
      final SourceOutcome<MangaSnapshot> out = await session.fetchManga(ref);
      check(out.failureOrNull).isA<SourceErrorFailure>();
      // The uncaptured request failed in replay instead of reaching a server.
      check(replay.misses).isNotEmpty();
      replay.misses.clear();
    });

    test('a reference from another settings revision or artifact is stale', () async {
      final otherRevision = NativeMangaRef(source: session.identity, mangaId: mangaId, settingsRevision: 'other');
      check((await session.fetchManga(otherRevision)).failureOrNull).isA<StaleReferenceFailure>();
      final otherArtifact = NativeMangaRef(
        source: const SourceIdentity(
          ecosystem: 'aidoku',
          packageId: 'multi.mangadex',
          sourceId: 'multi.mangadex',
          artifact: ArtifactBinding(sha256: 'different', kind: 'aix', version: '13'),
        ),
        mangaId: mangaId,
        settingsRevision: settings.revision,
      );
      check((await session.fetchManga(otherArtifact)).failureOrNull).isA<StaleReferenceFailure>();
    });

    test('a cancelled call is answered as cancelled', () async {
      final cancel = CancellationSource()..cancel('user');
      check(
        (await session.search(const SearchRequest(query: 'Onimai'), cancel: cancel.token)).failureOrNull,
      ).isA<CancelledFailure>();
    });

    test('an invalid cursor is rejected', () async {
      check(
        (await session.search(const SearchRequest(query: 'Onimai', cursor: 'x'))).failureOrNull,
      ).isA<StaleReferenceFailure>();
    });
  });

  group('AidokuSourceProvider admission', () {
    test('rejects a non-aix artifact and a tampered artifact', () async {
      final Directory temp = Directory.systemTemp.createTempSync('aidoku_adapter_admission');
      addTearDown(() => temp.deleteSync(recursive: true));
      final cache = ArtifactCache(Directory('${temp.path}/cache'));
      final bytes = Uint8List.fromList(<int>[1, 2, 3]);
      final String digest = sha256Hex(bytes);
      final provider = AidokuSourceProvider(httpClient: MockClient((_) async => http.Response('', 404)));
      final ArtifactLease jar = await cache.admit(
        bytes,
        binding: ArtifactBinding(sha256: digest, kind: 'jar', version: '1'),
        profile: profile,
        verifier: (_, _) {},
      );
      check((await provider.openPackage(jar, SettingsSnapshot())).failureOrNull).isA<ArtifactIncompatibleFailure>();
      final ArtifactLease tampered = await cache.admit(
        bytes,
        binding: ArtifactBinding(sha256: digest, kind: 'aix', version: '1'),
        profile: const ArtifactProfile(producer: 'aidoku-aix', converterVersion: '2', hostCompatibility: '1'),
        verifier: (_, _) {},
      );
      File(tampered.path).writeAsBytesSync(<int>[9, 9, 9]);
      check(
        (await provider.openPackage(tampered, SettingsSnapshot())).failureOrNull,
      ).isA<ArtifactIncompatibleFailure>();
    });

    test('typed settings reach fromAix defaults with their Dart types; secrets win', () async {
      final Directory temp = Directory.systemTemp.createTempSync('aidoku_adapter_defaults');
      addTearDown(() => temp.deleteSync(recursive: true));
      final bytes = Uint8List.fromList(<int>[4, 5, 6]);
      final ArtifactLease lease = await ArtifactCache(Directory('${temp.path}/cache')).admit(
        bytes,
        binding: ArtifactBinding(sha256: sha256Hex(bytes), kind: 'aix', version: '1'),
        profile: profile,
        verifier: (_, _) {},
      );
      Map<String, dynamic>? seen;
      final provider = AidokuSourceProvider(
        httpClient: MockClient((_) async => http.Response('', 404)),
        loadPlugin: (Uint8List aix, {Map<String, dynamic>? defaults, http.Client? httpClient}) async {
          seen = defaults;
          throw const FormatException('stop after capturing defaults');
        },
      );
      final settings = SettingsSnapshot(
        values: const <String, Object>{'nsfw': true, 'pageSize': 20, 'offset': -3, 'lang': 'en', 'token': 'public'},
        secrets: const <String, String>{'token': 'secret'},
      );
      check((await provider.openPackage(lease, settings)).failureOrNull).isA<ArtifactIncompatibleFailure>();
      lease.release();
      // fromAix encodes bool with writeBool, int with writeSignedVarInt and
      // String with writeString, so the types must survive the mapping.
      check(seen).isNotNull().deepEquals(<String, dynamic>{
        'nsfw': true,
        'pageSize': 20,
        'offset': -3,
        'lang': 'en',
        'token': 'secret',
      });
      check(seen!['nsfw']).isA<bool>();
      check(seen!['pageSize']).isA<int>();
      check(aidokuDefaultsFor(settings)).deepEquals(seen!);
    });

    test('discovers packages from a repository index without the network', () async {
      final File index = _fixture('test/aidoku/fixtures/index.json');
      final provider = AidokuSourceProvider(
        httpClient: MockClient((_) async => http.Response.bytes(index.readAsBytesSync(), 200)),
      );
      final List<PackageListing> listings = (await provider.discoverPackages(
        Uri.parse('https://repo.test/index.json'),
      )).valueOrNull!;
      check(listings).isNotEmpty();
      final PackageListing mangadex = listings.firstWhere((PackageListing l) => l.packageId == 'multi.mangadex');
      check(mangadex.downloadUrl.isAbsolute).isTrue();
    });
  });
}
