/// The `BrowserPort` contract (KTD20): source-scoped platform WebView
/// sessions behind one asynchronous, cancellable, generation-fenced API.
///
/// Implementations: the desktop helper (U2), iOS WKWebView (U10), Android
/// app-process WebView (U12), and the fake in `package:source_runtime_testing`.
/// Every implementation runs the reusable contract suite
/// (`runBrowserPortContractSuite`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:source_runtime/src/contracts/cancellation.dart';
import 'package:source_runtime/src/contracts/identity.dart';

/// Result of a browser operation.
sealed class BrowserOutcome<T> {
  const BrowserOutcome();

  /// The value of a completed operation, or `null`.
  T? get valueOrNull => switch (this) {
    BrowserCompleted<T>(:final T value) => value,
    _ => null,
  };
}

/// The operation completed.
final class BrowserCompleted<T> extends BrowserOutcome<T> {
  const BrowserCompleted(this.value);

  final T value;

  @override
  String toString() => 'BrowserCompleted($value)';
}

/// The operation was cancelled, its session closed, or its generation fenced.
/// A fenced operation never resolves a newer request.
final class BrowserCancelled<T> extends BrowserOutcome<T> {
  const BrowserCancelled(this.reason);

  final String reason;

  @override
  String toString() => 'BrowserCancelled($reason)';
}

/// The page needs a visible user interaction (for example a challenge), or
/// no display is available to show one.
final class BrowserInteractionRequired<T> extends BrowserOutcome<T> {
  const BrowserInteractionRequired(this.reason);

  final String reason;

  @override
  String toString() => 'BrowserInteractionRequired($reason)';
}

/// The platform cannot perform [operation] (a rejected scheme, a missing
/// WebView runtime, an unsupported interception tier, unconfirmed storage
/// deletion). Never answered with an empty value.
final class BrowserCapabilityUnavailable<T> extends BrowserOutcome<T> {
  const BrowserCapabilityUnavailable(this.operation, this.reason);

  final String operation;
  final String reason;

  @override
  String toString() => 'BrowserCapabilityUnavailable($operation: $reason)';
}

/// Navigation to [url] failed (network error, TLS failure, aborted load).
final class BrowserNavigationFailed<T> extends BrowserOutcome<T> {
  const BrowserNavigationFailed(this.url, this.reason);

  final Uri url;
  final String reason;

  @override
  String toString() => 'BrowserNavigationFailed($url: $reason)';
}

/// The evaluated script threw (only [BrowserSession.evaluate] returns this).
///
/// Reported only by implementations whose [BrowserSession.capabilities]
/// support [BrowserFeature.scriptErrors]; elsewhere a throwing script
/// completes with `null`, as Android's `evaluateJavascript` does. Callers
/// that need Android semantics use [BrowserEvaluateCompat.androidCompatible].
final class BrowserScriptError<T> extends BrowserOutcome<T> {
  const BrowserScriptError(this.message);

  /// The engine's description of the thrown value (for example
  /// `Error: boom`). May include page text; never contains host secrets.
  final String message;

  @override
  String toString() => 'BrowserScriptError($message)';
}

/// Android `WebView.evaluateJavascript` semantics for [BrowserSession.evaluate].
extension BrowserEvaluateCompat on BrowserOutcome<String> {
  /// This outcome with a [BrowserScriptError] replaced by the JSON text
  /// `null`, which is what Android reports for a script that throws. The
  /// Tachi `android.webkit` shim maps `evaluate` through this.
  BrowserOutcome<String> get androidCompatible => switch (this) {
    BrowserScriptError<String>() => const BrowserCompleted<String>('null'),
    final BrowserOutcome<String> other => other,
  };
}

/// Scheme rules for every load, navigation, redirect and base URL (KTD20).
///
/// Allowed: `http`, `https`, and `about:blank`; `loadData` content needs an
/// http(s) base URL. `file:` and every other local or app-custom scheme are
/// rejected with [BrowserCapabilityUnavailable], at the port and in each
/// platform's navigation delegate, so sandboxed sources cannot read local
/// files through a browser.
abstract final class BrowserUrlPolicy {
  static const Set<String> _webSchemes = <String>{'http', 'https'};

