import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:source_runtime/source_runtime.dart';

/// A page (or any response) the fake serves.
final class FakeWebPage {
  const FakeWebPage({
    this.html = '<html><head><title>fake</title></head></html>',
    this.redirectTo,
    this.status = 200,
    this.frames = const <Uri>[],
  });

  /// The response body as text.
  final String html;

  /// URLs of the page's child frames; scripts run in them through
  /// [FakeBrowserPort.frameScript], and page-start scripts run in them on
  /// every load.
  final List<Uri> frames;

  /// When set, loading the page redirects here (checked against the scheme
  /// policy like any navigation).
  final Uri? redirectTo;
  final int status;

  String get title => RegExp('<title>(.*?)</title>', dotAll: true).firstMatch(html)?.group(1) ?? '';
}

/// Resolves a URL to a fake page, or `null` for a navigation failure.
typedef FakePageResolver = FakeWebPage? Function(Uri url);

/// Resolves a request a page made (`fetch`, XHR) to a response, or `null`
/// for a network failure.
typedef FakeRequestResolver = FakeWebPage? Function(BrowserRequest request);

/// Browser storage that outlives a [FakeBrowserPort] instance, the way a
/// platform's persistent WebView store survives a killed helper process.
final class FakeBrowserStore {
  final Map<String, Map<String, BrowserCookie>> _cookies = <String, Map<String, BrowserCookie>>{};
  final Map<String, Map<String, String>> _webStorage = <String, Map<String, String>>{};

  /// When true, deleting a source's data cannot be confirmed.
  bool failDeletes = false;

  static String keyOf(SourceIdentity source) => '${source.ecosystem}/${source.packageId}/${source.sourceId}';

  Map<String, BrowserCookie> cookiesFor(String key) => _cookies.putIfAbsent(key, () => <String, BrowserCookie>{});

  Map<String, String> storageFor(String key) => _webStorage.putIfAbsent(key, () => <String, String>{});

  /// Whether any source has cookies or web storage left.
  bool get isEmpty =>
      _cookies.values.every((Map<String, BrowserCookie> c) => c.isEmpty) &&
      _webStorage.values.every((Map<String, String> s) => s.isEmpty);

  bool delete(String key) {
    if (failDeletes) return false;
    _cookies.remove(key);
    _webStorage.remove(key);
    return true;
  }

  bool deleteAll() {
    if (failDeletes) return false;
    _cookies.clear();
    _webStorage.clear();
    return true;
  }
}

/// In-memory [BrowserPort] for tests and in-lane development (U3, U6).
///
/// Serves pages from a [FakePageResolver] (or committed captures with
/// [FakeBrowserPort.replay]), enforces [BrowserUrlPolicy] on loads, redirects
/// and base URLs, and models a persistent store: data is deleted at session
/// close, and wiped on start when [wipeOnStart] is set.
///
/// Engine behaviour follows [capabilities] (default
/// [BrowserCapabilities.all], a WebView2-like engine; [degradedCapabilities]
/// models WebKit-style observation): which requests reach an observer,
/// whether headers, client hints (`sec-ch-ua*`, sent only by a Chromium-like
/// engine) and bodies are visible, whether replacement and script errors
/// are available.
///
/// `evaluate` understands a small JavaScript subset: `1 + 1`, `document.title`,
/// `document.cookie` (read and `document.cookie = "k=v"`),
/// `localStorage.setItem("k", "v")`, `localStorage.getItem("k")`,
/// `window.<name> = <JSON literal>` and `window.<name>`,
/// `window.<channel>.postMessage(<JSON string> | location.href)` (see
/// [BrowserMessageChannel]), `throw new Error("text")`, scripts carrying a
/// [fetchMarker] comment, plus the harness markers produced by [heldScript]
/// and [frameScript]. Page-start scripts use the same subset.
class FakeBrowserPort implements BrowserPort {
  FakeBrowserPort({
    FakePageResolver? pages,
    this._requests,
    FakeBrowserStore? store,
    BrowserCapabilities? capabilities,
    this.wipeOnStart = true,
    this.hasDisplay = false,
    List<CaptureKey>? misses,
  }) : _pages = pages ?? ((_) => null),
       store = store ?? FakeBrowserStore(),
       capabilities = capabilities ?? BrowserCapabilities.all(),
       misses = misses ?? <CaptureKey>[] {
    if (wipeOnStart) this.store.deleteAll();
  }

