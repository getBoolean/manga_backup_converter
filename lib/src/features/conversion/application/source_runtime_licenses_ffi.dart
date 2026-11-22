import 'package:flutter/foundation.dart';
import 'package:source_runtime_android/source_runtime_android.dart' as android;
import 'package:source_runtime_ios/source_runtime_ios.dart' as ios;

/// Notices of the platform's source runtime: the embedded iOS runtime's GPL
/// notices and source offer (R18), or the Android host libraries' notices.
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