  /// Whether [url] may be loaded or navigated to (including redirects).
  static bool isNavigable(Uri url) => _isWeb(url) || isAboutBlank(url);

  /// Whether [url] is an acceptable `loadData` base URL.
  static bool isAllowedBaseUrl(Uri url) => _isWeb(url);

  /// Whether [url] is exactly `about:blank`.
  static bool isAboutBlank(Uri url) => url.scheme == 'about' && url.path == 'blank' && !url.hasQuery;

  /// Failure for a rejected navigation target, or `null` if allowed.
  static BrowserCapabilityUnavailable<T>? checkNavigation<T>(Uri url, String operation) => isNavigable(url)
      ? null
      : BrowserCapabilityUnavailable<T>(
          operation,
          'Scheme "${url.scheme}" is not allowed (only http, https, about:blank)',
        );

  /// Failure for a rejected base URL, or `null` if allowed.
  static BrowserCapabilityUnavailable<T>? checkBaseUrl<T>(Uri url, String operation) => isAllowedBaseUrl(url)
      ? null
      : BrowserCapabilityUnavailable<T>(operation, 'Base URL scheme "${url.scheme}" is not allowed (only http, https)');

  static bool _isWeb(Uri url) => _webSchemes.contains(url.scheme) && url.host.isNotEmpty;
}

/// The page side of [BrowserSession.setMessageHandler] (KTD20).
///
/// While a handler is registered for channel `name`, every frame of the
/// session's pages sees a global object `window.<name>` with one method,
/// `postMessage(message)`, where `message` is a string. The Tachi shim's
/// `addJavascriptInterface` fallback (an object with `void postMessage`)
/// and Paperback's `executeInWebView` both rely on exactly this shape, so
/// a page script written for Android's `JavascriptInterface` runs unchanged.
///
/// - **Availability:** the object exists in the current page as soon as the
///   handler is registered, and is injected at document start in every page
///   loaded afterwards, until the handler is removed. Channel objects are
///   installed before any page-start script
///   ([BrowserSession.addPageStartScript]) runs, whatever the registration
///   order, so a page-start script may post on a channel.
/// - **Origin rule:** a message is delivered only when the frame that posted
///   it has the same origin (scheme, host, port) as the session's current
///   top-level document, and that document was loaded from http(s) (by
///   [BrowserSession.loadUrl] after redirects, or by
///   [BrowserSession.loadData] with its http(s) base URL). Messages from
///   cross-origin frames, and from `about:blank` or other opaque-origin
///   documents, are dropped silently: the page learns nothing and the
///   handler is not called.
/// - **Payload:** a non-string argument is dropped. Delivery is
///   asynchronous and in posting order for one frame.
/// - **No return value:** `postMessage` returns `undefined`; synchronous
///   `@JavascriptInterface` return values are not emulated (KTD20).
abstract final class BrowserMessageChannel {
  static final RegExp _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

  /// Whether [name] can be a channel: a plain JavaScript identifier, so
  /// `window.<name>` needs no quoting.
  ///
  /// The contract reserves no identifier, so `ipc` is valid: a Tachi
  /// extension's `addJavascriptInterface(obj, name)` may use any name.
  /// An implementation must therefore not occupy a `window.<identifier>`
  /// global with its own transport. In particular wry's IPC handler defines
  /// `window.ipc` as a non-writable, non-configurable property (verified in
  /// wry 0.57.3 for WebView2, WKWebView and WebKitGTK), so a wry-based
  /// helper must not enable it. It registers its own engine message handler
  /// instead (WebView2 `WebMessageReceived`, a WebKit script message handler
  /// under a private name), as wry only injects `window.ipc` when its IPC
  /// handler is set.
  static bool isValidName(String name) => _identifier.hasMatch(name);

