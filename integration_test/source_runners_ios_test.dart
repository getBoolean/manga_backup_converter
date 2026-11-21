// U9 qualification of the local iOS Tachi runtime (KTD11, KTD12, KTD23; AE7, AE8; R13, R14, R18).
//
// Runs inside the app on the iOS Simulator (and, later, a physical iPhone):
//
//   tools/tachi-source-runner/ios/scripts/stage_runtime.sh iphonesimulator --test
//   flutter test integration_test/source_runners_ios_test.dart -d <udid>
//
// Every source request is replayed from the committed captures under
// fixtures/source_captures/tachi in fail-closed mode: nothing reaches a server.
// Each case prints one `U9_RECEIPT {json}` line and the whole run is also in
// `binding.reportData`. Receipts carry `evidenceClass`, which is `simulator`
// unless the run is on a device.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_ios/source_runtime_ios.dart';

const String _keiyoushiSigner = '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2';

/// One AE7 qualification source.
final class _Qualification {
  const _Qualification(this.dir, this.artifactStem, this.querySourceId, this.minChapters);

  final String dir;
  final String artifactStem;
  final String querySourceId;
  final int minChapters;
}

const List<_Qualification> _sources = <_Qualification>[
  _Qualification('all.mangadex', 'tachiyomi-all.mangadex-v1.6.4', '2499283573021220255', 1),
  _Qualification('en.weebcentral', 'tachiyomi-en.weebcentral-v1.6.27', '2131019126180322627', 100),
  _Qualification('all.mangafire', 'tachiyomi-all.mangafire-v1.6.38', '6084907896154116083', 50),
];

const String _query = 'Onimai';

/// Diagnostic: start the VM without `--illegal-native-access=deny` to show the
/// baked java.base native-load guard on its own (never the shipping setting).
// ignore: do_not_use_environment
const bool _guardOnly = bool.fromEnvironment('U9_GUARD_ONLY');

