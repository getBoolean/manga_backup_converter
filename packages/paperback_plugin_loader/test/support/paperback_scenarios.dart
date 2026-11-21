import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

/// The fixed public query every Paperback qualification capture uses (the
/// same title the Aidoku and Tachi captures use).
const String qualificationQuery = 'Onimai';

/// Sites whose catalogue does not answer [qualificationQuery] search the
/// same title by another of its names.
const Map<String, String> siteQueries = <String, String>{
  // Mangahub lists the title as "Onii-Chan wa Oshimai". "Onimai" was not
  // tried; "Oshimai" was chosen as a word of that title. It also matches other
  // titles, so the Mangahub bundle names its hit ([PinnedBundle.targetMangaId]).
  'mangahub': 'Oshimai',
};

/// The query [site]'s scenario searches.
String queryFor(String site) => siteQueries[site] ?? qualificationQuery;

/// A pinned bundle under `fixtures/source_captures/paperback/<repoDir>/`.
final class PinnedBundle {
  const PinnedBundle(this.repoDir, this.sourceId, {required this.fallbackMangaId, this.targetMangaId});

  final String repoDir;
  final String sourceId;

  /// The manga fetched when search yields no hit (the capture still records
  /// a details run).
  final String fallbackMangaId;

  /// When set, the scenario fetches details for the search hit with this ID
  /// (or this ID directly when search does not list it) instead of the first
  /// hit: for a query that also matches other titles.
  final String? targetMangaId;

  String get label => '$repoDir/$sourceId';
}

/// One capture per qualification site; every bundle of that site, from both
/// API families, runs through the same recorder in one worker session.
const Map<String, List<PinnedBundle>> captureSites = <String, List<PinnedBundle>>{
  'mangadex': <PinnedBundle>[
    PinnedBundle('inkdex-0.9', 'MangaDex', fallbackMangaId: 'ed996855-70de-449f-bba2-e8e24224c14d'),
    PinnedBundle('community-0.8', 'MangaDex', fallbackMangaId: 'ed996855-70de-449f-bba2-e8e24224c14d'),
  ],
  'weebcentral': <PinnedBundle>[
    PinnedBundle('inkdex-0.9', 'WeebCentral', fallbackMangaId: '01J76XYF0TGKQ7XJ4XVPV1C0BP'),
    PinnedBundle('gabrielcwt-0.8', 'WeebCentral', fallbackMangaId: '01J76XYF0TGKQ7XJ4XVPV1C0BP'),
    PinnedBundle('numby-0.8', 'WeebCentral', fallbackMangaId: '01J76XYF0TGKQ7XJ4XVPV1C0BP'),
  ],
  'mangafire': <PinnedBundle>[PinnedBundle('inkdex-0.9', 'MangaFire', fallbackMangaId: '72k68')],
  // The 0.8 substitute for the MangaFire cell: a Cloudflare-fronted site
  // (`CLOUDFLARE_BYPASS_REQUIRED`).
  'mangahub': <PinnedBundle>[
    PinnedBundle(
      'kittycatgit-0.8',
      'Mangahub',
      fallbackMangaId: 'onii-chan-wa-oshimai',
      targetMangaId: 'onii-chan-wa-oshimai',
    ),
  ],
};

/// Cookies whose `Set-Cookie` a site's capture keeps (capture format 1.3,
/// `setCookieAllowList`); every other site keeps none. Mangahub issues its
/// API access token as the `mhub_access` cookie, a credential, so the
/// capture records that the site set it with the value `redacted`.
///
/// The committed Mangahub capture predates this allow-list and holds no
/// `Set-Cookie`; the next recording of the site picks it up.
const Map<String, Map<String, CapturedCookieValue>> captureSetCookies = <String, Map<String, CapturedCookieValue>>{
  'mangahub': <String, CapturedCookieValue>{'mhub_access': CapturedCookieValue.redact},
};

