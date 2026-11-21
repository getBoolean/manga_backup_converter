import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:paperback_plugin_loader/src/admission.dart';
import 'package:paperback_plugin_loader/src/host/browser.dart';
import 'package:paperback_plugin_loader/src/host/js_assets.g.dart';
import 'package:paperback_plugin_loader/src/host/network.dart';
import 'package:paperback_plugin_loader/src/runtime/promise_bridge.dart';
import 'package:paperback_plugin_loader/src/runtime/quickjs_runtime.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_runtime.dart';

/// The user agent `getDefaultUserAgent` reports. Fixed so captures replay
/// byte-for-byte; a mobile Safari string, as the Paperback app is an iOS app.
const String paperbackDefaultUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

/// A source enumerated by a loaded bundle.
final class PaperbackLoadedSource {
  const PaperbackLoadedSource({required this.sourceId, required this.name, this.language, this.version});

  final String sourceId;
  final String name;
  final String? language;
  final String? version;
}

/// One Paperback bundle running in its own [SourceJsRuntime] (KTD2, KTD6):
/// the host primitives, the shared prelude, the pinned host library, the
/// family's API adapter, the original bundle and the operation glue are
/// evaluated in that order. Host behaviour is in `assets/*.js`; this class
/// supplies the Dart primitives and maps results to the source contracts.
///
/// Settings and secure state live in the runtime's memory only (KTD9):
/// [load] seeds them from the settings snapshot, and nothing is persisted.
final class PaperbackSourceHost {
  PaperbackSourceHost({
    required this.runtime,
    required this.http,
    this.browser,
    this.userAgent = paperbackDefaultUserAgent,
    this.cloudflareAutoSolveWait = const Duration(seconds: 8),
    void Function(String line)? log,
  }) : _log = log ?? ((String _) {});

  /// How long a Cloudflare bypass waits for a challenge to clear on its own
  /// before showing the page to the user.
  final Duration cloudflareAutoSolveWait;

  final SourceJsRuntime runtime;
  final PaperbackHttp http;

  /// Browser channel for `executeInWebView`; `null` makes it a named
  /// capability failure.
  final PaperbackBrowserChannel? browser;
  final String userAgent;
  final void Function(String line) _log;

  PaperbackApiFamily? _family;
  final Map<String, PaperbackLoadedSource> _sources = <String, PaperbackLoadedSource>{};

  /// The family admitted at [load].
  PaperbackApiFamily get family => _family ?? (throw StateError('No bundle loaded'));

  Map<String, PaperbackLoadedSource> get sources => Map<String, PaperbackLoadedSource>.unmodifiable(_sources);

  /// Admits [bytes] against [binding] (digest, family, shape) and only then
  /// evaluates anything. Seeds state from [settings] per source.
  Future<List<PaperbackLoadedSource>> load(
    Uint8List bytes,
    ArtifactBinding binding,
    SettingsPayload settings, {
    CancellationToken? cancel,
  }) async {
    final PaperbackApiFamily family;
    try {
      family = admitBundle(bytes, binding);
    } on BundleAdmissionException catch (e) {
      throw PaperbackRuntimeException(e.failure, reason: PaperbackFailureReason.sourceError);
    }
    _family = family;
    _installHost();
    await runtime.evaluate(preludeJs, filename: 'paperback/prelude.js', cancel: cancel);
    await runtime.evaluate(hostLibJs, filename: 'paperback/host_lib.js', cancel: cancel);
    await runtime.evaluate(
      family == PaperbackApiFamily.v08 ? api08Js : api09Js,
      filename: 'paperback/${family.wire}.js',
      cancel: cancel,
    );
    await runtime.evaluate(
      // The script's completion value (often the exported module) is not
      // data; discard it. The bundle text itself is evaluated unchanged.
      '${utf8.decode(bytes, allowMalformed: true)}\n;void 0;',
      filename: 'bundle/${binding.sha256.substring(0, 12)}.js',
      cancel: cancel,
    );
    await runtime.evaluate(opsJs, filename: 'paperback/ops.js', cancel: cancel);
    // Every source of a package sees its own effective settings; a Paperback
    // bundle hosts one source, so the package scope and its source coincide.
    await _seed(settings, cancel);
    final Object? loaded = await _op('__pbOpsLoad', const <Object?>[], cancel);
    _sources.clear();
    for (final s in loaded! as List<Object?>) {
      final m = s! as Map<String, Object?>;
      final source = PaperbackLoadedSource(
        sourceId: m['sourceId']! as String,
        name: m['name'] as String? ?? m['sourceId']! as String,
        language: m['language'] as String?,
        version: m['version'] as String?,
      );
      _sources[source.sourceId] = source;
    }
    if (_sources.isEmpty) {
      throw const PaperbackRuntimeException(
        ArtifactIncompatibleFailure('The bundle exports no Paperback source'),
        reason: PaperbackFailureReason.sourceError,
      );
    }
    return _sources.values.toList();
  }

