import 'dart:async';

import 'package:source_runtime/src/backends/protocol_payloads.dart';
import 'package:source_runtime/src/backends/worker_supervisor.dart';
import 'package:source_runtime/src/contracts/browser_port.dart';
import 'package:source_runtime/src/contracts/identity.dart';
import 'package:source_runtime/src/contracts/outcome.dart';

/// Resolves the identity a worker package may open a browser session for.
/// Returns `null` to refuse (a package may not claim another's identity).
typedef BrowserSourceResolver = SourceIdentity? Function(String? packageId, String sourceId);

/// Sends a worker-bound event, normally [WorkerSupervisor.sendEvent].
typedef WorkerEventSink = void Function(String op, Map<String, Object?> payload, {required int generation});

/// Serves KTD4 `host.browser.*` reverse requests of one worker from a
/// [BrowserPort].
///
/// Request and reply shapes are the [HostBrowserRequest] subclasses (see
/// `doc/protocol-v1.md`). Page messages reach the worker as
/// [HostBrowserMessage] events and observed or held requests as
/// [HostBrowserRequestEvent]s. Sessions are scoped to the package that
/// opened them and to the worker generation that opened them.
///
/// Versions: an operation newer than the minor the worker negotiated
/// ([ReverseRequest.protocolMinor]) is answered `protocol-violation`. A
/// pre-1.2 worker gets no capabilities in the open reply, and a script
/// error as the plain `null` result.
///
/// Lifetime (KTD4, KTD20):
/// - [fence] closes every session opened in a generation below the given
///   one; an open that completes after its generation was fenced is closed
///   at once and answered as cancelled, so a late reply never leaves a
///   session behind. Wire it to [WorkerSupervisor.onGenerationFenced].
/// - [close] closes every session and refuses later opens; the conversion
///   scope calls it when it closes.
/// - Held requests (replace tier) of a closed or fenced session proceed
///   unchanged; no event is sent for them.
///
/// One bridge serves one worker: generation numbers are per worker.
class BrowserReverseBridge {
  BrowserReverseBridge({
    required this.port,
    required this.resolveSource,
    this.interactionTimeout,
    this.replacementTimeout,
    this.emitEvent,
    this.onLog,
  });

  final BrowserPort port;
  final BrowserSourceResolver resolveSource;

  /// Bound on `host.browser.show` when the request does not carry the
  /// supervisor's own bound ([ReverseRequest.interactionTimeout] wins).
  final Duration? interactionTimeout;

  /// How long a held request (replace tier) waits for the worker's
  /// `host.browser.respond` before it proceeds unchanged. Without it the
  /// replace tier is refused as `capability-unavailable`; no default is
  /// invented (KTD25).
  final Duration? replacementTimeout;
  WorkerEventSink? emitEvent;

  /// Receives a line for every session this bridge closed on its own (on a
  /// fence, on [close], or after a late open) whose close did not complete,
  /// for example because storage deletion could not be confirmed (KTD20),
  /// and for every held request whose answer timed out. Request headers are
  /// never logged. Pass a redacting sink.
  final void Function(String line)? onLog;

  final Map<String, _Entry> _sessions = <String, _Entry>{};
  final Map<String, _Held> _held = <String, _Held>{};
  int _validFrom = 0;
  int _requestCounter = 0;
  bool _closed = false;

  /// IDs of the sessions currently open through this bridge.
  Iterable<String> get openSessionIds => _sessions.keys;

  /// Number of requests held for a worker answer (replace tier).
  int get heldRequests => _held.length;

  bool _isFenced(int generation) => _closed || generation < _validFrom;

