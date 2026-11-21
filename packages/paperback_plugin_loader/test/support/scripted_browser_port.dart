import 'dart:convert';

import 'package:source_runtime/source_runtime.dart';

/// A [BrowserPort] test double that "runs" injected scripts by answering
/// from [respond], the way a page would: the injected function's result is
/// posted on the registered message channel. It records what the host sent
/// (HTML, base URL, user agent, cookies) so tests can check the context, and
/// keeps per-session cookies so tests can check they come back.
///
/// With [evaluateUnavailable] set, `evaluate` fails as a platform that
/// cannot express it would. By default `evaluate` behaves like a pre-1.3
/// engine (it replies before the injected promise settles, and the result
/// arrives on the message channel); [awaitsPromises] makes it a 1.3 engine
/// that replies with the settled value and posts nothing.
final class ScriptedBrowserPort implements BrowserPort {
  ScriptedBrowserPort({
    this.respond = _noResult,
    this.evaluateUnavailable = false,
    this.setCookiesOnLoad = const <BrowserCookie>[],
    this.probe,
    this.onShow,
    this.userAgent = 'ScriptedBrowser/1.0',
    this.awaitsPromises = false,
    this.scriptError,
    this.showDelay = Duration.zero,
  });

  /// Whether `evaluate` awaits the injected promise (protocol 1.3).
  final bool awaitsPromises;

  /// When it returns a message, the injected script throws with it
  /// (`BrowserScriptError`, protocol 1.2).
  final String? Function(ScriptedPage page)? scriptError;

  /// How long the user takes in the shown window before [onShow] acts.
  final Duration showDelay;

  static Object? _noResult(ScriptedPage page) => null;

  /// The injected function's result for a page, as JSON-able data.
  final Object? Function(ScriptedPage page) respond;
  final bool evaluateUnavailable;

  /// Cookies the "page" sets while loading (for example a challenge cookie).
  final List<BrowserCookie> setCookiesOnLoad;

  /// The value a plain `evaluate` (no result channel) returns for a page,
  /// as JSON-able data: what a page-inspecting script would compute (for
  /// example whether a challenge is still shown). `null` evaluates to `null`.
  final Object? Function(ScriptedPage page)? probe;

  /// Runs when the host shows the page for an interaction; the user's
  /// actions (solving a challenge, closing the window) mutate the page. The
  /// default reports that no display is available.
  final BrowserOutcome<void> Function(ScriptedPage page)? onShow;

  /// The engine's own user agent (`navigator.userAgent` without an override).
  final String userAgent;

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

  /// URLs loaded with `loadUrl`, with the headers sent.
  final List<(Uri, Map<String, String>)> loads = <(Uri, Map<String, String>)>[];

  /// Free-form page state for scripted probes (for example `challenged`).
  final Map<String, Object?> state = <String, Object?>{};

  /// Times the page was shown for an interaction.
  int shown = 0;
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
  }) async {
    _page.loads.add((url, Map<String, String>.of(headers)));
    for (final BrowserCookie c in _port.setCookiesOnLoad) {
      _page.cookies[c.name] = c;
    }
    return BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: url, statusCode: 200));
  }

  @override
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel}) async {
    _page.scripts.add(script);
    if (_port.evaluateUnavailable) {
      return const BrowserCapabilityUnavailable<String>('host.browser.evaluate', 'evaluate is not available here');
    }
    final void Function(String)? post = _handlers['__pbResult'];
    if (post != null) {
      final String? thrown = _port.scriptError?.call(_page);
      if (thrown != null) return BrowserScriptError<String>(thrown);
      final Object? result = _port.respond(_page);
      if (_port.awaitsPromises) return BrowserCompleted<String>(jsonEncode(<String, Object?>{'ok': result}));
      Future<void>.delayed(const Duration(milliseconds: 5), () => post(jsonEncode(<String, Object?>{'ok': result})));
      return const BrowserCompleted<String>('true');
    }
    final Object? Function(ScriptedPage page)? probe = _port.probe;
    return BrowserCompleted<String>(jsonEncode(probe == null ? null : probe(_page)));
  }

  /// The scripted engine reports no optional protocol 1.2 features.
  @override
  BrowserCapabilities get capabilities => BrowserCapabilities.unreported();

  @override
  Future<BrowserOutcome<void>> addPageStartScript(String script) async =>
      const BrowserCapabilityUnavailable<void>('host.browser.pageStartScripts', 'not scripted');

  @override
  Future<BrowserOutcome<void>> setRequestObserver(BrowserRequestObserver? observer) async =>
      const BrowserCapabilityUnavailable<void>('host.browser.observeRequests', 'not scripted');

  @override
  Future<BrowserOutcome<void>> setRequestReplacer(BrowserRequestReplacer? replacer) async =>
      const BrowserCapabilityUnavailable<void>('host.browser.replaceRequests', 'not scripted');

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
  Future<BrowserOutcome<void>> showForInteraction({required Duration timeout, CancellationToken? cancel}) async {
    _page.shown++;
    if (_port.showDelay > Duration.zero) await Future<void>.delayed(_port.showDelay);
    final BrowserOutcome<void> Function(ScriptedPage page)? onShow = _port.onShow;
    return onShow == null ? const BrowserInteractionRequired<void>('no display in tests') : onShow(_page);
  }

  @override
  Future<BrowserOutcome<void>> close() async {
    _port.closed.add(id);
    return const BrowserCompleted<void>(null);
  }
}
