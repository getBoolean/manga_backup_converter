import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/src/aidoku/_aidoku_decode.dart';
import 'package:aidoku_plugin_loader/src/aidoku/aidoku_isolate_exited_exception.dart';
import 'package:aidoku_plugin_loader/src/aidoku/aix_parser.dart';
import 'package:aidoku_plugin_loader/src/aidoku/libs/host_store.dart';
import 'package:aidoku_plugin_loader/src/codec/postcard_reader.dart';
import 'package:aidoku_plugin_loader/src/codec/postcard_writer.dart';
import 'package:aidoku_plugin_loader/src/models/chapter.dart';
import 'package:aidoku_plugin_loader/src/models/filter.dart';
import 'package:aidoku_plugin_loader/src/models/filter_info.dart';
import 'package:aidoku_plugin_loader/src/models/language_info.dart';
import 'package:aidoku_plugin_loader/src/models/manga.dart';
import 'package:aidoku_plugin_loader/src/models/page.dart';
import 'package:aidoku_plugin_loader/src/models/setting_item.dart';
import 'package:aidoku_plugin_loader/src/models/source_info.dart';
import 'package:aidoku_plugin_loader/src/native/wasm_isolate.dart';
import 'package:aidoku_plugin_loader/src/native/wasm_semaphore_io.dart';
import 'package:aidoku_plugin_loader/src/native/wasm_shared_state_io.dart';
import 'package:http/http.dart' as http;
import 'package:wasm_runner/wasm_runner.dart';

/// A loaded Aidoku WASM source plugin (native implementation).
///
/// WASM executes in a long-running background [Isolate]. When a host import
/// requires async work (HTTP, sleep), the WASM isolate thread blocks via a
/// POSIX/Win32 semaphore while the main isolate performs the async operation.
class AidokuPlugin {
  AidokuPlugin._({
    required this._wasmCmdPort,
    required this._asyncPort,
    required this._semaphore,
    required this._sharedState,
    required this.sourceInfo,
    required this.settings,
    required this.filterDefinitions,
    required this._httpClient,
    required this._exit,
  });

  final SendPort _wasmCmdPort;
  final ReceivePort _asyncPort;
  final WasmSemaphore _semaphore;
  final WasmSharedState _sharedState;

  final StreamController<HomePartialResult> _partialResultsController = StreamController<HomePartialResult>.broadcast();

  final List<String> _recentWarnings = [];

  RateLimiter? _rateLimiter;

  final SourceInfo sourceInfo;

  /// Parsed settings from `settings.json`.
  final List<SettingItem> settings;

  /// Parsed filter definitions from `filters.json`.
  final List<FilterInfo> filterDefinitions;

  /// Default filters derived from `filters.json` default values.
  List<FilterValue> get defaultFilters => filterDefinitions
      .expand((FilterInfo f) => f.type == 'group' ? f.items : <FilterInfo>[f])
      .map((FilterInfo f) => f.toDefaultFilterValue())
      .whereType<FilterValue>()
      .toList();

  /// Returns and clears any host-level warnings accumulated during recent
  /// WASM calls (e.g. unsupported CSS selectors, HTML parse failures).
  List<String> drainWarnings() {
    final result = List<String>.of(_recentWarnings);
    _recentWarnings.clear();
    return result;
  }

  // Shared HTTP client reused for every plugin that is not given its own.
  static final http.Client _sharedHttpClient = http.Client();

  // HTTP client used for this plugin's `net::send` requests.
  final http.Client _httpClient;

  // Completes when the WASM isolate exits, for any reason (shutdown, an
  // uncaught error, or a kill). Every reply wait races it, so a dead isolate
  // fails the call instead of leaving `port.first` waiting forever.
  final _IsolateExit _exit;

  // ---------------------------------------------------------------------------
  // Factory
  // ---------------------------------------------------------------------------

