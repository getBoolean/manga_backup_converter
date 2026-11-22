import 'package:source_runtime/src/capture/capture_format.dart';
import 'package:source_runtime/src/contracts/browser_port.dart';

/// The capture key for a browser [request] under [captures]' matching rules
/// (method, canonical URL, body SHA-256), or `null` when the request cannot
/// be matched because its body was omitted ([BrowserRequest.bodyOmitted]).
CaptureKey? browserCaptureKey(CaptureSet captures, BrowserRequest request) =>
    request.bodyOmitted ? null : captures.manifest.keyFor(request.method, request.url, request.body);
