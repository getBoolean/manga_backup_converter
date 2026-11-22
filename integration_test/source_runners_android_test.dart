// U13: the Aidoku runner on Android (KTD22), U11's Tachi cases, U12's
// Paperback and app-process BrowserPort cases (android_u12_cases.dart) and
// U14's complete conversion jobs (android_u14_cases.dart) and the background
// gate inside jobs (android_background_cases.dart). Runs
// on an Android device or emulator:
//   flutter test integration_test/source_runners_android_test.dart -d <device>
//
// The existing Aidoku host runs unchanged in the app process (one WASM
// worker isolate per source: wasm3, the Rust scraper HTML backend, the POSIX
// WasmSemaphore, the postcard ABI), registered through the Android backend
// and driven only through the shared SourceProvider/SourceSession contract.
//
// No request reaches a server. The pinned .aix artifacts and the committed
// site captures are embedded by tool/generate_android_aidoku_fixtures.dart
// (aidoku_fixture_bundle.g.dart) and replayed; every case asserts that no
// request missed the captures. Each case prints one `U13_RECEIPT {json}`
// line, collected under docs/validation/source-runners/android/.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/source_adapter.dart';
import 'package:aidoku_plugin_loader/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_android/source_runtime_android.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';

import 'aidoku_fixture_bundle.g.dart';
import 'android_background_cases.dart';
import 'android_u12_cases.dart';
import 'android_u14_cases.dart';
import 'support/android_conversion_harness.dart' show webViewOfflineUnavailable;

const Duration _noHang = Duration(seconds: 60);
const ArtifactProfile _profile = ArtifactProfile(
  producer: 'aidoku-aix',
  converterVersion: '1',
  hostCompatibility: '1',
);

void _receipt(String scenario, Map<String, Object?> data) {
  print(
    'U13_RECEIPT ${jsonEncode(<String, Object?>{'scenario': scenario, 'evidence': 'emulator-or-device', ...data})}',
  );
}

/// One qualification source: its pinned artifact, replayed captures, the
/// fixed query and the hit to fetch.
final class _Qualification {
  const _Qualification(
    this.sourceId,
    this.aix,
    this.version, {
    this.mangaId,
    this.defaults,
  });

  final String sourceId;
  final String aix;
  final String version;

  /// Hit to fetch; the first hit when null (as the capture run did).
  final String? mangaId;
  final Map<String, dynamic>? defaults;
}

const List<_Qualification> _sources = <_Qualification>[
  _Qualification(
    'multi.mangadex',
    'multi.mangadex-v12.aix',
    '12',
    mangaId: 'ed996855-70de-449f-bba2-e8e24224c14d',
    // Same seeded login default as the desktop tests and the capture run.
    defaults: <String, dynamic>{
      'login': <int>[2, 0x7B, 0x7D],
    },
  ),
  _Qualification('en.weebcentral', 'en.weebcentral-v6.aix', '6'),
  _Qualification('multi.mangafire', 'multi.mangafire-v8.aix', '8'),
];

/// A client that fails every request: synthetic modules must not touch the
/// network, and nothing may fall through to a real client.
final http.Client _noNetwork = MockClient(
  (http.Request r) async => throw StateError('unexpected request ${r.url}'),
);

/// Delays every replayed response so a call is still in flight when the
/// test cancels it.
final class _SlowClient extends http.BaseClient {
  _SlowClient(this._inner, this.delay);
  final http.Client _inner;
  final Duration delay;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(delay);
    return _inner.send(request);
  }
}

/// Answers the header probe. Stamps each request synchronously on entry to
/// `send`, which the host calls right after the rate limiter records the
/// request (`MockClient` would stamp only after reading the body
/// asynchronously, which drifts under load).
final class _ProbeServer extends http.BaseClient {
  final List<DateTime> sent = <DateTime>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent.add(DateTime.now());
    return Future<http.StreamedResponse>.value(
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('ok')),
        200,
        request: request,
        headers: <String, String>{'X-Probe': 'value-${sent.length}'},
      ),
    );
  }
}

final class _Artifact implements VerifiedArtifact {
  _Artifact(this.bytes);
  final Uint8List bytes;
  @override
  ArtifactBinding get binding =>
      const ArtifactBinding(sha256: 'synthetic', kind: 'aix', version: '1');
  @override
  Future<Uint8List> readVerified() async => bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (u14Phase.isNotEmpty) {
    // A built-app launch runs only its phase (see android_u14_cases.dart).
    registerU14PhaseCases();
    return;
  }

  late Directory root;
  late ArtifactCache cache;

  /// Every line the host printed (WASM logs, `[wasm/net]`), per case.
  final printed = <String>[];