  /// Load a plugin from raw .aix file bytes.
  ///
  /// [httpClient] replaces the shared client used for the plugin's network
  /// requests (for example a capture-replay client in tests). The caller owns
  /// it; [dispose] does not close it.
  static Future<AidokuPlugin> fromAix(
    Uint8List aixBytes, {
    Map<String, dynamic>? defaults,
    http.Client? httpClient,
  }) async {
    final AixBundle bundle = AixParser.parse(aixBytes);

    final List<SettingItem> settings = bundle.settings ?? const <SettingItem>[];
    final List<FilterInfo> filterDefinitions = bundle.filters ?? const <FilterInfo>[];
    final String sourceId = bundle.sourceInfo.id;
    final initialDefaults = Map<String, Object>.from(
      flattenSettingDefaults(settings, sourceId: sourceId),
    );
    // Mirror Swift Source.loadSettings() defaultLanguages selection.
    List<String> defaultLanguages = bundle.languageInfos
        .where((LanguageInfo l) => l.isDefault ?? false)
        .map((LanguageInfo l) => l.effectiveValue)
        .toList();
    if (defaultLanguages.isEmpty && bundle.languageInfos.isNotEmpty) {
      defaultLanguages = <String>[bundle.languageInfos.first.effectiveValue];
    }
    if (bundle.languageSelectType == 'single' && defaultLanguages.length > 1) {
      defaultLanguages = <String>[defaultLanguages.first];
    }
    if (defaultLanguages.isNotEmpty) {
      initialDefaults['$sourceId.languages'] = encodeStringList(defaultLanguages);
    }

    if (defaults != null) {
      for (final MapEntry<String, dynamic> entry in defaults.entries) {
        final key = '$sourceId.${entry.key}';
        final Object? value = entry.value;
        if (value == null) {
          // skip
        } else if (value is bool) {
          initialDefaults[key] = (PostcardWriter()..writeBool(value)).bytes;
        } else if (value is int) {
          initialDefaults[key] = (PostcardWriter()..writeSignedVarInt(value)).bytes;
        } else if (value is Uint8List) {
          initialDefaults[key] = value;
        } else if (value is String) {
          initialDefaults[key] = (PostcardWriter()..writeString(value)).bytes;
        } else {
          // double, List, Map → JSON-encoded as postcard string
          initialDefaults[key] = (PostcardWriter()..writeString(jsonEncode(value))).bytes;
        }
      }
    }

    final WasmSemaphore semaphore = WasmSemaphore.create();
    final sharedState = WasmSharedState();

    // asyncPort: receives WasmHttpMsg / WasmSleepMsg from the WASM isolate.
    final asyncPort = ReceivePort();
    // handshakePort: receives the WASM isolate's command port on startup.
    final handshakePort = ReceivePort();

    // One port for both notifications keeps them ordered: an uncaught error
    // is delivered before the exit that it causes.
    final exit = _IsolateExit();
    await Isolate.spawn(
      wasmIsolateMain,
      WasmIsolateInit(
        handshakePort: handshakePort.sendPort,
        asyncPort: asyncPort.sendPort,
        wasmBytes: bundle.wasmBytes,
        semaphoreAddress: semaphore.address,
        resultSlotAddress: sharedState.resultSlotAddress,
        statusSlotAddress: sharedState.statusSlotAddress,
        bufferPtrSlotAddress: sharedState.bufferPtrSlotAddress,
        bufferLenSlotAddress: sharedState.bufferLenSlotAddress,
        headersPtrSlotAddress: sharedState.headersPtrSlotAddress,
        headersLenSlotAddress: sharedState.headersLenSlotAddress,
        sourceId: sourceId,
        initialDefaults: initialDefaults,
      ),
      onExit: exit.port.sendPort,
      onError: exit.port.sendPort,
    );

    final wasmCmdPort = await exit.race(handshakePort, 'start') as SendPort;

    final plugin = AidokuPlugin._(
      wasmCmdPort: wasmCmdPort,
      asyncPort: asyncPort,
      semaphore: semaphore,
      sharedState: sharedState,
      sourceInfo: bundle.sourceInfo,
      settings: settings,
      filterDefinitions: filterDefinitions,
      httpClient: httpClient ?? _sharedHttpClient,
      exit: exit,
    );

    asyncPort.listen((Object? msg) async {
      try {
        if (msg is WasmHttpMsg) {
          await plugin._handleHttpMsg(msg);
        } else if (msg is WasmSleepMsg) {
          try {
            await Future<void>.delayed(Duration(seconds: msg.seconds));
          } finally {
            WasmSemaphore.fromAddress(msg.semaphoreAddress).signal();
          }
        } else if (msg is WasmLogMsg) {
          // ignore: avoid_print
          print('[wasm] ${msg.message}\n${msg.stackTrace}');
        } else if (msg is WasmRateLimitMsg) {
          plugin._rateLimiter = RateLimiter(
            RateLimitConfig(permits: msg.permits, periodMs: msg.periodMs),
          );
        } else if (msg is WasmPartialResultMsg) {
          final HomePartialResult? decoded = decodeHomePartialResultFromBytes(msg.data);
          if (decoded != null) plugin._partialResultsController.add(decoded);
        }
      } on Object catch (e, st) {
        // ignore: avoid_print
        print('[wasm/async] unhandled error: $e\n$st');
      }
    });

    return plugin;
  }

