/// Android source runtime boundary: the private `:source_runtime` service
/// process for Tachi APK sources, driven from Dart through JNIgen bindings
/// (KTD17, KTD18, KTD23). No platform channel carries any call.
library;

export 'src/android_source_runtime.dart';
