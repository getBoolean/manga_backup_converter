// Android app-process implementation of the BrowserPort contract (KTD19,
// KTD20, KTD23, U12).
//
// Dart drives the Kotlin facade `AppBrowserHost` through JNIgen bindings
// with JSON commands; replies and events come back through the
// `AppBrowserListener` JNIgen listener. Every facade call only posts to the
// main looper and returns, and every listener method is asynchronous, so
// neither side ever waits for the other: there is no synchronous wait from
// a Dart isolate on the main thread and no main-thread wait on Dart. No
// platform channel carries any call (KTD23).
import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate, Platform;
import 'dart:math';

import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_android/src/app_foreground.dart';
import 'package:source_runtime_android/src/bindings/source_runtime_bindings.g.dart' as jni;

/// The native side of [AndroidWebViewBrowserPort]: posts JSON commands to
/// the main-looper WebView host. Replies arrive through the callbacks given
/// to an [AppBrowserNativeFactory].
abstract interface class AppBrowserNative {
  /// Posts [op] with [args]; its outcome arrives as one reply for [callId].
  void call(int callId, String op, Map<String, Object?> args);

  /// Destroys every WebView without deleting data, and stops listening.
  void dispose();
}

/// Builds the native side, wiring its replies and events to the port.
typedef AppBrowserNativeFactory = AppBrowserNative Function(
  void Function(int callId, bool ok, String payload) onReply,
  void Function(String session, String kind, String payload) onEvent,
);

/// The JNIgen-backed native side: the Kotlin `AppBrowserHost`.
final class JniAppBrowserNative implements AppBrowserNative {
  JniAppBrowserNative._(this._host, this._listener);

  /// Creates the host over the application context.
  static AppBrowserNative create(
    void Function(int callId, bool ok, String payload) onReply,
    void Function(String session, String kind, String payload) onEvent,
  ) {
    final listener = jni.AppBrowserListener.implement(
      jni.$AppBrowserListener(
        onReply: (int callId, bool ok, JString payload) =>
            onReply(callId, ok, payload.toDartString(releaseOriginal: true)),
        onReply$async: true,
        onEvent: (JString session, JString kind, JString payload) => onEvent(
          session.toDartString(releaseOriginal: true),
          kind.toDartString(releaseOriginal: true),
          payload.toDartString(releaseOriginal: true),
        ),
        onEvent$async: true,
      ),
    );
    final JObject context = androidApplicationContext;
    try {
      return JniAppBrowserNative._(jni.AppBrowserHost(context, listener), listener);
    } finally {
      context.release();
    }
  }

  final jni.AppBrowserHost _host;
  final jni.AppBrowserListener _listener;
  bool _disposed = false;

  @override
  void call(int callId, String op, Map<String, Object?> args) {
    if (_disposed) return;
    final JString jOp = op.toJString();
    final JString jArgs = jsonEncode(args).toJString();
    try {
      _host.call(callId, jOp, jArgs);
    } finally {
      jOp.release();
      jArgs.release();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _host
      ..dispose()
      ..release();
    _listener.release();
  }
}

/// Configuration of an [AndroidWebViewBrowserPort].
final class AndroidBrowserConfig {
  const AndroidBrowserConfig({
    this.allowInteraction = true,
    this.offline = false,
    this.disableProfiles = false,
    this.onLog,
  });

  /// When false (unattended runs), [BrowserSession.showForInteraction]
  /// answers [BrowserInteractionRequired] without showing anything.
  final bool allowInteraction;

  /// Replay mode for tests: the process's WebViews go through a loopback
  /// proxy that refuses every request (no DIRECT fallback, no DNS lookup);
  /// loopback hosts are reached directly. The port refuses to start when the
  /// override is not confirmed. Never set in production.
  final bool offline;

  /// Test hook: behave as a WebView without multi-profile (shared default
  /// profile, isolation unavailable).
  final bool disableProfiles;

  /// Receives diagnostic lines; pass a redacting sink (KTD9). Never receives
  /// cookie values, headers or page text.
  final void Function(String line)? onLog;
}

/// Why per-source browser isolation is unavailable without multi-profile.
const String androidIsolationUnavailableReason =
    'Source browser isolation unavailable: this WebView does not support androidx.webkit multi-profile, '
    'so every session would share the app process cookie store and web storage';

/// The capabilities of an app-process Android WebView session (protocol 1.2).
final BrowserCapabilities androidWebViewCapabilities = BrowserCapabilities(
  available: const <BrowserFeature>{
    BrowserFeature.pageStartScripts,
    BrowserFeature.observeNavigations,
    BrowserFeature.observeSubresources,
    BrowserFeature.observeRequestHeaders,
    // shouldInterceptRequest reports sec-ch-ua* on Android System WebView
    // (U12 emulator receipt `request-observation`, WebView 134).
    BrowserFeature.observeClientHints,
    BrowserFeature.scriptErrors,
  },
  unavailable: const <BrowserFeature, String>{
    BrowserFeature.observeRequestBodies: 'WebResourceRequest does not expose request bodies',
    BrowserFeature.replaceRequests:
        'Substituting a response means answering shouldInterceptRequest on a Chromium IO thread, which would '
        'block that thread on the Dart isolate (KTD23 cross-runtime wait); not implemented',
  },
);

/// Failure codes the Kotlin host replies with.
abstract final class _Code {
  static const String navigation = 'navigation';
  static const String superseded = 'superseded';
  static const String closed = 'closed';
  static const String disposed = 'disposed';
  static const String interaction = 'interaction';
  static const String unconfirmed = 'unconfirmed';
}

final class _Reply {
  const _Reply(this.ok, this.payload);
  final bool ok;
  final Map<String, Object?> payload;

