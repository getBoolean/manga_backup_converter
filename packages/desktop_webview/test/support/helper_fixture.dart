import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview/desktop_webview.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_testing/source_runtime_testing.dart';

import '../../tool/build_helper.dart';

/// `packages/desktop_webview`, found from the current directory.
Directory packageDir() {
  Directory dir = Directory.current.absolute;
  while (true) {
    for (final candidate in <String>[dir.path, p.join(dir.path, 'packages', 'desktop_webview')]) {
      if (File(p.join(candidate, 'helper', 'Cargo.toml')).existsSync()) return Directory(candidate);
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) throw StateError('packages/desktop_webview not found from ${Directory.current.path}');
    dir = parent;
  }
}

/// Repository root (the directory holding `fixtures/`).
Directory repoRoot() => packageDir().parent.parent;

final class _HelperCache {
  Future<File?>? built;
  String? unavailableReason;
}

final _cache = _HelperCache();

/// Why [builtHelper] returned `null`.
String? get helperUnavailableReason => _cache.unavailableReason;

/// Builds the helper with `tool/build_helper.dart` (debug, `--locked`) and
/// returns the binary verified against the runtime artifact manifest, or
/// `null` (with [helperUnavailableReason]) when cargo is unavailable.
Future<File?> builtHelper() => _cache.built ??= () async {
  try {
    final HelperBuild build = await buildHelper(packageDir: packageDir());
    final RuntimeArtifact? artifact = RuntimeArtifactManifest.load(
      build.manifestFile,
    ).findForHost(RuntimeArtifactManifest.webviewHelper);
    return artifact!.verifiedFile();
  } on HelperBuildException catch (e) {
    _cache.unavailableReason = e.message;
    return null;
  }
}();

/// Test override values for the KTD25 bounds (not product defaults).
DesktopWebViewConfig testConfig(
  File helper,
  Directory dataRoot, {
  bool allowVisibleWindows = false,
  bool offline = true,
  bool testHooks = true,
  List<String> extraArguments = const <String>[],
  List<String>? log,
}) => DesktopWebViewConfig(
  helperExecutable: helper,
  dataRoot: dataRoot,
  startupTimeout: const Duration(seconds: 60),
  shutdownGrace: const Duration(seconds: 10),
  allowVisibleWindows: allowVisibleWindows,
  offline: offline,
  testHooks: testHooks,
  extraArguments: extraArguments,
  onLog: log?.add,
);

/// Local HTTP fixture server (loopback only; tests never contact a server).
///
/// A second listener on another port is a different origin; it serves the
/// cross-origin child frame of `/framed`.
class FixtureServer {
  FixtureServer._(this._server, this._other) {
    _server.listen(_handle);
    // dart:io sends X-Frame-Options: SAMEORIGIN by default, which would stop
    // the cross-origin frame from rendering at all.
    _other.defaultResponseHeaders.removeAll('x-frame-options');
    _other.listen(_handleOther);
  }

  static Future<FixtureServer> start() async => FixtureServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  final HttpServer _server;
  final HttpServer _other;
  final List<Completer<void>> _held = <Completer<void>>[];

  /// Set by [releaseHeld] and cleared by [armHeld]: a `/hold` request that
  /// arrives after its release (the fetch raced the release) is not held.
  bool _released = false;

  /// Request headers seen per path, in arrival order.
  final List<(String, Map<String, String>)> seen = <(String, Map<String, String>)>[];

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  /// [path] on the second (cross-origin) listener.
  Uri otherOriginUrl(String path) => Uri.parse('http://127.0.0.1:${_other.port}$path');

  /// The cross-origin frame: on a window message `{name, message}` it calls
  /// `window[name].postMessage(message)` and tells its parent it did.
  static const String _framePage = '''
<html><head><title>frame</title><script>
var done = false;
addEventListener('message', function (e) {
  if (done) return;
  done = true;
  try { window[e.data.name].postMessage(e.data.message); } catch (err) {}
  parent.postMessage('posted', '*');
});
</script></head><body>frame</body></html>''';

