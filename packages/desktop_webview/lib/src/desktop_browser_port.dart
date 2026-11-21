import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview/src/helper_process.dart';
import 'package:meta/meta.dart';
import 'package:source_runtime/source_contracts.dart';

/// Configuration of a [DesktopBrowserPort]. Every time bound is supplied by
/// the caller (KTD25); none has a default.
@immutable
final class DesktopWebViewConfig {
  const DesktopWebViewConfig({
    required this.helperExecutable,
    required this.dataRoot,
    required this.startupTimeout,
    required this.shutdownGrace,
    this.allowVisibleWindows = true,
    this.offline = false,
    this.testHooks = false,
    this.launcher,
    this.onLog,
    this.extraArguments = const <String>[],
    this.wipeRetry,
  });

  /// The verified helper binary (see `RuntimeArtifactManifest`).
  final File helperExecutable;

  /// Parent of the helper's per-process data directories; stale ones are
  /// wiped when a helper starts (KTD20).
  final Directory dataRoot;

  /// How long a starting helper may take to report ready.
  final Duration startupTimeout;

  /// How long a helper may take to exit after `shutdown` before it is killed.
  final Duration shutdownGrace;

  /// When false (unattended runs), [BrowserSession.showForInteraction]
  /// returns [BrowserInteractionRequired] without opening a window.
  final bool allowVisibleWindows;

  /// Replay mode: the helper blocks every non-loopback request that a
  /// request handler does not answer, so a test can never reach a server.
  final bool offline;

  /// Enables helper test operations (`debugRequestClose`).
  final bool testHooks;

  final HelperLauncher? launcher;

  /// Receives helper stderr lines; pass a redacting sink (KTD9).
  final void Function(String line)? onLog;

  /// Appended to the helper's arguments (tests).
  final List<String> extraArguments;

  /// How long [DesktopBrowserPort.wipeAllSourceData] keeps retrying a stale
  /// data directory that is still in use (a dead helper's browser processes
  /// releasing files), or `null` for a single attempt. The helper's own
  /// start-up wipe always makes a single attempt.
  final Duration? wipeRetry;
}

/// The helper's JSON for a replacement (`respond` command).
Map<String, Object?> _replacementJson(BrowserReplacement r) => <String, Object?>{
  'status': r.status,
  'reason': r.reason,
  'headers': r.headers,
  'bodyBase64': base64Encode(r.body),
};

/// Settles exactly once; later results (late callbacks) are ignored.
final class _Settle<T> {
  final Completer<BrowserOutcome<T>> _c = Completer<BrowserOutcome<T>>();

  Future<BrowserOutcome<T>> get future => _c.future;

  bool get isSettled => _c.isCompleted;

  bool settle(BrowserOutcome<T> outcome) {
    if (_c.isCompleted) return false;
    _c.complete(outcome);
    return true;
  }
}

/// `BrowserPort` over one `desktop_webview_helper` process (KTD20).
///
/// One port (and so one helper process) serves one conversion; each source
/// session is a separate WebView with its own ephemeral store. The helper is
/// started on first use; if it dies, open sessions resolve as cancelled and
/// the next [openSession] starts a fresh helper, whose start-up wipe removes
/// anything the dead one left behind.
class DesktopBrowserPort implements BrowserPort {
  DesktopBrowserPort(this.config);

  final DesktopWebViewConfig config;

  Future<HelperStart>? _starting;
  HelperProcess? _helper;
  final Map<String, DesktopBrowserSession> _sessions = <String, DesktopBrowserSession>{};
  final List<SourceIdentity> _opened = <SourceIdentity>[];
  int _validFrom = 0;
  int _nextSession = 0;
  bool _disposed = false;

  /// Info from the running helper's `ready` event, if one is running.
  HelperInfo? get helperInfo => _helper?.info;

  List<String> get _arguments => <String>[
    '--data-root',
    config.dataRoot.path,
    if (config.offline) '--offline',
    if (config.testHooks) '--test-hooks',
    ...config.extraArguments,
  ];