  String get code => payload['code'] as String? ?? 'error';
  String get message => payload['message'] as String? ?? '$payload';
}

/// [BrowserPort] over the app-process Android WebView (KTD19, KTD20).
///
/// - **Threading:** WebViews live on the main looper, owned by the Kotlin
///   host; this port only posts commands and settles operations from
///   listener callbacks.
/// - **Storage:** with multi-profile ([sourceIsolationAvailable]) every
///   session gets its own androidx.webkit profile, deleted and verified at
///   [BrowserSession.close]. Without it, sessions share the default profile:
///   the port refuses a second concurrently open source by name rather than
///   claim isolation, and wipes the default profile at close. [start] wipes
///   every port-owned profile and the default profile before the first
///   session, so a killed app leaves nothing behind.
/// - **Backgrounding:** with no started Activity in the process, pending
///   loads and evaluations end as [BrowserInteractionRequired], new ones are
///   refused the same way, and late callbacks are discarded. A shown
///   interaction keeps the process in the foreground.
final class AndroidWebViewBrowserPort implements BrowserPort {
  AndroidWebViewBrowserPort._(this.config);

  final AndroidBrowserConfig config;

  late final AppBrowserNative _native;
  final Map<int, Completer<_Reply>> _calls = <int, Completer<_Reply>>{};
  final Map<String, AndroidWebViewBrowserSession> _sessions = <String, AndroidWebViewBrowserSession>{};
  int _nextCall = 1;
  int _nextSession = 1;
  int _validFrom = 0;
  int _started = 1;
  bool? _backgroundOverride;
  AndroidAppForeground? _foreground;
  bool _wasBackgrounded = false;
  bool _disposed = false;

  /// What `init` reported: features, WebView package, profile support.
  Map<String, Object?> info = const <String, Object?>{};

  /// What the start-up wipe removed.
  Map<String, Object?> startupWipe = const <String, Object?>{};

  /// Why this process cannot drive the app-process WebView, or `null`.
  static String? get unavailableReason => Platform.isAndroid ? null : 'AndroidWebViewBrowserPort runs on Android only';

  /// Starts the port: creates the host, probes features, sets the replay
  /// proxy when [AndroidBrowserConfig.offline], and wipes all source browser
  /// data (KTD20 start-up rule). Fails with a named reason, never with a
  /// half-started port.
  ///
  /// With [foreground] (the app's one lifecycle signal, shared with the
  /// background gate), the port follows it instead of its host's own
  /// foreground events; both come from the same Activity tracker.
  static Future<SourceOutcome<AndroidWebViewBrowserPort>> start({
    AndroidBrowserConfig config = const AndroidBrowserConfig(),
    AppBrowserNativeFactory? native,
    AndroidAppForeground? foreground,
  }) async {
    final String? unavailable = native == null ? unavailableReason : null;
    if (unavailable != null) {
      return SourceFailed<AndroidWebViewBrowserPort>(RuntimeUnavailableFailure(unavailable));
    }
    final port = AndroidWebViewBrowserPort._(config);
    port._native = (native ?? JniAppBrowserNative.create)(port._onReply, port._onEvent);
    final _Reply init = await port._call('init', <String, Object?>{
      'offline': config.offline,
      'disableProfiles': config.disableProfiles,
    });
    if (!init.ok) {
      port._native.dispose();
      return SourceFailed<AndroidWebViewBrowserPort>(
        CapabilityUnavailableFailure('browser.start', 'WebView host did not start: ${init.message}'),
      );
    }
    port.info = init.payload;
    port._started = (init.payload['startedActivities'] as num?)?.toInt() ?? 1;
    final Map<String, Object?> features =
        (init.payload['features'] as Map<String, Object?>?) ?? const <String, Object?>{};
    for (final required in <String>['WEB_MESSAGE_LISTENER', 'DOCUMENT_START_SCRIPT']) {
      if (features[required] != true) {
        port._native.dispose();
        return SourceFailed<AndroidWebViewBrowserPort>(
          CapabilityUnavailableFailure(
            'browser.start',
            'The installed WebView lacks $required, which the origin-attested message channel needs',
          ),
        );
      }
    }
    final BrowserOutcome<void> wiped = await port.wipeAllSourceData();
    if (wiped is! BrowserCompleted<void>) {
      port._native.dispose();
      return SourceFailed<AndroidWebViewBrowserPort>(
        CapabilityUnavailableFailure('browser.wipe', 'Start-up wipe not confirmed: $wiped'),
      );
    }
    port
      .._foreground = foreground
      .._wasBackgrounded = port.isBackgrounded;
    foreground?.addListener(port._onForeground);
    port._log('started: ${jsonEncode(port.info)}');
    return SourceSuccess<AndroidWebViewBrowserPort>(port);
  }