  /// Failure for an invalid channel [name], or `null` if valid.
  static BrowserCapabilityUnavailable<T>? checkName<T>(String name) => isValidName(name)
      ? null
      : BrowserCapabilityUnavailable<T>(
          'setMessageHandler',
          'Channel name "$name" is not a JavaScript identifier',
        );

  /// The script a page runs to post [message] on channel [name]; the form
  /// the contract suite and worker shims use.
  static String postScript(String name, String message) => 'window.$name.postMessage(${jsonEncode(message)})';

  /// Whether a message posted by a frame at [frameOrigin] may reach the
  /// handler of a session whose top-level document is [documentUrl].
  static bool accepts({required Uri documentUrl, required Uri frameOrigin}) {
    if (!BrowserUrlPolicy.isAllowedBaseUrl(documentUrl) || !BrowserUrlPolicy.isAllowedBaseUrl(frameOrigin)) {
      return false;
    }
    return documentUrl.origin == frameOrigin.origin;
  }
}

/// Request to open a source-scoped browser session.
@immutable
final class BrowserSessionRequest {
  const BrowserSessionRequest({required this.source, required this.generation, this.userAgent});

  /// The source the session belongs to; storage is scoped to it.
  final SourceIdentity source;

  /// Runtime generation that opened the session (see [BrowserPort.fence]).
  final int generation;

  final String? userAgent;
}

/// A page after a completed load.
@immutable
final class BrowserPage {
  const BrowserPage({required this.finalUrl, this.statusCode});

  /// URL after redirects.
  final Uri finalUrl;
  final int? statusCode;
}

/// A cookie read from or written to a session.
@immutable
final class BrowserCookie {
  const BrowserCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path,
    this.expires,
    this.secure = false,
    this.httpOnly = false,
  });

  factory BrowserCookie.fromJson(Map<String, Object?> json) => BrowserCookie(
    name: json['name']! as String,
    value: json['value']! as String,
    domain: json['domain'] as String?,
    path: json['path'] as String?,
    expires: json['expires'] == null ? null : DateTime.parse(json['expires']! as String),
    secure: json['secure'] as bool? ?? false,
    httpOnly: json['httpOnly'] as bool? ?? false,
  );

  final String name;
  final String value;
  final String? domain;
  final String? path;
  final DateTime? expires;
  final bool secure;
  final bool httpOnly;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'value': value,
    'domain': domain,
    'path': path,
    'expires': expires?.toUtc().toIso8601String(),
    'secure': secure,
    'httpOnly': httpOnly,
  };
}

/// Optional browser behaviour whose availability depends on the engine
/// (protocol 1.2). Reported per session by [BrowserSession.capabilities].
enum BrowserFeature {
  /// [BrowserSession.addPageStartScript]: scripts at document start in
  /// every frame.
  pageStartScripts('pageStartScripts'),

  /// Observe tier: top-level (main-frame) document requests, including
  /// redirects, reach [BrowserSession.setRequestObserver].
  observeNavigations('observeNavigations'),

  /// Observe tier: subresource and child-frame requests (scripts, `fetch`,
  /// XHR, images, iframes) reach the observer. WKWebView and WebKitGTK
  /// cannot observe them.
  observeSubresources('observeSubresources'),

  /// Observed requests carry the request headers the engine sends.
  observeRequestHeaders('observeRequestHeaders'),

  /// Observed headers include Chromium client hints (`sec-ch-ua*`). WebKit
  /// engines never send client hints.
  observeClientHints('observeClientHints'),

  /// Observed requests carry their body ([BrowserRequest.body]).
  observeRequestBodies('observeRequestBodies'),

  /// Replace tier: [BrowserSession.setRequestReplacer] can substitute a
  /// response. WebView2 only among the desktop engines.
  replaceRequests('replaceRequests'),

  /// [BrowserSession.evaluate] reports a throwing script as
  /// [BrowserScriptError] instead of a `null` result.
  scriptErrors('scriptErrors');

