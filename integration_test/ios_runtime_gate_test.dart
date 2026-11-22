// U16 iOS runtime gate (M3 early gate): embedded Zero JVM driven from Dart
// through FFIgen bindings, native deadline interruption, and the WKWebView
// replay of MangaFire's browser behaviour.
//
// Run on an iOS simulator or device after building and staging the runtime
// (tools/tachi-source-runner/ios/README.md):
//
//   flutter test integration_test/ios_runtime_gate_test.dart -d <device> \
//     --dart-define=SRT_MECHANISM=stopThread     # or injected
//
// One VM per process, so each mechanism is a separate run:
// * stopThread: Zero back-edge poll on (patch 0004), JVMTI StopThread,
//   unrewritten classes and class library (mechanism B).
// * injected: Zero back-edge poll off (upstream behaviour), rewritten
//   extension/host classes and java.util.regex (mechanism A).
// Both runs also measure the baseline (no interruption) and GC liveness.
//
// Every interruption assertion uses the native dispatcher's outcome (the
// Java call ended with the deadline error, timed on the native side); a
// Dart-side timeout only fails the test.
// ignore_for_file: do_not_use_environment
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:source_runtime_ios/source_runtime_ios.dart';

const String _mechanismName = String.fromEnvironment(
  'SRT_MECHANISM',
  defaultValue: 'stopThread',
);
const int _repetitions = int.fromEnvironment(
  'SRT_REPETITIONS',
  defaultValue: 5,
);
const Duration _deadline = Duration(milliseconds: 250);
const Duration _boundedRun = Duration(seconds: 6);
const String _ext = 'gate.ext.GateExtension';

// Zero back-edge safepoint poll (patch 0004): on, off, or auto (on for
// stopThread, which needs it; off for injected, to measure mechanism A on
// upstream Zero semantics).
const String _pollName = String.fromEnvironment(
  'SRT_BACKEDGE_POLL',
  defaultValue: 'auto',
);

final DeadlineMechanism _mechanism = DeadlineMechanism.values.byName(
  _mechanismName,
);
final bool _rewritten = _mechanism == DeadlineMechanism.injected;
final bool _poll = _pollName == 'auto' ? !_rewritten : _pollName == 'on';

final Map<String, Object?> _report = {
  'evidence': Platform.resolvedExecutable.contains('/CoreSimulator/')
      ? 'simulator'
      : 'physical-device',
  'os': Platform.operatingSystemVersion,
  'dart': Platform.version,
  'mechanism': _mechanismName,
  'backedgePoll': _pollName,
};