  /// Whether sessions get their own androidx.webkit profile.
  bool get sourceIsolationAvailable => info['multiProfile'] == true;

  /// The isolation capability as receipts record it.
  Map<String, Object?> get isolationReport => <String, Object?>{
    'sourceBrowserIsolation': sourceIsolationAvailable ? 'available' : 'unavailable',
    if (!sourceIsolationAvailable) 'reason': androidIsolationUnavailableReason,
    'mechanism': sourceIsolationAvailable ? 'one androidx.webkit profile per session' : 'shared default profile',
  };

  Map<String, AndroidWebViewBrowserSession> get sessions =>
      Map<String, AndroidWebViewBrowserSession>.unmodifiable(_sessions);

  bool get isBackgrounded => _backgroundOverride ?? _foreground?.isBackgrounded ?? _started == 0;

  void _log(String line) => config.onLog?.call('[android-webview] $line');

  // --- native plumbing -------------------------------------------------------

  Future<_Reply> _call(String op, Map<String, Object?> args) {
    if (_disposed) return Future<_Reply>.value(const _Reply(false, <String, Object?>{'code': _Code.disposed}));
    final int id = _nextCall++;
    final completer = Completer<_Reply>();
    _calls[id] = completer;
    _native.call(id, op, args);
    return completer.future;
  }

  void _onReply(int callId, bool ok, String payload) {
    final Completer<_Reply>? completer = _calls.remove(callId);
    if (completer == null) return;
    Map<String, Object?> decoded;
    try {
      decoded = jsonDecode(payload) as Map<String, Object?>;
    } on FormatException {
      decoded = <String, Object?>{'code': 'error', 'message': 'Unreadable reply'};
    }
    completer.complete(_Reply(ok, decoded));
  }

  void _onEvent(String session, String kind, String payload) {
    final Map<String, Object?> data;
    try {
      data = jsonDecode(payload) as Map<String, Object?>;
    } on FormatException {
      return;
    }
    if (session.isEmpty) {
      if (kind == 'foreground' && _foreground == null) _setStarted((data['started'] as num?)?.toInt() ?? 0);
      return;
    }
    final AndroidWebViewBrowserSession? s = _sessions[session];
    if (s == null) return;
    switch (kind) {
      case 'bridge':
        s._onBridge(data);
      case 'request':
        s._onRequest(data);
      case 'interaction':
        _log('session ${s.id} interaction ${data['state']}');
    }
  }

  void _setStarted(int started) {
    _started = started;
    _backgroundChanged();
  }

  void _onForeground(bool _) => _backgroundChanged();

  /// Test seam: forces the background state (`null` follows the Activities).
  void setBackgroundedOverride(bool? backgrounded) {
    _backgroundOverride = backgrounded;
    _backgroundChanged();
  }

  void _backgroundChanged() {
    if (_wasBackgrounded == isBackgrounded) return;
    _wasBackgrounded = isBackgrounded;
    _log(isBackgrounded ? 'app entered the background' : 'app returned to the foreground');
    if (isBackgrounded) {
      for (final AndroidWebViewBrowserSession s in _sessions.values) {
        s._enterBackground();
      }
    }
  }

  // --- BrowserPort -------------------------------------------------------------

  @override
  Future<BrowserOutcome<void>> wipeAllSourceData() async {
    final _Reply r = await _call('wipeAll', const <String, Object?>{});
    startupWipe = r.payload;
    if (r.ok) return const BrowserCompleted<void>(null);
    return BrowserCapabilityUnavailable<void>('wipeAllSourceData', r.message);
  }

  @override
  Future<BrowserOutcome<BrowserSession>> openSession(BrowserSessionRequest request, {CancellationToken? cancel}) async {
    if (_disposed) return const BrowserCancelled<BrowserSession>('Browser port disposed');
    if (request.generation < _validFrom) {
      return BrowserCancelled<BrowserSession>('Generation ${request.generation} is fenced');
    }
    if (cancel?.isCancelled ?? false) return BrowserCancelled<BrowserSession>(cancel!.reason ?? 'cancelled');
    if (isBackgrounded) return const BrowserInteractionRequired<BrowserSession>('The app is in the background');
    if (!sourceIsolationAvailable) {
      for (final AndroidWebViewBrowserSession s in _sessions.values) {
        if (s.source != request.source) {
          return BrowserCapabilityUnavailable<BrowserSession>(
            'openSession',
            '$androidIsolationUnavailableReason; ${s.source.sourceId} has a session open, so '
                '${request.source.sourceId} cannot open one until it closes',
          );
        }
      }
    }
    final id = 'aw-${_nextSession++}';
    final bridge = 'srt${_randomHex()}';
    final _Reply r = await _call('open', <String, Object?>{
      'session': id,
      'bridge': bridge,
      'userAgent': request.userAgent,
    });
    if (!r.ok) return BrowserCapabilityUnavailable<BrowserSession>('openSession', r.message);
    final session = AndroidWebViewBrowserSession._(this, id, bridge, request, r.payload['profile'] as String?);
    _sessions[id] = session;
    // A session whose open completed after its generation was fenced closes
    // at once (protocol v1, "Late opens").
    if (request.generation < _validFrom || (cancel?.isCancelled ?? false) || _disposed) {
      await session.close();
      return BrowserCancelled<BrowserSession>(
        cancel?.isCancelled ?? false ? (cancel!.reason ?? 'cancelled') : 'Generation fenced while opening',
      );
    }
    return BrowserCompleted<BrowserSession>(session);
  }