  Future<void> _handleHttpMsg(WasmHttpMsg msg) async {
    try {
      final Uri uri = Uri.parse(msg.url);
      if (!uri.hasScheme || !uri.hasAuthority) {
        // ignore: avoid_print
        print('[wasm/net] error: relative URL from plugin: ${msg.url}');
        _sharedState.writeError();
        return;
      }
      final String methodStr = msg.method < _httpMethodNames.length ? _httpMethodNames[msg.method] : 'GET';
      final int timeoutSeconds = msg.timeout.isFinite ? msg.timeout.toInt() : 30;

      const maxRetries = 3;
      for (var attempt = 0; attempt <= maxRetries; attempt++) {
        // Enforce rate limiting before every attempt (first and retries).
        final RateLimiter? limiter = _rateLimiter;
        if (limiter != null) {
          final Duration wait = limiter.waitDuration();
          if (wait > Duration.zero) {
            await Future<void>.delayed(wait);
          }
          limiter.recordRequest();
        }

        // ignore: avoid_print
        print('[wasm/net] $methodStr ${msg.url}');
        final request = http.Request(methodStr, uri);
        request.headers.addAll(msg.headers);
        // Aidoku's own host adds its WebView user agent when the source sets
        // none (WasmNet.swift, AidokuRunner.swift). Some sites (Weeb Central)
        // refuse the Dart client's default `Dart/<version> (dart:io)`.
        if (!request.headers.keys.any((String k) => k.toLowerCase() == 'user-agent')) {
          request.headers['User-Agent'] = aidokuDefaultUserAgent;
        }
        if (msg.body != null) {
          request.bodyBytes = Uint8List.fromList(msg.body!);
        }
        final http.StreamedResponse response = await _httpClient
            .send(request)
            .timeout(Duration(seconds: timeoutSeconds));
        final Uint8List body = await response.stream.toBytes();
        // ignore: avoid_print
        print('[wasm/net] ${response.statusCode} ${body.length}b');

        if (response.statusCode == 429 && attempt < maxRetries) {
          final int delayMs = _retryDelayMs(response.headers['retry-after'], attempt);
          // ignore: avoid_print
          print('[wasm/net] 429, retrying in ${delayMs}ms');
          await Future<void>.delayed(Duration(milliseconds: delayMs));
          continue;
        }

        // Collect response headers (lowercased keys for case-insensitive lookup).
        final respHeaders = <String, String>{};
        response.headers.forEach((String key, String value) {
          respHeaders[key.toLowerCase()] = value;
        });
        _sharedState.writeResponse(statusCode: response.statusCode, body: body, headers: respHeaders);
        return;
      }
    } on Object catch (e) {
      // ignore: avoid_print
      print('[wasm/net] error: $e');
      _sharedState.writeError();
    } finally {
      WasmSemaphore.fromAddress(msg.semaphoreAddress).signal();
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Search for manga on this source. [page] is 1-based.
  ///
  /// Throws [Exception] if the WASM plugin encounters a fatal error (e.g. trap).
  Future<MangaPageResult> searchManga(
    String query,
    int page, {
    List<FilterValue> filters = const <FilterValue>[],
  }) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmSearchCmd(
        queryBytes: Uint8List.fromList(utf8.encode(query)),
        page: page,
        filtersBytes: encodeFilters(filters),
        replyPort: port.sendPort,
      ),
    );
    final (Uint8List? data, String? error, List<String> warnings) =
        await _exit.race(port, 'WasmSearchCmd') as (Uint8List?, String?, List<String>);
    port.close();
    _recentWarnings.addAll(warnings);
    if (error != null) throw WasmRuntimeException(error);
    if (data == null) return const MangaPageResult(manga: <Manga>[], hasNextPage: false);
    try {
      return decodeMangaPageResult(PostcardReader(data));
    } on Exception {
      return const MangaPageResult(manga: <Manga>[], hasNextPage: false);
    }
  }

