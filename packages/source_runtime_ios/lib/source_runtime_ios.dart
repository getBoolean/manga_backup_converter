/// Embedded interpreter-only JVM and WKWebView bindings for iOS source
/// runners: the U16 gate surface, the U9 local Tachi backend, and the
/// WKWebView `BrowserPort` (U10) (KTD11, KTD12, KTD13, KTD20, KTD23).
library;

export 'src/in_vm_worker.dart';
export 'src/ios_jvm_runtime.dart';
export 'src/tachi_backend.dart';
export 'src/wkwebview_browser_port.dart';
export 'src/wkwebview_replay.dart';
