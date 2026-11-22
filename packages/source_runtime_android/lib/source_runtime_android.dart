/// Android source runtime boundary: the private `:source_runtime` service
/// process for Tachi APK sources, the app-process WebView `BrowserPort` and
/// the Paperback and Aidoku admission checks, driven from Dart through JNIgen
/// bindings (KTD17, KTD18, KTD19, KTD23). No platform channel carries any call.
library;

export 'src/aidoku_backend.dart';
export 'src/android_source_runtime.dart';
export 'src/app_foreground.dart';
export 'src/browser_port.dart';
export 'src/paperback_backend.dart';
export 'src/runtime_licenses.dart';
export 'src/tachi_backend.dart';
