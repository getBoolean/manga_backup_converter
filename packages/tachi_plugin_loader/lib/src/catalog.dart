import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:source_runtime/source_contracts.dart';

/// Fetches the bytes at a URL. Injected so tests serve committed fixtures and
/// never contact a server.
typedef TachiFetch = Future<Uint8List> Function(Uri url);

/// A repository's metadata or index could not be read or parsed.
final class TachiCatalogException implements Exception {
  const TachiCatalogException(this.message);

  final String message;

  @override
  String toString() => 'TachiCatalogException: $message';
}

/// The two artifact kinds a Tachi repository may publish for a package
/// (KTD5). Both are first-class; neither is a fallback.
enum TachiArtifactKind { jar, apk }

/// Files a repository publishes beside its `repo.json`. A user may paste any
/// of them; all name the same repository.
const List<String> _repositoryFiles = <String>['repo.json', 'index.json', 'index.min.json'];

/// The canonical identity of a Tachi repository: the directory URL that holds
/// `repo.json` and `index.json`, without a trailing slash.
///
/// `…/repo/repo.json`, `…/repo/index.json`, `…/repo/index.min.json` and
/// `…/repo/` all name `…/repo`, so trust decisions and cache entries are keyed
/// once per repository however the user spelled it.
Uri tachiRepositoryBase(Uri input) {
  final segments = <String>[...input.pathSegments];
  while (segments.isNotEmpty && segments.last.isEmpty) {
    segments.removeLast();
  }
  if (segments.isNotEmpty && _repositoryFiles.contains(segments.last)) segments.removeLast();
  return Uri(
    scheme: input.scheme,
    userInfo: input.userInfo,
    host: input.host,
    port: input.hasPort ? input.port : null,
    pathSegments: segments,
  );
}

/// `repo.json`: the repository's name and published signing fingerprint.
///
/// The fingerprint read here proves consistency, not provenance (KTD5): it
/// becomes a trust anchor only after the user approves it (or a manifest pins
/// it) through the core repository trust gate.
@immutable
final class TachiRepository {
  const TachiRepository({
    required this.baseUrl,
    required this.name,
    required this.signingKeyFingerprint,
    this.shortName,
    this.website,
  });

  /// Parses a `repo.json` document (`{"meta": {...}}`) served from [baseUrl].
  factory TachiRepository.fromJson(Uri baseUrl, Object? json) {
    final Map<String, Object?> meta = switch (json) {
      {'meta': final Map<String, Object?> meta} => meta,
      _ => throw const TachiCatalogException('repo.json has no "meta" object'),
    };
    final String fingerprint;
    try {
      fingerprint = ArtifactTrustAnchor.normalizeFingerprint(
        _requireString(meta, 'signingKeyFingerprint', 'repo.json'),
      );
    } on FormatException catch (e) {
      throw TachiCatalogException('repo.json signingKeyFingerprint: ${e.message}');
    }
    return TachiRepository(
      baseUrl: tachiRepositoryBase(baseUrl),
      name: _requireString(meta, 'name', 'repo.json'),
      shortName: meta['shortName'] as String?,
      website: meta['website'] as String?,
      signingKeyFingerprint: fingerprint,
    );
  }

  /// Canonical repository URL ([tachiRepositoryBase]).
  final Uri baseUrl;
  final String name;
  final String? shortName;
  final String? website;

  /// The published certificate SHA-256 (64 lowercase hex digits).
  final String signingKeyFingerprint;

  Uri get repoJsonUrl => _child(baseUrl, 'repo.json');

  /// The live index. Never `index.min.json`, which keiyoushi leaves as a
  /// stale stub (plan appendix, Tachi artifacts).
  Uri get indexUrl => _child(baseUrl, 'index.json');
}

/// One source a package enumerates, as the index lists it. [id] is the
/// runtime source ID — distinct from the package's repository identifier.
@immutable
final class TachiIndexSource {
  const TachiIndexSource({required this.id, required this.name, required this.language, this.homeUrl});

  /// Decimal int64 source ID, kept as a string (KTD3).
  final Int64Id id;
  final String name;
  final String language;
  final String? homeUrl;
}

/// One package published by a repository's live `index.json`.
@immutable
final class TachiPackageListing {
  const TachiPackageListing({
    required this.repository,
    required this.packageId,
    required this.name,
    required this.versionName,
    required this.versionCode,
    required this.extensionLib,
    required this.sources,
    this.jarUrl,
    this.apkUrl,
    this.iconUrl,
    this.contentWarning,
  });

  final TachiRepository repository;

  /// The repository package identifier (Android package name). Never a
  /// runtime source ID.
  final String packageId;
  final String name;
  final String versionName;
  final int versionCode;

  /// The extensions-lib version the package was built against (`1.6`).
  final String extensionLib;
  final List<TachiIndexSource> sources;
  final Uri? jarUrl;
  final Uri? apkUrl;
  final Uri? iconUrl;

  /// The index's raw content warning, for example `CONTENT_WARNING_MIXED`.
  final String? contentWarning;

  /// The worker API family this package needs, as the worker reports its
  /// supported families in the handshake (`tachi-1.6`).
  String get apiFamily => 'tachi-$extensionLib';

  /// The published artifact URL of [kind], or `null` when not published.
  Uri? urlFor(TachiArtifactKind kind) => switch (kind) {
    TachiArtifactKind.jar => jarUrl,
    TachiArtifactKind.apk => apkUrl,
  };