  const BrowserFeature(this.wire);

  /// The name used in [BrowserCapabilities.toJson].
  final String wire;

  static BrowserFeature? fromWire(String wire) {
    for (final BrowserFeature f in values) {
      if (f.wire == wire) return f;
    }
    return null;
  }
}

/// How far a session can intercept requests (KTD20).
enum BrowserInterceptionTier {
  /// No request observation at all.
  none,

  /// Observe-only: requests are reported and proceed unchanged. Check
  /// [BrowserFeature.observeSubresources] for degraded (main-frame only)
  /// observation.
  observe,

  /// Observe and replace: a replacer may supply the response.
  replace,
}

/// The [BrowserFeature]s one session's engine provides, each missing one
/// with a named reason (protocol 1.2).
///
/// A feature the implementation does not list is unavailable, never
/// assumed: a peer that predates a feature cannot claim it, and a peer that
/// reports nothing (protocol 1.1 or older) has
/// [BrowserCapabilities.unreported].
@immutable
final class BrowserCapabilities {
  BrowserCapabilities({
    Set<BrowserFeature> available = const <BrowserFeature>{},
    Map<BrowserFeature, String> unavailable = const <BrowserFeature, String>{},
  }) : available = Set<BrowserFeature>.unmodifiable(available),
       unavailable = Map<BrowserFeature, String>.unmodifiable(<BrowserFeature, String>{
         for (final MapEntry<BrowserFeature, String> e in unavailable.entries)
           if (!available.contains(e.key)) e.key: e.value.trim().isEmpty ? _unnamed : e.value,
       });

  /// Every feature available (a WebView2-like engine; the fake's default).
  factory BrowserCapabilities.all() => BrowserCapabilities(available: BrowserFeature.values.toSet());

  /// What a peer that reports no capabilities has: nothing optional.
  factory BrowserCapabilities.unreported() => BrowserCapabilities();

  /// Decodes `{"available": [name], "unavailable": {name: reason}}`.
  /// Unknown feature names (from a newer peer) are ignored.
  factory BrowserCapabilities.fromJson(Map<String, Object?> json) {
    final Object available = json['available'] ?? const <Object?>[];
    final Object unavailable = json['unavailable'] ?? const <String, Object?>{};
    if (available is! List<Object?> || available.any((Object? v) => v is! String)) {
      throw const FormatException('Field "available" must be an array of strings');
    }
    if (unavailable is! Map<Object?, Object?> || unavailable.values.any((Object? v) => v is! String)) {
      throw const FormatException('Field "unavailable" must be an object of strings');
    }
    return BrowserCapabilities(
      available: <BrowserFeature>{
        for (final Object? name in available)
          if (BrowserFeature.fromWire(name! as String) case final BrowserFeature f) f,
      },
      unavailable: <BrowserFeature, String>{
        for (final MapEntry<Object?, Object?> e in unavailable.entries)
          if (BrowserFeature.fromWire(e.key! as String) case final BrowserFeature f) f: e.value! as String,
      },
    );
  }

  static const String _unnamed = 'Unavailable (no reason given)';

  /// Reason for a feature the implementation did not report at all.
  static const String notReported = 'Not reported by the browser implementation';

  final Set<BrowserFeature> available;

  /// Reported reasons for unavailable features.
  final Map<BrowserFeature, String> unavailable;

  bool supports(BrowserFeature feature) => available.contains(feature);

  /// Why [feature] is unavailable, or `null` when it is available. Never
  /// empty: an unlisted feature reads as [notReported].
  String? reasonFor(BrowserFeature feature) => supports(feature) ? null : (unavailable[feature] ?? notReported);

  /// The interception tier these features allow.
  BrowserInterceptionTier get interceptionTier {
    if (supports(BrowserFeature.replaceRequests)) return BrowserInterceptionTier.replace;
    if (supports(BrowserFeature.observeNavigations) || supports(BrowserFeature.observeSubresources)) {
      return BrowserInterceptionTier.observe;
    }
    return BrowserInterceptionTier.none;
  }

