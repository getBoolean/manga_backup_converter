sealed class ExtensionEntry {
  const ExtensionEntry({
    required this.id,
    required this.name,
    this.languages = const <String>[],
    this.contentRating = 0,
  });

  final String id;
  final String name;
  final List<String> languages;
  final int contentRating;

  String get cacheKey;
}

class AidokuExtensionEntry extends ExtensionEntry {
  const AidokuExtensionEntry({
    required super.id,
    required super.name,
    required this.version,
    required this.iconUrl,
    required this.downloadUrl,
    super.languages,
    super.contentRating,
    this.baseUrl,
    this.altNames = const <String>[],
  });

  final int version;
  final String iconUrl;
  final String downloadUrl;
  final String? baseUrl;
  final List<String> altNames;

  @override
  String get cacheKey => '$id-v$version';
}

/// A Tachi extension package from a repository's live index. One entry is
/// one package ([id] is its repository package identifier, not a runtime
/// source ID); loading it yields every source the package enumerates.
class TachiExtensionEntry extends ExtensionEntry {
  const TachiExtensionEntry({
    required super.id,
    required super.name,
    required this.repositoryUrl,
    required this.versionName,
    required this.versionCode,
    required this.artifactKind,
    super.languages,
    super.contentRating,
    this.sourceIds = const <String>[],
  });

  /// Canonical repository URL the package was listed by.
  final String repositoryUrl;
  final String versionName;
  final int versionCode;

  /// The artifact kind selected for loading: `jar` or `apk`.
  final String artifactKind;

  /// Runtime source IDs the index lists for the package (decimal strings).
  final List<String> sourceIds;

  @override
  String get cacheKey => '$id-v$versionCode-$artifactKind';
}

/// A source bundle listed by a Paperback repository catalog (U6).
///
/// [id] is the package ID, `<repository>#<sourceId>`, unique across
/// repositories (several repositories publish a `WeebCentral`). The bundle's
/// trust decision binds its digest and [apiFamily] when it is loaded.
class PaperbackExtensionEntry extends ExtensionEntry {
  const PaperbackExtensionEntry({
    required super.id,
    required super.name,
    required this.sourceId,
    required this.version,
    required this.repository,
    required this.bundleUrl,
    required this.apiFamily,
    super.languages,
    super.contentRating,
  });

  /// The catalog source ID (bundle directory and exported source name).
  final String sourceId;
  final String version;

  /// Repository base URL.
  final String repository;

  /// Installation entry point of the bundle.
  final String bundleUrl;

  /// `paperback-0.8` or `paperback-0.9`.
  final String apiFamily;

  /// A file-name-safe key (the package ID is a URL).
  @override
  String get cacheKey => '${id.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_')}-v$version-$apiFamily';
}

class StubExtensionEntry extends ExtensionEntry {
  const StubExtensionEntry({
    required super.id,
    required super.name,
    super.languages,
  });

  @override
  String get cacheKey => id;
}
