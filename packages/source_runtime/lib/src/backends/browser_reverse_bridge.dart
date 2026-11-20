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
/// [HostBrowserMessage] events. Sessions are scoped to the package that
/// opened them and to the worker generation that opened them.
///
/// Lifetime (KTD4, KTD20):
/// - [fence] closes every session opened in a generation below the given
///   one; an open that completes after its generation was fenced is closed
///   at once and answered as cancelled, so a late reply never leaves a
///   session behind. Wire it to [WorkerSupervisor.onGenerationFenced].
/// - [close] closes every session and refuses later opens; the conversion
///   scope calls it when it closes.
///
/// One bridge serves one worker: generation numbers are per worker.
class BrowserReverseBridge {
  BrowserReverseBridge({
    required this.port,
    required this.resolveSource,
    this.interactionTimeout,
    this.emitEvent,
    this.onLog,
  });

  final BrowserPort port;
  final BrowserSourceResolver resolveSource;

  /// Bound on `host.browser.show` when the request does not carry the
  /// supervisor's own bound ([ReverseRequest.interactionTimeout] wins).
  final Duration? interactionTimeout;
  WorkerEventSink? emitEvent;

  /// Receives a line for every session this bridge closed on its own (on a
  /// fence, on [close], or after a late open) whose close did not complete,
  /// for example because storage deletion could not be confirmed (KTD20).
  /// Pass a redacting sink.
  final void Function(String line)? onLog;

  final Map<String, ({BrowserSession session, String? packageId})> _sessions =
      <String, ({BrowserSession session, String? packageId})>{};
  int _validFrom = 0;
  bool _closed = false;

  /// IDs of the sessions currently open through this bridge.
  Iterable<String> get openSessionIds => _sessions.keys;

  bool _isFenced(int generation) => _closed || generation < _validFrom;

  /// Handles one reverse request; suitable as a [ReverseRequestHandler].
  Future<SourceOutcome<Map<String, Object?>>> handle(ReverseRequest request) async {
    final HostBrowserOperation? operation = HostBrowserOperation.fromWire(request.op);
    if (operation == null) {
      return SourceFailed<Map<String, Object?>>(
        CapabilityUnavailableFailure(request.op, 'Unknown browser operation'),
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
      _sessions[session.id] = (session: session, packageId: request.packageId);
    }
    return _map(opened, (BrowserSession s) => HostBrowserOpened(session: s.id));
  }

  Future<SourceOutcome<ProtocolPayload>> _onSession(
    HostBrowserSessionRequest<ProtocolPayload> typed,
    ReverseRequest request,
  ) async {
    final ({BrowserSession session, String? packageId})? entry = _sessions[typed.session];
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
      HostBrowserEvaluate(:final String script) => _map(
        await s.evaluate(script, cancel: request.cancel),
        (String r) => HostBrowserEvaluated(result: r),
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
    };
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

  /// Closes a session nobody else will close, reporting an incomplete close.
  Future<void> _closeOwned(BrowserSession session, String why) async {
    _sessions.remove(session.id);
    final BrowserOutcome<void> outcome = await session.close();
    if (outcome is BrowserCompleted<void>) return;
    onLog?.call('[browser] closing session ${session.id} of ${session.source} ($why) did not complete: $outcome');
  }

  Future<BrowserOutcome<void>> _closeSession(String id, BrowserSession session) {
    _sessions.remove(id);
    return session.close();
  }

  /// Closes every session opened in a generation below [validFrom] and
  /// refuses later requests from those generations.
  Future<void> fence(int validFrom) async {
    if (validFrom > _validFrom) _validFrom = validFrom;
    final stale = <BrowserSession>[
      for (final e in _sessions.values)
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
    final sessions = <BrowserSession>[for (final e in _sessions.values) e.session];
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
  };
}
