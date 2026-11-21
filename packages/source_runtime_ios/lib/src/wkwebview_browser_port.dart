// WKWebView implementation of the BrowserPort contract (KTD13, KTD20, U10).
//
// Everything is driven from Dart through the FFIgen WebKit/UIKit bindings in
// `webkit_bindings.g.dart`; there is no platform channel and no Objective-C
// glue beyond FFIgen's generated block/protocol trampolines. Navigation,
// script-message and presentation delegates are Dart-implemented protocols
// built with `implementAsListener`, so WebKit never waits synchronously on
// Dart: every decision handler WebKit hands over is called back
// asynchronously, which WebKit permits.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:objective_c/objective_c.dart' as objc;
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_ios/src/webkit/nullable_blocks.dart';
import 'package:source_runtime_ios/src/webkit_bindings.g.dart';

/// Configuration of a [WKWebViewBrowserPort].
final class WKWebViewBrowserConfig {
  const WKWebViewBrowserConfig({
    this.allowInteraction = true,
    this.offlineAllowedHosts,
    this.inspectable = false,
    this.storageDeletionTimeout,
    this.onLog,
  });

  /// When false (unattended runs), [BrowserSession.showForInteraction]
  /// answers [BrowserInteractionRequired] without presenting anything.
  final bool allowInteraction;

  /// Replay mode for tests: when set, a WebKit content rule list blocks every
  /// http(s)/ws(s) load whose host is not listed, in every frame, so a test
  /// can never reach a server. Main-frame `loadData` content still renders
  /// (it is not a network load). `null` (production) blocks nothing.
  final Set<String>? offlineAllowedHosts;

  /// Makes session web views inspectable from Safari (debug builds only).
  final bool inspectable;

  /// How long [BrowserSession.close] waits for WebKit to confirm that the
  /// session's storage was deleted before reporting it unconfirmed; `null`
  /// waits for WebKit's completion handler.
  final Duration? storageDeletionTimeout;

  /// Receives diagnostic lines; pass a redacting sink (KTD9). Never receives
  /// cookie values, headers or page text.
  final void Function(String line)? onLog;
}

/// The capabilities every WKWebView session reports (protocol 1.2),
/// measured on the iOS Simulator (U10; `docs/validation/source-runners/ios`).
final BrowserCapabilities wkWebViewCapabilities = BrowserCapabilities(
  available: const <BrowserFeature>{
    BrowserFeature.pageStartScripts,
    BrowserFeature.observeNavigations,
    BrowserFeature.scriptErrors,
  },
  unavailable: const <BrowserFeature, String>{
    BrowserFeature.observeSubresources:
        'WKWebView cannot observe http(s) subresource or child-frame requests: WKURLSchemeHandler may not claim '
        'http or https, and no other public API reports them (degraded observe tier, KTD20)',
    BrowserFeature.observeRequestHeaders:
        'WKWebView exposes only the headers set on the navigation request, not the ones its network process sends '
        '(User-Agent, Accept, Cookie), so observed requests carry no headers',
    BrowserFeature.observeClientHints: 'WebKit does not send Chromium client hints (sec-ch-ua*)',
    BrowserFeature.observeRequestBodies:
        'WKWebView does not expose request bodies for observation, and subresource requests are not observable',
    BrowserFeature.replaceRequests:
        'WKWebView cannot substitute http(s) responses: WKURLSchemeHandler may not handle http or https',
  },
);

/// [BrowserPort] over WKWebView (KTD13).
///
/// - **Threading:** WebKit is main-thread only. Flutter 3.50 runs the root
///   isolate on the iOS platform thread, so this port must be created and
///   used on the root isolate; every WebKit call is dispatched through
///   `runOnPlatformThread`, which runs it on that thread. Listener callbacks
///   from WebKit arrive on the same isolate.
/// - **Storage:** every session gets its own non-persistent
///   `WKWebsiteDataStore`, so sources (and sessions) never share cookies or
///   web storage. [BrowserSession.close] deletes and verifies the store's
///   data. Nothing is ever written to a persistent store, so
///   [wipeAllSourceData] has nothing to delete.
/// - **Backgrounding (KTD12):** while the app is in the background
///   ([setBackgrounded], or [bindToAppLifecycle]) pending loads and
///   evaluations are cancelled, new ones are refused as cancelled, and late
///   callbacks are discarded; sessions stay open and are usable again in
///   the foreground. A visible interaction stays presented (the user may
///   switch apps to fetch a password) and keeps its own timeout.
final class WKWebViewBrowserPort implements BrowserPort {
  WKWebViewBrowserPort({this.config = const WKWebViewBrowserConfig()});

  final WKWebViewBrowserConfig config;

  /// Why this process cannot drive WKWebView, or `null` when it can.
  static String? get unavailableReason {
    if (!Platform.isIOS) return 'WKWebViewBrowserPort runs on iOS only';
    if (!ui.isRunningOnPlatformThread) {
      return 'WKWebViewBrowserPort must run on the root isolate on the iOS platform thread '
          '(Flutter merged platform and UI threads)';
    }
    return null;
  }

  final Set<WKWebViewBrowserSession> _sessions = <WKWebViewBrowserSession>{};
  int _validFrom = 0;
  int _nextId = 1;
  bool _backgrounded = false;
  bool _abandoned = false;
  Future<WKContentRuleList?>? _offlineRules;
  AppLifecycleListener? _lifecycle;

  /// Sessions currently open.
  Set<WKWebViewBrowserSession> get sessions => Set<WKWebViewBrowserSession>.unmodifiable(_sessions);

  bool get isBackgrounded => _backgrounded;

  void _log(String line) => config.onLog?.call('[wkwebview] $line');

  @override
  Future<BrowserOutcome<void>> wipeAllSourceData() async => const BrowserCompleted<void>(null);