  /// A port that serves only committed captures; other requests fail and
  /// are recorded in [misses].
  ///
  /// Top-level loads match `GET` keys. Requests a page makes (`fetch`)
  /// match on method, URL and body ([browserCaptureKey]), so a POST matches
  /// only its recorded body; a request whose body the engine omitted is
  /// always a miss.
  factory FakeBrowserPort.replay(
    CaptureSet captures, {
    FakeBrowserStore? store,
    BrowserCapabilities? capabilities,
  }) {
    final misses = <CaptureKey>[];
    FakeWebPage? serve(CaptureKey key, Uri url) {
      if (!captures.contains(key)) {
        misses.add(key);
        return null;
      }
      final CapturedResponse r = captures.lookup(key);
      final String? location = r.headers['location'];
      return FakeWebPage(
        html: utf8.decode(r.body, allowMalformed: true),
        status: r.status,
        redirectTo: r.status >= 300 && r.status < 400 && location != null ? url.resolve(location) : null,
      );
    }

    return FakeBrowserPort(
      store: store,
      capabilities: capabilities,
      misses: misses,
      pages: (Uri url) => serve(captures.manifest.keyFor('GET', url, null), url),
      requests: (BrowserRequest request) {
        final CaptureKey? key = browserCaptureKey(captures, request);
        if (key == null) {
          misses.add(captures.manifest.keyFor(request.method, request.url, null));
          return null;
        }
        return serve(key, request.url);
      },
    );
  }

  /// Observation as WebKit engines provide it, with Android-style
  /// `evaluate`: main-frame navigations and headers only, no subresources,
  /// client hints, bodies, replacement or script errors.
  static final BrowserCapabilities degradedCapabilities = BrowserCapabilities(
    available: const <BrowserFeature>{
      BrowserFeature.pageStartScripts,
      BrowserFeature.observeNavigations,
      BrowserFeature.observeRequestHeaders,
    },
    unavailable: const <BrowserFeature, String>{
      BrowserFeature.observeSubresources: 'WebKit cannot observe http(s) subresource requests',
      BrowserFeature.observeClientHints: 'WebKit engines do not send Chromium client hints',
      BrowserFeature.observeRequestBodies: 'The engine does not expose request bodies',
      BrowserFeature.replaceRequests: 'The engine cannot substitute http(s) responses',
      BrowserFeature.scriptErrors: 'evaluate reports a throwing script as null (Android semantics)',
    },
  );

  /// Client hints a Chromium-like fake engine sends with every request.
  static const Map<String, String> clientHints = <String, String>{
    'sec-ch-ua': '"Chromium";v="130", "Not?A_Brand";v="99"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Fake"',
  };

  /// Prefix of the comment that marks a `fetch` script for the fake; the
  /// contract suite's scripts carry it (see `BrowserContractScripts`).
  static const String fetchMarker = '/*fetch ';

  final FakePageResolver _pages;
  final FakeRequestResolver? _requests;
  final FakeBrowserStore store;
  final bool wipeOnStart;

  /// The features every session of this port reports.
  final BrowserCapabilities capabilities;

  /// Whether a visible interaction can be shown.
  final bool hasDisplay;

  /// Capture keys requested in replay mode without a committed capture.
  final List<CaptureKey> misses;

  int _fencedBelow = 0;
  int _sessionCounter = 0;
  final Set<FakeBrowserSession> _sessions = <FakeBrowserSession>{};
  final List<Completer<void>> _held = <Completer<void>>[];

  /// Returns a script whose evaluation completes with [resultJson] only after
  /// [releaseHeld].
  static String heldScript(String resultJson) => '/*held*/$resultJson';

  /// Returns a script that posts [message] on channel [name] from the top
  /// frame, as a page would.
  static String postMessageScript(String name, String message) => BrowserMessageChannel.postScript(name, message);

  /// Returns a script that runs [script] inside the current page's child
  /// frame loaded from [frame] (one of [FakeWebPage.frames]), with that
  /// frame's origin. Only `postMessage` scripts have an effect there.
  static String frameScript(Uri frame, String script) => '/*frame*/${jsonEncode(<String>[frame.toString(), script])}';

