import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The bundled notices of the Android host libraries (the Tachi source host
/// in `:source_runtime` and the WebView glue): Kotlin, kotlinx, OkHttp, Okio,
/// zstd, jsoup, RxJava, Injekt, apksig, AndroidX and the extracted Mihon
/// source API. Their Dart and native counterparts are in Flutter's own
/// notices.
const String androidHostNoticesAsset = 'packages/source_runtime_android/notices/android-host-notices.txt';

/// Adds the Android host notices to Flutter's [LicenseRegistry] (shown by
/// `showLicensePage`).
void registerSourceRuntimeLicenses({AssetBundle? bundle}) {
  LicenseRegistry.addLicense(() async* {
    final String text = await (bundle ?? rootBundle).loadString(androidHostNoticesAsset);
    yield LicenseEntryWithLineBreaks(const <String>['Android source runtime host'], text);
  });
}