  /// Starts the helper if it is not running. Returns the failure outcome
  /// (typed for [operation]) when it cannot run.
  Future<(HelperProcess?, BrowserOutcome<T>?)> _ensureHelper<T>(String operation) async {
    final HelperProcess? running = _helper;
    if (running != null && running.isAlive) return (running, null);
    final Future<HelperStart> starting = _starting ??= HelperProcess.start(
      executable: config.helperExecutable.path,
      arguments: _arguments,
      startupTimeout: config.startupTimeout,
      launcher: config.launcher,
      onLog: config.onLog,
    );
    final HelperStart started = await starting;
    if (identical(_starting, starting)) _starting = null;
    switch (started) {
      case HelperStarted(:final HelperProcess process):
        if (!identical(_helper, process)) {
          _helper = process;
          process.events.listen(_onEvent);
          unawaited(process.gone.then((String reason) => _onHelperGone(process, reason)));
        }
        return (process, null);
      case HelperFatal(:final String code, :final String message):
        return (null, BrowserCapabilityUnavailable<T>(operation, 'Browser helper cannot run ($code): $message'));
      case HelperLaunchFailed(:final String message):
        return (null, BrowserCapabilityUnavailable<T>(operation, 'Browser helper failed to start: $message'));
    }
  }

  void _onEvent(Map<String, Object?> event) {
    final id = event['session'] as String?;
    final DesktopBrowserSession? session = id == null ? null : _sessions[id];
    session?._onEvent(event);
  }

  void _onHelperGone(HelperProcess process, String reason) {
    if (!identical(_helper, process)) return;
    _helper = null;
    final dead = <DesktopBrowserSession>[
      for (final DesktopBrowserSession s in _sessions.values)
        if (identical(s._helper, process)) s,
    ];
    for (final s in dead) {
      _sessions.remove(s.id);
      s._terminate('browser helper exited: $reason', helperDied: true);
    }
  }

  @override
  Future<BrowserOutcome<void>> wipeAllSourceData() async {
    final (HelperProcess? helper, BrowserOutcome<void>? failed) = await _ensureHelper<void>('wipeAllSourceData');
    if (helper == null) return failed!;
    return switch (await helper.request('wipe', <String, Object?>{
      if (config.wipeRetry != null) 'retryMs': config.wipeRetry!.inMilliseconds,
    })) {
      HelperOk() => const BrowserCompleted<void>(null),
      HelperError(:final String message) => BrowserCapabilityUnavailable<void>('wipeAllSourceData', message),
      HelperGone(:final String reason) => BrowserCancelled<void>(reason),
    };
  }

  @override
  Future<BrowserOutcome<BrowserSession>> openSession(BrowserSessionRequest request, {CancellationToken? cancel}) async {
    if (_disposed) return const BrowserCancelled<BrowserSession>('Browser port disposed');
    if (request.generation < _validFrom) {
      return BrowserCancelled<BrowserSession>('Generation ${request.generation} is fenced');
    }
    if (cancel?.isCancelled ?? false) return BrowserCancelled<BrowserSession>(cancel!.reason ?? 'cancelled');
    final (HelperProcess? helper, BrowserOutcome<BrowserSession>? failed) = await _ensureHelper<BrowserSession>(
      'openSession',
    );
    if (helper == null) return failed!;
    final id = 's${++_nextSession}';
    final HelperReply reply = await helper.request('open', <String, Object?>{
      'session': id,
      'userAgent': ?request.userAgent,
      'title': 'Source browser: ${request.source.sourceId}',
    });
    switch (reply) {
      case HelperOk():
        final session = DesktopBrowserSession._(this, helper, id, request.source, request.generation);
        if (request.generation < _validFrom || (cancel?.isCancelled ?? false) || _disposed) {
          // Fenced or cancelled while the WebView was being created.
          unawaited(helper.request('close', <String, Object?>{'session': id}));
          return BrowserCancelled<BrowserSession>(cancel?.reason ?? 'Generation ${request.generation} is fenced');
        }
        _sessions[id] = session;
        _opened.add(request.source);
        return BrowserCompleted<BrowserSession>(session);
      case HelperError(:final String code, :final String message, :final String? operation):
        return switch (code) {
          'interaction-required' => BrowserInteractionRequired<BrowserSession>(message),
          // The helper is shutting down (port disposal) or the open was dropped.
          'cancelled' || 'session-closed' => BrowserCancelled<BrowserSession>(message),
          _ => BrowserCapabilityUnavailable<BrowserSession>(operation ?? 'openSession', message),
        };
      case HelperGone(:final String reason):
        return BrowserCancelled<BrowserSession>(reason);
    }
  }

