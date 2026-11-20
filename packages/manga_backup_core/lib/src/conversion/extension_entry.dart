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

class StubExtensionEntry extends ExtensionEntry {
  const StubExtensionEntry({
    required super.id,
    required super.name,
    super.languages,
  });

  @override
  String get cacheKey => id;
}