  /// Replaces the seeded state with [settings] (protocol `settings.update`).
  Future<void> updateSettings(SettingsPayload settings, {CancellationToken? cancel}) => _seed(settings, cancel);

  Future<void> _seed(SettingsPayload settings, CancellationToken? cancel) async {
    // A Paperback bundle hosts one source. Before enumeration (the seed must
    // precede 0.9 `initialise`, which may read state) its ID is the one the
    // settings scope names.
    final String? only = _sources.length == 1
        ? _sources.keys.single
        : (settings.sources.length == 1 ? settings.sources.keys.single : null);
    final Map<String, Object> values = only == null
        ? settings.values
        : _effective(settings.values, settings.sources[only]?.values);
    final Map<String, String> secrets = only == null
        ? settings.secrets
        : <String, String>{...settings.secrets, ...?settings.sources[only]?.secrets};
    final seed = '__pbApi.seed(${jsonEncode(values)}, ${jsonEncode(secrets)})';
    await runtime.evaluate(seed, filename: 'paperback/seed.js', cancel: cancel);
  }

  static Map<String, Object> _effective(Map<String, Object> base, Map<String, Object>? scoped) => <String, Object>{
    ...base,
    ...?scoped,
  };

  /// Searches [sourceId]. [cursor] is the source's own pagination metadata
  /// from a previous page, JSON-encoded; `null` asks for the first page.
  Future<PaperbackSearchPage> search(String sourceId, String query, String? cursor, {CancellationToken? cancel}) async {
    final ok = (await _op('__pbOpsSearch', <Object?>[sourceId, query, cursor], cancel))! as Map<String, Object?>;
    return PaperbackSearchPage(
      items: <Map<String, Object?>>[
        for (final Object? i in ok['items'] as List<Object?>? ?? const <Object?>[])
          if (i is Map<String, Object?> && i['mangaId'] is String) i,
      ],
      nextCursor: ok['metadataJson'] as String?,
    );
  }

  /// Fetches details and the complete chapter list for [mangaId].
  Future<Map<String, Object?>> details(String sourceId, String mangaId, {CancellationToken? cancel}) async =>
      (await _op('__pbOpsDetails', <Object?>[sourceId, mangaId], cancel))! as Map<String, Object?>;

  Future<Object?> _op(String function, List<Object?> args, CancellationToken? cancel) async {
    final int misses = http.captureMisses.length;
    final Object? reply = await runtime.call(function, args, cancel: cancel);
    if (http.captureMisses.length > misses) {
      // A capture miss must fail loudly even when the source caught it.
      throw PaperbackRuntimeException(
        SourceErrorFailure('No committed capture for: ${http.captureMisses.sublist(misses).join(', ')}'),
        reason: PaperbackFailureReason.sourceError,
      );
    }
    final map = reply! as Map<String, Object?>;
    final failure = map['failure'] as Map<String, Object?>?;
    if (failure != null) {
      final String code = failure['code'] as String? ?? 'source-error';
      final String message = failure['message'] as String? ?? 'unknown failure';
      throw PaperbackRuntimeException(
        SourceFailure.fromWire(
          code,
          message,
          operation: code == 'capability-unavailable' ? _capabilityName(message) : null,
        ),
        reason: PaperbackFailureReason.sourceError,
        stack: failure['stack'] as String?,
      );
    }
    return map['ok'];
  }

  static String _capabilityName(String message) =>
      RegExp(r'(Application\.\w+|executeInWebView|host\.browser\.\w+|TextDecoder)').firstMatch(message)?.group(1) ??
      'paperback-host';

