// U13: the Aidoku runner on Android (KTD22). Runs on an Android device or
// emulator:
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

// ignore_for_file: avoid_print, implementation_imports

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
import 'package:source_runtime_android/src/aidoku_backend.dart';

import 'aidoku_fixture_bundle.g.dart';

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
}