  /// Releases every evaluation started with a [heldScript].
  void releaseHeld() {
    for (final Completer<void> c in _held) {
      if (!c.isCompleted) c.complete();
    }
    _held.clear();
  }

  /// Open sessions.
  int get openSessions => _sessions.length;

  FakeWebPage? _resolveRequest(BrowserRequest request) {
    final FakeRequestResolver? resolver = _requests;
    if (resolver != null) return resolver(request);
    return request.method == 'GET' ? _pages(request.url) : null;
  }

  @override
  Future<BrowserOutcome<void>> wipeAllSourceData() async => store.deleteAll()
      ? const BrowserCompleted<void>(null)
      : const BrowserCapabilityUnavailable<void>('wipeAllSourceData', 'Could not confirm deletion');

  @override
  Future<BrowserOutcome<BrowserSession>> openSession(BrowserSessionRequest request, {CancellationToken? cancel}) async {
    if (cancel?.isCancelled ?? false) return const BrowserCancelled<BrowserSession>('cancelled');
    if (request.generation < _fencedBelow) {
      return BrowserCancelled<BrowserSession>('Generation ${request.generation} is fenced');
    }
    final session = FakeBrowserSession._(this, 'fake-${++_sessionCounter}', request);
    _sessions.add(session);
    return BrowserCompleted<BrowserSession>(session);
  }

  @override
  Future<void> fence(int generation) async {
    if (generation <= _fencedBelow) return;
    _fencedBelow = generation;
    for (final FakeBrowserSession s in _sessions.toList()) {
      if (s.generation < generation) s._fence();
    }
  }
}

/// Result of sending one request through a session's interceptor.
sealed class _Fetched {
  const _Fetched();
}

final class _Served extends _Fetched {
  const _Served(this.page);

  final FakeWebPage page;
}

final class _Failed extends _Fetched {
  const _Failed(this.reason);

  final String reason;
}

/// A session of [FakeBrowserPort].
class FakeBrowserSession implements BrowserSession {
  FakeBrowserSession._(this._port, this.id, BrowserSessionRequest request)
    : source = request.source,
      generation = request.generation,
      _userAgent = request.userAgent ?? 'FakeBrowser/1.0';

  final FakeBrowserPort _port;

  @override
  final String id;

  @override
  final SourceIdentity source;

  @override
  final int generation;

  @override
  BrowserCapabilities get capabilities => _port.capabilities;

  String _userAgent;
  Uri _current = Uri.parse('about:blank');
  FakeWebPage _page = const FakeWebPage(html: '');
  bool _closed = false;
  bool _fenced = false;
  final Map<String, void Function(String message)> _handlers = <String, void Function(String message)>{};
  final Set<Completer<BrowserOutcome<String>>> _pending = <Completer<BrowserOutcome<String>>>{};
  final List<String> _startScripts = <String>[];
  final Map<String, String> _globals = <String, String>{};
  BrowserRequestObserver? _observer;
  BrowserRequestReplacer? _replacer;

  /// Requests the session's pages made, whether or not an observer saw them.
  final List<BrowserRequest> requestsMade = <BrowserRequest>[];

  String get _key => FakeBrowserStore.keyOf(source);

  BrowserCancelled<T>? _dead<T>(CancellationToken? cancel) {
    if (_fenced) return BrowserCancelled<T>('Generation $generation is fenced');
    if (_closed) return BrowserCancelled<T>('Session closed');
    if (cancel?.isCancelled ?? false) return BrowserCancelled<T>(cancel!.reason ?? 'cancelled');
    return null;
  }

  bool get _alive => !_fenced && !_closed;

  void _fence() {
    _fenced = true;
    _observer = null;
    _replacer = null;
    for (final Completer<BrowserOutcome<String>> c in _pending) {
      if (!c.isCompleted) c.complete(BrowserCancelled<String>('Generation $generation is fenced'));
    }
    _pending.clear();
  }

  // --- requests ------------------------------------------------------------