  /// Handles one reverse request; suitable as a [ReverseRequestHandler].
  Future<SourceOutcome<Map<String, Object?>>> handle(ReverseRequest request) async {
    final HostBrowserOperation? operation = HostBrowserOperation.fromWire(request.op);
    if (operation == null) {
      return SourceFailed<Map<String, Object?>>(
        CapabilityUnavailableFailure(request.op, 'Unknown browser operation'),
      );
    }
    if (operation.sinceMinor > request.protocolMinor) {
      return SourceFailed<Map<String, Object?>>(
        ProtocolViolationFailure(
          '${request.op} needs protocol 1.${operation.sinceMinor}; the worker negotiated 1.${request.protocolMinor}',
        ),
      );
    }
    final HostBrowserRequest<ProtocolPayload> typed;
    try {
      typed = HostBrowserRequest.fromWire(operation, request.payload);
    } on FormatException catch (e) {
      return SourceFailed<Map<String, Object?>>(ProtocolViolationFailure('Malformed ${request.op}: ${e.message}'));
    }
    if (_isFenced(request.generation)) {
      return SourceFailed<Map<String, Object?>>(CancelledFailure('Generation ${request.generation} is fenced'));
    }
    final SourceOutcome<ProtocolPayload> outcome = switch (typed) {
      final HostBrowserOpen open => await _open(open, request),
      final HostBrowserSessionRequest<ProtocolPayload> r => await _onSession(r, request),
    };
    return outcome.map((ProtocolPayload reply) => reply.toJson());
  }

  Future<SourceOutcome<ProtocolPayload>> _open(HostBrowserOpen open, ReverseRequest request) async {
    final SourceIdentity? source = resolveSource(request.packageId, open.sourceId);
    if (source == null) {
      return SourceFailed<ProtocolPayload>(
        CapabilityUnavailableFailure(open.operation.wire, 'Package may not open a browser session for that source'),
      );
    }
    final BrowserOutcome<BrowserSession> opened = await port.openSession(
      BrowserSessionRequest(source: source, generation: request.generation, userAgent: open.userAgent),
      cancel: request.cancel,
    );
    if (opened case BrowserCompleted<BrowserSession>(value: final BrowserSession session)) {
      if (_isFenced(request.generation)) {
        // The generation ended while the platform was opening the session:
        // nobody can use it, so close it rather than leak it.
        await _closeOwned(session, 'late open');
        return SourceFailed<ProtocolPayload>(CancelledFailure('Generation ${request.generation} is fenced'));
      }
      _sessions[session.id] = _Entry(session, request.packageId);
    }
    return _map(
      opened,
      (BrowserSession s) =>
          HostBrowserOpened(session: s.id, capabilities: request.protocolMinor >= 2 ? s.capabilities : null),
    );
  }

  Future<SourceOutcome<ProtocolPayload>> _onSession(
    HostBrowserSessionRequest<ProtocolPayload> typed,
    ReverseRequest request,
  ) async {
    final _Entry? entry = _sessions[typed.session];
    if (entry == null || entry.packageId != request.packageId || entry.session.generation != request.generation) {
      return SourceFailed<ProtocolPayload>(CancelledFailure('Unknown or foreign browser session ${typed.session}'));
    }
    final BrowserSession s = entry.session;
    return switch (typed) {
      HostBrowserLoad(:final Uri url, :final Map<String, String> headers) => _map(
        await s.loadUrl(url, headers: headers, cancel: request.cancel),
        _page,
      ),
      HostBrowserLoadData(:final String html, :final Uri baseUrl) => _map(
        await s.loadData(html, baseUrl: baseUrl, cancel: request.cancel),
        _page,
      ),
      HostBrowserEvaluate(:final String script) => _evaluated(
        await s.evaluate(script, cancel: request.cancel),
        request,
      ),
      HostBrowserSetMessageHandler(:final String name, :final bool enabled) => _map(
        await s.setMessageHandler(name, enabled ? _messageSink(s.id, name, request.generation) : null),
        _empty,
      ),
      HostBrowserGetCookies(:final Uri url) => _map(
        await s.getCookies(url, cancel: request.cancel),
        (List<BrowserCookie> c) => HostBrowserCookies(cookies: c),
      ),
      HostBrowserSetCookie(:final Uri url, :final BrowserCookie cookie) => _map(
        await s.setCookie(url, cookie, cancel: request.cancel),
        _empty,
      ),
      HostBrowserSetUserAgent(:final String userAgent) => _map(
        await s.setUserAgent(userAgent, cancel: request.cancel),
        _empty,
      ),
      HostBrowserShow() => switch (request.interactionTimeout ?? interactionTimeout) {
        null => SourceFailed<ProtocolPayload>(
          CapabilityUnavailableFailure(request.op, 'No interaction timeout is configured'),
        ),
        final Duration timeout => _map(await s.showForInteraction(timeout: timeout, cancel: request.cancel), _empty),
      },
      HostBrowserClose() => _map(await _closeSession(s.id, s), _empty),
      HostBrowserAddPageStartScript(:final String script) => _map(await s.addPageStartScript(script), _empty),
      HostBrowserSetRequestInterception(:final HostBrowserInterception mode) => await _setInterception(
        entry,
        mode,
        request,
      ),
      HostBrowserRespond(:final String requestId, :final BrowserReplacement? response) => _respond(
        s.id,
        requestId,
        response,
      ),
    };
  }