  /// [BrowserCapabilityUnavailable] for [operation] when [feature] is
  /// missing, or `null` when it is available.
  BrowserCapabilityUnavailable<T>? check<T>(BrowserFeature feature, String operation) => switch (reasonFor(feature)) {
    null => null,
    final String reason => BrowserCapabilityUnavailable<T>(operation, '${feature.wire}: $reason'),
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'available': <String>[
      for (final BrowserFeature f in BrowserFeature.values)
        if (supports(f)) f.wire,
    ],
    'unavailable': <String, String>{
      for (final BrowserFeature f in BrowserFeature.values)
        if (!supports(f)) f.wire: reasonFor(f)!,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is BrowserCapabilities &&
      BrowserFeature.values.every((BrowserFeature f) => reasonFor(f) == other.reasonFor(f));

  @override
  int get hashCode => Object.hashAll(BrowserFeature.values.map(reasonFor));

  @override
  String toString() => 'BrowserCapabilities(${available.map((BrowserFeature f) => f.wire).join(', ')})';
}

/// What kind of resource a [BrowserRequest] loads.
enum BrowserRequestContext {
  document,
  script,
  fetch,
  xhr,
  image,
  stylesheet,
  other;

  /// Decodes a wire name; unknown names read as [other].
  static BrowserRequestContext fromWire(String? wire) {
    for (final BrowserRequestContext c in values) {
      if (c.name == wire) return c;
    }
    return other;
  }
}

/// A request a page made, as reported to a request observer or replacer
/// (protocol 1.2; Android's `WebResourceRequest`).
///
/// Only http(s) requests are reported. [headers] are as the engine sends
/// them and may include `Cookie` and `Authorization`: never log them, and
/// never put them in a capture key.
@immutable
final class BrowserRequest {
  BrowserRequest({
    required this.url,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    this.body,
    this.bodyOmitted = false,
    this.mainFrame = false,
    this.redirect = false,
    this.context = BrowserRequestContext.other,
  }) : method = method.toUpperCase(),
       headers = Map<String, String>.unmodifiable(headers);

  final Uri url;

  /// Uppercase HTTP method.
  final String method;

  /// Request headers, names as the engine reports them; empty without
  /// [BrowserFeature.observeRequestHeaders]. Look names up with [header].
  final Map<String, String> headers;

  /// The request body, when it had one and the engine exposed it
  /// ([BrowserFeature.observeRequestBodies]); `null` for no body.
  final Uint8List? body;

  /// The request had a body that [body] does not carry: the engine could
  /// not read it, or it exceeded a forwarding limit. Replay treats such a
  /// request as a miss rather than matching a bodiless capture.
  final bool bodyOmitted;

  /// A top-level document request (Android's `isForMainFrame`).
  final bool mainFrame;

  /// The request follows a redirect.
  final bool redirect;

  final BrowserRequestContext context;

  /// The value of header [name], matched case-insensitively.
  String? header(String name) {
    final String lower = name.toLowerCase();
    for (final MapEntry<String, String> e in headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }

  @override
  String toString() => 'BrowserRequest($method $url${mainFrame ? ' main-frame' : ''})';
}

/// A response a request replacer substitutes for a [BrowserRequest]
/// (replace tier; Android's `WebResourceResponse`).
@immutable
final class BrowserReplacement {
  BrowserReplacement({
    required this.status,
    this.reason = 'OK',
    Map<String, String> headers = const <String, String>{},
    List<int> body = const <int>[],
  }) : headers = Map<String, String>.unmodifiable(headers),
       body = Uint8List.fromList(body);

  final int status;
  final String reason;
  final Map<String, String> headers;
  final Uint8List body;

  /// Why this replacement may not be served, or `null` when it may.
  ///
  /// The status must be 100-599 and not a redirect (300-399): Android's
  /// `WebResourceResponse` refuses redirects, and a substituted `Location`
  /// could otherwise steer a load around the scheme policy. The reason
  /// phrase must be one non-empty line.
  String? get invalidReason {
    if (status < 100 || status > 599) return 'Status $status is outside 100-599';
    if (status >= 300 && status <= 399) return 'Redirect status $status cannot be substituted';
    if (reason.isEmpty || reason.contains('\n') || reason.contains('\r')) {
      return 'Reason phrase must be one non-empty line';
    }
    return null;
  }

  @override
  String toString() => 'BrowserReplacement($status, ${body.length} bytes)';
}

/// Receives every observable request (observe tier).
typedef BrowserRequestObserver = void Function(BrowserRequest request);

/// Answers a request with a replacement, or `null` to let it proceed
/// unchanged (replace tier).
typedef BrowserRequestReplacer = FutureOr<BrowserReplacement?> Function(BrowserRequest request);

/// Platform WebView access for sources.
abstract interface class BrowserPort {
  /// Startup cleanup: removes all source browser data a previous process may
  /// have left behind. Implementations with persistent stores call this when
  /// the helper or app process starts, before opening any session.
  Future<BrowserOutcome<void>> wipeAllSourceData();

  /// Opens a session with storage scoped to [BrowserSessionRequest.source].
  Future<BrowserOutcome<BrowserSession>> openSession(BrowserSessionRequest request, {CancellationToken? cancel});

  /// Fences every session and pending operation whose generation is lower
  /// than [generation]: pending operations resolve as [BrowserCancelled] and
  /// late platform callbacks are discarded.
  Future<void> fence(int generation);
}

/// One source-scoped browser session.
abstract interface class BrowserSession {
  String get id;

  SourceIdentity get source;

  int get generation;

  /// Loads [url]; redirects are checked against [BrowserUrlPolicy].
  Future<BrowserOutcome<BrowserPage>> loadUrl(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    CancellationToken? cancel,
  });

  /// Loads [html] with an http(s) [baseUrl].
  Future<BrowserOutcome<BrowserPage>> loadData(String html, {required Uri baseUrl, CancellationToken? cancel});

  /// The optional features this session's engine provides (protocol 1.2).
  /// Fixed for the session's lifetime.
  BrowserCapabilities get capabilities;

  /// Evaluates [script] in the current page; returns its JSON-encoded result.
  ///
  /// **Promises (protocol 1.3 rule):** when the script's completion value is
  /// a promise (any thenable), `evaluate` awaits it and returns the JSON of
  /// the settled value; a rejected promise is a throwing script. `undefined`
  /// and values JSON cannot encode read as `null`. A promise that never
  /// settles keeps `evaluate` pending until [cancel], the session closing,
  /// or a fence; the caller's deadline bounds it. This is what the desktop
  /// helper and WKWebView's `callAsyncJavaScript` do; an Android port wraps
  /// `evaluateJavascript` (which would report `{}`) to await it.
  ///
  /// A script that throws completes with [BrowserScriptError] when
  /// [capabilities] support [BrowserFeature.scriptErrors], and with `null`
  /// otherwise. [BrowserEvaluateCompat.androidCompatible] gives Android's
  /// `evaluateJavascript` behaviour for throwing scripts on every
  /// implementation (a promise result still reads as its settled value).
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel});