  @override
  Future<BrowserOutcome<BrowserSession>> openSession(
    BrowserSessionRequest request, {
    CancellationToken? cancel,
  }) async {
    final String? unavailable = unavailableReason;
    if (unavailable != null) return BrowserCapabilityUnavailable<BrowserSession>('openSession', unavailable);
    if (_abandoned) return const BrowserCancelled<BrowserSession>('Browser port abandoned');
    if (request.generation < _validFrom) {
      return BrowserCancelled<BrowserSession>('Generation ${request.generation} is fenced');
    }
    if (cancel?.isCancelled ?? false) return BrowserCancelled<BrowserSession>(cancel!.reason ?? 'cancelled');
    if (_backgrounded) return const BrowserCancelled<BrowserSession>('The app is in the background');
    WKContentRuleList? rules;
    if (config.offlineAllowedHosts != null) {
      rules = await (_offlineRules ??= _compileOfflineRules(config.offlineAllowedHosts!));
      if (rules == null) {
        return const BrowserCapabilityUnavailable<BrowserSession>(
          'openSession',
          'The offline content rule list did not compile; refusing to open a session that could reach a server',
        );
      }
    }
    final WKWebViewBrowserSession session = await ui.runOnPlatformThread(
      () => WKWebViewBrowserSession._(this, 'wk-${_nextId++}', request, rules),
    );
    // A session whose open completed after its generation was fenced closes
    // at once (protocol v1, "Late opens").
    if (request.generation < _validFrom || _abandoned || (cancel?.isCancelled ?? false)) {
      await session.close();
      return BrowserCancelled<BrowserSession>(
        cancel?.isCancelled ?? false ? (cancel!.reason ?? 'cancelled') : 'Generation fenced while opening',
      );
    }
    _sessions.add(session);
    return BrowserCompleted<BrowserSession>(session);
  }

  @override
  Future<void> fence(int generation) async {
    if (generation <= _validFrom) return;
    _validFrom = generation;
    final stale = <WKWebViewBrowserSession>[
      for (final WKWebViewBrowserSession s in _sessions)
        if (s.generation < generation) s,
    ];
    await Future.wait(<Future<void>>[
      for (final WKWebViewBrowserSession s in stale)
        s.close(reason: 'Generation ${s.generation} fenced').then((BrowserOutcome<void> closed) {
          if (closed is! BrowserCompleted<void>) _log('closing fenced session ${s.id} did not complete: $closed');
        }),
    ]);
  }

  /// Enters or leaves the background state (KTD12 iOS backgrounding).
  void setBackgrounded(bool backgrounded) {
    if (_backgrounded == backgrounded) return;
    _backgrounded = backgrounded;
    _log(backgrounded ? 'app entered the background' : 'app returned to the foreground');
    if (backgrounded) {
      for (final WKWebViewBrowserSession s in _sessions) {
        s._enterBackground();
      }
    }
  }

  /// Follows the Flutter app lifecycle: `hidden`/`paused` enter the
  /// background, `resumed` leaves it. Needs an initialized Flutter binding.
  void bindToAppLifecycle() {
    _lifecycle ??= AppLifecycleListener(
      onStateChange: (AppLifecycleState state) => switch (state) {
        AppLifecycleState.hidden || AppLifecycleState.paused => setBackgrounded(true),
        AppLifecycleState.resumed => setBackgrounded(false),
        AppLifecycleState.inactive || AppLifecycleState.detached => null,
      },
    );
  }

  /// Closes every session; later opens are refused.
  Future<void> dispose() async {
    _lifecycle?.dispose();
    _lifecycle = null;
    await fence(1 << 62);
  }

  /// Test hook: drops every session without closing it or deleting storage,
  /// as a process death would. Later opens are refused.
  void debugAbandon() {
    _abandoned = true;
    for (final WKWebViewBrowserSession s in _sessions.toList()) {
      s._teardown('Browser port abandoned', deleteStorage: false);
    }
    _sessions.clear();
  }

  Future<WKContentRuleList?> _compileOfflineRules(Set<String> allowedHosts) {
    final completer = Completer<WKContentRuleList?>();
    // WebKit's content-blocker regular expressions have no alternation, so
    // every scheme and host gets its own rule.
    const schemes = <String>['https?', 'wss?'];
    final String rules = jsonEncode(<Object?>[
      for (final String scheme in schemes)
        <String, Object?>{
          'trigger': <String, Object?>{'url-filter': '^$scheme://'},
          'action': <String, Object?>{'type': 'block'},
        },
      for (final String host in allowedHosts)
        for (final String scheme in schemes)
          <String, Object?>{
            'trigger': <String, Object?>{'url-filter': '^$scheme://${RegExp.escape(host)}[:/]'},
            'action': <String, Object?>{'type': 'ignore-previous-rules'},
          },
    ]);
    final identifier = 'srt-offline-${rules.hashCode.toUnsigned(32).toRadixString(16)}';
    unawaited(
      ui.runOnPlatformThread(() {
        WKContentRuleListStore.defaultStore().compileContentRuleListForIdentifier(
          identifier.toNSString(),
          encodedContentRuleList: rules.toNSString(),
          completionHandler: nullableObjectPairListener<ffi.Void Function(WKContentRuleList, objc.NSError)>((
            objc.ObjCObject? list,
            objc.ObjCObject? error,
          ) {
            if (list == null) {
              _log(
                'offline rule list failed to compile: ${error == null ? '?' : objc.NSError.as(error).localizedDescription.toDartString()}',
              );
              completer.complete(null);
            } else {
              completer.complete(WKContentRuleList.as(list));
            }
          }),
        );
      }),
    );
    return completer.future;
  }
}

/// One settle-once pending operation of a session.
final class _Op<T> {
  _Op(this.operation);

  final String operation;
  final Completer<BrowserOutcome<T>> _completer = Completer<BrowserOutcome<T>>();
  StreamSubscription<void>? _cancelSub;

  Future<BrowserOutcome<T>> get future => _completer.future;

  bool get isSettled => _completer.isCompleted;

  bool settle(BrowserOutcome<T> outcome) {
    if (_completer.isCompleted) return false;
    _completer.complete(outcome);
    unawaited(_cancelSub?.cancel());
    return true;
  }

  void cancel(String reason) => settle(BrowserCancelled<T>(reason));
}

/// A pending main-frame navigation.
final class _Nav {
  _Nav(this.op, this.requested, {required this.isData});

