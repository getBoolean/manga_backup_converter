/// Desktop `BrowserPort` (KTD20): a client for the standalone
/// `desktop_webview_helper` process (wry/tao over WebView2, WKWebView and
/// WebKitGTK), the runtime artifact manifest that locates it, and replay
/// support for tests.
library;

export 'src/artifact_manifest.dart';
export 'src/capture_replay.dart';
export 'src/desktop_browser_port.dart';
export 'src/helper_process.dart';