void main() {
  final IntegrationTestWidgetsFlutterBinding binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final receipts = <Map<String, Object?>>[];
  final logs = <String>[];
  final platformMessages = <String>[];
  late BundledRuntime bundle;
  late IosJvmRuntime runtime;
  late Directory work;
  late ArtifactCache cache;
  late int baselineGlobalRefs;
  late int baselineImages;
  late String testSigner;
  late IosTachiBackend qualification;
  final evidenceClass = Platform.resolvedExecutable.contains('/CoreSimulator/') ? 'simulator' : 'device';

  void receipt(String name, Map<String, Object?> data) {
    final r = <String, Object?>{'case': name, 'evidenceClass': evidenceClass, ...data};
    receipts.add(r);
    // ignore: avoid_print
    print('U9_RECEIPT ${jsonEncode(r)}');
  }

  String data(String rel) => '${bundle.testData}/$rel';

  Uint8List artifact(_Qualification q, String kind) => File(data('${q.dir}/${q.artifactStem}.$kind')).readAsBytesSync();

  List<String> expectedSourceIds(_Qualification q) {
    final entry = jsonDecode(File(data('${q.dir}/index-entry.json')).readAsStringSync()) as Map<String, Object?>;
    return <String>[
      for (final Object? s in entry['sources']! as List<Object?>) (s! as Map<String, Object?>)['id']! as String,
    ]..sort();
  }

  String packageIdOf(_Qualification q) {
    final entry = jsonDecode(File(data('${q.dir}/index-entry.json')).readAsStringSync()) as Map<String, Object?>;
    return entry['packageName']! as String;
  }

  String versionOf(_Qualification q) {
    final entry = jsonDecode(File(data('${q.dir}/index-entry.json')).readAsStringSync()) as Map<String, Object?>;
    return entry['versionName']! as String;
  }

  IosTachiBackend backend({
    required Duration native,
    required Duration dart,
    List<String> replay = const <String>[],
    List<String> hang = const <String>[],
    BrowserPort? browser,
    String label = 'b',
  }) => IosTachiBackend(
    runtime: runtime,
    config: IosTachiConfig(
      limits: SupervisorLimits(
        maxConcurrentPackages: 2,
        operationDeadline: dart,
        cancelGrace: const Duration(seconds: 5),
        interactionTimeout: const Duration(seconds: 30),
        shutdownGrace: const Duration(seconds: 10),
      ),
      nativeDeadline: native,
      stateRoot: Directory('${work.path}/state-$label')..createSync(recursive: true),
      cache: cache,
      replay: replay,
      replayHang: hang,
    ),
    browserPort: browser,
    onLog: (String line) {
      logs.add(line);
      // ignore: avoid_print
      print('U9_LOG $line');
    },
  );

  setUpAll(() async {
    bundle = BundledRuntime.prepare();
    expect(bundle.classPath, isNotEmpty, reason: 'stage the payload with stage_runtime.sh <sdk> --test');
    expect(bundle.testData, isNotNull, reason: 'stage the payload with stage_runtime.sh <sdk> --test');
    work = Directory.systemTemp.createTempSync('u9-');
    cache = ArtifactCache(Directory('${work.path}/cache'));
    testSigner = File(bundle.fixtures['test-signer.txt']!).readAsStringSync().trim();
    baselineImages = IosJvmRuntime.loadedImageCount;
    final sw = Stopwatch()..start();
    runtime = await IosJvmRuntime.start(
      javaHome: bundle.javaHome,
      // ignore: avoid_redundant_argument_values
      options: bundle.productionOptions(tempDirectory: work.path, denyIllegalNativeAccess: !_guardOnly),
    );
    baselineGlobalRefs = runtime.globalRefCount;
    receipt('vm-start', <String, Object?>{
      'wallMs': sw.elapsedMilliseconds,
      'start': runtime.startEvent.payload,
      'stamp': bundle.stamp,
      'classPathJars': bundle.classPath.length,
      'globalRefsAfterStart': baselineGlobalRefs,
      'imagesBeforeStart': baselineImages,
      'imagesAfterStart': IosJvmRuntime.loadedImageCount,
    });
    // Record every platform message the app sends while sources run; the
    // source runtime must not use any.
    binding.defaultBinaryMessenger.allMessagesHandler = (String channel, MessageHandler? handler, ByteData? message) {
      platformMessages.add(channel);
      return binding.defaultBinaryMessenger.delegate.send(channel, message);
    };
    qualification = backend(
      native: const Duration(minutes: 9),
      dart: const Duration(minutes: 10),
      replay: <String>[for (final _Qualification q in _sources) data(q.dir)],
      label: 'qual',
    );
  });

  tearDownAll(() async {
    binding.defaultBinaryMessenger.allMessagesHandler = null;
    await qualification.close();
    receipt('summary', <String, Object?>{
      'platformMessagesDuringRun': platformMessages.toSet().toList(),
      'vmCount': runtime.createdVmCount(),
      'globalRefs': runtime.globalRefCount,
      'baselineGlobalRefs': baselineGlobalRefs,
      'liveWorkers': InVmWorkerProcess.liveWorkers,
      'armedDeadlines': InVmWorkerProcess.armedDeadlines,
      'firedDeadlines': InVmWorkerProcess.firedDeadlines,
      'images': IosJvmRuntime.loadedImageCount,
      'replayMisses': logs.where((String l) => l.contains('capture miss')).toList(),
    });
    binding.reportData = <String, dynamic>{'receipts': receipts};
  });

  test('the worker runs in the single VM: interpreter only, iOS platform hooks, no Dart thread attached', () async {
    final SourceOutcome<WorkerSupervisor> started = await qualification.worker();
    expect(started.failureOrNull, isNull);
    final WorkerSupervisor supervisor = started.valueOrNull!;
    final HandshakeResponse hs = supervisor.handshake!;
    expect(runtime.createdVmCount(), 1);
    expect(runtime.callingThreadAttached(), isFalse);
    // The shared worker speaks 1.1 until the U3b worker merge brings 1.2.
    expect(hs.protocolMinor, greaterThanOrEqualTo(1));
    expect(hs.capabilities.apiFamilies, contains('tachi-1.6'));
    receipt('handshake', <String, Object?>{
      'worker': hs.worker,
      'protocol': '${hs.protocolVersion}.${hs.protocolMinor}',
      'apiFamilies': hs.capabilities.apiFamilies.toList()..sort(),
      'limits': hs.limits?.toJson(),
      'sizing': hs.sizing?.toJson(),
      'liveWorkers': InVmWorkerProcess.liveWorkers,
    });
  });

  // AE7: both artifact paths, exact int64 source IDs, search/details/chapters from captures.
  final results = <String, String>{};
  for (final _Qualification q in _sources) {
    for (final kind in <String>['jar', 'apk']) {
      test('AE7 ${q.dir} from the ${kind == 'jar' ? 'repository JAR' : 'APK converted on the device'}', () async {
        final trust = ArtifactTrustAnchor(signerFingerprints: const <String>[_keiyoushiSigner]);
        final sw = Stopwatch()..start();
        final SourceOutcome<IosTachiPreparedArtifact> prepared = await qualification.prepare(
          packageId: packageIdOf(q),
          bytes: artifact(q, kind),
          kind: kind,
          version: versionOf(q),
          trust: trust,
        );
        final int prepareMs = sw.elapsedMilliseconds;
        expect(prepared.failureOrNull, isNull);
        final IosTachiPreparedArtifact a = prepared.valueOrNull!;
        sw.reset();
        final SourceOutcome<SourcePackage> opened = await qualification.openPackage(a, SettingsSnapshot());
        final int loadMs = sw.elapsedMilliseconds;
        expect(opened.failureOrNull, isNull);
        final SourcePackage package = opened.valueOrNull!;
        try {
          final ids = <String>[for (final SourceSession s in package.sessions) s.identity.sourceId]..sort();
          expect(ids, expectedSourceIds(q), reason: 'exact int64 source identities');
          for (final id in ids) {
            expect(BigInt.parse(id).toString(), id);
            expect(BigInt.parse(id).bitLength, lessThanOrEqualTo(63));
          }
          final SourceSession session = package.sessions.firstWhere(
            (SourceSession s) => s.identity.sourceId == q.querySourceId,
          );
          sw.reset();
          final SourceOutcome<SearchPage> searched = await session.search(const SearchRequest(query: _query));
          final int searchMs = sw.elapsedMilliseconds;
          expect(searched.failureOrNull, isNull);
          final SearchPage page = searched.valueOrNull!;
          expect(page.hits, isNotEmpty);
          final SearchHit hit = page.hits.firstWhere(
            (SearchHit h) => h.title.toLowerCase().contains(_query.toLowerCase()),
            orElse: () => page.hits.first,
          );
          sw.reset();
          final SourceOutcome<MangaSnapshot> fetched = await session.fetchManga(hit.ref);
          final int detailsMs = sw.elapsedMilliseconds;
          expect(fetched.failureOrNull, isNull);
          final MangaSnapshot snapshot = fetched.valueOrNull!;
          expect(snapshot.chapters.length, greaterThanOrEqualTo(q.minChapters));
          // Rehydrate from the durable reference alone (no live handle).
          final SourceOutcome<MangaSnapshot> rehydrated = await session.fetchManga(hit.ref.withHandle(null));
          expect(rehydrated.valueOrNull?.chapters.length, snapshot.chapters.length);
          final String canonical = jsonEncode(<Object?>[
            <String>[for (final SearchHit h in page.hits) h.title],
            snapshot.metadata.toJson(),
            <Object?>[for (final NativeChapter c in snapshot.chapters) c.toJson()],
          ]);
          results['${q.dir}/$kind'] = canonical;
          receipt('ae7-${q.dir}-$kind', <String, Object?>{
            'sourceIds': ids,
            'querySourceId': q.querySourceId,
            'prepareMs': prepareMs,
            'loadMs': loadMs,
            'searchMs': searchMs,
            'detailsMs': detailsMs,
            'hits': page.hits.length,
            'title': snapshot.metadata.title,
            'chapters': snapshot.chapters.length,
            'resultBytes': utf8.encode(canonical).length,
            'preparedSha256': a.binding.sha256,
            'inputSha256': a.input.sha256,
          });
        } finally {
          await package.close();
        }
        if (kind == 'apk') {
          expect(results['${q.dir}/apk'], results['${q.dir}/jar'], reason: 'JAR and converted APK disagree');
        }
      }, timeout: const Timeout(Duration(minutes: 20)));
    }
  }

  test('no source request missed the committed captures', () {
    expect(logs.where((String l) => l.contains('capture miss')), isEmpty);
  });

  group('KTD5 tamper refusal', () {
    final trust = ArtifactTrustAnchor(signerFingerprints: const <String>[_keiyoushiSigner]);
    const q = _Qualification('en.weebcentral', 'tachiyomi-en.weebcentral-v1.6.27', '', 0);

    Future<SourceFailure?> prepareFailure(Uint8List bytes, String kind) async {
      final SourceOutcome<IosTachiPreparedArtifact> r = await qualification.prepare(
        packageId: packageIdOf(q),
        bytes: bytes,
        kind: kind,
        version: versionOf(q),
        trust: trust,
      );
      r.valueOrNull?.lease.release();
      return r.failureOrNull;
    }

    test('a JAR with one modified class fails verification before loading', () async {
      final Uint8List jar = artifact(q, 'jar');
      final zip = _Zip.read(jar);
      final String victim = zip.names.firstWhere((String n) => n.endsWith('.class'));
      zip.replace(victim, (Uint8List b) => Uint8List.fromList(b)..[b.length ~/ 2] ^= 0x01);
      final SourceFailure? f = await prepareFailure(zip.write(), 'jar');
      expect(f, isA<ArtifactIncompatibleFailure>());
      receipt('tamper-jar-modified', <String, Object?>{'entry': victim, 'failure': f.toString()});
    });

    test('a JAR with an appended unsigned class fails verification before loading', () async {
      final zip = _Zip.read(artifact(q, 'jar'))
        ..add('eu/kanade/tachiyomi/extension/en/weebcentral/Injected.class', _minimalClass());
      final SourceFailure? f = await prepareFailure(zip.write(), 'jar');
      expect(f, isA<ArtifactIncompatibleFailure>());
      expect(f!.message, contains('not covered by the signature'));
      receipt('tamper-jar-appended', <String, Object?>{'failure': f.toString()});
    });

    test('a tampered APK fails verification before conversion', () async {
      final zip = _Zip.read(artifact(q, 'apk'))
        ..replace('classes.dex', (Uint8List b) => Uint8List.fromList(b)..[b.length - 9] ^= 0x01);
      final SourceFailure? f = await prepareFailure(zip.write(), 'apk');
      expect(f, isA<ArtifactIncompatibleFailure>());
      expect(f!.message, contains('APK signature'));
      receipt('tamper-apk', <String, Object?>{'failure': f.toString()});
    });

    test('an APK signed by another key is refused', () async {
      final SourceFailure? f = await qualification
          .prepare(
            packageId: packageIdOf(q),
            bytes: artifact(q, 'apk'),
            kind: 'apk',
            version: versionOf(q),
            trust: ArtifactTrustAnchor(signerFingerprints: <String>[testSigner]),
          )
          .then((SourceOutcome<IosTachiPreparedArtifact> r) => r.failureOrNull);
      expect(f, isA<ArtifactIncompatibleFailure>());
      receipt('untrusted-signer', <String, Object?>{'failure': f.toString()});
    });

    test('a cached converted JAR is re-verified by digest before loading', () async {
      final SourceOutcome<IosTachiPreparedArtifact> prepared = await qualification.prepare(
        packageId: packageIdOf(q),
        bytes: artifact(q, 'apk'),
        kind: 'apk',
        version: versionOf(q),
        trust: trust,
      );
      final IosTachiPreparedArtifact a = prepared.valueOrNull!;
      final String path = await a.lease.verifiedPath();
      final file = File(path);
      final Uint8List original = file.readAsBytesSync();
      file.writeAsBytesSync(Uint8List.fromList(original)..[original.length ~/ 2] ^= 0x01);
      final SourceOutcome<SourcePackage> opened = await qualification.openPackage(a, SettingsSnapshot());
      expect(opened.failureOrNull, isA<ArtifactIncompatibleFailure>());
      file.writeAsBytesSync(original);
      receipt('tamper-cached', <String, Object?>{'failure': opened.failureOrNull.toString()});
    });
  });

  group('AE8 native deadlines', () {
    const native = Duration(milliseconds: 1500);
    late IosTachiBackend ae8;
    late IosTachiPreparedArtifact busy;
    late SourceSession session;
    late SourcePackage package;

    setUpAll(() async {
      final trust = ArtifactTrustAnchor(signerFingerprints: <String>[testSigner]);
      final SourceOutcome<IosTachiPreparedArtifact> prepared = await qualification.prepare(
        packageId: 'fixture.busy',
        bytes: File(bundle.fixtures['fixture-busy-signed.jar']!).readAsBytesSync(),
        kind: 'jar',
        version: '1',
        trust: trust,
      );
      expect(prepared.failureOrNull, isNull);
      busy = prepared.valueOrNull!;
      ae8 = backend(
        native: native,
        dart: const Duration(seconds: 8),
        replay: <String>[data('all.mangadex')],
        hang: const <String>['hang.test'],
        label: 'ae8',
      );
      final SourceOutcome<SourcePackage> opened = await ae8.openPackage(busy, SettingsSnapshot());
      expect(opened.failureOrNull, isNull);
      package = opened.valueOrNull!;
      session = package.sessions.single;
    });

    tearDownAll(() async {
      await package.close();
      await ae8.close();
    });

    Future<String> count() async =>
        (await session.search(const SearchRequest(query: 'count'))).valueOrNull!.hits.single.title;

    for (final query in <String>['busy', 'catch', 'regex', 'hang']) {
      test('"$query" stops at its native deadline and stays stopped', () async {
        final int generation = ae8.supervisor!.generation;
        final int armedBefore = InVmWorkerProcess.armedDeadlines;
        final sw = Stopwatch()..start();
        final SourceOutcome<SearchPage> r = await session.search(SearchRequest(query: query));
        final int elapsed = sw.elapsedMilliseconds;
        expect(r.failureOrNull, isA<TimeoutFailure>(), reason: '$r');
        // Settled by the worker's native deadline: no Dart deadline, no restart.
        expect(elapsed, lessThan(4000));
        expect(ae8.supervisor!.generation, generation);
        final String c1 = await count();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final String c2 = await count();
        expect(c2, c1, reason: 'the loop kept running after its deadline');
        expect(InVmWorkerProcess.armedDeadlines, armedBefore);
        receipt('ae8-$query', <String, Object?>{
          'nativeDeadlineMs': native.inMilliseconds,
          'elapsedMs': elapsed,
          'overshootMs': elapsed - native.inMilliseconds,
          'failure': r.failureOrNull.toString(),
          'counterAfter': c1,
          'generation': generation,
        });
      });
    }

    test('a delayed browser callback is bounded by the native deadline', () async {
      final SourceOutcome<IosTachiPreparedArtifact> prepared = await qualification.prepare(
        packageId: 'fixture.webview',
        bytes: File(bundle.fixtures['fixture-webview-signed.jar']!).readAsBytesSync(),
        kind: 'jar',
        version: '1',
        trust: ArtifactTrustAnchor(signerFingerprints: <String>[testSigner]),
      );
      final IosTachiPreparedArtifact webview = prepared.valueOrNull!;
      final port = _TestBrowserPort(neverOpen: true);
      final IosTachiBackend b = backend(native: native, dart: const Duration(seconds: 8), browser: port, label: 'wv1');
      try {
        final SourcePackage p = (await b.openPackage(webview, SettingsSnapshot())).valueOrNull!;
        final sw = Stopwatch()..start();
        final SourceOutcome<SearchPage> r = await p.sessions.single.search(const SearchRequest(query: 'solved'));
        final int elapsed = sw.elapsedMilliseconds;
        expect(r.failureOrNull, isA<TimeoutFailure>(), reason: '$r');
        expect(elapsed, lessThan(4000));
        expect(b.supervisor!.generation, 1);
        await p.close();
        receipt('ae8-browser', <String, Object?>{
          'nativeDeadlineMs': native.inMilliseconds,
          'elapsedMs': elapsed,
          'opensRequested': port.opens,
          'opensCancelled': port.cancelled,
          'failure': r.failureOrNull.toString(),
        });
      } finally {
        await b.close();
      }
    });

    test('a throwing script reaches the source as Android evaluateJavascript null (androidCompatible)', () async {
      final SourceOutcome<IosTachiPreparedArtifact> prepared = await qualification.prepare(
        packageId: 'fixture.webview',
        bytes: File(bundle.fixtures['fixture-webview-signed.jar']!).readAsBytesSync(),
        kind: 'jar',
        version: '1',
        trust: ArtifactTrustAnchor(signerFingerprints: <String>[testSigner]),
      );
      final port = _TestBrowserPort();
      final IosTachiBackend b = backend(
        native: const Duration(seconds: 20),
        dart: const Duration(seconds: 30),
        browser: port,
        label: 'wv2',
      );
      try {
        final SourcePackage p = (await b.openPackage(prepared.valueOrNull!, SettingsSnapshot())).valueOrNull!;
        final SourceOutcome<SearchPage> r = await p.sessions.single.search(const SearchRequest(query: 'evalthrow'));
        expect(r.failureOrNull, isNull);
        final String title = r.valueOrNull!.hits.single.title;
        expect(title, 'no-glue:eval=null');
        await p.close();
        receipt('browser-script-error', <String, Object?>{'title': title, 'evaluations': port.evaluations});
      } finally {
        await b.close();
      }
    });

    test('R18: an extension cannot load native code', () async {
      final int images = IosJvmRuntime.loadedImageCount;
      final SourceOutcome<SearchPage> r = await session.search(const SearchRequest(query: 'native'));
      expect(r.failureOrNull, isNull);
      final String title = r.valueOrNull!.hits.single.title;
      // --illegal-native-access=deny refuses JNI and foreign library loads
      // from unnamed modules first (IllegalCallerException); the baked
      // java.base guard (UnsatisfiedLinkError) stands behind it.
      final attempts = <String, String>{
        for (final String part in title.split(';')) part.split('=').first: part.split('=').last,
      };
      expect(attempts.keys, <String>['loadLibrary', 'load', 'reflective', 'foreign']);
      if (_guardOnly) {
        // Diagnostic run without --illegal-native-access=deny: the baked guard
        // alone refuses every JNI load; foreign lookups are only refused by deny.
        expect(attempts['loadLibrary'], 'UnsatisfiedLinkError');
        expect(attempts['load'], 'UnsatisfiedLinkError');
        expect(attempts['reflective'], 'UnsatisfiedLinkError');
      } else {
        for (final String outcome in attempts.values) {
          expect(outcome, anyOf('IllegalCallerException', 'UnsatisfiedLinkError'));
        }
      }
      expect(IosJvmRuntime.loadedImageCount, images);
      receipt('r18-native', <String, Object?>{
        'attempts': title,
        'images': images,
        'denyIllegalNativeAccess': !_guardOnly,
      });
    });
  });

  test('session and package closure never destroy the VM; references return to baseline', () async {
    final trust = ArtifactTrustAnchor(signerFingerprints: const <String>[_keiyoushiSigner]);
    const q = _Qualification('all.mangadex', 'tachiyomi-all.mangadex-v1.6.4', '2499283573021220255', 1);
    final IosTachiPreparedArtifact first = (await qualification.prepare(
      packageId: packageIdOf(q),
      bytes: artifact(q, 'jar'),
      kind: 'jar',
      version: versionOf(q),
      trust: trust,
    )).valueOrNull!;
    final String path = await first.lease.verifiedPath();
    first.lease.release();
    final counts = <Map<String, int>>[];
    for (var i = 0; i < 5; i++) {
      final IosTachiPreparedArtifact a = (await qualification.prepare(
        packageId: packageIdOf(q),
        bytes: artifact(q, 'jar'),
        kind: 'jar',
        version: versionOf(q),
        trust: trust,
      )).valueOrNull!;
      expect(await a.lease.verifiedPath(), path, reason: 'cached by KTD5 identity');
      final SourcePackage p = (await qualification.openPackage(a, SettingsSnapshot())).valueOrNull!;
      final SourceSession s = p.sessions.firstWhere((SourceSession s) => s.identity.sourceId == q.querySourceId);
      expect((await s.search(const SearchRequest(query: _query))).failureOrNull, isNull);
      await p.close();
      counts.add(<String, int>{
        'globalRefs': runtime.globalRefCount,
        'armedDeadlines': InVmWorkerProcess.armedDeadlines,
        'liveWorkers': InVmWorkerProcess.liveWorkers,
        'vms': runtime.createdVmCount(),
      });
    }
    expect(runtime.createdVmCount(), 1);
    expect(runtime.globalRefCount, baselineGlobalRefs);
    expect(InVmWorkerProcess.armedDeadlines, 0);
    // A closed backend leaves the VM serving the next one.
    final IosTachiBackend again = backend(
      native: const Duration(minutes: 2),
      dart: const Duration(minutes: 3),
      replay: <String>[data(q.dir)],
      label: 'again',
    );
    final IosTachiPreparedArtifact a = (await again.prepare(
      packageId: packageIdOf(q),
      bytes: artifact(q, 'jar'),
      kind: 'jar',
      version: versionOf(q),
      trust: trust,
    )).valueOrNull!;
    final SourcePackage p = (await again.openPackage(a, SettingsSnapshot())).valueOrNull!;
    final SourceSession s = p.sessions.firstWhere((SourceSession s) => s.identity.sourceId == q.querySourceId);
    expect((await s.search(const SearchRequest(query: _query))).failureOrNull, isNull);
    await p.close();
    await again.close();
    expect(runtime.createdVmCount(), 1);
    expect(runtime.globalRefCount, baselineGlobalRefs);
    receipt('lifecycle', <String, Object?>{
      'cycles': counts,
      'baselineGlobalRefs': baselineGlobalRefs,
      'afterSecondBackend': <String, int>{
        'globalRefs': runtime.globalRefCount,
        'liveWorkers': InVmWorkerProcess.liveWorkers,
        'vms': runtime.createdVmCount(),
      },
    });
  });

  test('no platform channel carried any source operation', () {
    // Only the Flutter engine's own system channels may appear.
    expect(platformMessages.where((String c) => !c.startsWith('flutter/')), isEmpty);
  });
}

