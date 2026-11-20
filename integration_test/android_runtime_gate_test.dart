// U17 Android runtime gate (M2 early gate). Runs on an Android device or
// emulator:
//   flutter test integration_test/android_runtime_gate_test.dart -d <device>
//
// Every call crosses the JNIgen facade in package:source_runtime_android; no
// platform channel is involved. Each scenario prints one `U17_RECEIPT {json}`
// line that docs/validation/source-runners/android/ records (redacted).
// The test never contacts a server: the extension APK is the committed
// fixture under fixtures/source_captures/tachi/, shipped as a debug asset.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:source_runtime_android/source_runtime_android.dart';

const String _apkAsset = 'all.mangadex/tachiyomi-all.mangadex-v1.6.4.apk';

/// SHA-256 recorded in fixtures/source_captures/tachi/all.mangadex/artifact.json.
const String _apkSha256 =
    '611bd20d91cdd4152b6d976081cc0cd4651208f7a153ddbef133f4ebba1688c3';
const String _factoryClass = 'keiyoushi.source.Generated';
const int _terminationRounds = 5;
const int _refRounds = 30;
const Duration _eventTimeout = Duration(seconds: 30);

void _receipt(String scenario, Map<String, Object?> data) {
  print(
    'U17_RECEIPT ${jsonEncode(<String, Object?>{'scenario': scenario, ...data})}',
  );
}

Map<String, Object?> _json(String payload) =>
    jsonDecode(payload) as Map<String, Object?>;

