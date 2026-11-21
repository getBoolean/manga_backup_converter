import 'dart:convert';

import 'package:paperback_plugin_loader/src/admission.dart';
import 'package:source_runtime/source_contracts.dart';

/// One source listed in a Paperback repository's `versioning.json`.
final class PaperbackCatalogEntry {
  const PaperbackCatalogEntry({
    required this.repository,
    required this.family,
    required this.sourceId,
    required this.name,
    required this.version,
    required this.bundleUrl,
    required this.contentRating,
    this.languages = const <String>[],
    this.description,
  });

  final Uri repository;
  final PaperbackApiFamily family;

  /// The catalog `id`: the bundle directory and the exported source name.
  final String sourceId;
  final String name;
  final String version;

  /// The installation entry point: `<repository>/<sourceId>/<entry file>`.
  final Uri bundleUrl;

  /// 0 safe, 1 suggestive, 2 adult (unknown ratings count as adult), the
  /// scale `SourceRatingPolicy` uses.
  final int contentRating;
  final List<String> languages;
  final String? description;

  /// The package ID this bundle is hosted under: unique per repository and
  /// source, stable across versions.
  String get packageId => '$repository#$sourceId';

  ContentRatingLevel get contentRatingLevel => switch (contentRating) {
    0 => ContentRatingLevel.safe,
    1 => ContentRatingLevel.suggestive,
    _ => ContentRatingLevel.nsfw,
  };

  PackageListing toListing() => PackageListing(
    packageId: packageId,
    name: name,
    version: version,
    downloadUrl: bundleUrl,
    languages: languages,
    contentRating: contentRatingLevel,
  );
}

/// A parsed repository catalog.
final class PaperbackCatalog {
  const PaperbackCatalog({
    required this.repository,
    required this.family,
    required this.entries,
    this.name,
    this.toolchain,
    this.types,
  });

  final Uri repository;
  final PaperbackApiFamily family;
  final List<PaperbackCatalogEntry> entries;
  final String? name;

  /// `builtWith.toolchain` and `builtWith.types`.
  final String? toolchain;
  final String? types;

  /// Where a repository publishes its catalog.
  static Uri catalogUrl(Uri repository) => normalizeRepository(repository).resolve('versioning.json');

  /// The repository base URL with a trailing slash, so relative paths
  /// resolve inside it.
  static Uri normalizeRepository(Uri repository) {
    String path = repository.path;
    if (path.endsWith('/versioning.json')) path = path.substring(0, path.length - 'versioning.json'.length);
    if (!path.endsWith('/')) path = '$path/';
    return Uri(
      scheme: repository.scheme,
      host: repository.host,
      port: repository.hasPort ? repository.port : null,
      path: path,
    );
  }

  /// Parses `versioning.json`. Both layouts carry `builtWith.types`, which
  /// selects the API family; 0.8 entries also carry `author`/`desc`/
  /// `websiteBaseURL`, 0.9 entries `language`/`capabilities`/`developers`.
  /// A catalog for any other API version is a [FormatException].
  static PaperbackCatalog parse(Uri repository, String json) {
    final Object? decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) throw const FormatException('versioning.json is not an object');
    final builtWith = decoded['builtWith'] as Map<String, Object?>? ?? const <String, Object?>{};
    final types = builtWith['types'] as String?;
    final PaperbackApiFamily family =
        PaperbackApiFamily.fromTypesVersion(types) ??
        (throw FormatException('Unsupported Paperback API version: builtWith.types = ${types ?? 'missing'}'));
    final Uri base = normalizeRepository(repository);
    final sources = decoded['sources'] as List<Object?>? ?? const <Object?>[];
    final entries = <PaperbackCatalogEntry>[
      for (final Object? s in sources)
        if (s is Map<String, Object?> && s['id'] is String && s['version'] is String)
          PaperbackCatalogEntry(
            repository: base,
            family: family,
            sourceId: s['id']! as String,
            name: s['name'] as String? ?? s['id']! as String,
            version: s['version']! as String,
            bundleUrl: base.resolve('${Uri.encodeComponent(s['id']! as String)}/${family.entryFile}'),
            contentRating: ratingOf(s['contentRating'] as String?),
            languages: <String>[
              if (s['language'] case final String l when l.isNotEmpty) l,
            ],
            description: (s['description'] ?? s['desc']) as String?,
          ),
    ];
    final repo = decoded['repository'] as Map<String, Object?>?;
    return PaperbackCatalog(
      repository: base,
      family: family,
      entries: entries,
      name: repo?['name'] as String?,
      toolchain: builtWith['toolchain'] as String?,
      types: types,
    );
  }

  /// Paperback ratings on the `SourceRatingPolicy` scale: EVERYONE (0.8) and
  /// SAFE (0.9) are safe, MATURE suggestive, ADULT and anything unknown
  /// adult.
  static int ratingOf(String? rating) => switch (rating?.toUpperCase()) {
    'EVERYONE' || 'SAFE' => 0,
    'MATURE' => 1,
    _ => 2,
  };
}
