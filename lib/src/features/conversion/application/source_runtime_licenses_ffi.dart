import 'package:flutter/foundation.dart';
import 'package:source_runtime_android/source_runtime_android.dart' as android;
import 'package:source_runtime_ios/source_runtime_ios.dart' as ios;

/// Notices of the platform's source runtime and the other libraries the app
/// bundles besides Dart packages: on iOS the embedded runtime's GPL notices,
/// the pointer to its corresponding source (R18) and the generated
/// third-party notices; on Android the generated third-party notices.
void registerPlatformSourceRuntimeLicenses() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
      ios.registerSourceRuntimeLicenses();
    case TargetPlatform.android:
      android.registerSourceRuntimeLicenses();
    default:
      break;
  }
}
