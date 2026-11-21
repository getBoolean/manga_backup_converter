import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';
import 'package:test/scaffolding.dart';

void main() {
  late FixtureRepository keiyoushi;
  late FixtureFetch fetch;
  late TachiCatalog catalog;

  setUp(() {
    keiyoushi = FixtureRepository(baseUrl: keiyoushiRepository, captures: tachiCaptures());
    fetch = FixtureFetch(<FixtureRepository>[keiyoushi]);
    catalog = TachiCatalog(fetch.call);
  });

  group('repository spellings', () {
    test('repo.json, index.json, index.min.json and a trailing slash all name one repository', () {
      for (final spelling in <String>[
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo',
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/',
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/repo.json',
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.json',
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json?x=1#f',
      ]) {
        check(tachiRepositoryBase(Uri.parse(spelling))).equals(keiyoushiRepository);
      }
    });

    test('the stale index.min.json stub is never read: repo.json leads to the live index.json', () async {
      final TachiRepository repository = await catalog.fetchRepository(
        Uri.parse('https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json'),
      );
      final List<TachiPackageListing> listings = await catalog.fetchPackages(repository);

      check(fetch.requests).deepEquals(<Uri>[repository.repoJsonUrl, repository.indexUrl]);
      check(repository.indexUrl.path).endsWith('/index.json');
      check(
        listings.map((TachiPackageListing l) => l.packageId),
      ).not((Subject<Iterable<String>> it) => it.contains('eu.kanade.tachiyomi.extension.en.stale'));
      check(repository.signingKeyFingerprint).equals(keiyoushiFingerprint);
    });
  });

  group('live index.json', () {
    late List<TachiPackageListing> listings;

    setUp(() async => listings = await catalog.fetchPackages(await catalog.fetchRepository(keiyoushiRepository)));

    TachiPackageListing listing(String packageId) =>
        listings.firstWhere((TachiPackageListing l) => l.packageId == packageId);

    test('reads every captured package with both artifact URLs', () {
      check(listings).length.equals(3);
      for (final TachiCapture c in tachiCaptures()) {
        final TachiPackageListing l = listing(c.packageId);
        check(l.jarUrl).equals(c.urlOf(TachiArtifactKind.jar));
        check(l.apkUrl).equals(c.urlOf(TachiArtifactKind.apk));
        check(l.apiFamily).equals('tachi-1.6');
        check(l.repository.baseUrl).equals(keiyoushiRepository);
      }
    });

    test('a multi-source package lists every source ID apart from its package ID, as exact decimal strings', () {
      final TachiPackageListing mangaDex = listing('eu.kanade.tachiyomi.extension.all.mangadex');
      final ids = <String>[for (final TachiIndexSource s in mangaDex.sources) s.id.decimal];
      final List<Object?> indexed = (tachiCaptures().first.indexEntry['sources']! as List<Object?>)
          .map((Object? s) => (s! as Map<String, Object?>)['id'])
          .toList();

      check(ids).deepEquals(indexed);
      check(ids.toSet()).length.equals(ids.length);
      check(ids).not((Subject<Iterable<String>> it) => it.contains(mangaDex.packageId));
      // Above 2^53: survives only because it never becomes a number.
      check(ids).contains('9194073792736219759');
      check(mangaDex.languages).contains('en');

      final TachiPackageListing mangaFire = listing('eu.kanade.tachiyomi.extension.all.mangafire');
      check(mangaFire.sources).length.equals(7);
    });

    test('CONTENT_WARNING_MIXED is suggestive; any other warning is unknown (treated as adult)', () {
      check(listing('eu.kanade.tachiyomi.extension.en.weebcentral').contentRating)
          .equals(ContentRatingLevel.suggestive);
    });
  });

  group('strict parsing', () {
    final repository = TachiRepository(
      baseUrl: keiyoushiRepository,
      name: 'Keiyoushi',
      signingKeyFingerprint: keiyoushiFingerprint,
    );

    Map<String, Object?> entry() => <String, Object?>{...tachiCaptures()[1].indexEntry};

    test('an unknown content warning is unknown', () {
      final List<TachiPackageListing> parsed = parseTachiIndex(repository, <Object?>[
        <String, Object?>{...entry(), 'contentWarning': 'CONTENT_WARNING_NSFW'},
      ]);
      check(parsed.single.contentRating).equals(ContentRatingLevel.unknown);
    });

    test('a numeric source ID is rejected (int64 IDs are decimal strings)', () {
      final Map<String, Object?> e = entry();
      e['sources'] = <Object?>[
        // ignore: avoid_js_rounded_ints, the point: a JSON number cannot carry an int64 ID.
        <String, Object?>{'id': 2131019126180322627, 'name': 'Weeb Central', 'language': 'en'},
      ];
      check(() => parseTachiIndex(repository, <Object?>[e])).throws<TachiCatalogException>();
    });

    test('a package without artifacts or sources is rejected rather than skipped', () {
      check(
        () => parseTachiIndex(repository, <Object?>[
          <String, Object?>{...entry(), 'resources': <String, Object?>{}},
        ]),
      ).throws<TachiCatalogException>();
      check(
        () => parseTachiIndex(repository, <Object?>[
          <String, Object?>{...entry(), 'sources': <Object?>[]},
        ]),
      ).throws<TachiCatalogException>();
    });

    test('repo.json needs a meta object with a certificate SHA-256 fingerprint', () {
      check(() => TachiRepository.fromJson(keiyoushiRepository, const <String, Object?>{}))
          .throws<TachiCatalogException>();
      check(
        () => TachiRepository.fromJson(keiyoushiRepository, const <String, Object?>{
          'meta': <String, Object?>{'name': 'x', 'signingKeyFingerprint': 'abc'},
        }),
      ).throws<TachiCatalogException>();
      final colons = TachiRepository.fromJson(keiyoushiRepository, <String, Object?>{
        'meta': <String, Object?>{
          'name': 'x',
          'signingKeyFingerprint': RegExp('..')
              .allMatches(keiyoushiFingerprint.toUpperCase())
              .map((m) => m[0])
              .join(':'),
        },
      });
      check(colons.signingKeyFingerprint).equals(keiyoushiFingerprint);
    });

    test('a non-JSON index is a catalog error', () async {
      final badCatalog = TachiCatalog((Uri url) async => Uint8List.fromList(utf8.encode('<html>')));
      await check(badCatalog.fetchRepository(keiyoushiRepository)).throws<TachiCatalogException>();
    });
  });
}