  /// Builds the request a Chromium- or WebKit-like engine would send.
  BrowserRequest _request(
    Uri url, {
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    List<int>? body,
    bool mainFrame = false,
    bool redirect = false,
    BrowserRequestContext context = BrowserRequestContext.other,
  }) => BrowserRequest(
    url: url,
    method: method,
    headers: <String, String>{
      'User-Agent': _userAgent,
      if (capabilities.supports(BrowserFeature.observeClientHints)) ...FakeBrowserPort.clientHints,
      ...headers,
    },
    body: body == null || body.isEmpty ? null : Uint8List.fromList(body),
    mainFrame: mainFrame,
    redirect: redirect,
    context: context,
  );

  /// What an observer is shown of [request] on this engine.
  BrowserRequest _asReported(BrowserRequest request) {
    final bool headers = capabilities.supports(BrowserFeature.observeRequestHeaders);
    final bool bodies = capabilities.supports(BrowserFeature.observeRequestBodies);
    if (headers && bodies) return request;
    return BrowserRequest(
      url: request.url,
      method: request.method,
      headers: headers ? request.headers : const <String, String>{},
      body: bodies ? request.body : null,
      bodyOmitted: request.bodyOmitted || (!bodies && request.body != null),
      mainFrame: request.mainFrame,
      redirect: request.redirect,
      context: request.context,
    );
  }

  /// Sends [request] through the interceptor, then (unless replaced) to
  /// [network]. Only http(s) requests are observed or replaced.
  Future<_Fetched> _send(BrowserRequest request, FakeWebPage? Function() network) async {
    requestsMade.add(request);
    final bool web = BrowserUrlPolicy.isAllowedBaseUrl(request.url);
    final BrowserRequest reported = _asReported(request);
    final bool observable = request.mainFrame
        ? capabilities.supports(BrowserFeature.observeNavigations)
        : capabilities.supports(BrowserFeature.observeSubresources);
    final BrowserRequestObserver? observer = _observer;
    if (web && observable && observer != null && _alive) observer(reported);
    final BrowserRequestReplacer? replacer = _replacer;
    if (web && replacer != null && _alive) {
      final BrowserReplacement? replacement;
      try {
        replacement = await replacer(reported);
      } on Object catch (e) {
        return _Failed('Request replacer threw: $e');
      }
      if (!_alive) return const _Failed('Session closed');
      if (replacement != null) {
        final String? invalid = replacement.invalidReason;
        if (invalid != null) return _Failed('Replacement refused: $invalid');
        return _Served(
          FakeWebPage(html: utf8.decode(replacement.body, allowMalformed: true), status: replacement.status),
        );
      }
    }
    final FakeWebPage? page = network();
    return page == null ? const _Failed('No such page') : _Served(page);
  }

  // --- documents -----------------------------------------------------------

  /// Makes [url] the current document: resets page globals and runs the
  /// page-start scripts in the top frame, then in each child frame.
  Future<void> _enterDocument(Uri url, FakeWebPage page) async {
    _current = url;
    _page = page;
    _globals.clear();
    for (final String script in _startScripts) {
      _runIn(script, frame: url, top: true);
    }
    for (final Uri frame in page.frames) {
      await _send(
        _request(frame, context: BrowserRequestContext.document),
        () => const FakeWebPage(html: ''),
      );
      for (final String script in _startScripts) {
        _runIn(script, frame: frame, top: false);
      }
    }
  }