  final _Op<BrowserPage> op;
  final Uri requested;
  final bool isData;

  /// Address of the `WKNavigation` WebKit returned for this load.
  int navigation = 0;
  int? statusCode;
  int actions = 0;
}

/// A WKWebView session; see [WKWebViewBrowserPort].
final class WKWebViewBrowserSession implements BrowserSession {
  WKWebViewBrowserSession._(this._port, this.id, BrowserSessionRequest request, WKContentRuleList? rules)
    : source = request.source,
      generation = request.generation,
      _bridgeName = 'srt${_randomHex()}' {
    _controller = WKUserContentController.new$();
    if (rules != null) _controller.addContentRuleList(rules);
    _store = WKWebsiteDataStore.nonPersistentDataStore();
    final WKWebViewConfiguration configuration = WKWebViewConfiguration.new$()
      ..userContentController = _controller
      ..websiteDataStore = _store;
    final objc.CGRect frame = ffi.Struct.create<objc.CGRect>();
    frame.size.width = 390;
    frame.size.height = 844;
    final WKWebView webView = _webView = WKWebView.alloc().initWithFrame(frame, configuration: configuration);
    if (_port.config.inspectable) webView.isInspectable = true;
    final String? ua = request.userAgent;
    if (ua != null) webView.customUserAgent = ua.toNSString();

    final self = WeakReference<WKWebViewBrowserSession>(this);
    _handler = WKScriptMessageHandler$Builder.implementAsListener(
      userContentController_didReceiveScriptMessage_: (_, WKScriptMessage message) =>
          self.target?._onScriptMessage(message),
      $keepIsolateAlive: false,
    );
    _controller.addScriptMessageHandler(_handler, name: _bridgeName.toNSString());
    _delegate = WKNavigationDelegate$Builder.implementAsListener(
      webView_decidePolicyForNavigationAction_decisionHandler_:
          (_, WKNavigationAction action, objc.ObjCBlock<ffi.Void Function(ffi.Long)> decide) {
            final WKWebViewBrowserSession? s = self.target;
            final WKNavigationActionPolicy policy = s == null
                ? WKNavigationActionPolicy.WKNavigationActionPolicyCancel
                : s._decideAction(action);
            ObjCBlock_ffiVoid_WKNavigationActionPolicy$CallExtension(decide).call(policy);
          },
      webView_decidePolicyForNavigationResponse_decisionHandler_:
          (_, WKNavigationResponse response, objc.ObjCBlock<ffi.Void Function(ffi.Long)> decide) {
            self.target?._onResponse(response);
            ObjCBlock_ffiVoid_WKNavigationResponsePolicy$CallExtension(
              decide,
            ).call(WKNavigationResponsePolicy.WKNavigationResponsePolicyAllow);
          },
      webView_didCommitNavigation_: (_, WKNavigation n) => self.target?._onCommit(n),
      webView_didFinishNavigation_: (_, WKNavigation n) => self.target?._onFinish(n),
      webView_didFailNavigation_withError_: (_, WKNavigation n, objc.NSError e) => self.target?._onFail(n, e),
      webView_didFailProvisionalNavigation_withError_: (_, WKNavigation n, objc.NSError e) =>
          self.target?._onFail(n, e),
      webViewWebContentProcessDidTerminate_: (_) => self.target?._onProcessTerminated(),
      $keepIsolateAlive: false,
    );
    webView.navigationDelegate = _delegate;
    if (!_park(webView)) _port._log('no foreground window: session $id runs outside the view hierarchy (throttled)');
  }

  static final Random _random = Random.secure();

  static String _randomHex() =>
      List<String>.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  final WKWebViewBrowserPort _port;

  @override
  final String id;

  @override
  final SourceIdentity source;

  @override
  final int generation;

  /// Private script-message handler name behind every channel object.
  final String _bridgeName;

  late final WKUserContentController _controller;
  late final WKWebsiteDataStore _store;
  WKWebView? _webView;
  late final WKScriptMessageHandler _handler;
  late final WKNavigationDelegate _delegate;

  String? _closedReason;
  Future<BrowserOutcome<void>>? _closeFuture;
  Uri? _documentUrl;
  _Nav? _nav;
  final Set<_Op<Object?>> _pending = <_Op<Object?>>{};
  final Map<String, void Function(String message)> _channels = <String, void Function(String message)>{};
  final List<String> _pageStartScripts = <String>[];
  BrowserRequestObserver? _observer;
  _Interaction? _interaction;

  @override
  BrowserCapabilities get capabilities => wkWebViewCapabilities;

  bool get isClosed => _closedReason != null;

  /// The session's top-level document URL as the origin rule sees it.
  Uri? get documentUrl => _documentUrl;

  /// Operations still waiting for WebKit (for disposal tests).
  int get pendingOperations => _pending.where((_Op<Object?> o) => !o.isSettled).length + (_nav == null ? 0 : 1);

  bool get _fenced => generation < _port._validFrom;

  BrowserCancelled<T>? _dead<T>(CancellationToken? cancel) {
    final String? closed = _closedReason;
    if (closed != null) return BrowserCancelled<T>(closed);
    if (_fenced) return BrowserCancelled<T>('Generation $generation is fenced');
    if (cancel?.isCancelled ?? false) return BrowserCancelled<T>(cancel!.reason ?? 'cancelled');
    return null;
  }

  BrowserCancelled<T>? _refuseWork<T>(CancellationToken? cancel) =>
      _dead<T>(cancel) ?? (_port._backgrounded ? BrowserCancelled<T>('The app is in the background') : null);

  _Op<T> _track<T>(String operation, CancellationToken? cancel) {
    final op = _Op<T>(operation);
    _pending.add(op as _Op<Object?>);
    unawaited(op.future.whenComplete(() => _pending.remove(op)));
    if (cancel != null) {
      op._cancelSub = cancel.whenCancelled.asStream().listen((_) => op.cancel(cancel.reason ?? 'cancelled'));
    }
    return op;
  }

  // --- loads -----------------------------------------------------------------

