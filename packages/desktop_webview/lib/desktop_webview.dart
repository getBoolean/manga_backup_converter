/// Desktop `BrowserPort` (KTD20): a client for the standalone
/// `desktop_webview_helper` process (wry/tao over WebView2, WKWebView and
/// WebKitGTK) and the runtime artifact manifest that locates it. Offline
/// replay serves committed captures to every session
/// (`BrowserCaptureReplay`); manual capture runs record a session's traffic
/// (`BrowserCaptureRecorder`).
library;

export 'src/artifact_manifest.dart';
export 'src/browser_capture.dart';
export 'src/desktop_browser_port.dart';
export 'src/helper_process.dart';