  @override
  Future<BrowserOutcome<BrowserPage>> loadUrl(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    CancellationToken? cancel,
  }) async {
    final BrowserCancelled<BrowserPage>? dead = _dead(cancel);
    if (dead != null) return dead;
    var target = url;
    for (var hop = 0; hop < 10; hop++) {
      final BrowserCapabilityUnavailable<BrowserPage>? rejected = BrowserUrlPolicy.checkNavigation<BrowserPage>(
        target,
        hop == 0 ? 'loadUrl' : 'redirect',
      );
      if (rejected != null) return rejected;
      if (BrowserUrlPolicy.isAboutBlank(target)) {
        await _enterDocument(target, const FakeWebPage(html: ''));
        return BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: target));
      }
      final hopUrl = target;
      final _Fetched fetched = await _send(
        _request(
          hopUrl,
          headers: hop == 0 ? headers : const <String, String>{},
          mainFrame: true,
          redirect: hop > 0,
          context: BrowserRequestContext.document,
        ),
        () => _port._pages(hopUrl),
      );
      final BrowserCancelled<BrowserPage>? deadNow = _dead(cancel);
      if (deadNow != null) return deadNow;
      if (fetched case _Failed(:final String reason)) return BrowserNavigationFailed<BrowserPage>(target, reason);
      final FakeWebPage page = (fetched as _Served).page;
      final Uri? next = page.redirectTo;
      if (next == null) {
        await _enterDocument(target, page);
        return BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: target, statusCode: page.status));
      }
      target = next;
    }
    return BrowserNavigationFailed<BrowserPage>(url, 'Too many redirects');
  }

  @override
  Future<BrowserOutcome<BrowserPage>> loadData(String html, {required Uri baseUrl, CancellationToken? cancel}) async {
    final BrowserCancelled<BrowserPage>? dead = _dead(cancel);
    if (dead != null) return dead;
    final BrowserCapabilityUnavailable<BrowserPage>? rejected = BrowserUrlPolicy.checkBaseUrl<BrowserPage>(
      baseUrl,
      'loadData',
    );
    if (rejected != null) return rejected;
    await _enterDocument(baseUrl, FakeWebPage(html: html));
    return BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: baseUrl));
  }

  // --- scripts -------------------------------------------------------------

  @override
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel}) async {
    final BrowserCancelled<String>? dead = _dead(cancel);
    if (dead != null) return dead;
    final String s = script.trim();
    if (s.startsWith('/*held*/')) return _held(s.substring(8), cancel);
    if (s.startsWith('/*frame*/')) {
      final args = jsonDecode(s.substring(9)) as List<Object?>;
      final Uri frame = Uri.parse(args[0]! as String);
      if (_page.frames.contains(frame)) _post((args[1]! as String).trim(), origin: frame);
      return const BrowserCompleted<String>('null');
    }
    if (s.startsWith(FakeBrowserPort.fetchMarker)) return _fetch(s);
    final RegExpMatch? thrown = _throwPattern.firstMatch(s);
    if (thrown != null) {
      final message = 'Error: ${jsonDecode(thrown[1]!)}';
      return capabilities.supports(BrowserFeature.scriptErrors)
          ? BrowserScriptError<String>(message)
          : const BrowserCompleted<String>('null');
    }
    final String? ran = _runIn(s, frame: _current, top: true);
    if (ran != null) return BrowserCompleted<String>(ran);
    return BrowserCompleted<String>(_interpret(s));
  }

  static final RegExp _postPattern = RegExp(r'^(?:window\.)?([A-Za-z_$][A-Za-z0-9_$]*)\.postMessage\((.*)\);?$');
  static final RegExp _throwPattern = RegExp(r'^throw\s+new\s+Error\(\s*("(?:[^"\\]|\\.)*")\s*\);?$');
  static final RegExp _setGlobal = RegExp(r'^window\.([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(.+?);?$');
  static final RegExp _getGlobal = RegExp(r'^window\.([A-Za-z_$][A-Za-z0-9_$]*);?$');

  /// Runs the statements the fake understands in a frame at [frame]:
  /// `postMessage` and (in the top frame) `window.<name>` globals. Returns
  /// the JSON result, or `null` for a script it does not handle here.
  String? _runIn(String script, {required Uri frame, required bool top}) {
    final String s = script.trim();
    if (_post(s, origin: frame)) return 'null';
    final RegExpMatch? set = _setGlobal.firstMatch(s);
    if (set != null) {
      try {
        final String value = jsonEncode(jsonDecode(set[2]!));
        if (top) _globals[set[1]!] = value;
        return value;
      } on FormatException {
        return null;
      }
    }
    final RegExpMatch? get = _getGlobal.firstMatch(s);
    if (get != null && top) return _globals[get[1]!] ?? 'null';
    return null;
  }

  /// Runs a `postMessage` script posted from a frame at [origin]; returns
  /// whether [script] was one. Delivery follows [BrowserMessageChannel]:
  /// asynchronous, and only for a registered channel and an accepted origin.
  /// The argument may be a JSON literal or `location.href`.
  bool _post(String script, {required Uri origin}) {
    final RegExpMatch? match = _postPattern.firstMatch(script);
    if (match == null) return false;
    final String argument = match[2]!.trim();
    Object? message;
    if (argument == 'location.href') {
      message = origin.toString();
    } else {
      try {
        message = jsonDecode(argument);
      } on FormatException {
        message = null;
      }
    }
    _deliver(match[1]!, message, origin: origin);
    return true;
  }

  void _deliver(String channel, Object? message, {required Uri origin}) {
    final void Function(String message)? handler = _handlers[channel];
    if (handler == null ||
        message is! String ||
        !BrowserMessageChannel.accepts(documentUrl: _current, frameOrigin: origin)) {
      return;
    }
    final int generationAtPost = generation;
    scheduleMicrotask(() {
      if (_alive && generationAtPost == generation && identical(_handlers[channel], handler)) handler(message);
    });
  }

  /// Runs a contract `fetch` script: sends the request from the current
  /// document through the interceptor and posts the response text (or
  /// `fetch-failed`) on the script's channel.
  Future<BrowserOutcome<String>> _fetch(String script) async {
    final int end = script.indexOf('*/');
    final spec = jsonDecode(script.substring(FakeBrowserPort.fetchMarker.length, end)) as Map<String, Object?>;
    final Uri url = _current.resolve(spec['url']! as String);
    final body = spec['body'] as String?;
    final BrowserRequest request = _request(
      url,
      method: spec['method']! as String,
      body: body == null ? null : utf8.encode(body),
      context: BrowserRequestContext.fetch,
    );
    final Uri origin = _current;
    final _Fetched fetched = BrowserUrlPolicy.isAllowedBaseUrl(url)
        ? await _send(request, () => _port._resolveRequest(request))
        : const _Failed('Scheme not fetchable');
    if (!_alive) return const BrowserCancelled<String>('Session closed');
    if (origin == _current) {
      _deliver(spec['channel']! as String, switch (fetched) {
        _Served(:final FakeWebPage page) => page.html,
        _Failed() => 'fetch-failed',
      }, origin: origin);
    }
    return const BrowserCompleted<String>('null');
  }

  Future<BrowserOutcome<String>> _held(String resultJson, CancellationToken? cancel) async {
    final completer = Completer<BrowserOutcome<String>>();
    _pending.add(completer);
    final release = Completer<void>();
    _port._held.add(release);
    unawaited(
      release.future.then((_) {
        // A late completion after a fence or close never resolves anything.
        if (!completer.isCompleted && _alive) completer.complete(BrowserCompleted<String>(resultJson));
      }),
    );
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (!completer.isCompleted) completer.complete(BrowserCancelled<String>(cancel.reason ?? 'cancelled'));
        }),
      );
    }
    final BrowserOutcome<String> outcome = await completer.future;
    _pending.remove(completer);
    return outcome;
  }

  String _interpret(String s) {
    final Map<String, BrowserCookie> cookies = _port.store.cookiesFor(_key);
    final Map<String, String> storage = _port.store.storageFor(_key);
    if (RegExp(r'^1\s*\+\s*1;?$').hasMatch(s)) return '2';
    if (RegExp(r'^document\.title;?$').hasMatch(s)) return jsonEncode(_page.title);
    if (RegExp(r'^document\.cookie;?$').hasMatch(s)) {
      final String host = _current.host;
      return jsonEncode(
        cookies.values
            .where((BrowserCookie c) => c.domain == null || host.endsWith(c.domain!))
            .map((BrowserCookie c) => '${c.name}=${c.value}')
            .join('; '),
      );
    }
    final RegExpMatch? setCookie = RegExp(
      r'''^document\.cookie\s*=\s*["']([^=;"']+)=([^;"']*)[^"']*["'];?$''',
    ).firstMatch(s);
    if (setCookie != null) {
      cookies[setCookie[1]!] = BrowserCookie(name: setCookie[1]!, value: setCookie[2]!, domain: _current.host);
      return jsonEncode('${setCookie[1]}=${setCookie[2]}');
    }
    final RegExpMatch? setItem = RegExp(
      r'''^localStorage\.setItem\(\s*["']([^"']*)["']\s*,\s*["']([^"']*)["']\s*\);?$''',
    ).firstMatch(s);
    if (setItem != null) {
      storage[setItem[1]!] = setItem[2]!;
      return 'null';
    }
    final RegExpMatch? getItem = RegExp(r'''^localStorage\.getItem\(\s*["']([^"']*)["']\s*\);?$''').firstMatch(s);
    if (getItem != null) return jsonEncode(storage[getItem[1]!]);
    if (RegExp(r'^navigator\.userAgent;?$').hasMatch(s)) return jsonEncode(_userAgent);
    return 'null';
  }

  @override
  Future<BrowserOutcome<void>> addPageStartScript(String script) async {
    final BrowserCancelled<void>? dead = _dead(null);
    if (dead != null) return dead;
    final BrowserCapabilityUnavailable<void>? missing = capabilities.check<void>(
      BrowserFeature.pageStartScripts,
      'addPageStartScript',
    );
    if (missing != null) return missing;
    _startScripts.add(script);
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<void>> setRequestObserver(BrowserRequestObserver? observer) async {
    final BrowserCancelled<void>? dead = _dead(null);
    if (dead != null) return dead;
    if (observer != null &&
        !capabilities.supports(BrowserFeature.observeNavigations) &&
        !capabilities.supports(BrowserFeature.observeSubresources)) {
      return capabilities.check<void>(BrowserFeature.observeNavigations, 'setRequestObserver')!;
    }
    _observer = observer;
    _replacer = null;
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<void>> setRequestReplacer(BrowserRequestReplacer? replacer) async {
    final BrowserCancelled<void>? dead = _dead(null);
    if (dead != null) return dead;
    if (replacer != null) {
      final BrowserCapabilityUnavailable<void>? missing = capabilities.check<void>(
        BrowserFeature.replaceRequests,
        'setRequestReplacer',
      );
      if (missing != null) return missing;
      _observer = null;
    }
    _replacer = replacer;
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<void>> setMessageHandler(String name, void Function(String message)? handler) async {
    final BrowserCancelled<void>? dead = _dead(null);
    if (dead != null) return dead;
    final BrowserCapabilityUnavailable<void>? invalid = BrowserMessageChannel.checkName<void>(name);
    if (invalid != null) return invalid;
    if (handler == null) {
      _handlers.remove(name);
    } else {
      _handlers[name] = handler;
    }
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<List<BrowserCookie>>> getCookies(Uri url, {CancellationToken? cancel}) async {
    final BrowserCancelled<List<BrowserCookie>>? dead = _dead(cancel);
    if (dead != null) return dead;
    return BrowserCompleted<List<BrowserCookie>>(
      _port.store
          .cookiesFor(_key)
          .values
          .where((BrowserCookie c) => c.domain == null || url.host.endsWith(c.domain!))
          .toList(),
    );
  }

  @override
  Future<BrowserOutcome<void>> setCookie(Uri url, BrowserCookie cookie, {CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead(cancel);
    if (dead != null) return dead;
    final BrowserCapabilityUnavailable<void>? rejected = BrowserUrlPolicy.checkBaseUrl<void>(url, 'setCookie');
    if (rejected != null) return rejected;
    _port.store.cookiesFor(_key)[cookie.name] = BrowserCookie(
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain ?? url.host,
      path: cookie.path,
      expires: cookie.expires,
      secure: cookie.secure,
      httpOnly: cookie.httpOnly,
    );
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<void>> setUserAgent(String userAgent, {CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead(cancel);
    if (dead != null) return dead;
    _userAgent = userAgent;
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<void>> showForInteraction({required Duration timeout, CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead(cancel);
    if (dead != null) return dead;
    if (!_port.hasDisplay) return const BrowserInteractionRequired<void>('No display available for interaction');
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<void>> close() async {
    if (_closed) return const BrowserCompleted<void>(null);
    _closed = true;
    _observer = null;
    _replacer = null;
    for (final Completer<BrowserOutcome<String>> c in _pending) {
      if (!c.isCompleted) c.complete(const BrowserCancelled<String>('Session closed'));
    }
    _pending.clear();
    _port._sessions.remove(this);
    return _port.store.delete(_key)
        ? const BrowserCompleted<void>(null)
        : const BrowserCapabilityUnavailable<void>('close', 'Could not confirm deletion of browser storage');
  }
}
