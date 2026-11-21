import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The embedded runtime's notices as staged in the package assets.
const List<String> _runtimeNotices = <String>[
  'home__legal__LICENSE',
  'home__legal__ASSEMBLY_EXCEPTION',
  'home__legal__ADDITIONAL_LICENSE_INFO',
];

/// Written offer of the corresponding source of the statically linked
/// OpenJDK runtime (GPLv2, KTD11). Kept in code so it ships even when the
/// runtime payload is absent from a build.
const String sourceRuntimeSourceOffer = '''
This app embeds the OpenJDK mobile port (HotSpot Zero interpreter and the
JDK class library), statically linked, under the GNU General Public License,
version 2 (HotSpot without, the class library with the Classpath exception),
and libffi under the MIT licence.

Written offer: for at least three years after we last distribute this app,
anyone may obtain the complete corresponding source code from us, at no
charge beyond the cost of physically performing the transfer, by asking
through the project's issue tracker. It comprises the OpenJDK mobile
repository at commit ad8bb1b065bf230d193a1dfd0ebd39a8b1fedf53, libffi
3.8.1, our patches, build manifest and scripts under
tools/tachi-source-runner/ios/ in the app's source repository, and the native
dispatcher under packages/source_runtime_ios/src/.''';

/// Adds the embedded runtime's GPL notices and the written source offer to
/// Flutter's [LicenseRegistry] (shown by `showLicensePage`). Notices missing
/// from the bundle are skipped; the offer is always registered.
void registerSourceRuntimeLicenses({AssetBundle? bundle}) {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(<String>['OpenJDK (source runtime)'], sourceRuntimeSourceOffer);
    final AssetBundle assets = bundle ?? rootBundle;
    for (final String name in _runtimeNotices) {
      try {
        final String text = await assets.loadString('packages/source_runtime_ios/runtime/$name');
        yield LicenseEntryWithLineBreaks(<String>['OpenJDK (source runtime)'], text);
      } on Object {
        // Not staged in this build.
      }
    }
  });
}
