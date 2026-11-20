/// The `BrowserPort` contract (KTD20): source-scoped platform WebView
/// sessions behind one asynchronous, cancellable, generation-fenced API.
///
/// Implementations: the desktop helper (U2), iOS WKWebView (U10), Android
/// app-process WebView (U12), and the fake in `package:source_runtime_testing`.
/// Every implementation runs the reusable contract suite
/// (`runBrowserPortContractSuite`).
library;

import 'dart:convert';

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
///   loaded afterwards, until the handler is removed.
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

  /// Evaluates [script] in the current page; returns its JSON-encoded result.
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel});

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
  Future<BrowserOutcome<void>> showForInteraction({required Duration timeout, CancellationToken? cancel});

  /// Closes the session and deletes its cookies and web storage. Returns
  /// [BrowserCapabilityUnavailable] if deletion cannot be confirmed (KTD9).
  Future<BrowserOutcome<void>> close();
}