  /// Fetch updated manga details. Returns null on error or no data.
  Future<Manga?> getMangaDetails(String key, {bool includeChapters = false}) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmMangaDetailsCmd(
        keyBytes: Uint8List.fromList(utf8.encode(key)),
        replyPort: port.sendPort,
        includeChapters: includeChapters,
      ),
    );
    final (Uint8List? data, String? error, List<String> warnings) =
        await _exit.race(port, 'WasmMangaDetailsCmd') as (Uint8List?, String?, List<String>);
    port.close();
    _recentWarnings.addAll(warnings);
    if (error != null) throw WasmRuntimeException(error);
    if (data == null) return null;
    try {
      return decodeManga(PostcardReader(data));
    } on Exception {
      return null;
    }
  }

  /// Fetch page image URLs for a chapter.
  Future<List<Page>> getPageList(Manga manga, Chapter chapter) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmPageListCmd(
        mangaBytes: encodeManga(manga),
        chapterBytes: encodeChapter(chapter),
        replyPort: port.sendPort,
      ),
    );
    final data = await _exit.race(port, 'WasmPageListCmd') as Uint8List?;
    port.close();
    if (data == null) return <Page>[];
    try {
      return decodePageList(PostcardReader(data));
    } on Object {
      return <Page>[];
    }
  }

  /// Browse manga listing (page is 1-based, listing selects the source's listing).
  Future<MangaPageResult> getMangaList(int page, {SourceListing? listing}) async {
    final Uint8List? listingBytes = listing != null
        ? encodeListing(AidokuListing(id: listing.id, name: listing.name, kind: listing.kind))
        : null;
    final port = ReceivePort();
    _wasmCmdPort.send(WasmMangaListCmd(listingBytes: listingBytes, page: page, replyPort: port.sendPort));
    final data = await _exit.race(port, 'WasmMangaListCmd') as Uint8List?;
    port.close();
    if (data == null) return const MangaPageResult(manga: <Manga>[], hasNextPage: false);
    try {
      return decodeMangaPageResult(PostcardReader(data));
    } on Exception {
      return const MangaPageResult(manga: <Manga>[], hasNextPage: false);
    }
  }

  /// Decoded filter definitions from the WASM `get_filters` export.
  Future<List<AidokuFilter>?> getFilters() async {
    final Uint8List? bytes = await _rawGet('get_filters');
    if (bytes == null) return null;
    return decodeFilterListResult(bytes);
  }

  /// Decoded settings from the WASM `get_settings` export.
  Future<List<AidokuSetting>?> getSettings() async {
    final Uint8List? bytes = await _rawGet('get_settings');
    if (bytes == null) return null;
    return decodeSettingListResult(bytes);
  }

  /// Decoded home layout from `get_home`, or null if not supported.
  Future<HomeLayout?> getHome() async {
    final Uint8List? bytes = await _rawGet('get_home');
    if (bytes == null) return null;
    return decodeHomeLayoutResult(bytes);
  }

  /// Available source listings from `get_listings`.
  Future<List<AidokuListing>> getListings() async {
    final Uint8List? bytes = await _rawGet('get_listings');
    if (bytes == null) return const <AidokuListing>[];
    try {
      return decodeListings(PostcardReader(bytes));
    } on Object {
      return const <AidokuListing>[];
    }
  }

  /// Alternate cover URLs for a manga from `get_alternate_covers`.
  Future<List<String>> getAlternateCovers(Manga manga) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmAlternateCoversCmd(mangaBytes: encodeManga(manga), replyPort: port.sendPort),
    );
    final data = await _exit.race(port, 'WasmAlternateCoversCmd') as Uint8List?;
    port.close();
    if (data == null) return const <String>[];
    return decodeStringVecResult(data);
  }

  /// Custom image request for a URL from `get_image_request`.
  Future<ImageRequest?> getImageRequest(String url, {Map<String, String>? context}) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmImageRequestCmd(
        urlBytes: encodeStringBytes(url),
        contextBytes: encodeOptionalStringMap(context),
        replyPort: port.sendPort,
      ),
    );
    final data = await _exit.race(port, 'WasmImageRequestCmd') as Uint8List?;
    port.close();
    if (data == null) return null;
    return decodeImageRequestResult(data);
  }

  /// Source base URL from `get_base_url`.
  Future<String?> getBaseUrl() async {
    final Uint8List? bytes = await _rawGet('get_base_url');
    if (bytes == null) return null;
    return decodeStringResult(bytes);
  }

  /// Page description string from `get_page_description`.
  Future<String?> getPageDescription(Page page) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmPageDescriptionCmd(pageBytes: encodePage(page), replyPort: port.sendPort),
    );
    final data = await _exit.race(port, 'WasmPageDescriptionCmd') as Uint8List?;
    port.close();
    if (data == null) return null;
    return decodeStringResult(data);
  }

  /// Process a page image (e.g. descramble) via `process_page_image`.
  ///
  /// Returns standard image bytes (PNG/JPEG/WebP) usable with `Image.memory()`
  /// or `package:image`.
  Future<Uint8List?> processPageImage(Uint8List imageBytes, {Map<String, String>? context}) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmProcessPageImageCmd(
        imageBytes: encodeImageResponse(imageBytes),
        contextBytes: encodeOptionalStringMap(context),
        replyPort: port.sendPort,
      ),
    );
    final data = await _exit.race(port, 'WasmProcessPageImageCmd') as Uint8List?;
    port.close();
    return data;
  }

  /// Deliver a notification string to the plugin via `handle_notification`.
  Future<void> handleNotification(String notification) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmNotificationCmd(notifBytes: encodeStringBytes(notification), replyPort: port.sendPort),
    );
    await _exit.race(port, 'WasmNotificationCmd');
    port.close();
  }

  /// Handle a deep link URL via `handle_deep_link`.
  Future<DeepLinkResult?> handleDeepLink(String url) async {
    final port = ReceivePort();
    _wasmCmdPort.send(WasmDeepLinkCmd(urlBytes: encodeStringBytes(url), replyPort: port.sendPort));
    final data = await _exit.race(port, 'WasmDeepLinkCmd') as Uint8List?;
    port.close();
    if (data == null) return null;
    return decodeDeepLinkResultFromBytes(data);
  }

  /// Perform basic (username/password) login via `handle_basic_login`.
  Future<bool> handleBasicLogin(String key, String username, String password) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmBasicLoginCmd(
        keyBytes: encodeStringBytes(key),
        usernameBytes: encodeStringBytes(username),
        passwordBytes: encodeStringBytes(password),
        replyPort: port.sendPort,
      ),
    );
    final Object? result = await _exit.race(port, 'WasmBasicLoginCmd');
    port.close();
    return result is bool && result;
  }

  /// Perform web (cookie) login via `handle_web_login`.
  Future<bool> handleWebLogin(String key, Map<String, String> cookies) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmWebLoginCmd(
        keyBytes: encodeStringBytes(key),
        cookiesBytes: encodeStringMap(cookies),
        replyPort: port.sendPort,
      ),
    );
    final Object? result = await _exit.race(port, 'WasmWebLoginCmd');
    port.close();
    return result is bool && result;
  }

  /// Migrate a manga key via `handle_key_migration`.
  Future<String?> handleMangaMigration(String key) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmMangaMigrationCmd(keyBytes: encodeStringBytes(key), replyPort: port.sendPort),
    );
    final data = await _exit.race(port, 'WasmMangaMigrationCmd') as Uint8List?;
    port.close();
    if (data == null) return null;
    return decodeStringResult(data);
  }

  /// Migrate a chapter key via `handle_key_migration`.
  Future<String?> handleChapterMigration(String mangaKey, String chapterKey) async {
    final port = ReceivePort();
    _wasmCmdPort.send(
      WasmChapterMigrationCmd(
        mangaKeyBytes: encodeStringBytes(mangaKey),
        chapterKeyBytes: encodeStringBytes(chapterKey),
        replyPort: port.sendPort,
      ),
    );
    final data = await _exit.race(port, 'WasmChapterMigrationCmd') as Uint8List?;
    port.close();
    if (data == null) return null;
    return decodeStringResult(data);
  }

  /// Partial results stream — pushed by `env::_send_partial_result` during
  /// `get_home` and other streaming exports.
  Stream<HomePartialResult> get partialResults => _partialResultsController.stream;

  /// Shut down the WASM background isolate and free native resources.
  void dispose() {
    _wasmCmdPort.send(const WasmShutdownCmd());
    // Stop watching: later calls fail at once, and the open port no longer
    // keeps this isolate alive if the WASM isolate is slow to exit.
    _exit.close();
    _asyncPort.close();
    _semaphore.dispose();
    _sharedState.dispose();
    _partialResultsController.close();
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<Uint8List?> _rawGet(String funcName) async {
    final port = ReceivePort();
    _wasmCmdPort.send(WasmRawGetCmd(funcName: funcName, replyPort: port.sendPort));
    final data = await _exit.race(port, funcName) as Uint8List?;
    port.close();
    return data;
  }
}