/// A WebKit-like test port: script errors reported, no interception. With
/// [neverOpen], opening a session never completes unless cancelled (the
/// delayed browser callback case).
final class _TestBrowserPort implements BrowserPort {
  _TestBrowserPort({this.neverOpen = false});

  final bool neverOpen;
  int opens = 0;
  int cancelled = 0;
  final List<String> evaluations = <String>[];

  @override
  Future<BrowserOutcome<void>> wipeAllSourceData() async => const BrowserCompleted<void>(null);

  @override
  Future<void> fence(int generation) async {}

  @override
  Future<BrowserOutcome<BrowserSession>> openSession(BrowserSessionRequest request, {CancellationToken? cancel}) async {
    opens++;
    if (neverOpen) {
      await (cancel ?? CancellationToken.none).whenCancelled;
      cancelled++;
      return const BrowserCancelled<BrowserSession>('cancelled while opening');
    }
    return BrowserCompleted<BrowserSession>(_TestSession(this, request));
  }
}

final class _TestSession implements BrowserSession {
  _TestSession(this._port, BrowserSessionRequest request) : source = request.source, generation = request.generation;

  final _TestBrowserPort _port;

  @override
  final SourceIdentity source;

  @override
  final int generation;

  @override
  String get id => 'test-session';

  @override
  BrowserCapabilities get capabilities => BrowserCapabilities(
    available: const <BrowserFeature>{BrowserFeature.pageStartScripts, BrowserFeature.scriptErrors},
    unavailable: const <BrowserFeature, String>{
      BrowserFeature.observeSubresources: 'test port',
      BrowserFeature.replaceRequests: 'test port',
    },
  );

