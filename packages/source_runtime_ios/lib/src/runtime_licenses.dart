import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:source_runtime/third_party_notices.dart';
import 'package:source_runtime_ios/source_archive.dart';

/// The release tag this build was made for, set by the release workflow
/// (`--dart-define=SOURCE_RELEASE_TAG=<tag>`); empty for any other build.
// ignore: do_not_use_environment, build identity is a compile-time define by design
const String sourceReleaseTag = String.fromEnvironment('SOURCE_RELEASE_TAG');

/// The repository commit this build was made from, when the build passes it
/// (`--dart-define=SOURCE_COMMIT=<sha>`).
// ignore: do_not_use_environment, build identity is a compile-time define by design
const String sourceCommit = String.fromEnvironment('SOURCE_COMMIT');

/// The generated notices of every library the iOS app ships besides the
/// Dart packages and the runtime's own GPL notices
/// (`scripts/generate_notices.dart ios`).
const String iosThirdPartyNoticesAsset = 'packages/source_runtime_ios/notices/third_party_notices.json';

const String _runtimeAssets = 'packages/source_runtime_ios/runtime';
const String _runtimePackage = 'OpenJDK (source runtime)';

/// Where the corresponding source of the statically linked OpenJDK runtime
/// (GPLv2) is: the source archive published next to the iOS build of the
/// release [tag], or, for a build that is not a tagged release, how to build
/// that archive. Kept in code so it ships even when the runtime payload is
/// absent from a build.
String sourceRuntimeSourceNotice({String tag = sourceReleaseTag, String commit = sourceCommit}) {
  const intro = '''
This app embeds the OpenJDK mobile port (HotSpot with the Zero interpreter,
and the JDK class library), built for iOS and statically linked, under the
GNU General Public License, version 2 (HotSpot without, the class library
with the Classpath exception), and libffi $libffiVersion under the MIT licence.''';
  const contents =
      '''
The archive holds the OpenJDK mobile tree at commit
$openJdkMobileCommit, the libffi $libffiVersion release
tarball, the patches, build manifest and scripts under
tools/tachi-source-runner/ios/, the native dispatcher under
packages/source_runtime_ios/, a SHA-256 manifest and rebuilding
instructions.''';
  if (tag.isNotEmpty) {
    return '''
$intro

Corresponding source: the complete corresponding source of this runtime is
published with this release ($tag), next to its iOS build:
${sourceRuntimeArchiveUrl(tag)}
(release page: ${releasePageUrl(tag)}).
$contents''';
  }
  final from = commit.isEmpty ? '' : ' at commit $commit';
  return '''
$intro

Corresponding source: this is a development build, not a tagged release,
so no source archive was published with it. The corresponding source of
the runtime is built from the project's repository ($projectRepositoryUrl)$from
with scripts/build_gpl_source_archive.dart; every tagged release publishes
that archive next to its iOS build.
$contents''';
}

/// Adds to Flutter's [LicenseRegistry] (shown by `showLicensePage`):
/// - the runtime's source notice ([sourceRuntimeSourceNotice]), always;
/// - every GPL and third-party notice staged with the runtime image
///   (`legal/` in `layout.txt`), when the payload is in this build;
/// - each library in [iosThirdPartyNoticesAsset] with its full licence texts.
void registerSourceRuntimeLicenses({AssetBundle? bundle}) {
  LicenseRegistry.addLicense(() async* {
    final AssetBundle assets = bundle ?? rootBundle;
    yield LicenseEntryWithLineBreaks(const <String>[_runtimePackage], sourceRuntimeSourceNotice());
    String? layout;
    try {
      layout = await assets.loadString('$_runtimeAssets/layout.txt');
    } on Object {
      // No runtime payload staged in this build: nothing of OpenJDK ships.
    }
    for (final String line in layout?.split('\n') ?? const <String>[]) {
      if (line.split('\t') case ['home', final String flat, final String path] when path.startsWith('legal/')) {
        yield LicenseEntryWithLineBreaks(const <String>[
          _runtimePackage,
        ], await assets.loadString('$_runtimeAssets/$flat'));
      }
    }
    for (final ThirdPartyNotice n in parseThirdPartyNotices(await assets.loadString(iosThirdPartyNoticesAsset))) {
      yield LicenseEntryWithLineBreaks(<String>[n.name], n.text);
    }
  });
}