  /// Registers [script] to run at document start in every frame (child
  /// frames included, whatever their origin) of every document this session
  /// loads afterwards, until the session closes (protocol 1.2; Android's
  /// `WebViewCompat.addDocumentStartJavaScript`).
  ///
  /// - **Order:** message channel objects are installed first, then
  ///   page-start scripts in registration order, then the page's own
  ///   scripts.
  /// - **Current document:** not affected; evaluate the script as well if
  ///   it must run there.
  /// - **Origins:** the script runs in documents of every origin. A caller
  ///   that needs Android's `allowedOriginRules` wraps the script in its own
  ///   `location.origin` check. Messages it posts follow the
  ///   [BrowserMessageChannel] origin rule.
  /// - **Removal:** none; scripts last until the session closes.
  ///
  /// Fails with [BrowserCapabilityUnavailable] without
  /// [BrowserFeature.pageStartScripts].
  Future<BrowserOutcome<void>> addPageStartScript(String script);

  /// Observe tier (protocol 1.2): reports each request this session's pages
  /// make to [observer]; requests proceed unchanged. `null` stops it.
  ///
  /// Which requests are reported depends on [capabilities]: top-level
  /// navigations with [BrowserFeature.observeNavigations], subresources and
  /// child frames with [BrowserFeature.observeSubresources]. A request the
  /// engine cannot observe still proceeds. Only http(s) requests are
  /// reported, and only while the session is open and its generation is
  /// current. Fails with [BrowserCapabilityUnavailable] when neither
  /// feature is available.
  ///
  /// A session has at most one interceptor: setting an observer removes
  /// any replacer, and the reverse.
  Future<BrowserOutcome<void>> setRequestObserver(BrowserRequestObserver? observer);