  @override
  Future<BrowserOutcome<BrowserPage>> loadUrl(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    CancellationToken? cancel,
  }) async {
    final BrowserCancelled<BrowserPage>? refused = _refuseWork<BrowserPage>(cancel);
    if (refused != null) return refused;
    final BrowserCapabilityUnavailable<BrowserPage>? scheme = BrowserUrlPolicy.checkNavigation<BrowserPage>(
      url,
      'loadUrl',
    );
    if (scheme != null) return scheme;
    final objc.NSURL? nsUrl = objc.NSURL.URLWithString(url.toString().toNSString());
    if (nsUrl == null) return BrowserNavigationFailed<BrowserPage>(url, 'WebKit rejected the URL');
    final _Nav nav = _beginNav(url, cancel, isData: false);
    await ui.runOnPlatformThread(() {
      if (nav.op.isSettled || _webView == null) return;
      final NSMutableURLRequest request = NSMutableURLRequest.requestWithURL(nsUrl);
      for (final MapEntry<String, String> h in headers.entries) {
        request.setValue(h.value.toNSString(), forHTTPHeaderField: h.key.toNSString());
      }
      nav.navigation = _webView!.loadRequest(request)?.ref.pointer.address ?? 0;
    });
    return nav.op.future;
  }

  @override
  Future<BrowserOutcome<BrowserPage>> loadData(String html, {required Uri baseUrl, CancellationToken? cancel}) async {
    final BrowserCancelled<BrowserPage>? refused = _refuseWork<BrowserPage>(cancel);
    if (refused != null) return refused;
    final BrowserCapabilityUnavailable<BrowserPage>? base = BrowserUrlPolicy.checkBaseUrl<BrowserPage>(
      baseUrl,
      'loadData',
    );
    if (base != null) return base;
    final objc.NSURL? nsBase = objc.NSURL.URLWithString(baseUrl.toString().toNSString());
    if (nsBase == null) return BrowserNavigationFailed<BrowserPage>(baseUrl, 'WebKit rejected the base URL');
    final _Nav nav = _beginNav(baseUrl, cancel, isData: true);
    await ui.runOnPlatformThread(() {
      if (nav.op.isSettled || _webView == null) return;
      nav.navigation =
          _webView!
              .loadData(
                utf8.encode(html).toNSData(),
                MIMEType: 'text/html'.toNSString(),
                characterEncodingName: 'utf-8'.toNSString(),
                baseURL: nsBase,
              )
              ?.ref
              .pointer
              .address ??
          0;
    });
    return nav.op.future;
  }

  _Nav _beginNav(Uri url, CancellationToken? cancel, {required bool isData}) {
    _nav?.op.cancel('Superseded by a new load');
    final _Op<BrowserPage> op = _track<BrowserPage>(isData ? 'loadData' : 'loadUrl', cancel);
    final _Nav nav = _nav = _Nav(op, url, isData: isData);
    unawaited(
      op.future.whenComplete(() {
        if (identical(_nav, nav)) _nav = null;
      }),
    );
    return nav;
  }

  bool _isCurrentNav(_Nav nav, WKNavigation navigation) =>
      nav.navigation == 0 || nav.navigation == navigation.ref.pointer.address;

  bool get _ignoreCallbacks => isClosed || _fenced;

  WKNavigationActionPolicy _decideAction(WKNavigationAction action) {
    if (_ignoreCallbacks || _webView == null) return WKNavigationActionPolicy.WKNavigationActionPolicyCancel;
    final NSURLRequest request = action.request;
    final Uri? url = Uri.tryParse(request.URL?.absoluteString?.toDartString() ?? '');
    final WKFrameInfo? target = action.targetFrame;
    final bool mainFrame = target == null || target.isMainFrame;
    final _Nav? nav = mainFrame ? _nav : null;
    if (nav != null) nav.actions++;
    if (url == null || !_allowedFrameUrl(url, mainFrame: mainFrame)) {
      _port._log('refused a ${mainFrame ? 'main-frame' : 'child-frame'} navigation to scheme "${url?.scheme}"');
      nav?.op.settle(
        BrowserCapabilityUnavailable<BrowserPage>(
          nav.op.operation,
          'Navigation to scheme "${url?.scheme}" is not allowed (only http, https, about:blank)',
        ),
      );
      return WKNavigationActionPolicy.WKNavigationActionPolicyCancel;
    }
    final BrowserRequestObserver? observer = _observer;
    final bool dataDocument = nav != null && nav.isData && nav.actions == 1;
    if (observer != null && mainFrame && !dataDocument && BrowserUrlPolicy.isAllowedBaseUrl(url)) {
      try {
        observer(
          BrowserRequest(
            url: url,
            method: request.HTTPMethod?.toDartString() ?? 'GET',
            mainFrame: true,
            redirect: nav != null && nav.actions > 1,
            context: BrowserRequestContext.document,
          ),
        );
      } on Object catch (e) {
        _port._log('request observer threw: $e');
      }
    }
    return WKNavigationActionPolicy.WKNavigationActionPolicyAllow;
  }

  static bool _allowedFrameUrl(Uri url, {required bool mainFrame}) {
    if (BrowserUrlPolicy.isNavigable(url)) return true;
    // Child frames may also hold srcdoc documents.
    return !mainFrame && url.scheme == 'about' && url.path == 'srcdoc';
  }

  void _onResponse(WKNavigationResponse response) {
    if (_ignoreCallbacks || !response.isForMainFrame) return;
    final NSURLResponse r = response.response;
    if (NSHTTPURLResponse.isA(r)) _nav?.statusCode = NSHTTPURLResponse.as(r).statusCode;
  }

  void _onCommit(WKNavigation navigation) {
    if (_ignoreCallbacks) return;
    final String? url = _webView?.URL?.absoluteString?.toDartString();
    _documentUrl = url == null ? null : Uri.tryParse(url);
  }

  void _onFinish(WKNavigation navigation) {
    if (_ignoreCallbacks) return;
    final String? url = _webView?.URL?.absoluteString?.toDartString();
    final Uri? finalUrl = url == null ? null : Uri.tryParse(url);
    _documentUrl = finalUrl;
    final _Nav? nav = _nav;
    if (nav == null || !_isCurrentNav(nav, navigation)) return;
    if (finalUrl != null && !BrowserUrlPolicy.isNavigable(finalUrl)) {
      nav.op.settle(
        BrowserCapabilityUnavailable<BrowserPage>(nav.op.operation, 'Ended on scheme "${finalUrl.scheme}"'),
      );
      return;
    }
    nav.op.settle(
      BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: finalUrl ?? nav.requested, statusCode: nav.statusCode)),
    );
  }

  void _onFail(WKNavigation navigation, objc.NSError error) {
    if (_ignoreCallbacks) return;
    final _Nav? nav = _nav;
    if (nav == null || !_isCurrentNav(nav, navigation)) return;
    final Object info = objc.toDartObject(error.userInfo, convertOther: (objc.ObjCObject o) => o);
    final Object? failing = info is Map ? info['NSErrorFailingURLStringKey'] : null;
    final Uri? failingUrl = failing is String ? Uri.tryParse(failing) : null;
    if (failingUrl != null && !BrowserUrlPolicy.isNavigable(failingUrl)) {
      nav.op.settle(
        BrowserCapabilityUnavailable<BrowserPage>(
          nav.op.operation,
          'Navigation to scheme "${failingUrl.scheme}" is not allowed (only http, https, about:blank)',
        ),
      );
      return;
    }
    final String domain = error.domain.toDartString();
    // NSURLErrorNoPermissionsToReadFile: WebKit's network layer refused a
    // local-file target (a redirect to file:), before any delegate saw it.
    if (domain == 'NSURLErrorDomain' && error.code == -1102) {
      nav.op.settle(
        BrowserCapabilityUnavailable<BrowserPage>(
          nav.op.operation,
          'WebKit refused a local-resource target (redirect to file:); only http, https and about:blank are allowed',
        ),
      );
      return;
    }
    nav.op.settle(
      BrowserNavigationFailed<BrowserPage>(
        failingUrl ?? nav.requested,
        '${error.localizedDescription.toDartString()} ($domain ${error.code})',
      ),
    );
  }

  void _onProcessTerminated() {
    if (_ignoreCallbacks) return;
    _port._log('web content process of session $id terminated');
    _nav?.op.settle(BrowserNavigationFailed<BrowserPage>(_nav!.requested, 'The web content process terminated'));
    for (final _Op<Object?> op in _pending.toList()) {
      op.cancel('The web content process terminated');
    }
  }

  // --- scripts and channels ------------------------------------------------

  static const String _evaluateBody = '''
var v;
try { v = (0, eval)(s); v = await v; }
catch (e) {
  var m;
  try { m = (e !== null && typeof e === 'object' && 'message' in e) ? String(e.name) + ': ' + String(e.message) : String(e); }
  catch (x) { m = 'The script threw a value that cannot be converted to a string'; }
  return JSON.stringify({e: m});
}
var j;
try { j = JSON.stringify(v); } catch (x) { j = undefined; }
return JSON.stringify({ok: j === undefined ? 'null' : j});
''';

  @override
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel}) async {
    final BrowserCancelled<String>? refused = _refuseWork<String>(cancel);
    if (refused != null) return refused;
    final _Op<String> op = _track<String>('evaluate', cancel);
    await ui.runOnPlatformThread(() {
      final WKWebView? webView = _webView;
      if (op.isSettled || webView == null) return;
      webView.callAsyncJavaScript(
        _evaluateBody.toNSString(),
        arguments: objc.NSDictionary.of(<objc.NSCopying, objc.ObjCObject>{'s'.toNSString(): script.toNSString()}),
        inContentWorld: WKContentWorld.getPageWorld(),
        completionHandler:
            nullableObjectPairListener<ffi.Void Function(ffi.Pointer<objc.ObjCObjectImpl>, objc.NSError?)>(
              (objc.ObjCObject? result, objc.ObjCObject? error) => op.settle(_evaluated(result, error)),
            ),
      );
    });
    return op.future;
  }

  BrowserOutcome<String> _evaluated(objc.ObjCObject? result, objc.ObjCObject? error) {
    if (_ignoreCallbacks) return BrowserCancelled<String>(_closedReason ?? 'Generation $generation is fenced');
    if (result != null && objc.NSString.isA(result)) {
      try {
        final wire = jsonDecode(objc.NSString.as(result).toDartString()) as Map<String, Object?>;
        final Object? thrown = wire['e'];
        if (thrown is String) return BrowserScriptError<String>(thrown);
        return BrowserCompleted<String>(wire['ok'] as String? ?? 'null');
      } on FormatException catch (e) {
        return BrowserScriptError<String>('Unreadable evaluation result: ${e.message}');
      }
    }
    if (error != null) {
      final e = objc.NSError.as(error);
      // WKErrorJavaScriptExceptionOccurred (4) outside the wrapper's own
      // try/catch, for example a syntax error in the wrapper's argument.
      if (e.domain.toDartString() == 'WKErrorDomain' && e.code == 4) {
        final Object info = objc.toDartObject(e.userInfo, convertOther: (objc.ObjCObject o) => o);
        final Object? message = info is Map ? info['WKJavaScriptExceptionMessage'] : null;
        return BrowserScriptError<String>(message is String ? message : e.localizedDescription.toDartString());
      }
      // The document went away before the script finished (navigation,
      // process termination): the evaluation cannot complete.
      return BrowserCancelled<String>('Evaluation ended: ${e.localizedDescription.toDartString()} (${e.code})');
    }
    return const BrowserCompleted<String>('null');
  }

  /// Fire-and-forget script in the current main frame (channel updates).
  Future<void> _runInCurrentDocument(String script) {
    final completer = Completer<void>();
    unawaited(
      ui.runOnPlatformThread(() {
        final WKWebView? webView = _webView;
        if (webView == null) {
          completer.complete();
          return;
        }
        webView.evaluateJavaScript(
          script.toNSString(),
          completionHandler:
              nullableObjectPairListener<ffi.Void Function(ffi.Pointer<objc.ObjCObjectImpl>, objc.NSError?)>(
                (_, _) => completer.complete(),
              ),
        );
      }),
    );
    return completer.future;
  }

  String _channelScript(Iterable<String> names) =>
      '''
(function () {
  var mh = window.webkit && window.webkit.messageHandlers;
  var h = mh && mh[${jsonEncode(_bridgeName)}];
  if (!h) return;
  ${jsonEncode(names.toList())}.forEach(function (n) {
    try {
      window[n] = Object.freeze({
        postMessage: function (m) { if (typeof m === 'string') h.postMessage({c: n, m: m}); }
      });
    } catch (e) {}
  });
})();
void 0;
''';

  /// Rebuilds the document-start user scripts: channel objects first, then
  /// page-start scripts in registration order (protocol 1.2).
  Future<void> _rebuildUserScripts() => ui.runOnPlatformThread(() {
    if (_webView == null) return;
    _controller.removeAllUserScripts();
    WKUserScript script(String source) => WKUserScript.alloc().initWithSource(
      source.toNSString(),
      injectionTime: WKUserScriptInjectionTime.WKUserScriptInjectionTimeAtDocumentStart,
      forMainFrameOnly: false,
    );
    if (_channels.isNotEmpty) _controller.addUserScript(script(_channelScript(_channels.keys)));
    for (final String s in _pageStartScripts) {
      _controller.addUserScript(script(s));
    }
  });

  @override
  Future<BrowserOutcome<void>> setMessageHandler(String name, void Function(String message)? handler) async {
    final BrowserCancelled<void>? dead = _dead<void>(null);
    if (dead != null) return dead;
    final BrowserCapabilityUnavailable<void>? invalid = BrowserMessageChannel.checkName<void>(name);
    if (invalid != null) return invalid;
    final bool existed = _channels.containsKey(name);
    if (handler == null) {
      if (!existed) return const BrowserCompleted<void>(null);
      _channels.remove(name);
      await _rebuildUserScripts();
      await _runInCurrentDocument('try { delete window[${jsonEncode(name)}]; } catch (e) {} void 0;');
    } else {
      _channels[name] = handler;
      if (!existed) {
        await _rebuildUserScripts();
        await _runInCurrentDocument(_channelScript(<String>[name]));
      }
    }
    return const BrowserCompleted<void>(null);
  }

  void _onScriptMessage(WKScriptMessage message) {
    if (_ignoreCallbacks) return;
    final Object body = objc.toDartObject(message.body, convertOther: (objc.ObjCObject o) => o);
    if (body is! Map) return;
    final Object? channel = body['c'];
    final Object? text = body['m'];
    if (channel is! String || text is! String) return;
    final void Function(String)? handler = _channels[channel];
    if (handler == null) return;
    final Uri? document = _documentUrl;
    final WKSecurityOrigin origin = message.frameInfo.securityOrigin;
    final int port = origin.port;
    final String scheme = origin.protocol.toDartString();
    final String host = origin.host.toDartString();
    if (document == null || scheme.isEmpty || host.isEmpty) return;
    final frameOrigin = Uri(scheme: scheme, host: host, port: port == 0 ? null : port);
    if (!BrowserMessageChannel.accepts(documentUrl: document, frameOrigin: frameOrigin)) return;
    try {
      handler(text);
    } on Object catch (e) {
      _port._log('message handler for channel "$channel" threw: $e');
    }
  }

  @override
  Future<BrowserOutcome<void>> addPageStartScript(String script) async {
    final BrowserCancelled<void>? dead = _dead<void>(null);
    if (dead != null) return dead;
    _pageStartScripts.add(script);
    await _rebuildUserScripts();
    return const BrowserCompleted<void>(null);
  }

  // --- interception ----------------------------------------------------------

  @override
  Future<BrowserOutcome<void>> setRequestObserver(BrowserRequestObserver? observer) async {
    final BrowserCancelled<void>? dead = _dead<void>(null);
    if (dead != null) return dead;
    _observer = observer;
    return const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<void>> setRequestReplacer(BrowserRequestReplacer? replacer) async {
    final BrowserCancelled<void>? dead = _dead<void>(null);
    if (dead != null) return dead;
    if (replacer == null) return const BrowserCompleted<void>(null);
    return capabilities.check<void>(BrowserFeature.replaceRequests, 'setRequestReplacer')!;
  }

  // --- cookies and user agent -----------------------------------------------

  @override
  Future<BrowserOutcome<List<BrowserCookie>>> getCookies(Uri url, {CancellationToken? cancel}) async {
    final BrowserCancelled<List<BrowserCookie>>? dead = _dead<List<BrowserCookie>>(cancel);
    if (dead != null) return dead;
    final _Op<List<BrowserCookie>> op = _track<List<BrowserCookie>>('getCookies', cancel);
    await ui.runOnPlatformThread(() {
      _store.httpCookieStore.getAllCookies(
        ObjCBlock_ffiVoid_NSArray.listener((objc.NSArray all) {
          if (_ignoreCallbacks) {
            op.cancel(_closedReason ?? 'Generation $generation is fenced');
            return;
          }
          final cookies = <BrowserCookie>[];
          for (var i = 0; i < all.count; i++) {
            final c = NSHTTPCookie.as(all.objectAtIndex(i));
            final String domain = c.domain.toDartString();
            final String path = c.path.toDartString();
            if (!_cookieMatches(url, domain: domain, path: path, secure: c.isSecure)) continue;
            cookies.add(
              BrowserCookie(
                name: c.name.toDartString(),
                value: c.value.toDartString(),
                domain: domain,
                path: path,
                expires: c.expiresDate?.toDateTime().toUtc(),
                secure: c.isSecure,
                httpOnly: c.isHTTPOnly,
              ),
            );
          }
          op.settle(BrowserCompleted<List<BrowserCookie>>(cookies));
        }, keepIsolateAlive: false),
      );
    });
    return op.future;
  }

  static bool _cookieMatches(Uri url, {required String domain, required String path, required bool secure}) {
    if (secure && url.scheme != 'https') return false;
    final String host = url.host.toLowerCase();
    final String d = domain.toLowerCase();
    final bool domainOk = d.startsWith('.') ? (host == d.substring(1) || host.endsWith(d)) : host == d;
    if (!domainOk) return false;
    final String requestPath = url.path.isEmpty ? '/' : url.path;
    if (path.isEmpty || path == '/') return true;
    return requestPath == path || requestPath.startsWith(path.endsWith('/') ? path : '$path/');
  }

  @override
  Future<BrowserOutcome<void>> setCookie(Uri url, BrowserCookie cookie, {CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead<void>(cancel);
    if (dead != null) return dead;
    if (!BrowserUrlPolicy.isAllowedBaseUrl(url)) {
      return BrowserCapabilityUnavailable<void>('setCookie', 'Cookie URL scheme "${url.scheme}" is not http(s)');
    }
    // NSHTTPCookie property keys (NSHTTPCookieName, ...) are these strings.
    final properties = <String, String>{
      'Name': cookie.name,
      'Value': cookie.value,
      'Domain': cookie.domain ?? url.host,
      'Path': cookie.path ?? '/',
      if (cookie.secure) 'Secure': 'TRUE',
      if (cookie.httpOnly) 'HttpOnly': 'TRUE',
    };
    final DateTime? expires = cookie.expires;
    final _Op<void> op = _track<void>('setCookie', cancel);
    await ui.runOnPlatformThread(() {
      final NSHTTPCookie? native = NSHTTPCookie.cookieWithProperties(
        objc.NSDictionary.of(<objc.NSCopying, objc.ObjCObject>{
          for (final MapEntry<String, String> e in properties.entries) e.key.toNSString(): e.value.toNSString(),
          if (expires != null) 'Expires'.toNSString(): expires.toNSDate(),
        }),
      );
      if (native == null) {
        op.settle(const BrowserCapabilityUnavailable<void>('setCookie', 'WebKit rejected the cookie properties'));
        return;
      }
      _store.httpCookieStore.setCookie(
        native,
        completionHandler: ObjCBlock_ffiVoid.listener(() {
          op.settle(
            _ignoreCallbacks
                ? BrowserCancelled<void>(_closedReason ?? 'Generation $generation is fenced')
                : const BrowserCompleted<void>(null),
          );
        }, keepIsolateAlive: false),
      );
    });
    return op.future;
  }

  @override
  Future<BrowserOutcome<void>> setUserAgent(String userAgent, {CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead<void>(cancel);
    if (dead != null) return dead;
    await ui.runOnPlatformThread(() => _webView?.customUserAgent = userAgent.toNSString());
    return const BrowserCompleted<void>(null);
  }

  /// The user agent WebKit will send (custom or default), for tests.
  Future<String?> debugUserAgent() async {
    final BrowserOutcome<String> ua = await evaluate('navigator.userAgent');
    final String? json = ua.valueOrNull;
    return json == null ? null : jsonDecode(json) as String?;
  }

  // --- interaction -------------------------------------------------------

  @override
  Future<BrowserOutcome<void>> showForInteraction({required Duration timeout, CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead<void>(cancel);
    if (dead != null) return dead;
    if (!_port.config.allowInteraction) {
      return const BrowserInteractionRequired<void>('Visible browser interaction is disabled for this run');
    }
    if (_port._backgrounded) return const BrowserInteractionRequired<void>('The app is in the background');
    if (_interaction != null && !_interaction!.op.isSettled) {
      return const BrowserCapabilityUnavailable<void>('showForInteraction', 'An interaction is already showing');
    }
    final _Op<void> op = _track<void>('showForInteraction', cancel);
    final _Interaction interaction = _interaction = _Interaction(op);
    final String? failure = await ui.runOnPlatformThread(() => interaction.present(this));
    if (failure != null) {
      op.settle(BrowserInteractionRequired<void>(failure));
      return op.future;
    }
    final timer = Timer(timeout, () {
      if (op.settle(BrowserInteractionRequired<void>('Interaction timed out after $timeout'))) {
        unawaited(ui.runOnPlatformThread(interaction.dismiss));
      }
    });
    unawaited(
      op.future.whenComplete(() {
        timer.cancel();
        unawaited(ui.runOnPlatformThread(interaction.dismiss));
      }),
    );
    return op.future;
  }

  /// Whether an interaction is presented now.
  bool get isShowingInteraction => _interaction != null && !_interaction!.op.isSettled;

  /// Test hook: dismisses a shown interaction exactly as the user swiping
  /// the sheet away does (UIKit sends no dismissal callback for a
  /// programmatic dismissal, so this calls the same handler).
  Future<void> debugUserDismiss() async {
    final _Interaction? interaction = _interaction;
    if (interaction == null) return;
    await ui.runOnPlatformThread(interaction.dismiss);
    interaction.userDismissed();
  }

  // --- lifetime ---------------------------------------------------------

  void _enterBackground() {
    if (isClosed) return;
    final _Nav? nav = _nav;
    if (nav != null) {
      nav.op.cancel('The app entered the background');
      unawaited(ui.runOnPlatformThread(() => _webView?.stopLoading()));
    }
    for (final _Op<Object?> op in _pending.toList()) {
      if (op.operation == 'showForInteraction') continue;
      op.cancel('The app entered the background');
    }
  }

  @override
  Future<BrowserOutcome<void>> close({String reason = 'Session closed'}) =>
      _closeFuture ??= _teardown(reason, deleteStorage: true);

  Future<BrowserOutcome<void>> _teardown(String reason, {required bool deleteStorage}) async {
    _closedReason ??= reason;
    _port._sessions.remove(this);
    _observer = null;
    _channels.clear();
    _nav?.op.cancel(reason);
    for (final _Op<Object?> op in _pending.toList()) {
      op.cancel(reason);
    }
    final _Interaction? interaction = _interaction;
    await ui.runOnPlatformThread(() {
      interaction?.dismiss();
      final WKWebView? webView = _webView;
      if (webView == null) return;
      webView.stopLoading();
      webView.navigationDelegate = null;
      webView.removeFromSuperview();
      _controller.removeScriptMessageHandlerForName(_bridgeName.toNSString());
      _controller.removeAllUserScripts();
    });
    final BrowserOutcome<void> deleted = deleteStorage ? await _deleteStorage() : const BrowserCompleted<void>(null);
    _webView = null;
    return deleted;
  }

  /// Deletes every data type from the session's store, then confirms that
  /// no records or cookies remain (KTD9).
  Future<BrowserOutcome<void>> _deleteStorage() async {
    final removed = Completer<void>();
    final records = Completer<int>();
    final cookies = Completer<int>();
    await ui.runOnPlatformThread(() {
      final objc.NSSet types = WKWebsiteDataStore.allWebsiteDataTypes();
      _store.removeDataOfTypes(
        types,
        modifiedSince: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toNSDate(),
        completionHandler: ObjCBlock_ffiVoid.listener(() {
          removed.complete();
          _store.fetchDataRecordsOfTypes(
            types,
            completionHandler: ObjCBlock_ffiVoid_NSArray.listener(
              (objc.NSArray r) => records.complete(r.count),
              keepIsolateAlive: false,
            ),
          );
          _store.httpCookieStore.getAllCookies(
            ObjCBlock_ffiVoid_NSArray.listener((objc.NSArray c) => cookies.complete(c.count), keepIsolateAlive: false),
          );
        }, keepIsolateAlive: false),
      );
    });
    Future<(int, int)> confirmed = Future.wait(<Future<int>>[records.future, cookies.future]).then(
      (List<int> counts) => (counts[0], counts[1]),
    );
    final Duration? bound = _port.config.storageDeletionTimeout;
    if (bound != null) confirmed = confirmed.timeout(bound);
    try {
      final (int leftRecords, int leftCookies) = await confirmed;
      if (leftRecords == 0 && leftCookies == 0) return const BrowserCompleted<void>(null);
      return BrowserCapabilityUnavailable<void>(
        'close',
        'Storage deletion left $leftRecords data records and $leftCookies cookies',
      );
    } on TimeoutException {
      return BrowserCapabilityUnavailable<void>('close', 'WebKit did not confirm storage deletion within $bound');
    }
  }

  @override
  String toString() => 'WKWebViewBrowserSession($id, ${source.sourceId}, generation $generation)';
}

/// A visible interaction: the session's web view presented as a sheet.
final class _Interaction {
  _Interaction(this.op);

  final _Op<void> op;
  UIViewController? _controller;
  WKWebView? _webView;

  // Retained here: UIKit holds presentation delegates weakly.
  // ignore: unused_field
  UIAdaptivePresentationControllerDelegate? _delegate;

  /// Presents on the platform thread; returns why it could not, or `null`.
  String? present(WKWebViewBrowserSession session) {
    final WKWebView? webView = session._webView;
    if (webView == null) return 'The session is closed';
    final UIViewController? top = _topViewController();
    if (top == null) return 'No foreground window is available to present the browser in';
    final UIViewController controller = _controller = UIViewController.alloc().init();
    // The web view is a subview, never the controller's root view: UIKit
    // refuses (throws) to adopt a WKWebView created outside a controller.
    final UIView root = controller.view;
    webView.frame = root.bounds;
    webView.autoresizingMask =
        UIViewAutoresizing.UIViewAutoresizingFlexibleWidth | UIViewAutoresizing.UIViewAutoresizingFlexibleHeight;
    root.addSubview(webView);
    _webView = webView;
    final self = WeakReference<_Interaction>(this);
    final UIAdaptivePresentationControllerDelegate delegate = _delegate =
        UIAdaptivePresentationControllerDelegate$Builder.implementAsListener(
          presentationControllerDidDismiss_: (_) => self.target?.userDismissed(),
          $keepIsolateAlive: false,
        );
    top.presentViewController(controller, animated: true);
    controller.presentationController?.delegate = delegate;
    return null;
  }

  void userDismissed() => op.settle(const BrowserCompleted<void>(null));

  /// Dismisses the sheet if it is still presented (platform thread).
  void dismiss() {
    final UIViewController? controller = _controller;
    _controller = null;
    if (controller == null) return;
    final WKWebView? webView = _webView;
    _webView = null;
    if (webView != null && !_park(webView)) webView.removeFromSuperview();
    controller.presentationController?.delegate = null;
    if (controller.presentingViewController != null && !controller.isBeingDismissed) {
      controller.dismissViewControllerAnimated(false);
    }
    _delegate = null;
  }

  static UIViewController? _topViewController() {
    UIViewController? top = _foregroundWindow()?.rootViewController;
    for (UIViewController? next = top?.presentedViewController; next != null; next = next.presentedViewController) {
      top = next;
    }
    return top;
  }
}

/// The key window of the foreground-active scene (platform thread).
UIWindow? _foregroundWindow() {
  final objc.NSArray scenes = UIApplication.getSharedApplication().connectedScenes.allObjects;
  for (var i = 0; i < scenes.count; i++) {
    final objc.ObjCObject scene = scenes.objectAtIndex(i);
    if (!UIWindowScene.isA(scene)) continue;
    final ws = UIWindowScene.as(scene);
    if (ws.activationState != UISceneActivationState.UISceneActivationStateForegroundActive) continue;
    final UIWindow? key = ws.keyWindow;
    if (key != null) return key;
    if (ws.windows.count > 0) return UIWindow.as(ws.windows.objectAtIndex(0));
  }
  return null;
}

/// Parks [webView] in the key window, outside its visible bounds (platform
/// thread). A WKWebView outside any window counts as hidden: WebKit then
/// throttles its timers and lets the processes of its cross-origin frames
/// be suspended, so pages (challenge scripts included) stall. Parked, it
/// runs as a visible page would, without being on screen. Returns whether a
/// window was available.
bool _park(WKWebView webView) {
  final UIWindow? window = _foregroundWindow();
  if (window == null) return false;
  final objc.CGRect frame = ffi.Struct.create<objc.CGRect>();
  frame.origin.x = -20000;
  frame.origin.y = -20000;
  frame.size.width = 390;
  frame.size.height = 844;
  webView.autoresizingMask = UIViewAutoresizing.UIViewAutoresizingNone;
  webView.frame = frame;
  window.addSubview(webView);
  return true;
}