  @override
  Future<BrowserOutcome<BrowserPage>> loadUrl(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    CancellationToken? cancel,
  }) async => BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: url, statusCode: 200));

  @override
  Future<BrowserOutcome<BrowserPage>> loadData(String html, {required Uri baseUrl, CancellationToken? cancel}) async =>
      BrowserCompleted<BrowserPage>(BrowserPage(finalUrl: baseUrl, statusCode: 200));

  @override
  Future<BrowserOutcome<String>> evaluate(String script, {CancellationToken? cancel}) async {
    _port.evaluations.add(script);
    return script.contains('throw')
        ? const BrowserScriptError<String>('Error: boom')
        : const BrowserCompleted<String>('null');
  }

  @override
  Future<BrowserOutcome<void>> addPageStartScript(String script) async => const BrowserCompleted<void>(null);

  @override
  Future<BrowserOutcome<void>> setRequestObserver(BrowserRequestObserver? observer) async =>
      const BrowserCapabilityUnavailable<void>('setRequestObserver', 'test port');

  @override
  Future<BrowserOutcome<void>> setRequestReplacer(BrowserRequestReplacer? replacer) async =>
      const BrowserCapabilityUnavailable<void>('setRequestReplacer', 'test port');

  @override
  Future<BrowserOutcome<void>> setMessageHandler(String name, void Function(String message)? handler) async =>
      const BrowserCompleted<void>(null);

  @override
  Future<BrowserOutcome<List<BrowserCookie>>> getCookies(Uri url, {CancellationToken? cancel}) async =>
      const BrowserCompleted<List<BrowserCookie>>(<BrowserCookie>[]);

  @override
  Future<BrowserOutcome<void>> setCookie(Uri url, BrowserCookie cookie, {CancellationToken? cancel}) async =>
      const BrowserCompleted<void>(null);

  @override
  Future<BrowserOutcome<void>> setUserAgent(String userAgent, {CancellationToken? cancel}) async =>
      const BrowserCompleted<void>(null);

  @override
  Future<BrowserOutcome<void>> showForInteraction({required Duration timeout, CancellationToken? cancel}) async =>
      const BrowserInteractionRequired<void>('test port has no display');

  @override
  Future<BrowserOutcome<void>> close() async => const BrowserCompleted<void>(null);
}

