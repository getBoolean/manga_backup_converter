import 'dart:async';
import 'dart:convert';

import 'package:source_runtime/source_runtime.dart';

/// Sends one `host.browser.*` request and returns its `ok` payload or a
/// typed failure. The worker implements it with reverse-request frames; an
/// in-process host implements it with a [BrowserReverseBridge] over a
/// [BrowserPort] ([InProcessBrowserChannel]). Both therefore have identical
/// session scoping, scheme policy and failure codes.
abstract interface class PaperbackBrowserChannel {
  Future<SourceOutcome<Map<String, Object?>>> send(
    HostBrowserRequest<ProtocolPayload> request,
    CancellationToken cancel,
  );

  /// Page messages (`host.browser.message` events) for this channel's
  /// sessions.
  Stream<HostBrowserMessage> get messages;
}

/// A failed browser step; [failure] is reported as the operation's failure.
final class PaperbackBrowserException implements Exception {
  const PaperbackBrowserException(this.failure);

  final SourceFailure failure;

  @override
  String toString() => 'PaperbackBrowserException($failure)';
}

/// The context of one Paperback `executeInWebView` call.
final class WebViewExecution {
  const WebViewExecution({
    required this.html,
    required this.baseUrl,
    required this.inject,
    this.userAgent,
    this.cookies = const <BrowserCookie>[],
  });

  factory WebViewExecution.fromJs(Map<String, Object?> json) => WebViewExecution(
    html: json['html'] as String? ?? '',
    baseUrl: json['baseUrl'] as String? ?? '',
    inject: json['inject'] as String? ?? '',
    userAgent: json['userAgent'] as String?,
    cookies: <BrowserCookie>[
      for (final Object? c in json['cookies'] as List<Object?>? ?? const <Object?>[])
        if (c is Map<String, Object?> && c['name'] is String && c['value'] is String)
          BrowserCookie(
            name: c['name']! as String,
            value: c['value']! as String,
            domain: c['domain'] as String?,
            path: c['path'] as String?,
            expires: c['expires'] is String ? DateTime.tryParse(c['expires']! as String) : null,
          ),
    ],
  );

  final String html;
  final String baseUrl;

  /// A function body; its (possibly asynchronous) return value is the result.
  final String inject;
  final String? userAgent;
  final List<BrowserCookie> cookies;
}

/// Runs Paperback `executeInWebView` (0.9) through a [PaperbackBrowserChannel]
/// (KTD20): open a source-scoped session, seed the source's cookies, load the
/// HTML with its base URL, run the injected function body, read the cookies
/// back, and close the session.
///
/// `inject` may return a promise, and `BrowserPort.evaluate` does not promise
/// to await one, so the result travels back through the protocol 1.1 message
/// channel (`window.<channel>.postMessage`), which every port implements
/// identically; `evaluate` only starts the function.
final class PaperbackBrowser {
  PaperbackBrowser(this.channel, {required this.sourceId, required this.resultTimeout});

  final PaperbackBrowserChannel channel;
  final String sourceId;

  /// Bound on waiting for the injected function's result; the operation
  /// deadline still applies around the whole call.
  final Duration resultTimeout;

  static const String resultChannel = '__pbResult';

