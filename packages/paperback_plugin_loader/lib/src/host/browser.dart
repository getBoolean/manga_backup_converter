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

/// A Paperback 0.8 `getCloudflareBypassRequestAsync()` request, as the host
/// adapter hands it over: the URL, its headers (no `cookie`, no echoed
/// default user agent), the user agent the source chose (if any), and the
/// cookies the host holds for that domain.
final class CloudflareBypass {
  const CloudflareBypass({
    required this.url,
    this.headers = const <String, String>{},
    this.userAgent,
    this.cookies = const <BrowserCookie>[],
  });

  factory CloudflareBypass.fromJs(Map<String, Object?> json) => CloudflareBypass(
    url: json['url'] as String? ?? '',
    headers: <String, String>{
      for (final MapEntry<String, Object?> h
          in (json['headers'] as Map<String, Object?>? ?? const <String, Object?>{}).entries)
        if (h.value != null) h.key: '${h.value}',
    },
    userAgent: json['userAgent'] as String?,
    cookies: WebViewExecution.fromJs(<String, Object?>{'cookies': json['cookies']}).cookies,
  );

  final String url;
  final Map<String, String> headers;
  final String? userAgent;
  final List<BrowserCookie> cookies;
}

final class _PageState {
  const _PageState({required this.challenged, this.userAgent});

  final bool challenged;
  final String? userAgent;
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

  /// Runs a Paperback 0.8 `getCloudflareBypassRequestAsync()` request
  /// (KTD20): open a source-scoped session (with the source's own user agent
  /// only when it chose one), seed [CloudflareBypass.cookies], load the URL
  /// with the request's headers, and wait for the challenge to clear: first
  /// on its own for [autoSolveWait], then in a visible window
  /// (`host.browser.show`, bounded by the supervisor's interaction timeout).
  /// Returns the session's cookies for the URL and the user agent the page
  /// ran with, which the clearance is bound to. A challenge still present
  /// fails as interaction-required.
  Future<Map<String, Object?>> bypassCloudflare(
    CloudflareBypass request,
    CancellationToken cancel, {
    Duration autoSolveWait = const Duration(seconds: 8),
    Duration pollInterval = const Duration(milliseconds: 500),
  }) async {
    final Uri? url = Uri.tryParse(request.url);
    if (url == null || !BrowserUrlPolicy.isNavigable(url) || BrowserUrlPolicy.isAboutBlank(url)) {
      throw PaperbackBrowserException(
        CapabilityUnavailableFailure(
          'host.browser.load',
          'The Cloudflare bypass needs an http(s) URL, got "${request.url}"',
        ),
      );
    }
    final HostBrowserOpened opened = await _send(
      HostBrowserOpen(sourceId: sourceId, userAgent: request.userAgent),
      cancel,
    );
    final String session = opened.session;
    try {
      for (final BrowserCookie cookie in request.cookies) {
        await _send(HostBrowserSetCookie(session: session, url: url, cookie: cookie), cancel);
      }
      await _send(HostBrowserLoad(session: session, url: url, headers: request.headers), cancel);
      _PageState state = await _pageState(session, cancel);
      final waited = Stopwatch()..start();
      while (state.challenged && waited.elapsed < autoSolveWait) {
        await Future<void>.delayed(pollInterval);
        if (cancel.isCancelled) throw PaperbackBrowserException(CancelledFailure(cancel.reason ?? 'cancelled'));
        state = await _pageState(session, cancel);
      }
      if (state.challenged) {
        // The user solves it in a visible window. The page is probed again
        // once `show` completes; the contract does not yet say whether it
        // completes when the window closes or only when the bound expires.
        await _send(HostBrowserShow(session: session), cancel);
        state = await _pageState(session, cancel);
        if (state.challenged) {
          throw PaperbackBrowserException(
            InteractionRequiredFailure('The Cloudflare challenge at $url was not solved'),
          );
        }
      }
      final HostBrowserCookies cookies = await _send(HostBrowserGetCookies(session: session, url: url), cancel);
      return <String, Object?>{
        'userAgent': state.userAgent ?? request.userAgent,
        'cookies': <Object?>[for (final BrowserCookie c in cookies.cookies) c.toJson()],
      };
    } finally {
      await channel.send(HostBrowserClose(session: session), CancellationToken.none);
    }
  }

  /// Whether the current page is a challenge, and the page's user agent.
  Future<_PageState> _pageState(String session, CancellationToken cancel) async {
    final HostBrowserEvaluated evaluated = await _send(
      HostBrowserEvaluate(session: session, script: _challengeProbe),
      cancel,
    );
    final Object? decoded = _tryDecode(evaluated.result);
    // A probe whose result cannot be read (a platform that reports `null`
    // for it) is treated as still challenged: the host never claims a
    // clearance it did not see.
    if (decoded is! Map<String, Object?>) return const _PageState(challenged: true);
    return _PageState(challenged: decoded['challenged'] != false, userAgent: decoded['userAgent'] as String?);
  }

  static Object? _tryDecode(String text) {
    try {
      final Object? v = jsonDecode(text);
      return v is String ? _tryDecode(v) : v;
    } on FormatException {
      return null;
    }
  }

  /// Cloudflare interstitial markers (title and challenge-platform scripts).
  static const String _challengeProbe = '''
(function () {
  var t = String(document.title || '');
  var h = document.documentElement ? String(document.documentElement.innerHTML) : '';
  return {
    challenged: /just a moment|attention required/i.test(t) || /challenge-platform|cf-chl|_cf_chl_opt/i.test(h),
    userAgent: String(navigator.userAgent)
  };
})()''';

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
    Duration? interactionTimeout,
    void Function(String line)? onLog,
  }) : _packageId = source.packageId {
    _bridge = BrowserReverseBridge(
      port: port,
      // Bounds `host.browser.show` (a Cloudflare challenge the user solves);
      // without it `show` is refused, as on the worker path without one.
      interactionTimeout: interactionTimeout,
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