late IosJvmRuntime _runtime;
late BundledRuntime _bundle;
late int _baselineGlobalRefs;
late double _spinPerMs;
late double _hostRoundsPerMs;
late int _regexN;

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDownAll(() {
    binding.reportData = _report;
    // One line, so the receipt can be pulled from device logs as well.
    // ignore: avoid_print
    print('SRT_GATE_REPORT ${jsonEncode(_report)}');
  });

  group('embedded JVM', () {
    testWidgets('starts once, interpreter-only, without attaching Dart threads', (
      tester,
    ) async {
      expect(
        IosJvmRuntime.linked,
        isTrue,
        reason: 'build and stage the runtime first',
      );
      _bundle = BundledRuntime.prepare();
      final String host =
          _bundle.fixtures[_rewritten
              ? 'gate-host-rewritten.jar'
              : 'gate-host-plain.jar']!;
      final String ext =
          _bundle.fixtures[_rewritten
              ? 'gate-ext-rewritten.jar'
              : 'gate-ext-plain.jar']!;
      final options = <String>[
        '-Xint',
        '-Xshare:off',
        '-XX:+UseSerialGC',
        '-Xms32m',
        '-Xmx256m',
        '-Djava.class.path=$host:$ext',
        '--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED',
        if (_rewritten)
          '--patch-module=java.base=${_bundle.fixtures['java-base-regex-rewritten.jar']}',
      ];
      final sw = Stopwatch()..start();
      _runtime = await IosJvmRuntime.start(
        javaHome: _bundle.javaHome,
        options: options,
      );
      final double startMs = sw.elapsedMicroseconds / 1000;
      _runtime.setBackedgePoll(enabled: _poll);
      _report['backedgePoll'] = _poll ? 'on' : 'off';
      _baselineGlobalRefs = _runtime.globalRefCount;

      expect(
        identical(
          await IosJvmRuntime.start(
            javaHome: _bundle.javaHome,
            options: options,
          ),
          _runtime,
        ),
        isTrue,
      );
      expect(_runtime.createdVmCount(), 1);
      expect(_runtime.callingThreadAttached(), isFalse);

      final RuntimeEvent hello = await _runtime.call(
        _ext,
        'hello',
        'from dart',
      );
      expect(hello.status, RuntimeStatus.ok, reason: '$hello');
      expect(hello.result, contains('Zero'));
      expect(hello.result, contains('interpreted mode'));
      _report['start'] = {
        ..._runtime.startEvent.payload,
        'startToReadyMs': startMs,
        'options': options
            .map(
              (o) => o.contains('/')
                  ? o.replaceAll(RegExp('/[^:= ]*/'), '<bundle>/')
                  : o,
            )
            .toList(),
      };
      _report['hello'] = hello.result!.replaceAll(
        RegExp(r'java\.home=\S+'),
        'java.home=<app container>',
      );
      _report['firstCallMs'] = hello.elapsedMs;
    });

    testWidgets('calibrates loop speeds', (tester) async {
      final RuntimeEvent spin = await _ok(
        _runtime.call('gate.ext.Unrewritten', 'spin', '2000000'),
      );
      _spinPerMs = 2000000 / (_elapsedNs(spin.result!) / 1e6);
      final RuntimeEvent hostLoop = await _ok(
        _runtime.call(_ext, 'hostLoop', '20000'),
      );
      _hostRoundsPerMs = 20000 / hostLoop.elapsedMs;
      // ((x+)\2?)+y roughly doubles per extra character; size it to run
      // about _boundedRun uninterrupted.
      final RuntimeEvent regex = await _ok(_runtime.call(_ext, 'regex', '12'));
      final double perStepMs = max(regex.elapsedMs, 0.5);
      _regexN = min(
        40,
        12 + (log(_boundedRun.inMilliseconds / perStepMs) / log(2.2)).ceil(),
      );
      _report['calibration'] = {
        'spinIterationsPerMs': _spinPerMs.round(),
        'hostRoundsPerMs': _hostRoundsPerMs.round(),
        'regexN12Ms': regex.elapsedMs,
        'regexN': _regexN,
      };
    });

    testWidgets('round trips repeatedly with stable references', (
      tester,
    ) async {
      final times = <double>[];
      for (var i = 0; i < 20; i++) {
        final RuntimeEvent e = await _ok(
          _runtime.call(_ext, 'hello', 'call $i'),
        );
        times.add(e.elapsedMs);
      }
      expect(_runtime.globalRefCount, _baselineGlobalRefs);
      expect(_runtime.activeJobs, 0);
      _report['roundTripMs'] = _stats(times);
    });
  });

  group('baseline and liveness', () {
    testWidgets(
      'without a Java mechanism the deadline cannot stop a call-free loop',
      (tester) async {
        final n = '${(_spinPerMs * 1500).round()}';
        final RuntimeEvent e = await _runtime.call(
          'gate.ext.Unrewritten',
          'spin',
          n,
          deadline: _deadline,
        );
        _report['baselineNoMechanism'] = e.payload;
        expect(e.status, RuntimeStatus.ok);
        expect(e.fired, isTrue);
        expect(e.elapsedMs, greaterThan(_deadline.inMilliseconds * 2));
      },
    );

    testWidgets('an unrewritten call-free loop under the selected mechanism', (
      tester,
    ) async {
      final n = '${(_spinPerMs * 1500).round()}';
      final RuntimeEvent e = await _runtime.call(
        'gate.ext.Unrewritten',
        'spin',
        n,
        deadline: _deadline,
        mechanism: _mechanism,
      );
      _report['unrewrittenLoop'] = e.payload;
      if (_mechanism == DeadlineMechanism.stopThread) {
        expect(
          e.status,
          RuntimeStatus.deadline,
          reason: 'the Zero back-edge poll reaches every loop',
        );
      }
    });

    for (final poll in [true, false]) {
      testWidgets(
        'GC on another thread during a call-free loop (back-edge poll ${poll ? 'on' : 'off'})',
        (
          tester,
        ) async {
          final bool previous = _runtime.setBackedgePoll(enabled: poll);
          try {
            // The unrewritten loop is the hard case: no injected calls, so only
            // the back-edge poll gives other threads a safepoint.
            final Future<RuntimeEvent> loop = _runtime.call(
              'gate.ext.Unrewritten',
              'spin',
              '${(_spinPerMs * 3000).round()}',
            );
            await Future<void>.delayed(const Duration(milliseconds: 300));
            final RuntimeEvent gc = await _ok(_runtime.call(_ext, 'gc', ''));
            final RuntimeEvent loopDone = await loop;
            final double gcMs = int.parse(gc.result!.split('=')[1]) / 1e6;
            _report['gcDuringUnrewrittenLoopPoll${poll ? 'On' : 'Off'}'] = {
              'gcMs': gcMs,
              'loopMs': loopDone.elapsedMs,
            };
            if (poll) {
              expect(
                gcMs,
                lessThan(1000),
                reason: 'GC stalled behind a call-free loop',
              );
            }
          } finally {
            _runtime.setBackedgePoll(enabled: previous);
          }
        },
      );
    }

    testWidgets('references return to baseline', (tester) async {
      expect(_runtime.activeJobs, 0);
      expect(_runtime.globalRefCount, _baselineGlobalRefs);
      _report['globalRefs'] = {
        'baseline': _baselineGlobalRefs,
        'final': _runtime.globalRefCount,
      };
    });
  });

  group('interruption (${_mechanism.name})', () {
    final cases = <String, (String, String Function())>{
      'callFreeLoop': (
        'spin',
        () => '${(_spinPerMs * _boundedRun.inMilliseconds).round()}',
      ),
      'hostLibraryLoop': (
        'hostLoop',
        () => '${(_hostRoundsPerMs * _boundedRun.inMilliseconds).round()}',
      ),
      'regexBacktrack': ('regex', () => '$_regexN'),
      'catchThrowableAndContinue': (
        'catchAll',
        () => '${(_spinPerMs * _boundedRun.inMilliseconds / 100000).round()}',
      ),
      'blockedNativeWait': (
        'nativeWait',
        () => '${_boundedRun.inMilliseconds}',
      ),
    };
    for (final MapEntry<String, (String, String Function())> c
        in cases.entries) {
      testWidgets(
        '${c.key} stops within its deadline and the VM keeps serving',
        (tester) async {
          final latencies = <double>[];
          final outcomes = <String>[];
          final exceptions = <String?>[];
          final deliveries = <Object?>[];
          var ticks = 0;
          final timer = Timer.periodic(
            const Duration(milliseconds: 16),
            (_) => ticks++,
          );
          final sw = Stopwatch()..start();
          for (var i = 0; i < _repetitions; i++) {
            final RuntimeEvent e = await _runtime
                .call(
                  _ext,
                  c.value.$1,
                  c.value.$2(),
                  deadline: _deadline,
                  mechanism: _mechanism,
                )
                .timeout(_boundedRun * 3);
            outcomes.add(e.status.name);
            exceptions.add(e.exception);
            deliveries.add(e.payload['deliveries']);
            if (e.status == RuntimeStatus.deadline) {
              latencies.add(e.stopLatencyMs!);
            }
            if (i == 0) _section('samples')[c.key] = e.payload;
            await _ok(_runtime.call(_ext, 'hello', 'after ${c.key}'));
          }
          timer.cancel();
          final double expectedTicks = sw.elapsedMilliseconds / 16;
          _section('interruption')[c.key] = {
            'outcomes': outcomes,
            'exceptions': exceptions.toSet().toList(),
            'deliveries': deliveries,
            'stopLatencyMs': _stats(latencies),
            'dartTimerTickRatio': double.parse(
              (ticks / expectedTicks).toStringAsFixed(2),
            ),
          };
          expect(outcomes, everyElement(RuntimeStatus.deadline.name));
          expect(
            latencies.reduce(max),
            lessThan(_deadline.inMilliseconds.toDouble()),
          );
          expect(
            ticks / expectedTicks,
            greaterThan(0.5),
            reason: 'main run loop was blocked',
          );
          expect(_runtime.globalRefCount, _baselineGlobalRefs);
        },
      );
    }
  });

  group('WKWebView', () {
    testWidgets('replays MangaFire browser behaviour from a local fixture', (
      tester,
    ) async {
      const ua =
          'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/131.0.0.0 Mobile Safari/537.36';
      final WebViewReplayResult r = await WKWebViewReplay.run(
        html: _mangaFireReplayFixture,
        baseUrl: 'https://mangafire.to/',
        userAgent: ua,
        interfaceName: 'MangaFireBridge',
      );
      _report['wkwebview'] = {
        'pageReport': r.pageReport,
        'messageFrameIsMain': r.messageFrameIsMain,
        'messageOrigin': r.messageOrigin,
        'cookies': r.cookies,
        'storePersistent': r.storePersistent,
        'elapsedMs': r.elapsedMs,
        'requestObservation':
            'unsupported (no WKWebView interception for https)',
      };
      expect(r.pageReport['interfaceBeforePageScripts'], isTrue);
      expect(r.pageReport['documentStartRan'], isTrue);
      expect(r.pageReport['userAgent'], ua);
      expect(r.pageReport['origin'], 'https://mangafire.to');
      expect(r.pageReport['cookie'], contains('fixture_clearance=ok'));
      expect(r.messageFrameIsMain, isTrue);
      expect(r.messageOrigin, 'https://mangafire.to');
      expect(r.storePersistent, isFalse);
      expect(
        r.cookies.any((c) => c.startsWith('fixture_clearance=ok')),
        isTrue,
      );
    });
  });
}