Future<SourceRuntimeDied> _nextDeath(
  AndroidSourceRuntime runtime,
  int generation,
) => runtime.events
    .where(
      (SourceRuntimeEvent e) =>
          e is SourceRuntimeDied && e.generation == generation,
    )
    .cast<SourceRuntimeDied>()
    .first
    .timeout(_eventTimeout);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AndroidSourceRuntime runtime;
  late SourceRuntimeBound bound;

  setUpAll(() async {
    runtime = AndroidSourceRuntime();
    bound = await runtime.bind().timeout(_eventTimeout);
  });

  tearDownAll(() => runtime.dispose());

  testWidgets(
    '1. JNIgen facade: dispatch and reply from the :source_runtime process',
    (_) async {
      expect(
        bound.pid,
        isNot(pid),
        reason: 'service must run in its own process',
      );
      final Map<String, Object?> ping = _json(
        await runtime.call('ping').timeout(_eventTimeout),
      );
      expect(ping['pid'], bound.pid);
      expect(ping['processName'], endsWith(':source_runtime'));
      await expectLater(
        runtime.call('no-such-op'),
        throwsA(
          isA<SourceRuntimeCallException>().having(
            (e) => e.payload,
            'payload',
            contains('unknown op'),
          ),
        ),
      );
      _receipt('facade', <String, Object?>{
        'appPid': pid,
        'servicePid': bound.pid,
        'sdkInt': bound.sdkInt,
        'serviceProcess': ping['processName'],
        'generation': bound.generation,
      });
    },
  );

  testWidgets(
    '2. Real DEX from read-only staging; writable or tampered files rejected',
    (_) async {
      expect(
        () => runtime.stageAsset(_apkAsset, 'f' * 64),
        throwsA(anything),
        reason: 'staging with the wrong digest must fail',
      );
      final String staged = runtime.stageAsset(_apkAsset, _apkSha256);
      final stagedFile = File(staged);
      final FileStat stat = stagedFile.statSync();
      // Owner-only read: no write bit for anyone.
      expect(
        stat.mode & 0x92,
        0,
        reason:
            'staged file must have no write bits (mode ${stat.modeString()})',
      );

      final Map<String, Object?> load = _json(
        await runtime.call(
          'loadExtension',
          jsonEncode(<String, String>{'path': staged, 'sha256': _apkSha256}),
        ),
      );
      expect(load['processName'], endsWith(':source_runtime'));
      expect(load['packageName'], 'eu.kanade.tachiyomi.extension.all.mangadex');
      expect(load['factoryClass'], _factoryClass);
      expect(load['factoryLinked'], isTrue);
      expect(load['factoryIsSourceFactory'], isTrue);
      expect(
        load['sourceFactoryParentOwned'],
        isTrue,
        reason: 'SourceFactory must be the parent-owned host type',
      );
      final construction = load['construction']! as Map<String, Object?>;
      // The pinned source API (mihonapp/extensions-lib 1.6.0) is a stub library;
      // MangaDex's HttpSource constructor therefore throws "Stub!". Source IDs
      // are compared with the index by U11 with its real host. If construction
      // ever succeeds here, extend this test to compare IDs with
      // fixtures/source_captures/tachi/all.mangadex/index-entry.json.
      expect(construction['ok'], isFalse);
      expect(construction['rootMessage'], 'Stub!');

      final Uint8List bytes = stagedFile.readAsBytesSync();
      final String dir = runtime.stagingDirectory;

      // Writable copy inside staging: rejected before any class loader exists.
      final writable = File('$dir/writable.apk');
      if (writable.existsSync()) writable.deleteSync();
      writable.writeAsBytesSync(bytes);
      await expectLater(
        runtime.call(
          'loadExtension',
          jsonEncode(<String, String>{
            'path': writable.path,
            'sha256': _apkSha256,
          }),
        ),
        throwsA(
          isA<SourceRuntimeCallException>().having(
            (e) => e.payload,
            'payload',
            contains('writable'),
          ),
        ),
      );
      writable.deleteSync();

      // Read-only copy with one byte flipped: rejected by digest.
      final tamperedBytes = Uint8List.fromList(bytes);
      tamperedBytes[tamperedBytes.length ~/ 2] ^= 0x01;
      final String tampered = runtime.stageBytes('tampered.apk', tamperedBytes);
      expect(File(tampered).statSync().mode & 0x92, 0);
      await expectLater(
        runtime.call(
          'loadExtension',
          jsonEncode(<String, String>{'path': tampered, 'sha256': _apkSha256}),
        ),
        throwsA(
          isA<SourceRuntimeCallException>().having(
            (e) => e.payload,
            'payload',
            contains('digest'),
          ),
        ),
      );
      File(tampered).deleteSync();

      _receipt('dex', <String, Object?>{
        'stagedMode': stat.modeString(),
        'sha256': load['sha256'],
        'packageName': load['packageName'],
        'versionName': load['versionName'],
        'extensionLib': load['extensionLib'],
        'factoryClass': load['factoryClass'],
        'factoryLoader': load['factoryLoader'],
        'factoryLinked': load['factoryLinked'],
        'sourceFactoryParentOwned': load['sourceFactoryParentOwned'],
        'construction': construction,
        'writableRejected': true,
        'tamperedRejected': true,
        'wrongDigestStagingRejected': true,
      });
    },
  );

  testWidgets(
    '3. CPU-looping call terminated by PID, death observed, rebound; app stays responsive',
    (_) async {
      final rounds = <Map<String, Object?>>[];
      for (var round = 0; round < _terminationRounds; round++) {
        final int generation = runtime.generation;
        final int victim = runtime.pid;
        expect(victim, greaterThan(0));

        // Capture the outcome now so the death-time error is never unhandled.
        final Future<Object?> loop = runtime
            .call('cpuLoop')
            .then<Object?>((String r) => r, onError: (Object e) => e);
        final Future<SourceRuntimeDied> death = _nextDeath(runtime, generation);
        // The loop occupies one service thread; the service still answers.
        final Map<String, Object?> busyPing = _json(
          await runtime.call('ping').timeout(_eventTimeout),
        );
        expect(busyPing['pid'], victim);

        // Responsiveness probe: the Dart event loop keeps ticking throughout.
        final ticks = Stopwatch()..start();
        var tickCount = 0;
        var maxGapMs = 0;
        var last = 0;
        final timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
          final int now = ticks.elapsedMilliseconds;
          if (now - last > maxGapMs) maxGapMs = now - last;
          last = now;
          tickCount++;
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final killWatch = Stopwatch()..start();
        expect(runtime.kill(), isTrue);
        final SourceRuntimeDied died = await death;
        final int killToDeathMs = killWatch.elapsedMilliseconds;
        expect(died.pid, victim);
        expect(await loop, isA<SourceRuntimeDiedException>());

        final rebindWatch = Stopwatch()..start();
        final SourceRuntimeBound rebound = await runtime.bind().timeout(
          _eventTimeout,
        );
        final int deathToRebindMs = rebindWatch.elapsedMilliseconds;
        expect(rebound.pid, isNot(victim));
        expect(rebound.generation, greaterThan(generation));
        final Map<String, Object?> after = _json(
          await runtime.call('ping').timeout(_eventTimeout),
        );
        expect(after['pid'], rebound.pid);

        timer.cancel();
        expect(tickCount, greaterThan(10));
        rounds.add(<String, Object?>{
          'round': round,
          'killedPid': victim,
          'reboundPid': rebound.pid,
          'killToDeathMs': killToDeathMs,
          'deathToRebindMs': deathToRebindMs,
          'dartTicks': tickCount,
          'maxDartTickGapMs': maxGapMs,
        });
      }
      // The Flutter app process itself was never killed.
      _receipt('termination', <String, Object?>{
        'appPid': pid,
        'rounds': rounds,
      });
    },
  );

  testWidgets('4. WebView in the service process alongside the app process', (
    _,
  ) async {
    final int sdk = bound.sdkInt;
    final Map<String, Object?> app = _json(
      await runtime.probeAppWebView().timeout(_eventTimeout),
    );
    expect(app['jsResult'], '"gate:42"');
    expect(app['pid'], pid);

    Map<String, Object?>? service;
    Object? serviceError;
    try {
      service = _json(
        await runtime.call('webViewProbe').timeout(_eventTimeout),
      );
    } on Object catch (e) {
      serviceError = e;
    }
    // Both alive at once: probe the app WebView again while the service one exists.
    final Map<String, Object?> appAgain = _json(
      await runtime.probeAppWebView().timeout(_eventTimeout),
    );

    _receipt('webview', <String, Object?>{
      'sdkInt': sdk,
      'app': app,
      'service': service,
      'serviceError': serviceError?.toString(),
      'appWhileServiceAlive': appAgain,
    });

    if (sdk >= 28) {
      expect(serviceError, isNull);
      expect(service!['jsResult'], '"gate:42"');
      expect(service['pid'], runtime.pid);
      expect(service['dataDirectorySuffixApplied'], isTrue);
      expect(
        service['webViewDataDirs']! as List<Object?>,
        contains('app_webview_source_runtime'),
      );
      expect(appAgain['jsResult'], '"gate:42"');
      expect(appAgain['liveWebViews'], 2);
    }
    await runtime
        .call('webViewRelease')
        .timeout(_eventTimeout)
        .catchError((Object _) => '');
    await runtime.destroyAppWebViews().timeout(_eventTimeout);
  });

  testWidgets(
    '5. JNI global references return to baseline after repeated bind/unbind',
    (_) async {
      // Warm-up: first use caches classes and method IDs (one-time references).
      await _refRound(runtime);
      final Map<String, int> before = await _settledRefs(runtime);
      if (before['total']! < 0) {
        _receipt('jniRefs', <String, Object?>{'available': false});
        markTestSkipped(
          'JNI global reference table unavailable on this runtime',
        );
        return;
      }
      final samples = <Map<String, int>>[];
      for (var i = 0; i < _refRounds; i++) {
        await _refRound(runtime);
        if (i % 10 == 9) samples.add(await _settledRefs(runtime));
      }
      final Map<String, int> after = await _settledRefs(runtime);
      final int ownedDelta = after['owned']! - before['owned']!;
      _receipt('jniRefs', <String, Object?>{
        'method':
            'ART JNI global reference table (Debug.dumpReferenceTables, read from own logcat) after forced Dart '
            'GC and Java GC in both processes',
        'rounds': _refRounds,
        'perRound': 'new AndroidSourceRuntime + bind + ping + unbind + dispose, and unbind + rebind of the shared runtime',
        'before': before,
        'samples': samples,
        'after': after,
        'ownedDelta': ownedDelta,
      });
      // References owned by this package's Dart wrappers and the jni listener
      // glue return to baseline: no per-round growth.
      expect(ownedDelta, lessThanOrEqualTo(2));
    },
  );
}

