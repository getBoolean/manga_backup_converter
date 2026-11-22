/// Where the corresponding source of the embedded iOS runtime (OpenJDK
/// mobile, HotSpot Zero; GPLv2, statically linked) is published: a release
/// asset next to each tagged iOS build on the project's GitHub releases
/// (GPLv2 section 3(a)).
///
/// Pure Dart (no Flutter imports): `scripts/build_gpl_source_archive.dart`
/// names the archive with [sourceRuntimeArchiveName], and the app's licence
/// page links to [sourceRuntimeArchiveUrl] for the same tag.
library;

/// The project's public source repository.
const String projectRepositoryUrl = 'https://github.com/getBoolean/manga_backup_converter';

/// The repository name, which also prefixes every release asset.
const String projectRepositoryName = 'manga_backup_converter';

/// The pinned OpenJDK mobile commit (`OPENJDK_MOBILE_COMMIT` in
/// `tools/tachi-source-runner/ios/manifest.env`).
const String openJdkMobileCommit = 'ad8bb1b065bf230d193a1dfd0ebd39a8b1fedf53';

/// The libffi release linked into the runtime (`LIBFFI_VERSION`).
const String libffiVersion = '3.8.1';

/// The release asset holding the runtime's corresponding source for [tag].
String sourceRuntimeArchiveName(String tag) => '$projectRepositoryName-$tag-ios-runtime-source.tar.gz';

/// The download URL of [sourceRuntimeArchiveName] on the release for [tag].
Uri sourceRuntimeArchiveUrl(String tag) =>
    Uri.parse('$projectRepositoryUrl/releases/download/$tag/${sourceRuntimeArchiveName(tag)}');

/// The release page for [tag].
Uri releasePageUrl(String tag) => Uri.parse('$projectRepositoryUrl/releases/tag/$tag');
