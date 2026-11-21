// Real Paperback catalogs (pinned under fixtures/source_captures/paperback):
// layout, API family, installation entry points, ratings, and the
// qualification-source availability matrix per API family.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:test/scaffolding.dart';

import 'support/paperback_scenarios.dart';

const List<String> _surveyed = <String>[
  'inkdex-0.9',
  'gabrielcwt-0.8',
  'numby-0.8',
  'netsky-0.8',
  'paperback-default-0.8',
  'kittycatgit-0.8',
  'community-0.8',
];

void main() {
  test('every pinned catalog parses and declares its API family through builtWith.types', () {
    final families = <String, PaperbackApiFamily>{
      for (final String d in _surveyed) d: PinnedRepository.load(d).catalog.family,
    };
    check(families).deepEquals(<String, PaperbackApiFamily>{
      'inkdex-0.9': PaperbackApiFamily.v09,
      'gabrielcwt-0.8': PaperbackApiFamily.v08,
      'numby-0.8': PaperbackApiFamily.v08,
      'netsky-0.8': PaperbackApiFamily.v08,
      'paperback-default-0.8': PaperbackApiFamily.v08,
      'kittycatgit-0.8': PaperbackApiFamily.v08,
      'community-0.8': PaperbackApiFamily.v08,
    });
    final PaperbackCatalog inkdex = PinnedRepository.load('inkdex-0.9').catalog;
    check(inkdex.types).equals('1.0.0-alpha.94');
    check(inkdex.name).equals('Inkdex Extensions (0.9)');
    check(PinnedRepository.load('numby-0.8').catalog.types).equals('0.8.7');
    check(PinnedRepository.load('gabrielcwt-0.8').catalog.types).equals('0.8.0-alpha.47');
  });

  test('installation entry points: 0.8 <id>/source.js, 0.9 <id>/index.js, matching the pinned artifacts', () {
    for (final d in <String>['inkdex-0.9', 'gabrielcwt-0.8', 'numby-0.8', 'kittycatgit-0.8', 'community-0.8']) {
      final repo = PinnedRepository.load(d);
      for (final MapEntry<String, Map<String, Object?>> pin in repo.pins.entries) {
        final PaperbackCatalogEntry entry = repo.entry(pin.key);
        check(entry.bundleUrl.toString()).equals(pin.value['sourceUrl']! as String);
        check(entry.version).equals(pin.value['version']! as String);
        // The committed bytes are the pinned artifact.
        check(bundleDigest(repo.bundle(pin.key))).equals(pin.value['sha256']! as String);
        // Each bundle's own structure declares the catalog's family.
        check(declaredFamilyOf(repo.bundle(pin.key))).equals(repo.catalog.family);
      }
    }
  });

  test('content ratings map onto the SourceRatingPolicy scale; unknown is adult', () {
    check(PaperbackCatalog.ratingOf('EVERYONE')).equals(0);
    check(PaperbackCatalog.ratingOf('SAFE')).equals(0);
    check(PaperbackCatalog.ratingOf('MATURE')).equals(1);
    check(PaperbackCatalog.ratingOf('ADULT')).equals(2);
    check(PaperbackCatalog.ratingOf(null)).equals(2);
    final PaperbackCatalog netsky = PinnedRepository.load('netsky-0.8').catalog;
    check(netsky.entries.firstWhere((PaperbackCatalogEntry e) => e.sourceId == 'DynastyScans').contentRating).equals(2);
    check(netsky.entries.firstWhere((PaperbackCatalogEntry e) => e.sourceId == 'ReadAllComics').contentRating)
        .equals(0);
  });

  test('a catalog for another API version is refused', () {
    check(
      () => PaperbackCatalog.parse(
        Uri.parse('https://x.test/0.7/'),
        jsonEncode(<String, Object?>{
          'builtWith': <String, Object?>{'toolchain': '0.7.0', 'types': '0.7.0'},
          'sources': <Object?>[],
        }),
      ),
    ).throws<FormatException>();
  });

  test('repository URLs normalise to a base with a trailing slash', () {
    check(PaperbackCatalog.normalizeRepository(Uri.parse('https://a.test/repo/0.9/stable')).toString())
        .equals('https://a.test/repo/0.9/stable/');
    check(PaperbackCatalog.catalogUrl(Uri.parse('https://a.test/repo/0.9/stable/versioning.json?x=1')).toString())
        .equals('https://a.test/repo/0.9/stable/versioning.json');
  });

  test(
    'qualification-source availability per API family (real catalogs; the missing cell is recorded, not substituted)',
    () {
      // MangaDex, WeebCentral and MangaFire, by catalog source ID, across every
      // surveyed catalog of each family.
      bool listed(PaperbackApiFamily family, String site) => _surveyed.any((String d) {
        final PaperbackCatalog c = PinnedRepository.load(d).catalog;
        return c.family == family && c.entries.any((PaperbackCatalogEntry e) => e.sourceId.toLowerCase() == site);
      });
      final matrix = <String, Map<String, bool>>{
        for (final PaperbackApiFamily f in PaperbackApiFamily.values)
          f.wire: <String, bool>{
            for (final site in <String>['mangadex', 'weebcentral', 'mangafire']) site: listed(f, site),
          },
      };
      check(matrix).deepEquals(<String, Map<String, bool>>{
        'paperback-0.8': <String, bool>{'mangadex': true, 'weebcentral': true, 'mangafire': false},
        'paperback-0.9': <String, bool>{'mangadex': true, 'weebcentral': true, 'mangafire': true},
      });
      // The 0.8 MangaFire cell is open: no surveyed 0.8 catalog lists it.
      check(Directory('${paperbackFixtures().path}/inkdex-0.9/MangaFire').existsSync()).isTrue();
    },
  );
}