  @override
  Future<void> fence(int generation) async {
    if (generation > _validFrom) _validFrom = generation;
    final stale = <DesktopBrowserSession>[
      for (final DesktopBrowserSession s in _sessions.values)
        if (s.generation < _validFrom) s,
    ];
    await Future.wait(<Future<void>>[
      for (final DesktopBrowserSession s in stale) s._fence('Generation ${s.generation} is fenced'),
    ]);
  }

  /// Closes every session and shuts the helper down (conversion end). An
  /// unresponsive helper is killed once [DesktopWebViewConfig.shutdownGrace]
  /// has passed, whether it hangs in a session close or in shutdown.
  Future<void> dispose() async {
    _disposed = true;
    final HelperProcess? helper = _helper;
    final List<DesktopBrowserSession> open = _sessions.values.toList();
    final bool closed = await Future.wait(<Future<void>>[for (final DesktopBrowserSession s in open) s.close()])
        .then((_) => true)
        .timeout(config.shutdownGrace, onTimeout: () => false);
    _helper = null;
    if (helper == null) return;
    if (closed) {
      await helper.shutdown(grace: config.shutdownGrace);
    } else {
      config.onLog?.call('[desktop_webview] sessions did not close within ${config.shutdownGrace}; killing the helper');
      await helper.kill();
    }
  }

  /// Kills the helper without closing sessions (crash simulation).
  @visibleForTesting
  Future<void> debugKillHelper() async => _helper?.kill();

  /// The running helper, for tests that speak to it directly.
  @visibleForTesting
  HelperProcess? get debugHelper => _helper;

  /// The source of every session this port opened, in order.
  @visibleForTesting
  List<SourceIdentity> get debugOpenedSources => List<SourceIdentity>.unmodifiable(_opened);

  /// Number of sessions currently open.
  @visibleForTesting
  int get debugOpenSessions => _sessions.length;

  /// Open sessions whose interaction window is shown (or being shown).
  @visibleForTesting
  Iterable<DesktopBrowserSession> get debugShowingSessions =>
      _sessions.values.where((DesktopBrowserSession s) => s.isShowing);
}

/// One source-scoped WebView session in the helper.
class DesktopBrowserSession implements BrowserSession {
  DesktopBrowserSession._(this._port, this._helper, this.id, this.source, this.generation)
    : capabilities = _helper.info.capabilities.browser;

  final DesktopBrowserPort _port;
  final HelperProcess _helper;

  @override
  final String id;

  @override
  final SourceIdentity source;

  @override
  final int generation;

  @override
  final BrowserCapabilities capabilities;

  /// Cancels each pending operation with a reason.
  final Set<void Function(String reason)> _pending = <void Function(String reason)>{};
  final Map<String, void Function(String message)> _handlers = <String, void Function(String message)>{};
  BrowserRequestObserver? _observer;
  BrowserRequestReplacer? _replacer;
  _Settle<void>? _interaction;
  String? _closedReason;
  BrowserOutcome<void>? _closeAfterCrash;

  bool get isClosed => _closedReason != null;

  /// Whether a [showForInteraction] call is in progress.
  bool get isShowing => !isClosed && _interaction != null && !_interaction!.isSettled;

  BrowserCancelled<T>? _dead<T>(CancellationToken? cancel) {
    final String? closed = _closedReason;
    if (closed != null) return BrowserCancelled<T>(closed);
    if (generation < _port._validFrom) return BrowserCancelled<T>('Generation $generation is fenced');
    if (cancel?.isCancelled ?? false) return BrowserCancelled<T>(cancel!.reason ?? 'cancelled');
    return null;
  }