  @override
  Future<void> fence(int generation) async {
    if (generation <= _validFrom) return;
    _validFrom = generation;
    final stale = <AndroidWebViewBrowserSession>[
      for (final AndroidWebViewBrowserSession s in _sessions.values)
        if (s.generation < generation) s,
    ];
    await Future.wait(<Future<void>>[
      for (final AndroidWebViewBrowserSession s in stale)
        s._closeWith('Generation ${s.generation} fenced').then((BrowserOutcome<void> closed) {
          if (closed is! BrowserCompleted<void>) _log('closing fenced session ${s.id} did not complete: $closed');
        }),
    ]);
  }

  /// Closes every session, then destroys the host. Later calls are refused.
  Future<void> dispose() async {
    if (_disposed) return;
    _foreground?.removeListener(_onForeground);
    await fence(1 << 62);
    _disposed = true;
    _native.dispose();
    for (final Completer<_Reply> c in _calls.values) {
      c.complete(const _Reply(false, <String, Object?>{'code': _Code.disposed, 'message': 'Browser port disposed'}));
    }
    _calls.clear();
  }

  /// Test hook: drops every session without closing it or deleting storage,
  /// as a process death would (the WebViews are destroyed, their profiles
  /// and data stay on disk). Later calls are refused.
  Future<void> debugAbandon() async {
    await _call('abandon', const <String, Object?>{});
    for (final AndroidWebViewBrowserSession s in _sessions.values.toList()) {
      s._abandon('Browser port abandoned');
    }
    _sessions.clear();
    _disposed = true;
    _native.dispose();
  }

  /// Diagnostics: open sessions, port-owned profiles, started Activities,
  /// refused proxy requests (replay mode).
  Future<Map<String, Object?>> debugState() async => (await _call('state', const <String, Object?>{})).payload;

  /// Runs the U12 `setProfile` timing probe in the app process.
  Future<Map<String, Object?>> debugProbeProfiles() async =>
      (await _call('probeProfile', const <String, Object?>{})).payload;

  /// Test hook: recreates the shown interaction Activity (configuration change).
  Future<bool> debugRecreateInteraction() async =>
      (await _call('recreateInteraction', const <String, Object?>{})).payload['recreated'] == true;

  /// Test hook: closes the shown interaction exactly as its close button does.
  Future<bool> debugCloseInteractionAsUser() async =>
      (await _call('closeInteraction', const <String, Object?>{})).payload['closed'] == true;

  static final Random _random = Random.secure();

  static String _randomHex() =>
      List<String>.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// One settle-once pending operation of a session.
final class _Op<T> {
  _Op(this.operation, {this.survivesBackground = false});

  final String operation;
  final bool survivesBackground;
  final Completer<BrowserOutcome<T>> _completer = Completer<BrowserOutcome<T>>();
  StreamSubscription<void>? _cancelSub;
  void Function()? onCancel;

  Future<BrowserOutcome<T>> get future => _completer.future;

  bool get isSettled => _completer.isCompleted;

  bool settle(BrowserOutcome<T> outcome) {
    if (_completer.isCompleted) return false;
    _completer.complete(outcome);
    unawaited(_cancelSub?.cancel());
    return true;
  }

  bool cancel(String reason) => settle(BrowserCancelled<T>(reason));

  bool needInteraction(String reason) => settle(BrowserInteractionRequired<T>(reason));
}

/// An app-process Android WebView session; see [AndroidWebViewBrowserPort].
final class AndroidWebViewBrowserSession implements BrowserSession {
  AndroidWebViewBrowserSession._(this._port, this.id, this._bridge, BrowserSessionRequest request, this.profile)
    : source = request.source,
      generation = request.generation;

  final AndroidWebViewBrowserPort _port;

  @override
  final String id;

  @override
  final SourceIdentity source;

  @override
  final int generation;

  /// The session's androidx.webkit profile, or `null` (shared default).
  final String? profile;

  /// The private engine message listener behind every channel object.
  final String _bridge;

  String? _closedReason;
  Future<BrowserOutcome<void>>? _closeFuture;
  final Set<_Op<Object?>> _pending = <_Op<Object?>>{};
  final Map<String, void Function(String message)> _channels = <String, void Function(String message)>{};
  final List<String> _pageStartScripts = <String>[];
  final Map<String, _Op<String>> _promises = <String, _Op<String>>{};
  _Op<BrowserPage>? _nav;
  _Op<void>? _interaction;

  /// Base URL of the current loadData document, or `null` after a loadUrl.
  Uri? _dataDocument;
  BrowserRequestObserver? _observer;
  int _nextEval = 1;

  @override
  BrowserCapabilities get capabilities => androidWebViewCapabilities;

  bool get isClosed => _closedReason != null;

  bool get isShowingInteraction => _interaction != null && !_interaction!.isSettled;