/// The smallest valid class file (`public class Injected`), for the
/// appended-entry tamper case. Its content is irrelevant: verification must
/// refuse the JAR before anything is loaded.
Uint8List _minimalClass() => Uint8List.fromList(<int>[
  0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41, // magic, version 65
  0x00, 0x05, // constant pool count
  0x07, 0x00, 0x02, // #1 Class #2
  0x01, 0x00, 0x08, ...'Injected'.codeUnits, // #2 Utf8
  0x07, 0x00, 0x04, // #3 Class #4
  0x01, 0x00, 0x10, ...'java/lang/Object'.codeUnits, // #4 Utf8
  0x00, 0x21, 0x00, 0x01, 0x00, 0x03, // flags, this, super
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // interfaces, fields, methods, attributes
]);

/// Minimal ZIP rewriter for the tamper cases: reads every entry (stored or
/// deflated), lets the test replace or add entries, and writes a plain ZIP
/// with stored entries. Signature files are carried over unchanged, so the
/// result is a signed archive whose content no longer matches.
final class _Zip {
  _Zip._(this._entries);

  final Map<String, Uint8List> _entries;

  Iterable<String> get names => _entries.keys;

  factory _Zip.read(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    int eocd = bytes.length - 22;
    while (eocd >= 0 && view.getUint32(eocd, Endian.little) != 0x06054b50) {
      eocd--;
    }
    final int count = view.getUint16(eocd + 10, Endian.little);
    int p = view.getUint32(eocd + 16, Endian.little);
    final entries = <String, Uint8List>{};
    for (var i = 0; i < count; i++) {
      final int method = view.getUint16(p + 10, Endian.little);
      final int compressed = view.getUint32(p + 20, Endian.little);
      final int nameLen = view.getUint16(p + 28, Endian.little);
      final int extraLen = view.getUint16(p + 30, Endian.little);
      final int commentLen = view.getUint16(p + 32, Endian.little);
      final int local = view.getUint32(p + 42, Endian.little);
      final String name = utf8.decode(bytes.sublist(p + 46, p + 46 + nameLen));
      final int localName = view.getUint16(local + 26, Endian.little);
      final int localExtra = view.getUint16(local + 28, Endian.little);
      final int start = local + 30 + localName + localExtra;
      final Uint8List raw = bytes.sublist(start, start + compressed);
      if (!name.endsWith('/')) {
        entries[name] = method == 0 ? raw : Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
      }
      p += 46 + nameLen + extraLen + commentLen;
    }
    return _Zip._(entries);
  }

