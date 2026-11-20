import 'dart:async';
import 'dart:convert';

import 'package:source_runtime/source_runtime.dart';

/// A page the fake serves.
final class FakeWebPage {
  const FakeWebPage({this.html = '<html><head><title>fake</title></head></html>', this.redirectTo, this.status = 200});

  final String html;

  /// When set, loading the page redirects here (checked against the scheme
  /// policy like any navigation).
  final Uri? redirectTo;
  final int status;

  String get title => RegExp('<title>(.*?)</title>', dotAll: true).firstMatch(html)?.group(1) ?? '';
}

/// Resolves a URL to a fake page, or `null` for a navigation failure.
typedef FakePageResolver = FakeWebPage? Function(Uri url);

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
/// `evaluate` understands a small JavaScript subset: `1 + 1`, `document.title`,
/// `document.cookie` (read and `document.cookie = "k=v"`),
/// `localStorage.setItem("k", "v")` and `localStorage.getItem("k")`, plus the
/// harness markers produced by [heldScript] and [postMessageScript].
class FakeBrowserPort implements BrowserPort {
  FakeBrowserPort({
    FakePageResolver? pages,
    FakeBrowserStore? store,
    this.wipeOnStart = true,
    this.hasDisplay = false,
    List<CaptureKey>? misses,
  }) : _pages = pages ?? ((_) => null),
       store = store ?? FakeBrowserStore(),
       misses = misses ?? <CaptureKey>[] {
    if (wipeOnStart) this.store.deleteAll();
  }

  /// A port that serves only committed captures; other URLs fail navigation
  /// and are recorded in [misses].
  factory FakeBrowserPort.replay(CaptureSet captures, {FakeBrowserStore? store}) {
    final misses = <CaptureKey>[];
    return FakeBrowserPort(
      store: store,
      misses: misses,
      pages: (Uri url) {
        final CaptureKey key = captures.manifest.keyFor('GET', url, null);
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
      },
    );
  }

  final FakePageResolver _pages;
  final FakeBrowserStore store;
  final bool wipeOnStart;

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

  /// Returns a script that posts [message] on channel [name].
  static String postMessageScript(String name, String message) => '/*post*/${jsonEncode(<String>[name, message])}';

  /// Releases every evaluation started with a [heldScript].
  void releaseHeld() {
    for (final Completer<void> c in _held) {
      if (!c.isCompleted) c.complete();
    }
    _held.clear();
  }

  /// Open sessions.
  int get openSessions => _sessions.length;

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

  // ignore: unused_field
  String _userAgent;
  Uri _current = Uri.parse('about:blank');
  FakeWebPage _page = const FakeWebPage(html: '');
  bool _closed = false;
  bool _fenced = false;
  final Map<String, void Function(String message)> _handlers = <String, void Function(String message)>{};
  final Set<Completer<BrowserOutcome<String>>> _pending = <Completer<BrowserOutcome<String>>>{};

  String get _key => FakeBrowserStore.keyOf(source);

  BrowserCancelled<T>? _dead<T>(CancellationToken? cancel) {
    if (_fenced) return BrowserCancelled<T>('Generation $generation is fenced');
    if (_closed) return BrowserCancelled<T>('Session closed');
    if (cancel?.isCancelled ?? false) return BrowserCancelled<T>(cancel!.reason ?? 'cancelled');
    return null;
  }

  void _fence() {
    _fenced = true;
    for (final Completer<BrowserOutcome<String>> c in _pending) {
      if (!c.isCompleted) c.complete(BrowserCancelled<String>('Generation $generation is fenced'));
    }
    _pending.clear();
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
        _current = target;
        _page = const FakeWebPage(html: '');
        return BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: target));
      }
      final FakeWebPage? page = _port._pages(target);
      if (page == null) return BrowserNavigationFailed<BrowserPage>(target, 'No such page');
      final Uri? next = page.redirectTo;
      if (next == null) {
        _current = target;
        _page = page;
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
    _current = baseUrl;
    _page = FakeWebPage(html: html);
    return BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: baseUrl));
  }

  @override
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel}) async {
    final BrowserCancelled<String>? dead = _dead(cancel);
    if (dead != null) return dead;
    final String s = script.trim();
    if (s.startsWith('/*held*/')) return _held(s.substring(8), cancel);
    if (s.startsWith('/*post*/')) {
      final args = jsonDecode(s.substring(8)) as List<Object?>;
      _handlers[args[0]! as String]?.call(args[1]! as String);
      return const BrowserCompleted<String>('null');
    }
    return BrowserCompleted<String>(_interpret(s));
  }

  Future<BrowserOutcome<String>> _held(String resultJson, CancellationToken? cancel) async {
    final completer = Completer<BrowserOutcome<String>>();
    _pending.add(completer);
    final release = Completer<void>();
    _port._held.add(release);
    unawaited(
      release.future.then((_) {
        // A late completion after a fence or close never resolves anything.
        if (!completer.isCompleted && !_fenced && !_closed) completer.complete(BrowserCompleted<String>(resultJson));
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
    return 'null';
  }

  @override
  Future<BrowserOutcome<void>> setMessageHandler(String name, void Function(String message)? handler) async {
    final BrowserCancelled<void>? dead = _dead(null);
    if (dead != null) return dead;
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