  /// Operations still waiting for the WebView (for disposal tests).
  int get pendingOperations => _pending.where((_Op<Object?> o) => !o.isSettled).length;

  bool get _fenced => generation < _port._validFrom;

  bool get _ignoreCallbacks => isClosed || _fenced;

  BrowserCancelled<T>? _dead<T>(CancellationToken? cancel) {
    final String? closed = _closedReason;
    if (closed != null) return BrowserCancelled<T>(closed);
    if (_fenced) return BrowserCancelled<T>('Generation $generation is fenced');
    if (cancel?.isCancelled ?? false) return BrowserCancelled<T>(cancel!.reason ?? 'cancelled');
    return null;
  }

  BrowserOutcome<T>? _refuseWork<T>(CancellationToken? cancel) =>
      _dead<T>(cancel) ?? (_port.isBackgrounded ? BrowserInteractionRequired<T>('The app is in the background') : null);

  _Op<T> _track<T>(String operation, CancellationToken? cancel, {bool survivesBackground = false}) {
    final op = _Op<T>(operation, survivesBackground: survivesBackground);
    _pending.add(op as _Op<Object?>);
    unawaited(op.future.whenComplete(() => _pending.remove(op)));
    if (cancel != null) {
      op._cancelSub = cancel.whenCancelled.asStream().listen((_) {
        if (op.cancel(cancel.reason ?? 'cancelled')) op.onCancel?.call();
      });
    }
    return op;
  }

  /// Sends [op] for this session and returns the reply, or `null` when the
  /// session closed or was fenced before it arrived (late reply discarded).
  Future<_Reply?> _send(String op, [Map<String, Object?> args = const <String, Object?>{}]) async {
    // Never outlives the session: a WebView call issued just before the
    // session closed may never be answered.
    final _Reply? r = await Future.any(<Future<_Reply?>>[
      _port._call(op, <String, Object?>{...args, 'session': id}),
      _closedSignal.future,
    ]);
    return r == null || _ignoreCallbacks ? null : r;
  }

  final Completer<_Reply?> _closedSignal = Completer<_Reply?>();

  BrowserOutcome<T> _failure<T>(_Reply r, String operation) => switch (r.code) {
    _Code.superseded || _Code.closed || _Code.disposed => BrowserCancelled<T>(r.message),
    _Code.interaction => BrowserInteractionRequired<T>(r.message),
    _Code.navigation => BrowserNavigationFailed<T>(Uri.tryParse(r.payload['url'] as String? ?? '') ?? Uri(), r.message),
    _ => BrowserCapabilityUnavailable<T>(operation, r.message),
  };

  // --- loads -----------------------------------------------------------------

  @override
  Future<BrowserOutcome<BrowserPage>> loadUrl(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    CancellationToken? cancel,
  }) async {
    final BrowserOutcome<BrowserPage>? refused = _refuseWork<BrowserPage>(cancel);
    if (refused != null) return refused;
    final BrowserCapabilityUnavailable<BrowserPage>? scheme = BrowserUrlPolicy.checkNavigation<BrowserPage>(
      url,
      'loadUrl',
    );
    if (scheme != null) return scheme;
    return _load('loadUrl', <String, Object?>{'url': url.toString(), 'headers': headers}, url, cancel);
  }

  @override
  Future<BrowserOutcome<BrowserPage>> loadData(String html, {required Uri baseUrl, CancellationToken? cancel}) async {
    final BrowserOutcome<BrowserPage>? refused = _refuseWork<BrowserPage>(cancel);
    if (refused != null) return refused;
    final BrowserCapabilityUnavailable<BrowserPage>? base = BrowserUrlPolicy.checkBaseUrl<BrowserPage>(
      baseUrl,
      'loadData',
    );
    if (base != null) return base;
    return _load('loadData', <String, Object?>{'baseUrl': baseUrl.toString(), 'html': html}, baseUrl, cancel);
  }

  Future<BrowserOutcome<BrowserPage>> _load(
    String op,
    Map<String, Object?> args,
    Uri requested,
    CancellationToken? cancel,
  ) {
    _nav?.cancel('Superseded by a new load');
    _dataDocument = op == 'loadData' ? requested : null;
    // The document is replaced: promise results of the old one never come.
    for (final _Op<String> p in _promises.values) {
      p.cancel('The document was replaced by a new load');
    }
    _promises.clear();
    final _Op<BrowserPage> nav = _nav = _track<BrowserPage>(op, cancel)..onCancel = () => unawaited(_send('stop'));
    unawaited(
      _send(op, args).then((_Reply? r) {
        if (r == null) return;
        if (!r.ok) {
          nav.settle(_failure<BrowserPage>(r, op));
          return;
        }
        final Uri finalUrl = Uri.tryParse(r.payload['url'] as String? ?? '') ?? requested;
        if (!BrowserUrlPolicy.isNavigable(finalUrl)) {
          nav.settle(BrowserCapabilityUnavailable<BrowserPage>(op, 'Ended on scheme "${finalUrl.scheme}"'));
          return;
        }
        nav.settle(
          BrowserCompleted<BrowserPage>(
            BrowserPage(
              // loadData documents report their base URL.
              finalUrl: op == 'loadData' ? requested : finalUrl,
              statusCode: (r.payload['status'] as num?)?.toInt(),
            ),
          ),
        );
      }),
    );
    return nav.future;
  }

