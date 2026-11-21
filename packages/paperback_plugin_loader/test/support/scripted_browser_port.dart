import 'dart:convert';

import 'package:source_runtime/source_runtime.dart';

/// A [BrowserPort] test double that "runs" injected scripts by answering
/// from [respond], the way a page would: the injected function's result is
/// posted on the registered message channel. It records what the host sent
/// (HTML, base URL, user agent, cookies) so tests can check the context, and
/// keeps per-session cookies so tests can check they come back.
///
/// With [evaluateUnavailable] set, `evaluate` fails as a platform that
/// cannot express it would.
final class ScriptedBrowserPort implements BrowserPort {
  ScriptedBrowserPort({
    required this.respond,
    this.evaluateUnavailable = false,
    this.setCookiesOnLoad = const <BrowserCookie>[],
  });

  /// The injected function's result for a page, as JSON-able data.
  final Object? Function(ScriptedPage page) respond;
  final bool evaluateUnavailable;

  /// Cookies the "page" sets while loading (for example a challenge cookie).
  final List<BrowserCookie> setCookiesOnLoad;

  final List<ScriptedPage> pages = <ScriptedPage>[];
  final List<String> closed = <String>[];
  int _n = 0;

  @override
  Future<BrowserOutcome<void>> wipeAllSourceData() async => const BrowserCompleted<void>(null);

  @override
  Future<void> fence(int generation) async {}

  @override
  Future<BrowserOutcome<BrowserSession>> openSession(
    BrowserSessionRequest request, {
    CancellationToken? cancel,
  }) async => BrowserCompleted<BrowserSession>(_Session(this, 's${++_n}', request));
}

/// What one session loaded.
final class ScriptedPage {
  ScriptedPage(this.userAgent);

  final String? userAgent;
  String? html;
  Uri? baseUrl;
  final Map<String, BrowserCookie> cookies = <String, BrowserCookie>{};
  final List<String> scripts = <String>[];
}

final class _Session implements BrowserSession {
  _Session(this._port, this.id, this._request) : _page = ScriptedPage(_request.userAgent) {
    _port.pages.add(_page);
  }

  final ScriptedBrowserPort _port;
  final BrowserSessionRequest _request;
  final ScriptedPage _page;
  final Map<String, void Function(String)> _handlers = <String, void Function(String)>{};

  @override
  final String id;

  @override
  SourceIdentity get source => _request.source;

  @override
  int get generation => _request.generation;

  @override
  Future<BrowserOutcome<BrowserPage>> loadData(String html, {required Uri baseUrl, CancellationToken? cancel}) async {
    _page
      ..html = html
      ..baseUrl = baseUrl;
    for (final BrowserCookie c in _port.setCookiesOnLoad) {
      _page.cookies[c.name] = c;
    }
    return BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: baseUrl, statusCode: 200));
  }

  @override
  Future<BrowserOutcome<BrowserPage>> loadUrl(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    CancellationToken? cancel,
  }) async => BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: url, statusCode: 200));

  @override
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel}) async {
    _page.scripts.add(script);
    if (_port.evaluateUnavailable) {
      return const BrowserCapabilityUnavailable<String>('host.browser.evaluate', 'evaluate is not available here');
    }
    final void Function(String)? post = _handlers['__pbResult'];
    if (post != null) {
      final Object? result = _port.respond(_page);
      Future<void>.delayed(const Duration(milliseconds: 5), () => post(jsonEncode(<String, Object?>{'ok': result})));
    }
    return const BrowserCompleted<String>('true');
  }

  @override
  Future<BrowserOutcome<void>> setMessageHandler(String name, void Function(String message)? handler) async {
    if (handler == null) {
      _handlers.remove(name);
    } else {
      _handlers[name] = handler;
    }
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<List<BrowserCookie>>> getCookies(Uri url, {CancellationToken? cancel}) async =>
      BrowserCompleted<List<BrowserCookie>>(_page.cookies.values.toList());

  @override
  Future<BrowserOutcome<void>> setCookie(Uri url, BrowserCookie cookie, {CancellationToken? cancel}) async {
    _page.cookies[cookie.name] = cookie;
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<void>> setUserAgent(String userAgent, {CancellationToken? cancel}) async =>
      const BrowserCompleted<void>(null);

  @override
  Future<BrowserOutcome<void>> showForInteraction({required Duration timeout, CancellationToken? cancel}) async =>
      const BrowserInteractionRequired<void>('no display in tests');

  @override
  Future<BrowserOutcome<void>> close() async {
    _port.closed.add(id);
    return const BrowserCompleted<void>(null);
  }
}