  /// Distinct source languages, in index order.
  List<String> get languages => <String>{for (final TachiIndexSource s in sources) s.language}.toList();

  /// The content rating the selection policy applies.
  ///
  /// Only `CONTENT_WARNING_MIXED` is evidenced in the committed index excerpt;
  /// it maps to suggestive (the package may show mature content but is not an
  /// adult-only source). `CONTENT_WARNING_SAFE` maps to safe. Every other or
  /// missing value is unknown, which the rating policy treats as adult.
  ContentRatingLevel get contentRating => switch (contentWarning) {
    'CONTENT_WARNING_SAFE' => ContentRatingLevel.safe,
    'CONTENT_WARNING_MIXED' => ContentRatingLevel.suggestive,
    _ => ContentRatingLevel.unknown,
  };
}

/// Parses a live `index.json` (an array of package objects with
/// `packageName`, `resources.{jarUrl,apkUrl,iconUrl}` and `sources`) for
/// [repository]. A malformed entry fails the whole index rather than being
/// skipped silently.
List<TachiPackageListing> parseTachiIndex(TachiRepository repository, Object? json) {
  if (json is! List<Object?>) throw const TachiCatalogException('index.json is not a JSON array');
  return <TachiPackageListing>[
    for (final (int i, Object? entry) in json.indexed) _parseListing(repository, entry, 'index.json[$i]'),
  ];
}

TachiPackageListing _parseListing(TachiRepository repository, Object? json, String where) {
  if (json is! Map<String, Object?>) throw TachiCatalogException('$where is not an object');
  final String packageId = _requireString(json, 'packageName', where);
  final Map<String, Object?> resources = switch (json['resources']) {
    final Map<String, Object?> r => r,
    null => const <String, Object?>{},
    _ => throw TachiCatalogException('$where.resources is not an object'),
  };
  Uri? url(String key) {
    final Object? value = resources[key];
    if (value == null) return null;
    if (value is! String) throw TachiCatalogException('$where.resources.$key is not a string');
    final Uri parsed = repository.baseUrl.resolve(value);
    if (parsed.scheme != 'https' && parsed.scheme != 'http') {
      throw TachiCatalogException('$where.resources.$key is not an http(s) URL');
    }
    return parsed;
  }

  final Uri? jarUrl = url('jarUrl');
  final Uri? apkUrl = url('apkUrl');
  if (jarUrl == null && apkUrl == null) throw TachiCatalogException('$where ($packageId) publishes no artifact');
  final String versionCode = _requireString(json, 'versionCode', where);
  final int? code = int.tryParse(versionCode);
  if (code == null) throw TachiCatalogException('$where.versionCode is not an integer');
  final Object? sources = json['sources'];
  if (sources is! List<Object?> || sources.isEmpty) throw TachiCatalogException('$where ($packageId) lists no sources');
  return TachiPackageListing(
    repository: repository,
    packageId: packageId,
    name: _requireString(json, 'name', where),
    versionName: _requireString(json, 'versionName', where),
    versionCode: code,
    extensionLib: _requireString(json, 'extensionLib', where),
    contentWarning: json['contentWarning'] as String?,
    jarUrl: jarUrl,
    apkUrl: apkUrl,
    iconUrl: url('iconUrl'),
    sources: <TachiIndexSource>[
      for (final (int i, Object? s) in sources.indexed) _parseSource(s, '$where.sources[$i]'),
    ],
  );
}

TachiIndexSource _parseSource(Object? json, String where) {
  if (json is! Map<String, Object?>) throw TachiCatalogException('$where is not an object');
  final Int64Id id;
  try {
    id = Int64Id.fromJson(json['id']);
  } on FormatException catch (e) {
    throw TachiCatalogException('$where.id: ${e.message}');
  }
  return TachiIndexSource(
    id: id,
    name: _requireString(json, 'name', where),
    language: _requireString(json, 'language', where),
    homeUrl: json['homeUrl'] as String?,
  );
}

/// Reads repositories: `repo.json` first, then the live `index.json` beside
/// it.
final class TachiCatalog {
  const TachiCatalog(this.fetch);

  final TachiFetch fetch;

  /// Reads `repo.json` for the repository [input] names (any spelling
  /// accepted by [tachiRepositoryBase]).
  Future<TachiRepository> fetchRepository(Uri input) async {
    final Uri base = tachiRepositoryBase(input);
    final Uri url = _child(base, 'repo.json');
    return TachiRepository.fromJson(base, await _fetchJson(url));
  }

  /// Reads [repository]'s live `index.json`.
  Future<List<TachiPackageListing>> fetchPackages(TachiRepository repository) async =>
      parseTachiIndex(repository, await _fetchJson(repository.indexUrl));

  Future<Object?> _fetchJson(Uri url) async {
    final Uint8List bytes = await fetch(url);
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw TachiCatalogException('$url is not JSON: ${e.message}');
    }
  }
}

Uri _child(Uri base, String name) => base.replace(pathSegments: <String>[...base.pathSegments, name]);

String _requireString(Map<String, Object?> json, String key, String where) => switch (json[key]) {
  final String value when value.isNotEmpty => value,
  _ => throw TachiCatalogException('$where.$key is missing or not a string'),
};
