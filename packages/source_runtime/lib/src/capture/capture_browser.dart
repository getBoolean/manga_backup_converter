import 'package:source_runtime/src/capture/capture_format.dart';
import 'package:source_runtime/src/contracts/browser_port.dart';

/// Status served for a browser request without a committed capture.
const int captureMissStatus = 599;

/// The capture key for a browser [request] under [captures]' matching rules
/// (method, canonical URL, body SHA-256), or `null` when the request cannot
/// be matched because its body was omitted ([BrowserRequest.bodyOmitted]).
CaptureKey? browserCaptureKey(CaptureSet captures, BrowserRequest request) =>
    request.bodyOmitted ? null : captures.manifest.keyFor(request.method, request.url, request.body);

/// A replace-tier [BrowserRequestReplacer] that serves only [captures].
///
/// Requests match on method, canonical URL and request body (so a POST such
/// as MangaFire's `verify` matches only the recorded body). A request
/// without a capture, or whose body the engine could not supply, is answered
/// with status [captureMissStatus] and reported to [onMiss]: it never
/// proceeds to the network and never matches a bodiless capture by
/// accident. Request headers take no part in matching.
BrowserRequestReplacer browserCaptureReplayReplacer(
  CaptureSet captures, {
  void Function(CaptureKey key, BrowserRequest request)? onMiss,
}) => (BrowserRequest request) {
  final CaptureKey? key = browserCaptureKey(captures, request);
  if (key == null || !captures.contains(key)) {
    onMiss?.call(key ?? captures.manifest.keyFor(request.method, request.url, null), request);
    return BrowserReplacement(
      status: captureMissStatus,
      reason: key == null ? 'Request body unavailable for capture matching' : 'No committed capture',
    );
  }
  final CapturedResponse r = captures.lookup(key);
  return BrowserReplacement(status: r.status, headers: r.headers, body: r.body);
};