/// Terms recorded for each site's captured responses.
const Map<String, String> captureTerms = <String, String>{
  'mangadex':
      'Third-party MangaDex API response; not openly licensed; retained only as an interoperability test fixture.',
  'weebcentral':
      'Third-party WeebCentral page content; not openly licensed; retained only as an interoperability test fixture.',
  'mangafire':
      'Third-party MangaFire page content; not openly licensed; retained only as an interoperability test fixture.',
  'mangahub':
      'Third-party Mangahub API response; not openly licensed; retained only as an interoperability test fixture.',
};

/// The repository root: the first ancestor holding `fixtures/source_captures`.
Directory repoRootDir() {
  Directory dir = Directory.current.absolute;
  while (true) {
    if (Directory('${dir.path}/fixtures/source_captures').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) throw StateError('Repository root not found from ${Directory.current.path}');
    dir = parent;
  }
}

/// `fixtures/source_captures/paperback`.
Directory paperbackFixtures() => Directory('${repoRootDir().path}/fixtures/source_captures/paperback');

/// The committed catalog and pinned artifact digests of one repository.
final class PinnedRepository {
  PinnedRepository._(this.dir, this.catalog, this.pins);

  factory PinnedRepository.load(String repoDir) {
    final dir = Directory('${paperbackFixtures().path}/$repoDir');
    final manifest = jsonDecode(File('${dir.path}/artifacts.json').readAsStringSync()) as Map<String, Object?>;
    final Uri repository = Uri.parse(manifest['repository']! as String);
    final PaperbackCatalog catalog = PaperbackCatalog.parse(
      repository,
      File('${dir.path}/versioning.json').readAsStringSync(),
    );
    return PinnedRepository._(dir, catalog, <String, Map<String, Object?>>{
      for (final Object? b in manifest['bundles']! as List<Object?>)
        (b! as Map<String, Object?>)['sourceId']! as String: b as Map<String, Object?>,
    });
  }

  final Directory dir;
  final PaperbackCatalog catalog;
  final Map<String, Map<String, Object?>> pins;

  PaperbackCatalogEntry entry(String sourceId) =>
      catalog.entries.firstWhere((PaperbackCatalogEntry e) => e.sourceId == sourceId);

  Uint8List bundle(String sourceId) => File('${dir.path}/${pins[sourceId]!['path']}').readAsBytesSync();

  String pinnedSha256(String sourceId) => pins[sourceId]!['sha256']! as String;

  /// A trust decision that accepts exactly the pinned digests (a trusted
  /// pinned artifact digest, KTD6).
  static PaperbackTrustDecision pinnedTrust(Iterable<PinnedRepository> repos) {
    final allowed = <String>{
      for (final PinnedRepository r in repos)
        for (final MapEntry<String, Map<String, Object?>> p in r.pins.entries)
          '${bundleTrustKey(r.catalog.repository, p.key)}|${bundleTrustFingerprint(r.catalog.family, p.value['sha256']! as String)}',
    };
    return (Uri key, String fingerprint) async => allowed.contains('$key|$fingerprint');
  }
}

/// What one bundle produced in the site scenario.
final class BundleRun {
  BundleRun(this.bundle, this.family, this.sha256);

  final PinnedBundle bundle;
  final PaperbackApiFamily family;
  final String sha256;
  SourceOutcome<SearchPage>? page1;
  SourceOutcome<SearchPage>? page2;
  NativeMangaRef? detailsRef;
  SourceOutcome<MangaSnapshot>? details;
  SourceFailure? openFailure;

