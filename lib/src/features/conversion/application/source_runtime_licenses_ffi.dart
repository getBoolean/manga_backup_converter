import 'package:flutter/foundation.dart';
import 'package:source_runtime_ios/source_runtime_ios.dart'
    show registerSourceRuntimeLicenses;

/// GPL notices and source offer of the embedded iOS runtime (R18).
void registerPlatformSourceRuntimeLicenses() {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    registerSourceRuntimeLicenses();
  }
}