  // --- scripts and channels ------------------------------------------------

  /// Wraps [script] so its completion value, a thrown error, or (for a
  /// thenable) a pending marker comes back through `evaluateJavascript`; a
  /// settled promise posts `{k: "e", id, ok | e}` on the private bridge
  /// (protocol 1.3 rule). An `EvalError` (a page CSP without
  /// `unsafe-eval`) reports `csp`, and the script then runs unwrapped.
  String _wrap(String script, String evalId) =>
      '''
(function () {
  var S = ${jsonEncode(script)}, B = ${jsonEncode(_bridge)}, I = ${jsonEncode(evalId)};
  function enc(v) { try { var j = JSON.stringify(v); return j === undefined ? 'null' : j; } catch (x) { return 'null'; } }
  function msg(e) {
    try { return (e !== null && typeof e === 'object' && 'message' in e) ? String(e.name) + ': ' + String(e.message) : String(e); }
    catch (x) { return 'The script threw a value that cannot be converted to a string'; }
  }
  var v;
  try { v = (0, eval)(S); }
  catch (e) { if (e instanceof EvalError) return {csp: msg(e)}; return {e: msg(e)}; }
  var thenable = false;
  try { thenable = v !== null && (typeof v === 'object' || typeof v === 'function') && typeof v.then === 'function'; } catch (x) {}
  if (!thenable) return {ok: enc(v)};
  var b = window[B];
  if (!b) return {e: 'A promise result cannot be awaited in this document'};
  try {
    v.then(function (r) { b.postMessage(JSON.stringify({k: 'e', id: I, ok: enc(r)})); },
           function (e) { b.postMessage(JSON.stringify({k: 'e', id: I, e: msg(e)})); });
  } catch (e) { return {e: msg(e)}; }
  return {p: 1};
})()''';