  Map<String, Object?> toJson() => <String, Object?>{
    'bundle': bundle.label,
    'apiFamily': family.wire,
    'sha256': sha256,
    if (openFailure != null) 'openFailure': openFailure!.toWire(),
    'search': _summary(
      page1,
      (SearchPage p) => <String, Object?>{
        'hits': p.hits.length,
        'first': p.hits.isEmpty
            ? null
            : <String, Object?>{'mangaId': p.hits.first.ref.mangaId, 'title': p.hits.first.title},
        'nextCursor': p.nextCursor,
      },
    ),
    if (page2 != null)
      'searchPage2': _summary(
        page2,
        (SearchPage p) => <String, Object?>{'hits': p.hits.length, 'nextCursor': p.nextCursor},
      ),
    'details': _summary(
      details,
      (MangaSnapshot s) => <String, Object?>{
        'mangaId': s.ref.mangaId,
        'title': s.metadata.title,
        'authors': s.metadata.authors,
        'status': s.metadata.status.name,
        'chapters': s.chapters.length,
        'firstChapter': s.chapters.isEmpty ? null : s.chapters.first.toJson(),
      },
    ),
  };

  static Object? _summary<T>(SourceOutcome<T>? o, Map<String, Object?> Function(T value) ok) => switch (o) {
    null => null,
    SourceSuccess<T>(:final T value) => ok(value),
    SourceFailed<T>(:final SourceFailure failure) => <String, Object?>{'failure': failure.toWire()},
  };
}

/// Runs the qualification scenario for every bundle of [site] through
/// [provider]: admit the pinned bytes, open, search [queryFor] the site,
/// fetch the next page when the source returned pagination metadata, then
/// fetch details with chapters for the first hit (the hit with the bundle's
/// [PinnedBundle.targetMangaId] when it names one; the bundle's fallback
/// manga when there is no hit). A search that needs an interaction (a Cloudflare challenge) ends
/// the bundle's run: nothing more is asked of a challenged site. The capture
/// run and the replay tests call exactly this, so they make exactly the same
/// requests.
///
/// [only] restricts the run to the bundle with that label (a re-recording of
/// one bundle, `capture_paperback_sources.dart --only`).
Future<List<BundleRun>> runSiteScenario(PaperbackSourceProvider provider, String site, {String? only}) async {
  final runs = <BundleRun>[];
  for (final PinnedBundle b in captureSites[site]!) {
    if (only != null && b.label != only) continue;
    final repo = PinnedRepository.load(b.repoDir);
    final PaperbackCatalogEntry entry = repo.entry(b.sourceId);
    final run = BundleRun(b, entry.family, repo.pinnedSha256(b.sourceId));
    runs.add(run);
    final SourceOutcome<ArtifactLease> admitted = await provider.admit(entry, repo.bundle(b.sourceId));
    if (admitted case SourceFailed<ArtifactLease>(:final SourceFailure failure)) {
      run.openFailure = failure;
      continue;
    }
    final ArtifactLease lease = (admitted as SourceSuccess<ArtifactLease>).value;
    final SourceOutcome<SourcePackage> opened = await provider.openPackage(lease, SettingsSnapshot());
    if (opened case SourceFailed<SourcePackage>(:final SourceFailure failure)) {
      run.openFailure = failure;
      lease.release();
      continue;
    }
    final SourcePackage package = (opened as SourceSuccess<SourcePackage>).value;
    try {
      final SourceSession session = package.sessions.single;
      final String query = queryFor(site);
      run.page1 = await session.search(SearchRequest(query: query));
      if (run.page1 case SourceFailed<SearchPage>(failure: InteractionRequiredFailure())) continue;
      final String? cursor = run.page1!.valueOrNull?.nextCursor;
      if (cursor != null) run.page2 = await session.search(SearchRequest(query: query, cursor: cursor));
      final List<SearchHit> hits = run.page1!.valueOrNull?.hits ?? const <SearchHit>[];
      final String? target = b.targetMangaId;
      final SearchHit? hit = target == null
          ? hits.firstOrNull
          : hits.where((SearchHit h) => h.ref.mangaId == target).firstOrNull;
      run.detailsRef =
          hit?.ref ??
          NativeMangaRef(
            source: session.identity,
            mangaId: target ?? b.fallbackMangaId,
            settingsRevision: session.settingsRevision,
          );
      run.details = await session.fetchManga(run.detailsRef!);
    } finally {
      await package.close();
      lease.release();
    }
  }
  return runs;
}