  SourceOutcome<ProtocolPayload> _evaluated(BrowserOutcome<String> outcome, ReverseRequest request) =>
      switch (outcome) {
        // A pre-1.2 worker gets Android's evaluateJavascript semantics.
        BrowserScriptError<String>(:final String message) => SourceSuccess<ProtocolPayload>(
          request.protocolMinor >= 2
              ? HostBrowserEvaluated.scriptError(message)
              : const HostBrowserEvaluated(result: 'null'),
        ),
        _ => _map(outcome, (String r) => HostBrowserEvaluated(result: r)),
      };

  Future<SourceOutcome<ProtocolPayload>> _setInterception(
    _Entry entry,
    HostBrowserInterception mode,
    ReverseRequest request,
  ) async {
    final BrowserSession s = entry.session;
    final BrowserOutcome<void> outcome;
    switch (mode) {
      case HostBrowserInterception.none:
        outcome = entry.interception == HostBrowserInterception.replace
            ? await s.setRequestReplacer(null)
            : await s.setRequestObserver(null);
      case HostBrowserInterception.observe:
        outcome = await s.setRequestObserver(_observerSink(s.id, request.generation));
      case HostBrowserInterception.replace:
        final Duration? timeout = replacementTimeout;
        if (timeout == null) {
          return SourceFailed<ProtocolPayload>(
            CapabilityUnavailableFailure(request.op, 'No replacement timeout is configured'),
          );
        }
        outcome = await s.setRequestReplacer(_replacerSink(s.id, request.generation, timeout));
    }
    if (outcome is BrowserCompleted<void>) {
      entry.interception = mode;
      // Requests still held under a previous replacer proceed unchanged.
      if (mode != HostBrowserInterception.replace) _releaseHeld(s.id);
    }
    return _map(outcome, _empty);
  }

  SourceOutcome<ProtocolPayload> _respond(String session, String requestId, BrowserReplacement? response) {
    final _Held? held = _held[requestId];
    if (held == null || held.session != session) {
      return SourceFailed<ProtocolPayload>(CancelledFailure('Request $requestId is no longer held'));
    }
    held.answer(response);
    return const SourceSuccess<ProtocolPayload>(EmptyPayload());
  }

  void Function(String message)? _messageSink(String session, String name, int generation) {
    final WorkerEventSink? sink = emitEvent;
    if (sink == null) return null;
    return (String message) {
      if (_isFenced(generation)) return;
      sink(
        HostBrowserMessage.op,
        HostBrowserMessage(session: session, name: name, message: message).toJson(),
        generation: generation,
      );
    };
  }

  BrowserRequestObserver? _observerSink(String session, int generation) {
    final WorkerEventSink? sink = emitEvent;
    if (sink == null) return null;
    return (BrowserRequest request) {
      if (_isFenced(generation) || !_sessions.containsKey(session)) return;
      sink(
        HostBrowserRequestEvent.op,
        HostBrowserRequestEvent.forward(session: session, request: request).toJson(),
        generation: generation,
      );
    };
  }

  BrowserRequestReplacer? _replacerSink(String session, int generation, Duration timeout) {
    final WorkerEventSink? sink = emitEvent;
    if (sink == null) return null;
    return (BrowserRequest request) {
      if (_isFenced(generation) || !_sessions.containsKey(session)) return null;
      final id = 'q${++_requestCounter}';
      final held = _Held(session);
      _held[id] = held;
      held.timer = Timer(timeout, () {
        if (held.answer(null)) {
          onLog?.call(
            '[browser] no answer for held request ${request.method} ${_logUrl(request.url)} in session $session '
            'within $timeout; it proceeds unchanged',
          );
        }
      });
      sink(
        HostBrowserRequestEvent.op,
        HostBrowserRequestEvent.forward(session: session, request: request, requestId: id).toJson(),
        generation: generation,
      );
      return held.completer.future.whenComplete(() => _held.remove(id));
    };
  }

