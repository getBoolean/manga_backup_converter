import 'package:desktop_webview/src/desktop_browser_port.dart';
import 'package:source_runtime/source_runtime.dart';

/// A replace-tier handler that serves [captures] and answers every request
/// without a capture with a 599 response, reporting it to [onMiss]. Combined
/// with [DesktopWebViewConfig.offline], a replayed page cannot reach a
/// server. The helper does not forward request bodies, so captures match on
/// method and URL (body-less requests).
BrowserRequestReplacer captureReplayHandler(CaptureSet captures, {void Function(CaptureKey key)? onMiss}) =>
    (BrowserRequest request) {
      final CaptureKey key = captures.manifest.keyFor(request.method, request.url, null);
      if (!captures.contains(key)) {
        onMiss?.call(key);
        return const BrowserReplacement(status: 599, reason: 'No committed capture');
      }
      final CapturedResponse r = captures.lookup(key);
      return BrowserReplacement(status: r.status, headers: r.headers, body: r.body);
    };