  Future<void> _handleOther(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write(_framePage);
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((String name, List<String> values) => headers[name] = values.join(', '));
    seen.add((request.uri.path, headers));
    final HttpResponse r = request.response;
    try {
      switch (request.uri.path) {
        case '/to-file':
          r.statusCode = HttpStatus.found;
          r.headers.set(HttpHeaders.locationHeader, 'file:///C:/Windows/win.ini');
        case '/hold':
          if (!_released) {
            final c = Completer<void>();
            _held.add(c);
            await c.future;
          }
          r.headers.contentType = ContentType.json;
          r.write('{}');
        case '/framed':
          r.headers.contentType = ContentType.html;
          r.write(
            '<html><head><title>framed</title></head><body>'
            '<iframe src="${otherOriginUrl('/frame')}"></iframe></body></html>',
          );
        case '/same-framed':
          r.headers.contentType = ContentType.html;
          r.write('<html><head><title>same</title></head><body><iframe src="/page"></iframe></body></html>');
        case '/set-cookie':
          r.headers.add(HttpHeaders.setCookieHeader, 'server=1; Path=/');
          r.headers.contentType = ContentType.html;
          r.write('<html><head><title>cookie</title></head></html>');
        default:
          r.headers.contentType = ContentType.html;
          r.write('<html><head><title>contract</title></head><body>fixture</body></html>');
      }
      await r.close();
    } on Object {
      // The WebView went away mid-response (closed or fenced session).
    }
  }

  /// Holds `/hold` requests until the next [releaseHeld].
  void armHeld() => _released = false;

  /// Completes every held `/hold` request, and later-arriving ones.
  Future<void> releaseHeld() async {
    _released = true;
    for (final Completer<void> c in _held) {
      if (!c.isCompleted) c.complete();
    }
    _held.clear();
  }

  Future<void> close() async {
    await releaseHeld();
    await _server.close(force: true);
    await _other.close(force: true);
  }
}

/// [BrowserPortHarness] for [DesktopBrowserPort] over the real helper.
///
/// Runs with visible windows disabled (`canShowInteraction == false`): the
/// contract suite's displayed branch expects an immediate completion, which a
/// real window cannot give unaided. The visible path is covered by
/// `desktop_browser_port_test.dart`.
class DesktopBrowserPortHarness implements BrowserPortHarness {
  DesktopBrowserPortHarness(this.helper, this.server, this.dataRoot);

  final File helper;
  final FixtureServer server;
  final Directory dataRoot;
  DesktopBrowserPort? _port;

  @override
  Future<BrowserPort> start() async => _port = DesktopBrowserPort(testConfig(helper, dataRoot));

  @override
  Future<void> kill() async => _port?.debugKillHelper();

  @override
  Future<void> stop() async {
    await server.releaseHeld();
    await _port?.dispose();
    _port = null;
  }

  @override
  Uri get pageUrl => server.url('/page');

  @override
  Uri get redirectToFileUrl => server.url('/to-file');

  @override
  bool get canShowInteraction => false;

  @override
  String heldScript(String resultJson) {
    server.armHeld();
    return _held(resultJson);
  }

  static String _held(String resultJson) => 'fetch("/hold").then(function () { return $resultJson; })';

  @override
  Future<void> releaseHeld() => server.releaseHeld();

  @override
  Uri get crossOriginFramePageUrl => server.url('/framed');

  /// Completes once the cross-origin child frame has called
  /// `window.<name>.postMessage(message)`.
  @override
  String crossOriginFramePostScript(String name, String message) =>
      // Re-posts until the frame acknowledges: the frame may still be
      // loading when the top document's load completes.
      'new Promise(function (resolve) { '
      'var timer = setInterval(send, 100); '
      'function send() { document.querySelector("iframe").contentWindow.postMessage( '
      '{name: ${jsonEncode(name)}, message: ${jsonEncode(message)}}, "*"); } '
      'addEventListener("message", function h(e) { '
      'if (e.data === "posted") { clearInterval(timer); removeEventListener("message", h); resolve("posted"); } '
      '}); '
      'send(); '
      '})';
}
