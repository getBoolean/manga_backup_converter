import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:objective_c/objective_c.dart' as objc;

import 'package:source_runtime_ios/src/webkit_bindings.g.dart';

/// Outcome of replaying a Tachi source's WebView use on WKWebView.
final class WebViewReplayResult {
  WebViewReplayResult({
    required this.pageReport,
    required this.messageFrameIsMain,
    required this.messageOrigin,
    required this.cookies,
    required this.storePersistent,
    required this.elapsedMs,
  });

  /// JSON object the page posted through the fallback bridge.
  final Map<String, Object?> pageReport;
  final bool messageFrameIsMain;
  final String messageOrigin;

  /// `name=value; domain` of every cookie in the session's data store.
  final List<String> cookies;
  final bool storePersistent;
  final double elapsedMs;
}

final class WebViewReplayException implements Exception {
  WebViewReplayException(this.message);
  final String message;
  @override
  String toString() => 'WebViewReplayException($message)';
}

/// Replays the browser behaviour of keiyoushi's `runWebViewBlocking` fallback
/// path (as used by MangaFire's challenge solver) on WKWebView through FFIgen
/// WebKit bindings:
///
/// * user-agent override (`WebSettings.setUserAgentString` -> `customUserAgent`);
/// * `loadDataWithBaseURL` -> `loadData:MIMEType:characterEncodingName:baseURL:`;
/// * `addJavascriptInterface(obj, name)` with a `void postMessage(String)` method
///   -> a page-start `WKUserScript` that defines `window[name].postMessage`
///   forwarding to a `WKScriptMessageHandler` (no synchronous return value);
/// * a per-source non-persistent `WKWebsiteDataStore`.
///
/// Runs on the platform thread (Flutter 3.50 runs the root isolate there on
/// iOS); delegate callbacks arrive as listener callbacks. Request observation
/// (`shouldInterceptRequest`) has no WKWebView equivalent for https and is
/// reported by callers as a capability gap.
abstract final class WKWebViewReplay {
  static const _handlerName = 'srtBridge';

  static Future<WebViewReplayResult> run({
    required String html,
    required String baseUrl,
    required String userAgent,
    required String interfaceName,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final stopwatch = Stopwatch()..start();
    final message = Completer<(String, bool, String)>();
    final navigation = Completer<void>();

    final WKScriptMessageHandler handler = WKScriptMessageHandler$Builder.implementAsListener(
      userContentController_didReceiveScriptMessage_: (controller, msg) {
        final objc.ObjCObject body = msg.body;
        if (message.isCompleted) return;
        if (!objc.NSString.isA(body)) {
          message.completeError(WebViewReplayException('message body is not a string'));
          return;
        }
        final WKFrameInfo frame = msg.frameInfo;
        final WKSecurityOrigin origin = frame.securityOrigin;
        message.complete((
          objc.NSString.as(body).toDartString(),
          frame.isMainFrame,
          '${origin.protocol.toDartString()}://${origin.host.toDartString()}',
        ));
      },
    );
    final WKNavigationDelegate delegate = WKNavigationDelegate$Builder.implementAsListener(
      webView_didFinishNavigation_: (_, _) {
        if (!navigation.isCompleted) navigation.complete();
      },
      webView_didFailNavigation_withError_: (_, _, error) {
        if (!navigation.isCompleted) {
          navigation.completeError(WebViewReplayException(error.localizedDescription.toDartString()));
        }
      },
      webView_didFailProvisionalNavigation_withError_: (_, _, error) {
        if (!navigation.isCompleted) {
          navigation.completeError(WebViewReplayException(error.localizedDescription.toDartString()));
        }
      },
    );

    final WKUserContentController controller = WKUserContentController.new$();
    controller.addUserScript(
      WKUserScript.alloc().initWithSource(
        _interfaceShim(interfaceName).toNSString(),
        injectionTime: WKUserScriptInjectionTime.WKUserScriptInjectionTimeAtDocumentStart,
        forMainFrameOnly: true,
      ),
    );
    controller.addScriptMessageHandler(handler, name: _handlerName.toNSString());

    final WKWebsiteDataStore store = WKWebsiteDataStore.nonPersistentDataStore();
    final WKWebViewConfiguration configuration = WKWebViewConfiguration.new$()
      ..userContentController = controller
      ..websiteDataStore = store;

    final objc.CGRect frame = Struct.create<objc.CGRect>();
    frame.size.width = 390;
    frame.size.height = 844;
    final WKWebView webView = WKWebView.alloc().initWithFrame(frame, configuration: configuration);
    webView.customUserAgent = userAgent.toNSString();
    webView.navigationDelegate = delegate;

    final objc.NSURL? base = objc.NSURL.URLWithString(baseUrl.toNSString());
    if (base == null) throw WebViewReplayException('invalid base URL $baseUrl');
    try {
      webView.loadData(
        utf8.encode(html).toNSData(),
        MIMEType: 'text/html'.toNSString(),
        characterEncodingName: 'utf-8'.toNSString(),
        baseURL: base,
      );
      await navigation.future.timeout(timeout);
      final (String body, bool isMain, String origin) = await message.future.timeout(timeout);
      final List<String> cookies = await _cookies(store).timeout(timeout);
      return WebViewReplayResult(
        pageReport: jsonDecode(body) as Map<String, Object?>,
        messageFrameIsMain: isMain,
        messageOrigin: origin,
        cookies: cookies,
        storePersistent: store.isPersistent,
        elapsedMs: stopwatch.elapsedMicroseconds / 1000,
      );
    } finally {
      webView.stopLoading();
      controller.removeScriptMessageHandlerForName(_handlerName.toNSString());
      controller.removeAllUserScripts();
    }
  }

  // Equivalent of addJavascriptInterface(object, name) for an object whose
  // only method is `void postMessage(String)`.
  static String _interfaceShim(String name) =>
      '''
(function () {
  var handler = window.webkit.messageHandlers.$_handlerName;
  window[${jsonEncode(name)}] = Object.freeze({
    postMessage: function (message) { handler.postMessage(String(message)); }
  });
  window.__srtDocumentStart = true;
})();
''';

  static Future<List<String>> _cookies(WKWebsiteDataStore store) {
    final completer = Completer<List<String>>();
    store.httpCookieStore.getAllCookies(
      ObjCBlock_ffiVoid_NSArray.listener((objc.NSArray array) {
        final out = <String>[];
        for (var i = 0; i < array.count; i++) {
          final cookie = NSHTTPCookie.as(array.objectAtIndex(i));
          out.add('${cookie.name.toDartString()}=${cookie.value.toDartString()}; ${cookie.domain.toDartString()}');
        }
        completer.complete(out);
      }),
    );
    return completer.future;
  }
}