/// User agent sent when a source request carries none, matching the WebKit
/// user agent that Aidoku's host supplies.
const String aidokuDefaultUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

/// Watches the WASM isolate's exit and error notifications.
final class _IsolateExit {
  _IsolateExit() {
    port.handler = (Object? message) {
      if (message is List && message.isNotEmpty) {
        // onError: [error, stackTrace] as strings.
        _error ??= '${message.first}';
        return;
      }
      // onExit: null.
      close();
    };
  }

  /// Treats the isolate as gone from now on.
  void close() {
    port.close();
    if (!_exited.isCompleted) _exited.complete();
  }

  final RawReceivePort port = RawReceivePort();
  final Completer<void> _exited = Completer<void>();
  String? _error;

  /// Waits for the first message on [reply], or fails with
  /// [AidokuIsolateExitedException] once the isolate has exited. Closes
  /// [reply] either way.
  ///
  /// Returns `dynamic`, like `ReceivePort.first`, so call sites keep their
  /// existing reply casts.
  Future<dynamic> race(ReceivePort reply, String operation) async {
    final Future<dynamic> first = reply.first;
    // The loser of the race must not surface as an unhandled error.
    first.ignore();
    try {
      return await Future.any(<Future<dynamic>>[
        first,
        _exited.future.then<dynamic>(
          (_) => throw AidokuIsolateExitedException(operation, error: _error),
        ),
      ]);
    } finally {
      reply.close();
    }
  }
}

const List<String> _httpMethodNames = <String>['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'];

/// Parse `Retry-After` header (integer seconds or HTTP-date) and return delay
/// in milliseconds, falling back to exponential backoff: 1s, 2s, 4s.
/// Uses exponential backoff as a floor so `Retry-After: 0` doesn't cause
/// immediate retries. Clamped to 60 seconds max.
int _retryDelayMs(String? retryAfter, int attempt) {
  const maxDelayMs = 60000;
  final int backoffMs = (1000 * (1 << attempt)).clamp(0, maxDelayMs);
  if (retryAfter != null) {
    final int? seconds = int.tryParse(retryAfter);
    if (seconds != null) {
      final int headerMs = (seconds * 1000).clamp(0, maxDelayMs);
      return headerMs > backoffMs ? headerMs : backoffMs;
    }
    try {
      final DateTime date = HttpDate.parse(retryAfter);
      final int headerMs = date.difference(DateTime.now()).inMilliseconds.clamp(0, maxDelayMs);
      return headerMs > backoffMs ? headerMs : backoffMs;
    } on Object {
      // Fall through to exponential backoff.
    }
  }
  return backoffMs;
}