  /// Replace tier (protocol 1.2): holds each http(s) request of this
  /// session until [replacer] answers. A [BrowserReplacement] is served
  /// instead of the network response; `null` lets the request proceed. A
  /// replacement with an [BrowserReplacement.invalidReason], or a replacer
  /// that throws, fails that request (the page sees a network error); a
  /// replacer still pending when the session closes or is fenced lets it
  /// proceed. `null` removes the replacer. Replaces any observer.
  ///
  /// Fails with [BrowserCapabilityUnavailable] without
  /// [BrowserFeature.replaceRequests].
  Future<BrowserOutcome<void>> setRequestReplacer(BrowserRequestReplacer? replacer);

  /// Registers (or with `null` removes) a handler for messages the page
  /// posts on channel [name]. See [BrowserMessageChannel] for the page-side
  /// API (`window.<name>.postMessage(string)`) and the origin rule every
  /// implementation enforces. An invalid [name] fails with
  /// [BrowserCapabilityUnavailable].
  Future<BrowserOutcome<void>> setMessageHandler(String name, void Function(String message)? handler);

  Future<BrowserOutcome<List<BrowserCookie>>> getCookies(Uri url, {CancellationToken? cancel});

  Future<BrowserOutcome<void>> setCookie(Uri url, BrowserCookie cookie, {CancellationToken? cancel});

  Future<BrowserOutcome<void>> setUserAgent(String userAgent, {CancellationToken? cancel});

  /// Shows the page for a user interaction, bounded by [timeout].
  ///
  /// Completion (protocol 1.3), one outcome per way the interaction ends:
  /// - **The user closes the window:** [BrowserCompleted]. The session stays
  ///   open with whatever the user left in it (cookies, storage, page).
  /// - **[cancel] fires:** the window is hidden and the call returns
  ///   [BrowserCancelled]; the session stays open and usable. This is how a
  ///   page's completion signal ends the interaction: see
  ///   [showBrowserInteraction], which callers use instead of calling this
  ///   directly.
  /// - **[timeout] elapses:** the window is hidden and the call returns
  ///   [BrowserInteractionRequired] naming the timeout; the session stays
  ///   open.
  /// - **The session closes or its generation is fenced:** [BrowserCancelled].
  /// - **No display:** [BrowserInteractionRequired] at once.
  ///
  /// Only one of these settles the call; the window is never left shown
  /// after it returns.
  Future<BrowserOutcome<void>> showForInteraction({required Duration timeout, CancellationToken? cancel});

  /// Closes the session and deletes its cookies and web storage. Returns
  /// [BrowserCapabilityUnavailable] if deletion cannot be confirmed (KTD9).
  Future<BrowserOutcome<void>> close();
}

/// How a visible browser interaction ended (protocol 1.3).
enum BrowserInteractionEnd {
  /// The user closed the window.
  closedByUser('closed'),