  Future<Map<String, Object?>> execute(WebViewExecution context, CancellationToken cancel) async {
    final Uri? base = Uri.tryParse(context.baseUrl);
    if (base == null || !BrowserUrlPolicy.isAllowedBaseUrl(base)) {
      throw PaperbackBrowserException(
        CapabilityUnavailableFailure(
          'host.browser.loadData',
          'executeInWebView needs an http(s) baseUrl, got "${context.baseUrl}"',
        ),
      );
    }
    final HostBrowserOpened opened = await _send(
      HostBrowserOpen(sourceId: sourceId, userAgent: context.userAgent),
      cancel,
    );
    final String session = opened.session;
    try {
      for (final BrowserCookie cookie in context.cookies) {
        await _send(HostBrowserSetCookie(session: session, url: base, cookie: cookie), cancel);
      }
      final result = Completer<String>();
      final StreamSubscription<HostBrowserMessage> sub = channel.messages
          .where((HostBrowserMessage m) => m.session == session && m.name == resultChannel)
          .listen((HostBrowserMessage m) {
            if (!result.isCompleted) result.complete(m.message);
          });
      try {
        await _send(HostBrowserSetMessageHandler(session: session, name: resultChannel, enabled: true), cancel);
        await _send(HostBrowserLoadData(session: session, html: context.html, baseUrl: base), cancel);
        await _send(HostBrowserEvaluate(session: session, script: _runner(context.inject)), cancel);
        final String message =
            await Future.any(<Future<String>>[
              result.future,
              cancel.whenCancelled.then<String>(
                (_) => throw PaperbackBrowserException(CancelledFailure(cancel.reason ?? 'cancelled')),
              ),
            ]).timeout(
              resultTimeout,
              onTimeout: () => throw PaperbackBrowserException(
                TimeoutFailure('executeInWebView produced no result within ${resultTimeout.inMilliseconds} ms'),
              ),
            );
        final Object? decoded = jsonDecode(message);
        if (decoded is! Map<String, Object?>) {
          throw const PaperbackBrowserException(SourceErrorFailure('executeInWebView returned a malformed result'));
        }
        if (decoded['error'] != null) {
          throw PaperbackBrowserException(SourceErrorFailure('executeInWebView script threw: ${decoded['error']}'));
        }
        final HostBrowserCookies cookies = await _send(HostBrowserGetCookies(session: session, url: base), cancel);
        return <String, Object?>{
          'result': decoded['ok'],
          'cookies': <Object?>[for (final BrowserCookie c in cookies.cookies) c.toJson()],
        };
      } finally {
        await sub.cancel();
      }
    } finally {
      // Closing deletes the session's storage (KTD20); a failure is logged by
      // the port owner and never replaces the operation's own outcome.
      await channel.send(HostBrowserClose(session: session), CancellationToken.none);
    }
  }

  Future<R> _send<R extends ProtocolPayload>(HostBrowserRequest<R> request, CancellationToken cancel) async {
    final SourceOutcome<Map<String, Object?>> outcome = await channel.send(request, cancel);
    switch (outcome) {
      case SourceSuccess<Map<String, Object?>>(:final Map<String, Object?> value):
        return request.decodeResponse(value);
      case SourceFailed<Map<String, Object?>>(:final SourceFailure failure):
        throw PaperbackBrowserException(failure);
    }
  }

  /// Starts [inject] as an async function and posts `{ok}` or `{error}` on
  /// the result channel. `evaluate` itself returns `true` at once.
  static String _runner(String inject) =>
      '''
(function () {
  const post = (v) => window.$resultChannel.postMessage(JSON.stringify(v));
  Promise.resolve()
    .then(async () => { const r = await (async function () {
$inject
    })(); post({ ok: r === undefined ? null : r }); })
    .catch((e) => post({ error: String((e && e.message) || e) }));
  return true;
})()''';
}

/// A [PaperbackBrowserChannel] served in this process from a [BrowserPort],
/// through the same [BrowserReverseBridge] the supervisor uses for worker
/// reverse requests. Mobile hosts (U10, U12) and tests use it.
final class InProcessBrowserChannel implements PaperbackBrowserChannel {
  InProcessBrowserChannel({
    required BrowserPort port,
    required SourceIdentity source,
    this.generation = 1,
    void Function(String line)? onLog,
  }) : _packageId = source.packageId {
    _bridge = BrowserReverseBridge(
      port: port,
      resolveSource: (String? packageId, String sourceId) =>
          packageId == source.packageId && sourceId == source.sourceId ? source : null,
      emitEvent: (String op, Map<String, Object?> payload, {required int generation}) {
        if (op == HostBrowserMessage.op) _messages.add(HostBrowserMessage.fromJson(payload));
      },
      onLog: onLog,
    );
  }

  final String _packageId;
  final int generation;
  late final BrowserReverseBridge _bridge;
  final StreamController<HostBrowserMessage> _messages = StreamController<HostBrowserMessage>.broadcast();

  @override
  Stream<HostBrowserMessage> get messages => _messages.stream;

  @override
  Future<SourceOutcome<Map<String, Object?>>> send(
    HostBrowserRequest<ProtocolPayload> request,
    CancellationToken cancel,
  ) => _bridge.handle(
    ReverseRequest(
      op: request.operation.wire,
      payload: request.toJson(),
      packageId: _packageId,
      generation: generation,
      cancel: cancel,
    ),
  );

  /// Closes every session this channel opened.
  Future<void> close() async {
    await _bridge.close();
    await _messages.close();
  }
}