Future<RuntimeEvent> _ok(Future<RuntimeEvent> f) async {
  final RuntimeEvent e = await f;
  expect(e.status, RuntimeStatus.ok, reason: '$e');
  return e;
}

Map<String, Object?> _section(String name) =>
    (_report[name] ??= <String, Object?>{}) as Map<String, Object?>;

int _elapsedNs(String result) =>
    int.parse(RegExp(r'elapsedNs=(\d+)').firstMatch(result)!.group(1)!);

Map<String, Object?> _stats(List<double> values) {
  if (values.isEmpty) return {'n': 0};
  final s = <double>[...values]..sort();
  double r(double v) => double.parse(v.toStringAsFixed(2));
  return {
    'n': s.length,
    'min': r(s.first),
    'median': r(s[s.length ~/ 2]),
    'max': r(s.last),
  };
}

// Local stand-in for the challenge page that keiyoushi's runWebViewBlocking
// loads with loadDataWithBaseURL. No network access: the page has no
// subresources. It records what the challenge script would see, sets a
// clearance-style cookie, and replies asynchronously through the injected
// `postMessage` interface (the helper's fallback path).
const String _mangaFireReplayFixture = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>replay</title>
<script>
(function () {
  var bridge = window.MangaFireBridge;
  var report = {
    interfaceBeforePageScripts: typeof bridge === 'object' && typeof bridge.postMessage === 'function',
    documentStartRan: window.__srtDocumentStart === true,
    userAgent: navigator.userAgent,
    clientHints: typeof navigator.userAgentData !== 'undefined',
    origin: location.origin,
    href: location.href
  };
  document.cookie = 'fixture_clearance=ok; path=/; Secure; SameSite=Lax';
  report.cookie = document.cookie;
  var h = 0, s = report.userAgent + '|' + report.origin;
  for (var i = 0; i < s.length; i++) { h = (h * 31 + s.charCodeAt(i)) | 0; }
  report.token = h;
  setTimeout(function () { bridge.postMessage(JSON.stringify(report)); }, 20);
})();
</script></head><body>challenge replay fixture</body></html>
''';
