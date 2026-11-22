import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:source_runtime/third_party_notices.dart';

/// The generated notices of every library the APK bundles besides the Dart
/// packages (`scripts/generate_notices.dart android`): the Kotlin/Java host
/// libraries of the Tachi source host and the WebView glue (every artifact of
/// the release runtime classpath), the extracted Mihon source API, the Rust
/// crates of the scraper bridge and the Rust-based plugins, and the vendored
/// native code (QuickJS-ng, Wasm3, Zstandard), each with its full licence
/// texts.
const String androidThirdPartyNoticesAsset = 'packages/source_runtime_android/notices/third_party_notices.json';

/// Adds each library in [androidThirdPartyNoticesAsset] to Flutter's
/// [LicenseRegistry] (shown by `showLicensePage`).
void registerSourceRuntimeLicenses({AssetBundle? bundle}) {
  LicenseRegistry.addLicense(() async* {
    final String source = await (bundle ?? rootBundle).loadString(androidThirdPartyNoticesAsset);
    for (final ThirdPartyNotice n in parseThirdPartyNotices(source)) {
      yield LicenseEntryWithLineBreaks(<String>[n.name], n.text);
    }
  });
}