/// One bind/unbind round exercising every wrapper the runtime owns.
Future<void> _refRound(AndroidSourceRuntime runtime) async {
  final scratch = AndroidSourceRuntime();
  await scratch.bind().timeout(_eventTimeout);
  await scratch.call('ping').timeout(_eventTimeout);
  scratch
    ..unbind()
    ..dispose();
  runtime.unbind();
  await runtime.bind().timeout(_eventTimeout);
}

/// Wrapper classes owned by package:source_runtime_android and package:jni:
/// facade objects, the Dart listener proxy, and listener argument arrays.
bool _isOwned(String cls) =>
    cls.startsWith('java.lang.Object[]') ||
    cls.startsWith(r'$Proxy') ||
    cls == 'java.lang.String' ||
    cls == 'dev.getboolean.sourceruntime.SourceRuntimeClient' ||
    cls == 'dev.getboolean.sourceruntime.AppWebViewProbe' ||
    cls == 'dev.getboolean.sourceruntime.ArtifactStaging' ||
    cls == 'dev.getboolean.sourceruntime.RuntimeDiagnostics';

/// Binder objects whose JNI global references the platform holds while a
/// remote process (the service, or system_server) still references them.
bool _isBinderHeld(String cls) =>
    cls.contains(r'LoadedApk$ServiceDispatcher') ||
    cls.startsWith(r'dev.getboolean.sourceruntime.SourceRuntimeClient$');