  /// [url] without query, fragment or user info: request URLs may carry
  /// tokens, and log lines must not.
  static String _logUrl(Uri url) => '${url.scheme}://${url.host}${url.hasPort ? ':${url.port}' : ''}${url.path}';

  /// Lets every request held for [session] proceed unchanged.
  void _releaseHeld(String session) {
    for (final _Held h in _held.values.where((_Held h) => h.session == session).toList()) {
      h.answer(null);
    }
  }

  /// Closes a session nobody else will close, reporting an incomplete close.
  Future<void> _closeOwned(BrowserSession session, String why) async {
    _sessions.remove(session.id);
    _releaseHeld(session.id);
    final BrowserOutcome<void> outcome = await session.close();
    if (outcome is BrowserCompleted<void>) return;
    onLog?.call('[browser] closing session ${session.id} of ${session.source} ($why) did not complete: $outcome');
  }

  Future<BrowserOutcome<void>> _closeSession(String id, BrowserSession session) {
    _sessions.remove(id);
    _releaseHeld(id);
    return session.close();
  }

  /// Closes every session opened in a generation below [validFrom] and
  /// refuses later requests from those generations.
  Future<void> fence(int validFrom) async {
    if (validFrom > _validFrom) _validFrom = validFrom;
    final stale = <BrowserSession>[
      for (final _Entry e in _sessions.values)
        if (e.session.generation < _validFrom) e.session,
    ];
    await Future.wait(<Future<void>>[
      for (final BrowserSession s in stale) _closeOwned(s, 'generation ${s.generation} fenced'),
    ]);
  }

  /// Closes every session and refuses every later request. Idempotent.
  Future<void> close() async {
    _closed = true;
    await closeAll();
  }

  /// Closes every session opened through this bridge.
  Future<void> closeAll() async {
    final sessions = <BrowserSession>[for (final _Entry e in _sessions.values) e.session];
    _sessions.clear();
    await Future.wait(<Future<void>>[for (final BrowserSession s in sessions) _closeOwned(s, 'bridge closed')]);
  }

  static HostBrowserPage _page(BrowserPage page) => HostBrowserPage(finalUrl: page.finalUrl, status: page.statusCode);

  static EmptyPayload _empty(void _) => const EmptyPayload();

  static SourceOutcome<ProtocolPayload> _map<T>(
    BrowserOutcome<T> outcome,
    ProtocolPayload Function(T value) onValue,
  ) => switch (outcome) {
    BrowserCompleted<T>(:final T value) => SourceSuccess<ProtocolPayload>(onValue(value)),
    BrowserCancelled<T>(:final String reason) => SourceFailed<ProtocolPayload>(CancelledFailure(reason)),
    BrowserInteractionRequired<T>(:final String reason) => SourceFailed<ProtocolPayload>(
      InteractionRequiredFailure(reason),
    ),
    BrowserCapabilityUnavailable<T>(:final String operation, :final String reason) => SourceFailed<ProtocolPayload>(
      CapabilityUnavailableFailure(operation, reason),
    ),
    BrowserNavigationFailed<T>(:final Uri url, :final String reason) => SourceFailed<ProtocolPayload>(
      SourceErrorFailure('Navigation to $url failed: $reason'),
    ),
    BrowserScriptError<T>(:final String message) => SourceFailed<ProtocolPayload>(
      SourceErrorFailure('Script error: $message'),
    ),
  };
}

/// One open session and the package that owns it.
final class _Entry {
  _Entry(this.session, this.packageId);

  final BrowserSession session;
  final String? packageId;
  HostBrowserInterception interception = HostBrowserInterception.none;
}

/// A request held for the worker's `host.browser.respond`.
final class _Held {
  _Held(this.session);

  final String session;
  final Completer<BrowserReplacement?> completer = Completer<BrowserReplacement?>();
  Timer? timer;

  /// Settles once; returns whether this call settled it.
  bool answer(BrowserReplacement? response) {
    if (completer.isCompleted) return false;
    timer?.cancel();
    completer.complete(response);
    return true;
  }
}
