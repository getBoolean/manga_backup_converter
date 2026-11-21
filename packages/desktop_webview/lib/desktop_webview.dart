/// Desktop `BrowserPort` (KTD20): a client for the standalone
/// `desktop_webview_helper` process (wry/tao over WebView2, WKWebView and
/// WebKitGTK) and the runtime artifact manifest that locates it. Offline
/// replay uses `browserCaptureReplayReplacer` from `package:source_runtime`.
library;

export 'src/artifact_manifest.dart';
export 'src/desktop_browser_port.dart';
export 'src/helper_process.dart';