Future<Map<String, int>> _settledRefs(AndroidSourceRuntime runtime) async {
  await _forceDartGc();
  await runtime.call('gc').timeout(_eventTimeout);
  final Map<String, Object?> summary =
      AndroidSourceRuntime.jniGlobalReferenceSummary();
  final Map<String, Object?> classes =
      (summary['classes'] as Map<String, Object?>?) ?? <String, Object?>{};
  var owned = 0;
  var binderHeld = 0;
  for (final MapEntry<String, Object?> e in classes.entries) {
    final count = e.value! as int;
    if (_isOwned(e.key)) owned += count;
    if (_isBinderHeld(e.key)) binderHeld += count;
  }
  return <String, int>{
    'total': summary['total']! as int,
    'owned': owned,
    'binderHeld': binderHeld,
  };
}

/// Forces full Dart garbage collections so finalizer-owned JNI references
/// (package:jni releases them through NativeFinalizer) are deleted.
Future<void> _forceDartGc() async {
  for (var cycle = 0; cycle < 3; cycle++) {
    Object? target = Object();
    final weak = WeakReference<Object>(target);
    var sink = <List<int>>[];
    // Keep the target alive across scavenges so it is promoted; collecting it
    // then requires an old-generation (full) collection.
    for (var i = 0; i < 64; i++) {
      sink.add(List<int>.filled(16 * 1024, i));
    }
    target = null;
    sink = <List<int>>[];
    for (var guard = 0; weak.target != null && guard < 4000; guard++) {
      sink.add(List<int>.filled(64 * 1024, guard));
      if (sink.length > 64) sink = <List<int>>[];
      if (guard % 50 == 0) await Future<void>.delayed(Duration.zero);
    }
  }
}