  Future<T> capturePrints<T>(Future<T> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        printed.add(line);
        parent.print(zone, line);
      },
    ),
  );

  ReplayHttpClient replayFor(String sourceId) => ReplayHttpClient(
    loadCaptureSet(Directory('${root.path}/captures/$sourceId')),
  );

  Future<ArtifactLease> admit(_Qualification q) async {
    final Uint8List bytes = File('${root.path}/aix/${q.aix}').readAsBytesSync();
    return cache.admit(
      bytes,
      binding: ArtifactBinding(
        sha256: sha256Hex(bytes),
        kind: 'aix',
        version: q.version,
      ),
      profile: _profile,
      verifier: (_, _) {},
    );
  }

  /// Registers Aidoku through the Android backend (real dlopen of both
  /// native libraries) and returns the admitted provider.
  SourceProvider register(
    http.Client client, {
    AidokuDefaultsMapper? defaultsFor,
  }) {
    final SourceOutcome<AndroidAidokuBackend> backend =
        AndroidAidokuBackend.register(
          AidokuSourceProvider(httpClient: client, defaultsFor: defaultsFor),
        );
    expect(
      backend.failureOrNull,
      isNull,
      reason: 'Aidoku backend registration',
    );
    return backend.valueOrNull!.provider;
  }

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('u13_aidoku');
    aidokuFixtureBundle.forEach((String path, String b64) {
      File('${root.path}/$path')
        ..createSync(recursive: true)
        ..writeAsBytesSync(base64.decode(b64));
    });
    cache = ArtifactCache(Directory('${root.path}/cache'));
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  setUp(printed.clear);

  testWidgets(
    '1. backend registration loads wasm3 and scraper in the app process',
    (_) async {
      final loaded = <String>[];
      final SourceOutcome<AndroidAidokuBackend> backend =
          AndroidAidokuBackend.register(
            AidokuSourceProvider(httpClient: _noNetwork),
            loadLibrary: (String name) {
              DynamicLibrary.open(name);
              loaded.add(name);
            },
          );
      expect(backend.failureOrNull, isNull);
      expect(loaded, aidokuNativeLibraries);
      _receipt('native-libraries', <String, Object?>{
        'abi': Abi.current().toString(),
        'loaded': loaded,
        'pid': pid,
      });
    },
  );

  for (final _Qualification q in _sources) {
    testWidgets(
      '2. ${q.sourceId}: search, details and chapters from replayed captures',
      (_) async {
        final ReplayHttpClient replay = replayFor(q.sourceId);
        final SourceProvider provider = register(
          replay,
          defaultsFor: q.defaults == null
              ? null
              : (_) => <String, dynamic>{
                  for (final MapEntry<String, dynamic> e in q.defaults!.entries)
                    e.key: e.value is List<int>
                        ? Uint8List.fromList(e.value as List<int>)
                        : e.value,
                },
        );
        final ArtifactLease lease = await admit(q);
        final settings = SettingsSnapshot();
        final watch = Stopwatch()..start();
        final SourcePackage package = await capturePrints(
          () async =>
              (await provider.openPackage(lease, settings).timeout(_noHang))
                  .valueOrNull!,
        );
        final int openMs = watch.elapsedMilliseconds;
        try {
          final SourceSession session = package.sessions.single;
          expect(session.identity.sourceId, q.sourceId);
          expect(session.identity.artifact, lease.binding);

          watch.reset();
          final SourceOutcome<SearchPage> searched = await capturePrints(
            () => session
                .search(const SearchRequest(query: 'Onimai'))
                .timeout(_noHang),
          );
          final int searchMs = watch.elapsedMilliseconds;
          final SearchPage page = searched.valueOrNull!;
          expect(page.hits, isNotEmpty);
          expect(page.warnings, isEmpty, reason: 'host warnings during search');
          final SearchHit hit = q.mangaId == null
              ? page.hits.first
              : page.hits.firstWhere(
                  (SearchHit h) => h.ref.mangaId == q.mangaId,
                );
          expect(hit.title, isNotEmpty);

          watch.reset();
          final SourceOutcome<MangaSnapshot> fetched = await capturePrints(
            () => session.fetchManga(hit.ref).timeout(_noHang),
          );
          final int detailsMs = watch.elapsedMilliseconds;
          final MangaSnapshot snapshot = fetched.valueOrNull!;
          expect(snapshot.metadata.title, isNotEmpty);
          expect(snapshot.chapters, isNotEmpty);

          expect(
            replay.misses,
            isEmpty,
            reason: 'requests without a committed capture',
          );
          expect(
            printed.where((String l) => l.contains('HTML parser unavailable')),
            isEmpty,
            reason: 'the scraper HTML backend must load in the WASM isolate',
          );
          _receipt('source', <String, Object?>{
            'sourceId': q.sourceId,
            'artifact': q.aix,
            'artifactSha256': lease.binding.sha256,
            'hits': page.hits.length,
            'title': snapshot.metadata.title,
            'chapters': snapshot.chapters.length,
            'requestsServed': replay.served.length,
            'replayMisses': replay.misses.length,
            'hostWarnings': page.warnings.length,
            'openMs': openMs,
            'searchMs': searchMs,
            'detailsMs': detailsMs,
          });
        } finally {
          await package.close();
          lease.release();
        }
      },
    );
  }

  testWidgets(
    '3. cancelling an in-flight call answers at once; the session stays usable',
    (_) async {
      final ReplayHttpClient replay = replayFor('multi.mangadex');
      final SourceProvider provider = register(
        _SlowClient(replay, const Duration(seconds: 2)),
        defaultsFor: (_) => <String, dynamic>{
          'login': Uint8List.fromList(<int>[2, 0x7B, 0x7D]),
        },
      );
      final ArtifactLease lease = await admit(_sources.first);
      final SourcePackage package = (await provider.openPackage(
        lease,
        SettingsSnapshot(),
      )).valueOrNull!;
      try {
        final SourceSession session = package.sessions.single;
        final cancel = CancellationSource();
        final watch = Stopwatch()..start();
        final Future<SourceOutcome<SearchPage>> pending = session.search(
          const SearchRequest(query: 'Onimai'),
          cancel: cancel.token,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        cancel.cancel('user');
        final SourceOutcome<SearchPage> cancelled = await pending.timeout(
          _noHang,
        );
        final int cancelMs = watch.elapsedMilliseconds;
        expect(cancelled.failureOrNull, isA<CancelledFailure>());
        expect(
          cancelMs,
          lessThan(2000),
          reason: 'answered before the delayed response arrived',
        );

        // The plugin call finishes in the background; the next call waits for it.
        final SourceOutcome<SearchPage> next = await session
            .search(const SearchRequest(query: 'Onimai'))
            .timeout(_noHang);
        expect(next.valueOrNull?.hits, isNotEmpty);
        expect(replay.misses, isEmpty);
        _receipt('cancel-in-flight', <String, Object?>{
          'failure': cancelled.failureOrNull!.code,
          'answeredAfterMs': cancelMs,
          'nextCallHits': next.valueOrNull!.hits.length,
        });
      } finally {
        await package.close();
        lease.release();
      }
    },
  );

  Future<SourceSession> openSynthetic(Uint8List aix, http.Client client) async {
    final SourcePackage package = (await register(
      client,
    ).openPackage(_Artifact(aix), SettingsSnapshot())).valueOrNull!;
    addTearDown(package.close);
    return package.sessions.single;
  }

  testWidgets(
    '4. a WASM trap is a typed source error and the session survives',
    (_) async {
      final SourceSession session = await openSynthetic(
        SyntheticAix.trapInSearch(),
        _noNetwork,
      );
      final codes = <String>[];
      for (var i = 0; i < 2; i++) {
        final SourceFailure? failure =
            (await session
                    .search(const SearchRequest(query: 'x'))
                    .timeout(_noHang))
                .failureOrNull;
        expect(failure, isA<SourceErrorFailure>());
        expect(failure!.message, contains('unreachable'));
        codes.add(failure.code);
      }
      _receipt('wasm-trap', <String, Object?>{'failures': codes});
    },
  );

  testWidgets(
    '5. isolate death fails calls with a typed failure, never a port.first hang',
    (_) async {
      final SourceSession session = await openSynthetic(
        SyntheticAix.trapInStart(),
        _noNetwork,
      );
      final codes = <String>[];
      final watch = Stopwatch()..start();
      for (var i = 0; i < 2; i++) {
        final SourceFailure? failure =
            (await session
                    .search(const SearchRequest(query: 'x'))
                    .timeout(_noHang))
                .failureOrNull;
        expect(failure, isA<RuntimeUnavailableFailure>());
        codes.add(failure!.code);
      }
      _receipt('isolate-death', <String, Object?>{
        'failures': codes,
        'elapsedMs': watch.elapsedMilliseconds,
      });
    },
  );

  testWidgets('6. response headers and rate limiting behave as on desktop', (
    _,
  ) async {
    final client = _ProbeServer();
    final List<DateTime> sent = client.sent;
    final SourceSession session = await capturePrints(
      () => openSynthetic(SyntheticAix.headerProbe(), client),
    );
    const calls = 5;
    for (var i = 0; i < calls; i++) {
      await capturePrints(
        () => session.search(const SearchRequest(query: 'x')).timeout(_noHang),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final List<String> values = printed
        .where((String l) => l.startsWith('[wasm] [aidoku] '))
        .map(
          (String l) =>
              l.split('\n').first.substring('[wasm] [aidoku] '.length),
        )
        .toList();
    expect(values, <String>[for (var i = 1; i <= calls; i++) 'value-$i']);
    expect(sent, hasLength(calls));
    final gaps = <int>[
      for (var i = SyntheticAix.probePermits; i < calls; i++)
        sent[i].difference(sent[i - SyntheticAix.probePermits]).inMilliseconds,
    ];
    for (final gap in gaps) {
      expect(
        gap,
        greaterThanOrEqualTo(SyntheticAix.probePeriodSeconds * 1000 - 20),
      );
    }
    _receipt('headers-rate-limit', <String, Object?>{
      'headerValues': values,
      'rateLimit':
          '${SyntheticAix.probePermits}/${SyntheticAix.probePeriodSeconds}s',
      'windowGapsMs': gaps,
    });
  });

  _tachiCases();
}

// ---------------------------------------------------------------------------
// U11: original Tachi APK sources in the `:source_runtime` service (KTD17,
// KTD18, KTD19). The shared protocol worker runs in the service; the app
// drives it with the desktop WorkerSupervisor through AndroidTachiBackend, and
// tachi_plugin_loader's catalog, trust gate and artifact cache compose over it
// unchanged (artifact policy forced to APK). The pinned keiyoushi APKs and
// their site captures reach the device only through the plugin's debug asset
// folder; the worker replays the captures over a fail-closed loopback
// transport, and service-process WebViews go through a refusing loopback
// proxy, so no request reaches a server. Each case prints `U11_RECEIPT {json}`.
// ---------------------------------------------------------------------------

const List<String> _tachiPackages = <String>[
  'all.mangadex',
  'en.weebcentral',
  'all.mangafire',
];

/// Chapter counts of the hit the desktop captured proof fetched.
const Map<String, int> _tachiChapters = <String, int>{
  'eu.kanade.tachiyomi.extension.all.mangadex': 15,
  'eu.kanade.tachiyomi.extension.en.weebcentral': 114,
  'eu.kanade.tachiyomi.extension.all.mangafire': 86,
};

/// The source the desktop captured proof searched in each package (CapturedProofTest).
const Map<String, String> _tachiSearched = <String, String>{
  'eu.kanade.tachiyomi.extension.all.mangadex': '2499283573021220255',
  'eu.kanade.tachiyomi.extension.en.weebcentral': '2131019126180322627',
  'eu.kanade.tachiyomi.extension.all.mangafire': '6084907896154116083',
};

void _tachiReceipt(String scenario, Map<String, Object?> data) {
  print(
    'U11_RECEIPT ${jsonEncode(<String, Object?>{'scenario': scenario, 'evidence': 'emulator', ...data})}',
  );
}

T _ok<T>(SourceOutcome<T> outcome, String what) {
  if (outcome case SourceFailed<T>(:final SourceFailure failure)) {
    fail('$what failed: ${failure.code}: ${failure.message}');
  }
  return outcome.valueOrNull as T;
}

/// The `:source_runtime` diagnostics (gate channel, separate binding).
Future<Map<String, Object?>> _diagnostics([
  Map<String, Object?> args = const <String, Object?>{},
]) async {
  final gate = AndroidSourceRuntime();
  try {
    await gate.bind().timeout(_noHang);
    return jsonDecode(
      await gate.call('diagnostics', jsonEncode(args)).timeout(_noHang),
    ) as Map<String, Object?>;
  } finally {
    gate.dispose();
  }
}

/// One conversion's Tachi stack on Android: backend → scope → TachiRuntime.
///
/// Serves the keiyoushi captures and, with `fixtures`, the synthetic U11
/// fixture repository (`fixtures/source_captures/tachi-android/`, test-only
/// signer) from the debug asset folder.
final class _TachiStack {
  _TachiStack(
    this.root, {
    List<String> extraArguments = const <String>[],
    bool fixtures = false,
  }) {
    captures = <TachiCapture>[
      for (final String name in _tachiPackages)
        TachiCapture(Directory(copyFixtureAssetDirectory(name))),
    ];
    repository = FixtureRepository(
      baseUrl: keiyoushiRepository,
      captures: captures,
    );
    final repositories = <FixtureRepository>[repository];
    if (fixtures) {
      final String dir = copyFixtureAssetDirectory('android-fixtures');
      final summary = jsonDecode(
        File('$dir/fixtures.json').readAsStringSync(),
      ) as Map<String, Object?>;
      fixtureDirectory = dir;
      fixtureRepository = FixtureRepository(
        baseUrl: Uri.parse(summary['repository']! as String),
        name: 'U11 fixtures',
        fingerprint: summary['signingKeyFingerprint']! as String,
        captures: <TachiCapture>[
          for (final String pkg
              in (summary['packages']! as Map<String, Object?>).keys)
            TachiCapture(Directory('$dir/$pkg')),
        ],
      );
      repositories.add(fixtureRepository!);
    }
    backend = AndroidTachiBackend(
      arguments: <String>[
        for (final String name in _tachiPackages) ...<String>['--replay', name],
        // The worker refuses it where WebViews cannot be blocked (U14); the
        // WebView cases skip there.
        if (_webViewOffline == null) '--offline-browser',
        ...extraArguments,
      ],
    );
    scope = backend.scope(onLog: logs.add);
    fetch = FixtureFetch(repositories);
    catalog = TachiCatalog(fetch.call);
    runtime = TachiRuntime(
      worker: () => scope.worker(WorkerKind.jvm),
      store: TachiArtifactStore(
        cache: ArtifactCache(Directory('${root.path}/cache')),
        fetch: fetch.call,
      ),
      catalog: catalog,
      policy: const TachiArtifactPolicy(all: TachiArtifactKind.apk),
    );
  }

  final Directory root;
  late final List<TachiCapture> captures;
  late final AndroidTachiBackend backend;
  late final ConversionRuntimeScope scope;
  late final FixtureRepository repository;
  FixtureRepository? fixtureRepository;
  String? fixtureDirectory;
  late final FixtureFetch fetch;
  late final TachiCatalog catalog;
  late final TachiRuntime runtime;
  final List<String> logs = <String>[];

  FixtureRepository _repositoryOf(String packageId) =>
      packageId.startsWith('fixture.android.')
      ? fixtureRepository!
      : repository;

  /// The approved trust anchor of [packageId]'s repository.
  TachiTrustIdentity trustOf(String packageId) {
    final FixtureRepository r = _repositoryOf(packageId);
    return TachiTrustIdentity(
      repository: r.baseUrl,
      fingerprint: r.fingerprint,
    );
  }

  Future<WorkerSupervisor> supervisor() async =>
      _ok(await scope.worker(WorkerKind.jvm), 'worker start');

  Future<TachiPackageListing> listing(String packageId) async {
    final FixtureRepository r = _repositoryOf(packageId);
    return (await catalog.fetchPackages(
      await catalog.fetchRepository(r.baseUrl),
    )).firstWhere(
      (TachiPackageListing l) => l.packageId == packageId,
    );
  }

  Future<SourceOutcome<TachiPreparedArtifact>> prepare(
    TachiPackageListing l, {
    TachiTrustIdentity? withTrust,
  }) => runtime.prepare(
    l,
    _ok(runtime.policy.select(l), 'artifact choice'),
    trust: withTrust ?? trustOf(l.packageId),
  );

  Future<SourceOutcome<SourcePackage>> tryOpen(
    TachiPackageListing l, {
    SettingsSnapshot? settings,
  }) async {
    final SourceOutcome<TachiPreparedArtifact> prepared = await prepare(l);
    if (prepared case SourceFailed<TachiPreparedArtifact>(
      :final SourceFailure failure,
    )) {
      return SourceFailed<SourcePackage>(failure);
    }
    return runtime.openPackage(
      prepared.valueOrNull!,
      settings ?? SettingsSnapshot(),
    );
  }

  Future<TachiSourcePackage> open(
    TachiPackageListing l, {
    SettingsSnapshot? settings,
  }) async =>
      _ok(await tryOpen(l, settings: settings), 'open ${l.packageId}')
          as TachiSourcePackage;

  Future<TachiSourcePackage> openId(
    String packageId, {
    SettingsSnapshot? settings,
  }) async => open(await listing(packageId), settings: settings);

  /// The session the desktop captured proof searched (or a fixture's first source).
  TachiSourceSession first(TachiSourcePackage package, TachiPackageListing l) =>
      package.sessions.firstWhere(
        (TachiSourceSession s) =>
            s.identity.sourceId ==
            (_tachiSearched[l.packageId] ?? l.sources.first.id.decimal),
      );

  Future<void> close() => scope.close();
}

/// Worker start, reloads and replayed rate limits take longer than the default 30 s.
const Timeout _tachiTimeout = Timeout(Duration(minutes: 4));

/// See [webViewOfflineUnavailable]; set by the Tachi group.
String? _webViewOffline;

/// Skips a case that loads pages in a WebView where they cannot be kept off
/// the network.
bool _skipWithoutOfflineWebView() {
  final String? reason = _webViewOffline;
  if (reason == null) return false;
  markTestSkipped('WebView network cannot be blocked here: $reason');
  return true;
}

void _tachiCases() {
  late Directory root;

  setUpAll(() async => _webViewOffline = await webViewOfflineUnavailable());

  setUp(() {
    root = Directory.systemTemp.createTempSync('u11_tachi');
  });

  tearDown(() async {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('tachi: three pinned APKs load in one service with exact source IDs and replay search/details/chapters', () async {
    final stack = _TachiStack(root);
    try {
      final WorkerSupervisor supervisor = await stack.supervisor();
      final HandshakeResponse handshake = supervisor.handshake!;
      expect(handshake.worker, 'tachi-android');
      expect(
        handshake.pid,
        isNot(pid),
        reason: 'the worker runs in the :source_runtime process, not the app',
      );
      final results = <String, Object?>{};
      for (final TachiCapture capture in stack.captures) {
        final TachiPackageListing l = await stack.listing(capture.packageId);
        final clock = Stopwatch()..start();
        final TachiSourcePackage package = await stack.open(l);
        final int loadMs = clock.elapsedMilliseconds;
        final loaded = <String>{
          for (final TachiSourceSession s in package.sessions)
            s.identity.sourceId,
        };
        final indexed = <String>{
          for (final TachiIndexSource s in l.sources) s.id.decimal,
        };
        expect(
          loaded,
          indexed,
          reason: '${l.packageId}: enumerated source IDs equal the index',
        );
        expect(package.sessions, hasLength(l.sources.length));
        final TachiSourceSession session = stack.first(package, l);
        clock.reset();
        final SearchPage page = _ok(
          await session.search(const SearchRequest(query: 'Onimai')),
          'search',
        );
        final int searchMs = clock.elapsedMilliseconds;
        expect(page.hits, isNotEmpty);
        clock.reset();
        final MangaSnapshot snapshot = _ok(
          await session.fetchManga(page.hits.first.ref.withHandle(null)),
          'details',
        );
        final int detailsMs = clock.elapsedMilliseconds;
        expect(snapshot.chapters, hasLength(_tachiChapters[l.packageId]));
        results[l.packageId] = <String, Object?>{
          'artifactSha256': package.artifact.input.sha256,
          'sources': loaded.length,
          'searchedSource': session.identity.sourceId,
          'hits': page.hits.length,
          'title': snapshot.metadata.title,
          'chapters': snapshot.chapters.length,
          'loadMs': loadMs,
          'searchMs': searchMs,
          'detailsMs': detailsMs,
        };
      }
      final Map<String, Object?> d = await _diagnostics();
      final debug = d['debug']! as Map<String, Object?>;
      expect(
        debug['replayMisses'],
        isEmpty,
        reason: 'every request was served from the captures',
      );
      expect(
        d['liveLoaders'],
        3,
        reason: 'one class loader per package in the single service',
      );
      expect(
        d['pid'],
        handshake.pid,
        reason: 'all three packages live in the one service process',
      );
      _tachiReceipt('qualification-apks', <String, Object?>{
        'worker': handshake.worker,
        'protocolMinor': handshake.protocolMinor,
        'packages': results,
        'liveLoaders': d['liveLoaders'],
        'replayServed': debug['replayServed'],
        'replayMisses': debug['replayMisses'],
        'descriptorFramesSent': d['descriptorFramesSent'],
        'prepareCount': stack.runtime.prepareCount,
      });
    } finally {
      await stack.close();
    }
  }, timeout: _tachiTimeout);

  test('tachi: two repositories share one service with distinct loaders; duplicate source IDs are rejected', () async {
    final stack = _TachiStack(root, fixtures: true);
    try {
      final TachiSourcePackage weeb = await stack.openId(
        'eu.kanade.tachiyomi.extension.en.weebcentral',
      );
      // Both fixture packages carry their own fixture.android.FixtureSource: same class name, two loaders.
      final TachiSourcePackage busy = await stack.openId(
        'fixture.android.busy',
      );
      final TachiSourcePackage dup = await stack.openId('fixture.android.dup');
      final SourceOutcome<SourcePackage> clash = await stack.tryOpen(
        await stack.listing('fixture.android.dup2'),
      );
      final SourceFailure failure = clash.failureOrNull!;
      expect(failure, isA<ArtifactIncompatibleFailure>());
      expect(failure.message, contains('fixture.android.dup2'));
      expect(failure.message, contains('fixture.android.dup '));
      expect(failure.message, contains(dup.artifact.lease.binding.sha256));
      final SearchPage hits = _ok(
        await busy.sessions.single.search(const SearchRequest(query: 'plain')),
        'busy search',
      );
      expect(hits.hits.single.title, 'ok:plain');
      final Map<String, Object?> d = await _diagnostics();
      expect(
        d['liveLoaders'],
        3,
        reason: 'weebcentral, busy and dup; the rejected dup2 left no loader',
      );
      final List<Map<String, Object?>> staged = (d['staged']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(staged, hasLength(3));
      for (final f in staged) {
        expect(
          f['mode'],
          'r--------',
          reason: '${f['name']} is staged read-only',
        );
        expect(f['canWrite'], isFalse);
      }
      _tachiReceipt('two-repositories-duplicates-staging', <String, Object?>{
        'repositories': <String>[
          stack.repository.baseUrl.toString(),
          stack.fixtureRepository!.baseUrl.toString(),
        ],
        'packages': <String>[
          weeb.artifact.packageId,
          busy.artifact.packageId,
          dup.artifact.packageId,
        ],
        'liveLoaders': d['liveLoaders'],
        'duplicateRejection': failure.message,
        'staged': staged,
      });
    } finally {
      await stack.close();
    }
  }, timeout: _tachiTimeout);

  test('tachi: a tampered or re-signed APK, or a wrong trust anchor, is rejected before any class loading', () async {
    final stack = _TachiStack(root, fixtures: true);
    try {
      await stack.supervisor();
      final Map<String, Object?> before = await _diagnostics();
      final TachiPackageListing weeb = await stack.listing(
        'eu.kanade.tachiyomi.extension.en.weebcentral',
      );
      final Uint8List original = stack.captures[1].bytesOf(
        TachiArtifactKind.apk,
      );
      final tampered = Uint8List.fromList(original);
      tampered[tampered.length ~/ 2] ^= 0x01;
      final outcomes = <String, String>{};
      stack.fetch.overrides[weeb.apkUrl!] = tampered;
      final SourceFailure tamperedFailure = (await stack.prepare(
        weeb,
      )).failureOrNull!;
      expect(tamperedFailure, isA<ArtifactIncompatibleFailure>());
      outcomes['tampered'] = tamperedFailure.message;
      stack.fetch.overrides.remove(weeb.apkUrl);
      // A fixture re-signed with an untrusted key, offered under the fixture repository's anchor.
      final TachiPackageListing busy = await stack.listing(
        'fixture.android.busy',
      );
      stack.fetch.overrides[busy.apkUrl!] = File(
        '${stack.fixtureDirectory}/resigned/fixture.android.busy-resigned.apk',
      ).readAsBytesSync();
      final SourceFailure resignedFailure = (await stack.prepare(
        busy,
      )).failureOrNull!;
      expect(resignedFailure, isA<ArtifactIncompatibleFailure>());
      expect(resignedFailure.message, contains('untrusted certificate'));
      outcomes['resigned'] = resignedFailure.message;
      stack.fetch.overrides.remove(busy.apkUrl);
      final SourceFailure wrongAnchor = (await stack.prepare(
        weeb,
        withTrust: TachiTrustIdentity(
          repository: keiyoushiRepository,
          fingerprint: stack.fixtureRepository!.fingerprint,
        ),
      )).failureOrNull!;
      expect(wrongAnchor, isA<ArtifactIncompatibleFailure>());
      outcomes['wrong-anchor'] = wrongAnchor.message;
      final Map<String, Object?> after = await _diagnostics();
      expect(
        after['liveLoaders'],
        before['liveLoaders'],
        reason: 'no class loader was created',
      );
      expect(
        after['staged'],
        isEmpty,
        reason: 'nothing was staged for loading',
      );
      _tachiReceipt('admission-rejections', <String, Object?>{
        'outcomes': outcomes,
        'liveLoaders': after['liveLoaders'],
      });
    } finally {
      await stack.close();
    }
  }, timeout: _tachiTimeout);

  test('tachi: a chapter list far beyond the Binder limit arrives intact through a validated descriptor', () async {
    final stack = _TachiStack(root, fixtures: true);
    try {
      final TachiSourcePackage big = await stack.openId('fixture.android.big');
      final TachiSourceSession session = big.sessions.single;
      final Map<String, Object?> before = await _diagnostics();
      final SearchPage page = _ok(
        await session.search(const SearchRequest(query: '20000')),
        'search',
      );
      final MangaSnapshot snapshot = _ok(
        await session.fetchManga(page.hits.single.ref.withHandle(null)),
        'details',
      );
      expect(snapshot.chapters, hasLength(20000));
      expect(snapshot.chapters.last.title, startsWith('Chapter 19999 '));
      final int approxBytes = utf8
          .encode(
            jsonEncode(<Object?>[
              for (final c in snapshot.chapters) c.toJson(),
            ]),
          )
          .length;
      expect(
        approxBytes,
        greaterThan(1024 * 1024),
        reason: 'larger than the 1 MiB Binder buffer',
      );
      final Map<String, Object?> after = await _diagnostics();
      final int sent =
          (after['descriptorFramesSent']! as int) -
          (before['descriptorFramesSent']! as int);
      expect(sent, greaterThanOrEqualTo(1));
      expect(
        after['descriptorsClosed'],
        (after['descriptorFramesSent']! as int) +
            (after['descriptorFramesReceived']! as int),
        reason: 'the service closed every descriptor it sent or received',
      );
      _tachiReceipt('descriptor-transport', <String, Object?>{
        'chapters': snapshot.chapters.length,
        'chapterJsonBytes': approxBytes,
        'serviceDescriptorFramesSent': after['descriptorFramesSent'],
        'serviceDescriptorFramesReceived': after['descriptorFramesReceived'],
        'serviceDescriptorsClosed': after['descriptorsClosed'],
      });
    } finally {
      await stack.close();
    }
  }, timeout: _tachiTimeout);

  test('tachi AE10: a CPU-looping source is killed by PID and every package rehydrates without retrying it', () async {
    // Small explicit limits (KTD25 lets tests override); the worker reports them in its handshake.
    final stack = _TachiStack(
      root,
      fixtures: true,
      // poolSize=1: the other package's request queues behind the loop.
      extraArguments: <String>[
        '--limit',
        'operationDeadlineMs=4000',
        '--limit',
        'cancelGraceMs=500',
        '--limit',
        'poolSize=1',
      ],
    );
    try {
      final TachiSourcePackage busy = await stack.openId(
        'fixture.android.busy',
      );
      final TachiSourcePackage weeb = await stack.openId(
        'eu.kanade.tachiyomi.extension.en.weebcentral',
      );
      final WorkerSupervisor supervisor = await stack.supervisor();
      final int pidBefore = supervisor.handshake!.pid!;
      final TachiSourceSession loop = busy.sessions.single;

      // Dart stays responsive: a 16 ms timer keeps ticking while the worker loops and restarts.
      final ticks = <int>[];
      final clock = Stopwatch()..start();
      final ticker = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => ticks.add(clock.elapsedMilliseconds),
      );

      final Future<SourceOutcome<SearchPage>> looping = loop.search(
        const SearchRequest(query: 'busy'),
      );
      // Queued behind the loop (pool size 1); its deadline runs from its own dispatch, not from queueing.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final Future<SourceOutcome<SearchPage>> queued = weeb.sessions.single
          .search(const SearchRequest(query: 'Onimai'));

      final SourceFailure loopFailure = (await looping.timeout(_noHang))
          .failureOrNull!;
      final SearchPage after = _ok(
        await queued.timeout(_noHang),
        'queued search across the restart',
      );
      ticker.cancel();
      expect(
        loopFailure,
        isA<TimeoutFailure>(),
        reason: 'the deadline op fails; it is not retried',
      );
      expect(after.hits, isNotEmpty);

      final WorkerRestartedEvent restart = supervisor.events
          .whereType<WorkerRestartedEvent>()
          .single;
      expect(
        restart.requeued,
        isNot(contains('search')),
        reason: 'the looping search was not re-sent',
      );
      expect(
        restart.reloadFailures,
        isEmpty,
        reason: 'every hosted package rehydrated',
      );
      final int pidAfter = supervisor.handshake!.pid!;
      expect(pidAfter, isNot(pidBefore));
      // The looping package was reloaded into the new process too, and answers.
      final SearchPage busyHits = _ok(
        await loop.search(const SearchRequest(query: 'plain')),
        'busy after restart',
      );
      expect(busyHits.hits.single.title, 'ok:plain');
      final Map<String, Object?> d = await _diagnostics();
      expect(d['pid'], pidAfter);
      expect(d['liveLoaders'], 2);
      var maxGap = 0;
      for (var i = 1; i < ticks.length; i++) {
        maxGap = ticks[i] - ticks[i - 1] > maxGap
            ? ticks[i] - ticks[i - 1]
            : maxGap;
      }
      expect(
        maxGap,
        lessThan(500),
        reason: 'the Flutter isolate stayed responsive',
      );
      _tachiReceipt('ae10-kill-rehydrate', <String, Object?>{
        'pidBefore': pidBefore,
        'pidAfter': pidAfter,
        'loopFailure': '${loopFailure.code}: ${loopFailure.message}',
        'restartReason': restart.reason,
        'requeued': restart.requeued,
        'failed': restart.failed,
        'reloadFailures': restart.reloadFailures,
        'queuedHits': after.hits.length,
        'maxDartTickGapMs': maxGap,
        'startupWipe': d['startupWipe'],
        'events': <String>[
          for (final SupervisorEvent e in supervisor.events)
            e.runtimeType.toString(),
        ],
      });
    } finally {
      await stack.close();
    }
  }, timeout: _tachiTimeout);

  test('tachi: a seeded password and an extension-written token never reach shared_prefs or other app storage', () async {
    final stack = _TachiStack(root, fixtures: true);
    final password = 'u11-secret-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final TachiSourcePackage prefs = await stack.openId(
        'fixture.android.prefs',
        settings: SettingsSnapshot(
          secrets: <String, String>{'password': password},
        ),
      );
      final TachiSourceSession session = prefs.sessions.single;
      final SearchPage page = _ok(
        await session.search(const SearchRequest(query: 'q')),
        'search',
      );
      expect(page.hits.single.title, 'password=set;token=true');
      await session.close();
      final Map<String, Object?> d = await _diagnostics(<String, Object?>{
        'needles': <String>[password, '$password-token'],
      });
      final hits = d['needleHits']! as Map<String, Object?>;
      expect(
        hits['needle0'],
        isEmpty,
        reason: 'the password is in no file under the app data directory',
      );
      expect(
        hits['needle1'],
        isEmpty,
        reason: 'the token is in no file under the app data directory',
      );
      _tachiReceipt('password-not-persisted', <String, Object?>{
        'title': page.hits.single.title,
        'needleHits': hits,
        'sharedPrefsFiles': d['sharedPrefsFiles'],
      });
    } finally {
      await stack.close();
    }
  }, timeout: _tachiTimeout);

  test('tachi: extension WebViews run in the service; cookies and web storage are wiped at session close and on service start', () async {
    if (_skipWithoutOfflineWebView()) return;
    final stack = _TachiStack(root, fixtures: true);
    try {
      final TachiSourcePackage cookies = await stack.openId(
        'fixture.android.cookies',
      );
      final WorkerSupervisor supervisor = await stack.supervisor();
      final TachiPackageListing cl = await stack.listing(
        'fixture.android.cookies',
      );
      String idOf(String name) => cl.sources
          .firstWhere((TachiIndexSource s) => s.name == name)
          .id
          .decimal;
      final TachiSourceSession a = cookies.sessions.firstWhere(
        (s) => s.identity.sourceId == idOf('Android Cookies A'),
      );
      final TachiSourceSession b = cookies.sessions.firstWhere(
        (s) => s.identity.sourceId == idOf('Android Cookies B'),
      );
      final String setTitle = _ok(
        await a.search(const SearchRequest(query: 'set:alpha')),
        'A set',
      ).hits.single.title;
      expect(
        setTitle,
        startsWith('webview=fixture:42;pid=${supervisor.handshake!.pid};'),
        reason: 'a real WebView in :source_runtime',
      );
      expect(setTitle, endsWith('cookies=k'));
      // Web storage (U12, carried from U11): stored in the same shared profile.
      Future<Map<String, Object?>> storage([String? set]) async =>
          (await _diagnostics(<String, Object?>{
                'webStorage': <String, Object?>{
                  'origin': 'https://cookies.test/',
                  'set': ?set,
                },
              }))['webStorage']!
              as Map<String, Object?>;
      final Map<String, Object?> stored = await storage('kept');
      expect(stored['value'], '"kept"');
      // One shared profile: until A's session closes, B sees A's cookie (isolation is reported unavailable).
      final String sharedTitle = _ok(
        await b.search(const SearchRequest(query: 'get')),
        'B get',
      ).hits.single.title;
      final Map<String, Object?> d1 = await _diagnostics(<String, Object?>{
        'cookieUrls': <String>['https://cookies.test/'],
      });
      final isolation = d1['browserIsolation']! as Map<String, Object?>;
      expect(isolation['sourceBrowserIsolation'], 'unavailable');
      await a.close();
      final String afterClose = _ok(
        await b.search(const SearchRequest(query: 'get')),
        'B get after close',
      ).hits.single.title;
      expect(
        afterClose,
        endsWith('cookies='),
        reason: "A's session close wiped the shared WebView profile",
      );
      final Map<String, Object?> storageAfterClose = await storage();
      expect(
        storageAfterClose['value'],
        'null',
        reason: "A's session close wiped web storage",
      );
      final Map<String, Object?> d2 = await _diagnostics(<String, Object?>{
        'cookieUrls': <String>['https://cookies.test/'],
      });
      expect(
        (d2['cookieNames']! as Map<String, Object?>)['https://cookies.test/'],
        isEmpty,
      );

      // Service start wipe: leave a cookie behind, kill the process, and check the next start removed the data.
      _ok(await b.search(const SearchRequest(query: 'set:beta')), 'B set');
      expect((await storage('left-behind'))['value'], '"left-behind"');
      expect(supervisor.events.whereType<WorkerRestartedEvent>(), isEmpty);
      final gate = AndroidSourceRuntime();
      await gate.bind().timeout(_noHang);
      gate.kill();
      gate.dispose();
      final String afterRestart = _ok(
        await b.search(const SearchRequest(query: 'get')),
        'B get after restart',
      ).hits.single.title;
      expect(supervisor.events.whereType<WorkerRestartedEvent>(), hasLength(1));
      expect(
        afterRestart,
        endsWith('cookies='),
        reason: 'the restarted service wiped the WebView data first',
      );
      final Map<String, Object?> d3 = await _diagnostics();
      expect(d3['startupWipe'], contains('app_webview_source_runtime'));
      final Map<String, Object?> storageAfterRestart = await storage();
      expect(
        storageAfterRestart['value'],
        'null',
        reason: 'the restarted service wiped web storage first',
      );
      // Offline proof: a WebView page load in the service process reaches only the refusing loopback proxy.
      final String net = _ok(
        await b.search(const SearchRequest(query: 'net')),
        'B net',
      ).hits.single.title;
      final Map<String, Object?> d4 = await _diagnostics();
      final List<String> refused =
          ((d4['debug']! as Map<String, Object?>)['refusedBrowserRequests']!
                  as List<Object?>)
              .cast<String>();
      // Chromium sends the load to the host-chosen proxy (no DNS lookup of its own) and, with no DIRECT
      // fallback, fails closed when the proxy does not tunnel it.
      expect(
        net,
        anyOf(
          'net=net::ERR_PROXY_CONNECTION_FAILED',
          'net=net::ERR_TUNNEL_CONNECTION_FAILED',
        ),
      );
      expect((d4['debug']! as Map<String, Object?>)['browserProxy'], 'applied');
      _tachiReceipt('service-webview-cookies', <String, Object?>{
        'set': setTitle,
        'sharedBeforeClose': sharedTitle,
        'afterSessionClose': afterClose,
        'afterRestart': afterRestart,
        'webStorage': <String, Object?>{
          'stored': stored,
          'afterSessionClose': storageAfterClose,
          'afterRestart': storageAfterRestart,
        },
        'browserIsolation': isolation,
        'cookieNamesBeforeClose': d1['cookieNames'],
        'startupWipe': d3['startupWipe'],
        'webViewDataDirs': d3['webViewDataDirs'],
        'proxyCheck': net,
        'refusedBrowserRequests': refused,
      });
    } finally {
      await stack.close();
    }
  }, timeout: _tachiTimeout);

  test('tachi AE11: MangaFire runWebViewBlocking builds a real WebView in the service process (replayed challenge)', () async {
    if (_skipWithoutOfflineWebView()) return;
    final stack = _TachiStack(
      root,
      extraArguments: <String>['--challenge-once', '/api/titles'],
    );
    try {
      final TachiPackageListing l = await stack.listing(
        'eu.kanade.tachiyomi.extension.all.mangafire',
      );
      final TachiSourcePackage mangafire = await stack.open(
        l,
        settings: SettingsSnapshot(
          values: const <String, Object>{'solve_captcha': true},
        ),
      );
      final WorkerSupervisor supervisor = await stack.supervisor();
      final TachiSourceSession session = stack.first(mangafire, l);
      final clock = Stopwatch()..start();
      final SourceOutcome<SearchPage> outcome = await session
          .search(const SearchRequest(query: 'Onimai'))
          .timeout(
            const Duration(minutes: 3),
          );
      final int searchMs = clock.elapsedMilliseconds;
      final Map<String, Object?> d = await _diagnostics();
      final debug = d['debug']! as Map<String, Object?>;
      final List<String> refused =
          (debug['refusedBrowserRequests']! as List<Object?>).cast<String>();
      _tachiReceipt('ae11-mangafire-webview', <String, Object?>{
        'outcome': switch (outcome) {
          SourceSuccess<SearchPage>(:final SearchPage value) =>
            'success: ${value.hits.length} hits',
          SourceFailed<SearchPage>(:final SourceFailure failure) =>
            '${failure.code}: ${failure.message}',
        },
        'searchMs': searchMs,
        'challengesServed': debug['challengesServed'],
        'refusedBrowserRequests': refused,
        'replayMisses': debug['replayMisses'],
        'servicePid': d['pid'],
        'webViewDataDirs': d['webViewDataDirs'],
        'workerLog': stack.logs
            .where((String l) => !l.contains('capture miss'))
            .take(40)
            .toList(),
      });
      expect(debug['challengesServed'], 1, reason: 'the captcha 403 fired');
      final List<Map<String, Object?>> dirs =
          (d['webViewDataDirs']! as List<Object?>).cast<Map<String, Object?>>();
      expect(
        dirs.where(
          (Map<String, Object?> e) =>
              e['name'] == 'app_webview_source_runtime' &&
              (e['bytes']! as int) > 0,
        ),
        isNotEmpty,
        reason: "the extension's WebView ran in the :source_runtime process (its suffixed data directory)",
      );
      expect(d['pid'], supervisor.handshake!.pid);
    } finally {
      await stack.close();
    }
  }, timeout: _tachiTimeout);

  test('tachi: JNI global references return to baseline after repeated worker start and close', () async {
    Future<void> cycle() async {
      final stack = _TachiStack(root);
      await stack.supervisor();
      await stack.close();
    }

    await cycle(); // warm-up
    Map<String, Object?> sample() =>
        AndroidSourceRuntime.jniGlobalReferenceSummary();
    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    await settle();
    final Map<String, Object?> before = sample();
    const rounds = 10;
    for (var i = 0; i < rounds; i++) {
      await cycle();
    }
    int owned(Map<String, Object?> s) {
      final Map<String, Object?> classes =
          (s['classes'] as Map<String, Object?>?) ?? const <String, Object?>{};
      var n = 0;
      for (final MapEntry<String, Object?> e in classes.entries) {
        if (e.key.contains('sourceruntime') ||
            e.key.contains('jni') ||
            e.key.contains('Proxy')) {
          n += e.value! as int;
        }
      }
      return n;
    }

    // References owned by package:jni listeners are released when the Java
    // proxy and the Dart side are both collected; give both GCs a bounded
    // chance (Dart: allocation pressure; Java: the summary runs its GC).
    Map<String, Object?> after = sample();
    for (var i = 0; i < 20 && owned(after) - owned(before) > 2; i++) {
      final garbage = <List<int>>[
        for (var j = 0; j < 64; j++) List<int>.filled(1 << 16, j),
      ];
      expect(garbage, hasLength(64));
      await settle();
      after = sample();
    }
    final total0 = before['total']! as int;
    final total1 = after['total']! as int;
    final Map<String, Object?> c0 =
        (before['classes'] as Map<String, Object?>?) ??
        const <String, Object?>{};
    final Map<String, Object?> c1 =
        (after['classes'] as Map<String, Object?>?) ??
        const <String, Object?>{};
    final delta = <String, int>{
      for (final String k in <String>{...c0.keys, ...c1.keys})
        if (((c1[k] as int?) ?? 0) != ((c0[k] as int?) ?? 0))
          k: ((c1[k] as int?) ?? 0) - ((c0[k] as int?) ?? 0),
    };
    _tachiReceipt('jni-references', <String, Object?>{
      'rounds': rounds,
      'totalBefore': total0,
      'totalAfter': total1,
      'ownedBefore': owned(before),
      'ownedAfter': owned(after),
      'classDelta': delta,
    });
    expect(
      owned(after) - owned(before),
      lessThanOrEqualTo(2),
      reason: 'facade and listener references are released',
    );
    expect(total1, lessThan(50000));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('tachi: a visible challenge opens in the :source_runtime challenge Activity; non-web URLs are refused', () async {
    if (_skipWithoutOfflineWebView()) return;
    final stack = _TachiStack(root);
    try {
      final WorkerSupervisor supervisor = await stack.supervisor();
      final gate = AndroidSourceRuntime();
      await gate.bind().timeout(_noHang);
      try {
        final refused = jsonDecode(
          await gate.call(
            'showChallenge',
            jsonEncode(<String, Object?>{
              'url': 'file:///data/local/tmp/x.html',
            }),
          ),
        ) as Map<String, Object?>;
        expect(refused['result'], 'capability-unavailable');
        final shown = jsonDecode(
          await gate.call(
            'showChallenge',
            jsonEncode(<String, Object?>{
              'url': 'https://proxy-check.invalid/',
            }),
          ),
        ) as Map<String, Object?>;
        expect(shown['result'], 'shown');
        expect(
          shown['activityPid'],
          supervisor.handshake!.pid,
          reason: 'the challenge Activity runs in :source_runtime',
        );
        // Held on screen briefly so the run can be watched or captured.
        await Future<void>.delayed(const Duration(seconds: 8));
        final closed = jsonDecode(
          await gate.call('closeChallenge'),
        ) as Map<String, Object?>;
        expect(closed['result'], 'closed');
        _tachiReceipt('challenge-activity', <String, Object?>{
          'fileUrl': refused,
          'shown': shown,
          'closed': closed,
          'workerPid': supervisor.handshake!.pid,
        });
      } finally {
        gate.dispose();
      }
    } finally {
      await stack.close();
    }
  }, timeout: _tachiTimeout);

  // KTD25: measures the inputs of the Android sizing rule on this device. The
  // results (U11_BENCH lines) are committed under
  // docs/validation/source-runners/android/ and the rule in
  // tools/tachi-source-runner/android/src/main/resources/tachi-worker-sizing.json
  // is derived from them. Emulator values are provisional (R16).
  test('tachi benchmark: dispatch, operations, handshake, cancel, kill-to-rebind and shutdown', () async {
    List<int> sorted(List<int> v) => v.toList()..sort();
    int pct(List<int> v, double p) => sorted(v)[((v.length - 1) * p).round()];
    Map<String, Object?> stats(List<int> v) => <String, Object?>{
      'n': v.length,
      'p50': pct(v, 0.5),
      'p99': pct(v, 0.99),
      'max': sorted(v).last,
    };
    final handshake = <int>[];
    final shutdown = <int>[];
    final dispatch = <int>[];
    final operations = <int>[];
    final cancelSettle = <int>[];
    final killToRebind = <int>[];
    final rehydrate = <int>[];
    for (var round = 0; round < 3; round++) {
      final stack = _TachiStack(
        root,
        fixtures: true,
        extraArguments: <String>['--limit', 'cancelGraceMs=30000'],
      );
      final clock = Stopwatch()..start();
      final WorkerSupervisor supervisor = await stack.supervisor();
      handshake.add(clock.elapsedMilliseconds);
      final TachiSourcePackage busy = await stack.openId(
        'fixture.android.busy',
      );
      for (var i = 0; i < 30; i++) {
        clock.reset();
        _ok(
          await busy.sessions.single.search(SearchRequest(query: 'p$i')),
          'dispatch',
        );
        dispatch.add(clock.elapsedMilliseconds);
      }
      final packages = <TachiSourcePackage>[];
      for (final String id in _tachiChapters.keys) {
        final TachiPackageListing l = await stack.listing(id);
        final TachiSourcePackage p = await stack.open(l);
        packages.add(p);
        final TachiSourceSession s = stack.first(p, l);
        clock.reset();
        final SearchPage page = _ok(
          await s.search(const SearchRequest(query: 'Onimai')),
          'search',
        );
        operations.add(clock.elapsedMilliseconds);
        clock.reset();
        _ok(
          await s.fetchManga(page.hits.first.ref.withHandle(null)),
          'details',
        );
        operations.add(clock.elapsedMilliseconds);
      }
      // Cooperative cancel of an in-flight replayed details call.
      final TachiSourceSession weeb = packages[1].sessions.single;
      final SearchPage hits = _ok(
        await weeb.search(const SearchRequest(query: 'Onimai')),
        'search',
      );
      final cancel = CancellationSource();
      final Future<SourceOutcome<MangaSnapshot>> inFlight = weeb.fetchManga(
        hits.hits.first.ref.withHandle(null),
        cancel: cancel.token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      clock.reset();
      cancel.cancel();
      await inFlight;
      cancelSettle.add(clock.elapsedMilliseconds);
      // Kill by PID → death → rebind → handshake → reload of the four hosted packages.
      final int events = supervisor.events.length;
      final gate = AndroidSourceRuntime();
      await gate.bind().timeout(_noHang);
      clock.reset();
      gate.kill();
      gate.dispose();
      while (supervisor.events.whereType<WorkerStartedEvent>().length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      killToRebind.add(clock.elapsedMilliseconds);
      while (supervisor.events
          .skip(events)
          .whereType<WorkerRestartedEvent>()
          .isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      rehydrate.add(clock.elapsedMilliseconds);
      clock.reset();
      await stack.close();
      shutdown.add(clock.elapsedMilliseconds);
    }
    final Map<String, Object?> d = await _diagnostics();
    print(
      'U11_BENCH ${jsonEncode(<String, Object?>{
        'evidence': 'emulator',
        'device': 'Pixel_9_Pro AVD, Android 16 (API 36), x86_64',
        'cores': Platform.numberOfProcessors,
        'handshakeMs': stats(handshake),
        'dispatchRoundTripMs': stats(dispatch),
        'qualificationOperationMs': stats(operations),
        'cancelSettleMs': stats(cancelSettle),
        'killToRebindMs': stats(killToRebind),
        'killToRehydratedMs': stats(rehydrate),
        'shutdownMs': stats(shutdown),
        'servicePidAfter': d['pid'],
      })}',
    );
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('tachi: the production configuration (no debug arguments) starts, handshakes and shuts down', () async {
    // Default backend: live transport, no replay, no proxy override. No package is
    // loaded, so nothing can reach a server.
    final backend = AndroidTachiBackend();
    final ConversionRuntimeScope scope = backend.scope();
    try {
      final WorkerSupervisor supervisor = _ok(
        await scope.worker(WorkerKind.jvm),
        'worker start',
      );
      final HandshakeResponse handshake = supervisor.handshake!;
      expect(handshake.worker, 'tachi-android');
      expect(handshake.pid, isNot(pid));
      expect(
        supervisor.limits!.operationDeadline,
        const Duration(milliseconds: 133260),
      );
      expect(
        supervisor.limits!.shutdownGrace,
        const Duration(milliseconds: 2075),
      );
      _tachiReceipt('production-start', <String, Object?>{
        'arguments': backend.arguments,
        'worker': handshake.worker,
        'limits': <String, Object?>{
          'poolSize': supervisor.limits!.maxConcurrentPackages,
          'operationDeadlineMs':
              supervisor.limits!.operationDeadline.inMilliseconds,
          'cancelGraceMs': supervisor.limits!.cancelGrace.inMilliseconds,
          'shutdownGraceMs': supervisor.limits!.shutdownGrace.inMilliseconds,
        },
      });
    } finally {
      await scope.close();
    }
  }, timeout: _tachiTimeout);

  registerU12Cases();
  registerU14Cases();
  registerBackgroundCases();
}