  void replace(String name, Uint8List Function(Uint8List) change) => _entries[name] = change(_entries[name]!);

  void add(String name, Uint8List data) => _entries[name] = data;

  Uint8List write() {
    final out = BytesBuilder();
    final central = BytesBuilder();
    for (final MapEntry<String, Uint8List> e in _entries.entries) {
      final List<int> name = utf8.encode(e.key);
      final int crc = _crc32(e.value);
      final int offset = out.length;
      final local = ByteData(30)
        ..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint32(14, crc, Endian.little)
        ..setUint32(18, e.value.length, Endian.little)
        ..setUint32(22, e.value.length, Endian.little)
        ..setUint16(26, name.length, Endian.little);
      out
        ..add(local.buffer.asUint8List())
        ..add(name)
        ..add(e.value);
      final dir = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, e.value.length, Endian.little)
        ..setUint32(24, e.value.length, Endian.little)
        ..setUint16(28, name.length, Endian.little)
        ..setUint32(42, offset, Endian.little);
      central
        ..add(dir.buffer.asUint8List())
        ..add(name);
    }
    final int dirOffset = out.length;
    final Uint8List dirBytes = central.toBytes();
    out.add(dirBytes);
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, _entries.length, Endian.little)
      ..setUint16(10, _entries.length, Endian.little)
      ..setUint32(12, dirBytes.length, Endian.little)
      ..setUint32(16, dirOffset, Endian.little);
    out.add(end.buffer.asUint8List());
    return out.toBytes();
  }

  static final List<int> _table = List<int>.generate(256, (int n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    return c;
  });

  static int _crc32(Uint8List data) {
    var c = 0xFFFFFFFF;
    for (final b in data) {
      c = _table[(c ^ b) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