  Future<BrowserOutcome<T>> _call<T>(
    String op,
    Map<String, Object?> params,
    CancellationToken? cancel,
    BrowserOutcome<T> Function(Map<String, Object?> ok) onOk, {
    String? operation,
    void Function()? onCancelled,
  }) async {
    final BrowserCancelled<T>? dead = _dead<T>(cancel);
    if (dead != null) return dead;
    final settle = _Settle<T>();
    void cancelPending(String reason) => settle.settle(BrowserCancelled<T>(reason));
    _pending.add(cancelPending);
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (settle.settle(BrowserCancelled<T>(cancel.reason ?? 'cancelled'))) onCancelled?.call();
        }),
      );
    }
    unawaited(
      _helper.request(op, <String, Object?>{...params, 'session': id}).then((HelperReply reply) {
        settle.settle(_map<T>(reply, onOk, operation ?? op));
      }),
    );
    try {
      return await settle.future;
    } finally {
      _pending.remove(cancelPending);
    }
  }

  BrowserOutcome<T> _map<T>(HelperReply reply, BrowserOutcome<T> Function(Map<String, Object?>) onOk, String op) =>
      switch (reply) {
        HelperOk(:final Map<String, Object?> value) => onOk(value),
        HelperError(code: 'capability-unavailable', :final String message, :final String? operation) =>
          BrowserCapabilityUnavailable<T>(operation ?? op, message),
        HelperError(code: 'navigation-failed', :final String message, :final String? url) => BrowserNavigationFailed<T>(
          Uri.tryParse(url ?? '') ?? Uri(),
          message,
        ),
        HelperError(code: 'interaction-required', :final String message) => BrowserInteractionRequired<T>(message),
        HelperError(code: 'cancelled' || 'session-closed', :final String message) => BrowserCancelled<T>(message),
        HelperError(:final String code, :final String message) => BrowserCapabilityUnavailable<T>(
          op,
          '$code: $message',
        ),
        HelperGone(:final String reason) => BrowserCancelled<T>(reason),
      };

  static BrowserOutcome<BrowserPage> _page(Map<String, Object?> ok) => BrowserCompleted<BrowserPage>(
    BrowserPage(finalUrl: Uri.parse(ok['finalUrl']! as String), statusCode: ok['status'] as int?),
  );

  static BrowserOutcome<void> _done(Map<String, Object?> _) => const BrowserCompleted<void>(null);

  @override
  Future<BrowserOutcome<BrowserPage>> loadUrl(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    CancellationToken? cancel,
  }) async {
    final BrowserCapabilityUnavailable<BrowserPage>? refused = BrowserUrlPolicy.checkNavigation<BrowserPage>(
      url,
      'loadUrl',
    );
    if (refused != null) return _dead<BrowserPage>(cancel) ?? refused;
    return _call<BrowserPage>(
      'load',
      <String, Object?>{'url': url.toString(), if (headers.isNotEmpty) 'headers': headers},
      cancel,
      _page,
      operation: 'loadUrl',
      onCancelled: _stop,
    );
  }

  @override
  Future<BrowserOutcome<BrowserPage>> loadData(String html, {required Uri baseUrl, CancellationToken? cancel}) async {
    final BrowserCapabilityUnavailable<BrowserPage>? refused = BrowserUrlPolicy.checkBaseUrl<BrowserPage>(
      baseUrl,
      'loadData',
    );
    if (refused != null) return _dead<BrowserPage>(cancel) ?? refused;
    return _call<BrowserPage>(
      'loadData',
      <String, Object?>{'html': html, 'baseUrl': baseUrl.toString()},
      cancel,
      _page,
      onCancelled: _stop,
    );
  }

  void _stop() => unawaited(_helper.request('stop', <String, Object?>{'session': id}));

  /// Evaluates [script]; a promise result is awaited.
  ///
  /// A script that throws (or a rejected promise) is the helper's
  /// `script-error`: [BrowserScriptError] when [capabilities] support
  /// [BrowserFeature.scriptErrors], otherwise `null` as Android's
  /// `evaluateJavascript` gives. The helper's other non-results complete with
  /// `null` too, and are logged: `no-script-bridge` (no document with the
  /// page bridge, e.g. the initial `about:blank`) and `navigated` (the page
  /// navigated away before the script completed).
  @override
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel}) async {
    final BrowserCancelled<String>? dead = _dead<String>(cancel);
    if (dead != null) return dead;
    final settle = _Settle<String>();
    void cancelPending(String reason) => settle.settle(BrowserCancelled<String>(reason));
    _pending.add(cancelPending);
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) => settle.settle(BrowserCancelled<String>(cancel.reason ?? 'cancelled'))),
      );
    }
    unawaited(
      _helper.request('eval', <String, Object?>{'session': id, 'script': script}).then((HelperReply reply) {
        if (reply case HelperError(
          code: final String code && ('script-error' || 'no-script-bridge' || 'navigated'),
          :final message,
        )) {
          _port.config.onLog?.call('[desktop_webview] $code in session $id: $message');
          settle.settle(
            code == 'script-error' && capabilities.supports(BrowserFeature.scriptErrors)
                ? BrowserScriptError<String>(message)
                : const BrowserCompleted<String>('null'),
          );
          return;
        }
        settle.settle(
          _map<String>(
            reply,
            (Map<String, Object?> ok) => BrowserCompleted<String>(ok['result']! as String),
            'evaluate',
          ),
        );
      }),
    );
    try {
      return await settle.future;
    } finally {
      _pending.remove(cancelPending);
    }
  }

  @override
  Future<BrowserOutcome<void>> setMessageHandler(String name, void Function(String message)? handler) async {
    final BrowserCancelled<void>? dead = _dead<void>(null);
    if (dead != null) return dead;
    // Any identifier, `ipc` included (protocol 1.2 reserves none).
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name)) {
      return BrowserCapabilityUnavailable<void>('setMessageHandler', 'Channel name "$name" is not a usable identifier');
    }
    final BrowserOutcome<void> outcome = await _call<void>(
      'channel',
      <String, Object?>{'name': name, 'enabled': handler != null},
      null,
      _done,
      operation: 'setMessageHandler',
    );
    if (outcome is BrowserCompleted<void>) {
      if (handler == null) {
        _handlers.remove(name);
      } else {
        _handlers[name] = handler;
      }
    }
    return outcome;
  }

  @override
  Future<BrowserOutcome<List<BrowserCookie>>> getCookies(Uri url, {CancellationToken? cancel}) async {
    final BrowserCapabilityUnavailable<List<BrowserCookie>>? refused =
        BrowserUrlPolicy.checkBaseUrl<List<BrowserCookie>>(
          url,
          'getCookies',
        );
    if (refused != null) return _dead<List<BrowserCookie>>(cancel) ?? refused;
    return _call<List<BrowserCookie>>('cookies', <String, Object?>{'url': url.toString()}, cancel, (
      Map<String, Object?> ok,
    ) {
      final cookies = <BrowserCookie>[
        for (final Object? c in ok['cookies']! as List<Object?>) _cookieFromHelper(c! as Map<String, Object?>),
      ];
      return BrowserCompleted<List<BrowserCookie>>(cookies);
    }, operation: 'getCookies');
  }

  static BrowserCookie _cookieFromHelper(Map<String, Object?> c) => BrowserCookie(
    name: c['name']! as String,
    value: c['value']! as String,
    domain: c['domain'] as String?,
    path: c['path'] as String?,
    expires: c['expiresUnix'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((c['expiresUnix']! as int) * 1000, isUtc: true),
    secure: c['secure'] as bool? ?? false,
    httpOnly: c['httpOnly'] as bool? ?? false,
  );

  @override
  Future<BrowserOutcome<void>> setCookie(Uri url, BrowserCookie cookie, {CancellationToken? cancel}) async {
    final BrowserCapabilityUnavailable<void>? refused = BrowserUrlPolicy.checkBaseUrl<void>(url, 'setCookie');
    if (refused != null) return _dead<void>(cancel) ?? refused;
    return _call<void>(
      'setCookie',
      <String, Object?>{
        'url': url.toString(),
        'cookie': <String, Object?>{
          'name': cookie.name,
          'value': cookie.value,
          'domain': ?cookie.domain,
          'path': ?cookie.path,
          if (cookie.expires != null) 'expiresUnix': cookie.expires!.toUtc().millisecondsSinceEpoch ~/ 1000,
          'secure': cookie.secure,
          'httpOnly': cookie.httpOnly,
        },
      },
      cancel,
      _done,
    );
  }

  @override
  Future<BrowserOutcome<void>> setUserAgent(String userAgent, {CancellationToken? cancel}) =>
      _call<void>('userAgent', <String, Object?>{'userAgent': userAgent}, cancel, _done, operation: 'setUserAgent');

  /// Shows the session's window until the user closes it (completed), the
  /// [timeout] expires (interaction-required; the window is hidden), the
  /// caller cancels, or the session closes (cancelled). Other operations keep
  /// working meanwhile, and none of this time counts against their deadlines.
  @override
  Future<BrowserOutcome<void>> showForInteraction({required Duration timeout, CancellationToken? cancel}) async {
    final BrowserCancelled<void>? dead = _dead<void>(cancel);
    if (dead != null) return dead;
    if (!_port.config.allowVisibleWindows) {
      return const BrowserInteractionRequired<void>('Visible browser windows are disabled for this run');
    }
    if (_interaction != null && !_interaction!.isSettled) {
      return const BrowserCapabilityUnavailable<void>('showForInteraction', 'An interaction is already showing');
    }
    final _Settle<void> interaction = _interaction = _Settle<void>();
    final HelperReply shown = await _helper.request('show', <String, Object?>{'session': id});
    if (shown is! HelperOk) {
      interaction.settle(_map<void>(shown, _done, 'showForInteraction'));
      return interaction.future;
    }
    final timer = Timer(timeout, () {
      if (interaction.settle(BrowserInteractionRequired<void>('Interaction timed out after $timeout'))) _hide();
    });
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (interaction.settle(BrowserCancelled<void>(cancel.reason ?? 'cancelled'))) _hide();
        }),
      );
    }
    try {
      return await interaction.future;
    } finally {
      timer.cancel();
    }
  }

  void _hide() {
    if (!isClosed) unawaited(_helper.request('hide', <String, Object?>{'session': id}));
  }

  @override
  Future<BrowserOutcome<void>> addPageStartScript(String script) async =>
      _dead<void>(null) ??
      capabilities.check<void>(BrowserFeature.pageStartScripts, 'addPageStartScript') ??
      await _call<void>(
        'startScript',
        <String, Object?>{'script': script},
        null,
        _done,
        operation: 'addPageStartScript',
      );

  /// Observe tier: reports every request the page makes, with its request
  /// headers (including `sec-ch-ua*` on WebView2) and, where the engine
  /// exposes it, its body (up to 1 MiB; otherwise
  /// [BrowserRequest.bodyOmitted]); requests proceed unchanged. Pass `null`
  /// to stop.
  @override
  Future<BrowserOutcome<void>> setRequestObserver(BrowserRequestObserver? observer) async {
    final BrowserOutcome<void> outcome = await _intercept(
      observer == null ? 'none' : 'observe',
      'setRequestObserver',
      available: capabilities.interceptionTier != BrowserInterceptionTier.none,
      feature: BrowserFeature.observeNavigations,
    );
    if (outcome is BrowserCompleted<void>) {
      _observer = observer;
      _replacer = null;
    }
    return outcome;
  }

  /// Replace tier (WebView2 only): holds every request until [replacer]
  /// answers. Elsewhere this is [BrowserCapabilityUnavailable].
  ///
  /// An invalid replacement ([BrowserReplacement.invalidReason]) or a
  /// throwing replacer fails the request (helper `respond` with `fail`): the
  /// page sees a network error.
  @override
  Future<BrowserOutcome<void>> setRequestReplacer(BrowserRequestReplacer? replacer) async {
    final BrowserOutcome<void> outcome = await _intercept(
      replacer == null ? 'none' : 'replace',
      'setRequestReplacer',
      available: capabilities.supports(BrowserFeature.replaceRequests),
      feature: BrowserFeature.replaceRequests,
    );
    if (outcome is BrowserCompleted<void>) {
      _replacer = replacer;
      _observer = null;
    }
    return outcome;
  }

  /// Sets the helper's interception [mode] for [operation]. When the tier is
  /// not [available], enabling it is refused and removal (`none`) completes
  /// without asking the helper.
  Future<BrowserOutcome<void>> _intercept(
    String mode,
    String operation, {
    required bool available,
    required BrowserFeature feature,
  }) async {
    final BrowserCancelled<void>? dead = _dead<void>(null);
    if (dead != null) return dead;
    if (!available) {
      return mode == 'none' ? const BrowserCompleted<void>(null) : capabilities.check<void>(feature, operation)!;
    }
    return switch (await _call<void>('intercept', <String, Object?>{'mode': mode}, null, _done, operation: operation)) {
      // Report the contract operation, not the helper's internal name.
      BrowserCapabilityUnavailable<void>(:final String reason) => BrowserCapabilityUnavailable<void>(operation, reason),
      final BrowserOutcome<void> other => other,
    };
  }

  // --- Desktop extensions beyond the BrowserPort contract -----------------

  /// Hides a shown window without ending the session.
  Future<BrowserOutcome<void>> hide() => _call<void>('hide', const <String, Object?>{}, null, _done);

  /// Asks the helper to act as if the user closed the window (needs
  /// [DesktopWebViewConfig.testHooks]).
  @visibleForTesting
  Future<BrowserOutcome<void>> debugRequestClose() =>
      _call<void>('debugRequestClose', const <String, Object?>{}, null, _done);

  // --- events and lifetime -------------------------------------------------

  void _onEvent(Map<String, Object?> event) {
    if (isClosed || generation < _port._validFrom) return;
    switch (event['ev']) {
      case 'message':
        _handlers[event['name']]?.call(event['message']! as String);
      case 'interactionEnded':
        final String reason = event['reason'] as String? ?? 'closed';
        _interaction?.settle(
          reason == 'closed'
              ? const BrowserCompleted<void>(null)
              : BrowserCancelled<void>('Interaction ended: $reason'),
        );
      case 'request':
        final Object? rid = event['rid'];
        final Uri? url = Uri.tryParse(event['url'] as String? ?? '');
        if (url == null || !BrowserUrlPolicy.isAllowedBaseUrl(url)) {
          // Only http(s) requests are reported; a held one still proceeds.
          if (rid is int) unawaited(_helper.request('respond', <String, Object?>{'rid': rid, 'response': null}));
          return;
        }
        final bodyBase64 = event['bodyBase64'] as String?;
        final request = BrowserRequest(
          url: url,
          method: event['method'] as String? ?? 'GET',
          headers: <String, String>{
            for (final MapEntry<String, Object?> h in (event['headers'] as Map<String, Object?>? ?? const {}).entries)
              h.key: h.value! as String,
          },
          body: bodyBase64 == null ? null : base64Decode(bodyBase64),
          bodyOmitted: event['bodyOmitted'] as bool? ?? false,
          mainFrame: event['mainFrame'] as bool? ?? false,
          redirect: event['redirect'] as bool? ?? false,
          context: BrowserRequestContext.fromWire(event['context'] as String?),
        );
        if (rid is int) {
          unawaited(_answer(rid, request));
        } else {
          _observer?.call(request);
        }
    }
  }

  /// Answers held request [rid]: the replacement, `null` to proceed, or a
  /// failure for an invalid replacement or a throwing replacer.
  Future<void> _answer(int rid, BrowserRequest request) async {
    final BrowserRequestReplacer? replacer = _replacer;
    BrowserReplacement? replacement;
    String? fail;
    try {
      replacement = await replacer?.call(request);
      fail = replacement?.invalidReason;
    } on Object catch (e) {
      fail = 'request handler threw: $e';
    }
    if (fail != null) {
      _port.config.onLog?.call('[desktop_webview] failing request ${request.url}: $fail');
      await _helper.request('respond', <String, Object?>{'rid': rid, 'fail': fail});
      return;
    }
    await _helper.request('respond', <String, Object?>{
      'rid': rid,
      'response': replacement == null ? null : _replacementJson(replacement),
    });
  }

  /// Settles every pending operation as cancelled and stops accepting new
  /// ones.
  void _terminate(String reason, {bool helperDied = false}) {
    _closedReason ??= reason;
    if (helperDied) {
      _closeAfterCrash = BrowserCapabilityUnavailable<void>(
        'close',
        'Browser helper exited before confirming storage deletion ($reason); the next helper start-up wipes its data',
      );
    }
    for (final void Function(String) cancelPending in _pending.toList()) {
      cancelPending(reason);
    }
    _interaction?.settle(BrowserCancelled<void>(reason));
    _handlers.clear();
    _observer = null;
    _replacer = null;
  }

  Future<void> _fence(String reason) async {
    if (isClosed) return;
    _terminate(reason);
    _port._sessions.remove(id);
    final BrowserOutcome<void> closed = await _closeInHelper();
    if (closed is! BrowserCompleted<void>) {
      _port.config.onLog?.call('[desktop_webview] closing fenced session $id of $source did not complete: $closed');
    }
  }

  Future<BrowserOutcome<void>> _closeInHelper() async => switch (await _helper.request(
    'close',
    <String, Object?>{'session': id},
  )) {
    HelperOk() => const BrowserCompleted<void>(null),
    HelperError(code: 'session-closed') => const BrowserCompleted<void>(null),
    HelperError(:final String message) => BrowserCapabilityUnavailable<void>('close', message),
    HelperGone(:final String reason) => BrowserCapabilityUnavailable<void>(
      'close',
      'Browser helper exited before confirming storage deletion ($reason); the next helper start-up wipes its data',
    ),
  };

  @override
  Future<BrowserOutcome<void>> close() async {
    if (isClosed) return _closeAfterCrash ?? const BrowserCompleted<void>(null);
    _terminate('Session closed');
    _port._sessions.remove(id);
    return _closeInHelper();
  }
}