  /// The page signalled completion (through a message, a navigation, or a
  /// cookie the caller watches), and the caller ended the interaction.
  completedByPage('completed');

  const BrowserInteractionEnd(this.wire);

  /// The `host.browser.show` reply's `outcome` value.
  final String wire;

  static BrowserInteractionEnd? fromWire(String? wire) {
    for (final BrowserInteractionEnd e in values) {
      if (e.wire == wire) return e;
    }
    return null;
  }
}

/// Shows [session] for a user interaction with the protocol 1.3 completion
/// rules; every caller (the desktop reverse bridge, in-app adapters) uses
/// this rather than [BrowserSession.showForInteraction] directly.
///
/// The interaction ends at the first of:
/// - **The user closes the window:**
///   `BrowserCompleted(BrowserInteractionEnd.closedByUser)`.
/// - **[completion] completes** (the page signalled completion): the window
///   is hidden through the show's cancel token, and the result is
///   `BrowserCompleted(BrowserInteractionEnd.completedByPage)`.
/// - **[timeout] elapses:** [BrowserInteractionRequired] naming the timeout.
///   This helper enforces the bound itself, so it holds even if the port
///   overruns its own.
/// - **[cancel] fires, or the session closes or is fenced:**
///   [BrowserCancelled].
///
/// Any other port outcome (no display, an unavailable capability) is
/// returned as is. The session stays open in every case.
Future<BrowserOutcome<BrowserInteractionEnd>> showBrowserInteraction(
  BrowserSession session, {
  required Duration timeout,
  Future<void>? completion,
  CancellationToken? cancel,
}) async {
  if (cancel?.isCancelled ?? false) {
    return BrowserCancelled<BrowserInteractionEnd>(cancel!.reason ?? 'cancelled');
  }
  final hide = CancellationSource();
  _InteractionStop? stop;
  void end(_InteractionStop why, String reason) {
    if (stop != null) return;
    stop = why;
    hide.cancel(reason);
  }

  final timer = Timer(timeout, () => end(_InteractionStop.timeout, 'Interaction not completed within $timeout'));
  unawaited(completion?.then((_) => end(_InteractionStop.completed, 'The page signalled completion'), onError: (_) {}));
  unawaited(cancel?.whenCancelled.then((_) => end(_InteractionStop.cancelled, cancel.reason ?? 'cancelled')));
  final BrowserOutcome<void> shown;
  try {
    shown = await session.showForInteraction(timeout: timeout, cancel: hide.token);
  } finally {
    timer.cancel();
  }
  return switch (shown) {
    BrowserCompleted<void>() when stop == _InteractionStop.completed => const BrowserCompleted<BrowserInteractionEnd>(
      BrowserInteractionEnd.completedByPage,
    ),
    BrowserCompleted<void>() => const BrowserCompleted<BrowserInteractionEnd>(BrowserInteractionEnd.closedByUser),
    BrowserCancelled<void>(:final String reason) => switch (stop) {
      _InteractionStop.completed => const BrowserCompleted<BrowserInteractionEnd>(
        BrowserInteractionEnd.completedByPage,
      ),
      _InteractionStop.timeout => BrowserInteractionRequired<BrowserInteractionEnd>(reason),
      _InteractionStop.cancelled || null => BrowserCancelled<BrowserInteractionEnd>(reason),
    },
    BrowserInteractionRequired<void>(:final String reason) => BrowserInteractionRequired<BrowserInteractionEnd>(reason),
    BrowserCapabilityUnavailable<void>(:final String operation, :final String reason) =>
      BrowserCapabilityUnavailable<BrowserInteractionEnd>(operation, reason),
    BrowserNavigationFailed<void>(:final Uri url, :final String reason) =>
      BrowserNavigationFailed<BrowserInteractionEnd>(url, reason),
    BrowserScriptError<void>(:final String message) => BrowserScriptError<BrowserInteractionEnd>(message),
  };
}

enum _InteractionStop { completed, timeout, cancelled }