  @override
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel}) async {
    final BrowserOutcome<String>? refused = _refuseWork<String>(cancel);
    if (refused != null) return refused;
    final _Op<String> op = _track<String>('evaluate', cancel);
    final evalId = '${_bridge}e${_nextEval++}';
    // Registered before sending: a promise that settles at once posts its
    // result on the bridge before evaluateJavascript replies.
    _promises[evalId] = op;
    unawaited(op.future.whenComplete(() => _promises.remove(evalId)));
    unawaited(
      _send('evaluate', <String, Object?>{'script': _wrap(script, evalId)}).then((_Reply? r) async {
        if (r == null || op.isSettled) return;
        if (!r.ok) {
          op.settle(_failure<String>(r, 'evaluate'));
          return;
        }
        final Object? decoded = _decode(r.payload['value'] as String? ?? 'null');
        if (decoded is! Map<String, Object?>) {
          // The document went away mid-evaluation (Android reports null).
          op.settle(const BrowserCompleted<String>('null'));
          return;
        }
        if (decoded['e'] is String) {
          op.settle(BrowserScriptError<String>(decoded['e']! as String));
        } else if (decoded['ok'] is String) {
          op.settle(BrowserCompleted<String>(decoded['ok']! as String));
        } else if (decoded['p'] != null) {
          // Pending: the bridge settles it (or already did).
        } else if (decoded['csp'] != null) {
          _port._log('page CSP forbids eval; evaluating unwrapped (no promise awaiting, throws read as null)');
          final _Reply? raw = await _send('evaluate', <String, Object?>{'script': script});
          if (raw == null) return;
          op.settle(
            raw.ok
                ? BrowserCompleted<String>(raw.payload['value'] as String? ?? 'null')
                : _failure<String>(raw, 'evaluate'),
          );
        } else {
          op.settle(const BrowserCompleted<String>('null'));
        }
      }),
    );
    return op.future;
  }

  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  void _onBridge(Map<String, Object?> event) {
    if (_ignoreCallbacks) return;
    final Object? data = _decode(event['data'] as String? ?? '');
    if (data is! Map<String, Object?>) return;
    switch (data['k']) {
      case 'e':
        // Promise results only from the top frame's document.
        if (event['mainFrame'] != true) return;
        final _Op<String>? op = _promises.remove(data['id']);
        if (op == null) return;
        if (data['e'] is String) {
          op.settle(BrowserScriptError<String>(data['e']! as String));
        } else {
          op.settle(BrowserCompleted<String>(data['ok'] as String? ?? 'null'));
        }
      case 'm':
        final Object? channel = data['c'];
        final Object? text = data['m'];
        if (channel is! String || text is! String) return;
        final void Function(String)? handler = _channels[channel];
        if (handler == null) return;
        // WebView reports a loadData document's URL as `about:blank` (or its
        // `data:` URL); its origin is the base URL the session loaded it
        // with. The engine-attested frame origin is still checked against it.
        final String raw = event['document'] as String? ?? '';
        final Uri? document = _dataDocument != null && (raw.isEmpty || raw == 'about:blank' || raw.startsWith('data:'))
            ? _dataDocument
            : Uri.tryParse(raw);
        final Uri? origin = Uri.tryParse(event['origin'] as String? ?? '');
        if (document == null || origin == null) {
          _port._log('dropped a "$channel" message: unreadable document or frame origin');
          return;
        }
        if (!BrowserMessageChannel.accepts(documentUrl: document, frameOrigin: origin)) {
          _port._log('dropped a "$channel" message: frame origin $origin, document $document');
          return;
        }
        try {
          handler(text);
        } on Object catch (e) {
          _port._log('message handler for channel "$channel" threw: $e');
        }
    }
  }

  String _channelScript(Iterable<String> names) =>
      '''
(function () {
  var B = ${jsonEncode(_bridge)};
  ${jsonEncode(names.toList())}.forEach(function (n) {
    try {
      window[n] = Object.freeze({
        postMessage: function (m) {
          // Looked up per call: in loadData documents the engine installs the
          // bridge after document-start scripts run.
          var b = window[B];
          if (b && typeof m === 'string') b.postMessage(JSON.stringify({k: 'm', c: n, m: m}));
        }
      });
    } catch (e) {}
  });
})();
void 0;''';

  /// Rebuilds the document-start scripts: channel objects first, then
  /// page-start scripts in registration order (protocol 1.2).
  Future<void> _rebuildStartScripts() => _send('setStartScripts', <String, Object?>{
    'scripts': <String>[if (_channels.isNotEmpty) _channelScript(_channels.keys), ..._pageStartScripts],
  });

  Future<void> _runInCurrentDocument(String script) => _send('evaluate', <String, Object?>{'script': script});

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
      await _rebuildStartScripts();
      await _runInCurrentDocument('try { delete window[${jsonEncode(name)}]; } catch (e) {} void 0;');
    } else {
      _channels[name] = handler;
      if (!existed) {
        await _rebuildStartScripts();
        await _runInCurrentDocument(_channelScript(<String>[name]));
      }
    }
    return _dead<void>(null) ?? const BrowserCompleted<void>(null);
  }

  @override
  Future<BrowserOutcome<void>> addPageStartScript(String script) async {
    final BrowserCancelled<void>? dead = _dead<void>(null);
    if (dead != null) return dead;
    _pageStartScripts.add(script);
    await _rebuildStartScripts();
    return _dead<void>(null) ?? const BrowserCompleted<void>(null);
  }

  // --- interception ----------------------------------------------------------

  @override
  Future<BrowserOutcome<void>> setRequestObserver(BrowserRequestObserver? observer) async {
    final BrowserCancelled<void>? dead = _dead<void>(null);
    if (dead != null) return dead;
    _observer = observer;
    await _send('setObserver', <String, Object?>{'enabled': observer != null});
    return _dead<void>(null) ?? const BrowserCompleted<void>(null);
  }

  void _onRequest(Map<String, Object?> event) {
    final BrowserRequestObserver? observer = _observer;
    if (observer == null || _ignoreCallbacks) return;
    final Uri? url = Uri.tryParse(event['url'] as String? ?? '');
    if (url == null || !BrowserUrlPolicy.isAllowedBaseUrl(url)) return;
    final String method = event['method'] as String? ?? 'GET';
    try {
      observer(
        BrowserRequest(
          url: url,
          method: method,
          headers: <String, String>{
            for (final MapEntry<String, Object?> h
                in ((event['headers'] as Map<String, Object?>?) ?? const <String, Object?>{}).entries)
              h.key: '${h.value}',
          },
          // WebResourceRequest has no body: a request that may carry one is
          // marked omitted, so replay treats it as a miss.
          bodyOmitted: method != 'GET' && method != 'HEAD',
          mainFrame: event['mainFrame'] == true,
          redirect: event['redirect'] == true,
          context: event['mainFrame'] == true ? BrowserRequestContext.document : BrowserRequestContext.other,
        ),
      );
    } on Object catch (e) {
      _port._log('request observer threw: $e');
    }
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
    if (!BrowserUrlPolicy.isAllowedBaseUrl(url)) {
      return BrowserCapabilityUnavailable<List<BrowserCookie>>(
        'getCookies',
        'Cookie URL scheme "${url.scheme}" is not http(s)',
      );
    }
    final _Op<List<BrowserCookie>> op = _track<List<BrowserCookie>>('getCookies', cancel, survivesBackground: true);
    unawaited(
      _send('getCookies', <String, Object?>{'url': url.toString()}).then((_Reply? r) {
        if (r == null) {
          op.settle(BrowserCancelled<List<BrowserCookie>>(_closedReason ?? 'Generation $generation is fenced'));
          return;
        }
        if (!r.ok) {
          op.settle(_failure<List<BrowserCookie>>(r, 'getCookies'));
          return;
        }
        // CookieManager.getCookie reports name=value pairs only.
        op.settle(
          BrowserCompleted<List<BrowserCookie>>(<BrowserCookie>[
            for (final Object? c in r.payload['cookies'] as List<Object?>? ?? const <Object?>[])
              if (c case {'name': final String name, 'value': final String value})
                BrowserCookie(name: name, value: value),
          ]),
        );
      }),
    );
    return op.future;
  }

  @override
  Future<BrowserOutcome<void>> setCookie(Uri url, BrowserCookie cookie, {CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead<void>(cancel);
    if (dead != null) return dead;
    if (!BrowserUrlPolicy.isAllowedBaseUrl(url)) {
      return BrowserCapabilityUnavailable<void>('setCookie', 'Cookie URL scheme "${url.scheme}" is not http(s)');
    }
    if (RegExp(r'[;\r\n]').hasMatch(cookie.name) || RegExp(r'[;\r\n]').hasMatch(cookie.value)) {
      return const BrowserCapabilityUnavailable<void>('setCookie', 'Cookie name or value contains ";" or a line break');
    }
    final DateTime? expires = cookie.expires;
    final String header = <String>[
      '${cookie.name}=${cookie.value}',
      if (cookie.domain != null) 'Domain=${cookie.domain}',
      'Path=${cookie.path ?? '/'}',
      if (expires != null) 'Expires=${HttpDate.format(expires)}',
      if (cookie.secure) 'Secure',
      if (cookie.httpOnly) 'HttpOnly',
    ].join('; ');
    final _Op<void> op = _track<void>('setCookie', cancel, survivesBackground: true);
    unawaited(
      _send('setCookie', <String, Object?>{'url': url.toString(), 'header': header}).then((_Reply? r) {
        if (r == null) {
          op.settle(BrowserCancelled<void>(_closedReason ?? 'Generation $generation is fenced'));
        } else {
          op.settle(r.ok ? const BrowserCompleted<void>(null) : _failure<void>(r, 'setCookie'));
        }
      }),
    );
    return op.future;
  }

  @override
  Future<BrowserOutcome<void>> setUserAgent(String userAgent, {CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead<void>(cancel);
    if (dead != null) return dead;
    final _Reply? r = await _send('setUserAgent', <String, Object?>{'userAgent': userAgent});
    if (r == null) return BrowserCancelled<void>(_closedReason ?? 'Generation $generation is fenced');
    return r.ok ? const BrowserCompleted<void>(null) : _failure<void>(r, 'setUserAgent');
  }

  // --- interaction -------------------------------------------------------

  @override
  Future<BrowserOutcome<void>> showForInteraction({required Duration timeout, CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead<void>(cancel);
    if (dead != null) return dead;
    if (!_port.config.allowInteraction) {
      return const BrowserInteractionRequired<void>('Visible browser interaction is disabled for this run');
    }
    if (_port.isBackgrounded) return const BrowserInteractionRequired<void>('The app is in the background');
    if (isShowingInteraction) {
      return const BrowserCapabilityUnavailable<void>('showForInteraction', 'An interaction is already showing');
    }
    final _Op<void> op = _interaction = _track<void>('showForInteraction', cancel, survivesBackground: true)
      ..onCancel = () => unawaited(_send('hide'));
    final timer = Timer(timeout, () {
      if (op.settle(BrowserInteractionRequired<void>('Interaction timed out after $timeout'))) unawaited(_send('hide'));
    });
    unawaited(op.future.whenComplete(timer.cancel));
    unawaited(
      _send('show').then((_Reply? r) {
        if (r == null) {
          op.settle(BrowserCancelled<void>(_closedReason ?? 'Generation $generation is fenced'));
          return;
        }
        if (!r.ok) {
          op.settle(_failure<void>(r, 'showForInteraction'));
          return;
        }
        // `hidden` means the port ended it (timeout, cancel, close), which
        // already settled the call; `closed` is the user.
        op.settle(
          r.payload['end'] == 'closed'
              ? const BrowserCompleted<void>(null)
              : const BrowserCancelled<void>('The interaction was hidden'),
        );
      }),
    );
    return op.future;
  }

  // --- lifetime ---------------------------------------------------------

  void _enterBackground() {
    if (isClosed) return;
    var stopped = false;
    for (final _Op<Object?> op in _pending.toList()) {
      if (op.survivesBackground) continue;
      if (op.needInteraction('The app entered the background') && !stopped) {
        stopped = true;
        unawaited(_send('stop'));
      }
    }
  }

  void _settleAll(String reason) {
    if (!_closedSignal.isCompleted) _closedSignal.complete(null);
    for (final _Op<Object?> op in _pending.toList()) {
      op.cancel(reason);
    }
    _promises.clear();
    _observer = null;
    _channels.clear();
  }

  @override
  Future<BrowserOutcome<void>> close() => _closeWith('Session closed');

  Future<BrowserOutcome<void>> _closeWith(String reason) => _closeFuture ??= () async {
    _closedReason ??= reason;
    _settleAll(reason);
    final _Reply r = await _port._call('close', <String, Object?>{'session': id});
    _port._sessions.remove(id);
    if (r.ok) return const BrowserCompleted<void>(null);
    if (r.code == _Code.disposed) {
      return const BrowserCapabilityUnavailable<void>('close', 'Port disposed before deletion was confirmed');
    }
    return BrowserCapabilityUnavailable<void>(
      'close',
      r.code == _Code.unconfirmed ? r.message : '${r.code}: ${r.message}',
    );
  }();

  void _abandon(String reason) {
    _closedReason ??= reason;
    _settleAll(reason);
  }

  @override
  String toString() => 'AndroidWebViewBrowserSession($id, ${source.sourceId}, generation $generation)';
}