  void _installHost() {
    final JsContext c = runtime.context;
    runtime.installGlobal('__pbHost.defaultUserAgent', c.string(userAgent));
    runtime.bridge.registerAsync('__pbHost.fetch', (List<Object?> args) {
      final Object? wire = args.isEmpty ? null : args.first;
      if (wire is! Map<String, Object?>) throw const HostCallError('fetch expects an object');
      return http.exchange(wire);
    });
    runtime.bridge.registerAsync('__pbHost.wake', (List<Object?> args) async {
      final num ms = args.isEmpty ? 0 : (args.first as num? ?? 0);
      await Future<void>.delayed(Duration(microseconds: (ms * 1000).round()));
      return null;
    });
    runtime.bridge.registerAsync('__pbHost.webview', (List<Object?> args) async {
      final PaperbackBrowserChannel? channel = browser;
      if (channel == null) {
        throw const HostCallError('[capability-unavailable] executeInWebView: no browser port on this host');
      }
      final Object? spec = args.isEmpty ? null : args.first;
      if (spec is! Map<String, Object?>) throw const HostCallError('executeInWebView expects an object');
      final String sourceId = _sources.length == 1 ? _sources.keys.single : '';
      try {
        return await PaperbackBrowser(
          channel,
          sourceId: sourceId,
          resultTimeout: runtime.limits.operationDeadline,
        ).execute(WebViewExecution.fromJs(spec), _currentCancel ?? CancellationToken.none);
      } on PaperbackBrowserException catch (e) {
        final SourceFailure f = e.failure;
        final String tag = f is CapabilityUnavailableFailure ? 'capability-unavailable' : f.code;
        throw HostCallError('[$tag] executeInWebView: ${f.message}');
      }
    });
    runtime.installGlobal('__pbHost.hasBrowser', c.boolean(browser != null));
    runtime.bridge.registerAsync('__pbHost.cloudflareBypass', (List<Object?> args) async {
      final PaperbackBrowserChannel? channel = browser;
      if (channel == null) {
        throw const HostCallError(
          '[interaction-required] The source needs a Cloudflare bypass and this host has no browser',
        );
      }
      final Object? spec = args.isEmpty ? null : args.first;
      if (spec is! Map<String, Object?>) throw const HostCallError('cloudflareBypass expects an object');
      final String sourceId = _sources.length == 1 ? _sources.keys.single : '';
      try {
        return await PaperbackBrowser(
          channel,
          sourceId: sourceId,
          resultTimeout: runtime.limits.operationDeadline,
        ).bypassCloudflare(
          CloudflareBypass.fromJs(spec),
          _currentCancel ?? CancellationToken.none,
          autoSolveWait: cloudflareAutoSolveWait,
        );
      } on PaperbackBrowserException catch (e) {
        final SourceFailure f = e.failure;
        // A browser that cannot run the bypass leaves the challenge for the
        // user: the operation still needs an interaction, not a capability.
        final String tag = f is CapabilityUnavailableFailure ? 'interaction-required' : f.code;
        throw HostCallError('[$tag] Cloudflare bypass: ${f.message}');
      }
    });
    _sync(
      '__pbHost.utf8Decode',
      (JsContext c, List<JsValue> a) => c.string(utf8.decode(_bytes(a), allowMalformed: true)),
    );
    _sync('__pbHost.utf8DecodeStrict', (JsContext c, List<JsValue> a) => c.string(utf8.decode(_bytes(a))));
    _sync('__pbHost.utf8Encode', (JsContext c, List<JsValue> a) => c.uint8Array(utf8.encode(_string(a))));
    _sync('__pbHost.latin1Decode', (JsContext c, List<JsValue> a) => c.string(latin1.decode(_bytes(a))));
    _sync('__pbHost.utf16Decode', (JsContext c, List<JsValue> a) {
      final Uint8List b = _bytes(a);
      final units = Uint16List(b.length ~/ 2);
      for (var i = 0; i < units.length; i++) {
        units[i] = b[2 * i] | (b[2 * i + 1] << 8);
      }
      return c.string(String.fromCharCodes(units));
    });
    _sync('__pbHost.base64Encode', (JsContext c, List<JsValue> a) => c.string(base64.encode(_bytes(a))));
    _sync('__pbHost.base64Decode', (JsContext c, List<JsValue> a) {
      String s = _string(a).replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
      s = s.padRight((s.length + 3) ~/ 4 * 4, '=');
      return c.uint8Array(base64.decode(s));
    });
    _sync('__pbHost.md5', (JsContext c, List<JsValue> a) => c.string(crypto.md5.convert(_bytes(a)).toString()));
    _sync('__pbHost.hostOf', (JsContext c, List<JsValue> a) => c.string(Uri.tryParse(_string(a))?.host ?? ''));
  }

  CancellationToken? _currentCancel;

  void _sync(String name, JsValue Function(JsContext c, List<JsValue> args) fn) {
    runtime.installGlobal(
      name,
      runtime.context.newHostFunction(
        name.split('.').last,
        (JsContext c, JsValue self, List<JsValue> args) => fn(c, args),
      ),
    );
  }

  static Uint8List _bytes(List<JsValue> args) {
    if (args.isEmpty) throw ArgumentError('expected bytes');
    final Uint8List? b = args.first.bytes();
    if (b == null) throw ArgumentError('expected an ArrayBuffer or typed array');
    return b;
  }

  static String _string(List<JsValue> args) => args.isEmpty ? '' : args.first.toDartString();

  /// Runs [body] with [cancel] visible to host calls (`executeInWebView`).
  Future<T> withCancel<T>(CancellationToken? cancel, Future<T> Function() body) async {
    final CancellationToken? previous = _currentCancel;
    _currentCancel = cancel;
    try {
      return await body();
    } finally {
      _currentCancel = previous;
    }
  }

  void log(String line) => _log(line);
}

/// A page of raw Paperback search results.
final class PaperbackSearchPage {
  const PaperbackSearchPage({required this.items, this.nextCursor});

  /// `{mangaId, title, imageUrl?, subtitle?, contentRating?}` per item.
  final List<Map<String, Object?>> items;

  /// The source's own `PagedResults.metadata`, JSON-encoded; `null` when the
  /// source returned none.
  final String? nextCursor;
}
