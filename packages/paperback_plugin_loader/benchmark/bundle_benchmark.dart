// Real-bundle QuickJS benchmark (KTD25, U6). Measures what the pinned
// Paperback 0.8/0.9 bundles need from a QuickJS runtime on this device, on
// replayed captures (no network), and derives the workload profile.
//
// Entry points: `paperback_bundles_benchmark_test.dart` (flutter test, JIT
// host) and `bundle_benchmark_main.dart` (built with `dart build cli`, so
// stack and recursion are also measured in an AOT executable like the
// worker's).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_runtime.dart';

/// One measured bundle operation on a replayed capture.
final class BundleWorkload {
  const BundleWorkload(this.repoDir, this.sourceId, this.family, this.site, this.op, {this.mangaId});

  final String repoDir;
  final String sourceId;
  final PaperbackApiFamily family;
  final String site;

  /// `load`, `search` or `details`.
  final String op;
  final String? mangaId;

  String get name => '$repoDir/$sourceId:$op';
}

const String _query = 'Onimai';
const String _onimaiMd = 'ed996855-70de-449f-bba2-e8e24224c14d';
const String _onimaiWc = '01J76XYF0TGKQ7XJ4XVPV1C0BP';
const PaperbackApiFamily _v08 = PaperbackApiFamily.v08;
const PaperbackApiFamily _v09 = PaperbackApiFamily.v09;

/// Every pinned bundle is loaded; search and details are measured for the
/// bundles whose captures complete them (MangaFire needs a browser, and the
/// 0.8 MangaDex capture met MangaDex's challenge).
const List<BundleWorkload> bundleWorkloads = <BundleWorkload>[
  BundleWorkload('inkdex-0.9', 'MangaDex', _v09, 'mangadex', 'load'),
  BundleWorkload('inkdex-0.9', 'MangaDex', _v09, 'mangadex', 'search'),
  BundleWorkload('inkdex-0.9', 'MangaDex', _v09, 'mangadex', 'details', mangaId: _onimaiMd),
  BundleWorkload('inkdex-0.9', 'WeebCentral', _v09, 'weebcentral', 'load'),
  BundleWorkload('inkdex-0.9', 'WeebCentral', _v09, 'weebcentral', 'search'),
  BundleWorkload('inkdex-0.9', 'WeebCentral', _v09, 'weebcentral', 'details', mangaId: _onimaiWc),
  BundleWorkload('gabrielcwt-0.8', 'WeebCentral', _v08, 'weebcentral', 'load'),
  BundleWorkload('gabrielcwt-0.8', 'WeebCentral', _v08, 'weebcentral', 'search'),
  BundleWorkload('gabrielcwt-0.8', 'WeebCentral', _v08, 'weebcentral', 'details', mangaId: _onimaiWc),
  BundleWorkload('numby-0.8', 'WeebCentral', _v08, 'weebcentral', 'load'),
  BundleWorkload('numby-0.8', 'WeebCentral', _v08, 'weebcentral', 'search'),
  BundleWorkload('numby-0.8', 'WeebCentral', _v08, 'weebcentral', 'details', mangaId: _onimaiWc),
  BundleWorkload('neihc1002-0.8', 'Mangadex', _v08, 'mangadex', 'load'),
  BundleWorkload('inkdex-0.9', 'MangaFire', _v09, 'mangafire', 'load'),
];

/// Runs the benchmark against `fixtures/source_captures/paperback` at
/// [fixtures].
Future<Map<String, Object?>> runBundleBenchmark(String fixtures, {int runs = 5, void Function(String)? log}) async {
  final int threadStack = QuickJs.threadStackAvailable()!;
  final int stackCeiling = threadStack ~/ 2;
  final device = DeviceCapability.measure(processors: Platform.numberOfProcessors, calibrationRuns: 15);
  final results = <String, Object?>{};
  var peakHeap = 0;
  var peakStack = 0;
  var slowest = 0;
  var slowestName = '';
  var maxOvershoot = 0;
  for (final BundleWorkload w in bundleWorkloads) {
    log?.call('measuring ${w.name}');
    final times = <int>[];
    var heap = 0;
    for (var i = 0; i < runs; i++) {
      final _Run r =
          await _runOnce(fixtures, w, stack: stackCeiling, heap: 1 << 30) ??
          (throw StateError('${w.name} failed under harness limits'));
      times.add(r.micros);
      heap = math.max(heap, r.peakBytes);
    }
    times.sort();
    final int? minHeap = await _minimal(
      1 << 20,
      heap * 3,
      256 * 1024,
      (int h) async => await _runOnce(fixtures, w, stack: stackCeiling, heap: h) != null,
    );
    final int? minStack = await _minimal(
      8 * 1024,
      stackCeiling,
      4 * 1024,
      (int s) async => await _runOnce(fixtures, w, stack: s, heap: 1 << 30) != null,
    );
    // Deadline overshoot on the real workload, with the engine deadline
    // placed inside the operation (mid-parse, mid-mapping) and just around
    // its end (where a late reply conversion would show). A load is a
    // sequence of steps, each with its own deadline, so for loads the
    // deadline lands in whichever step is running.
    final int median = _percentile(times, 0.5);
    final overshoots = <int>[];
    for (final fraction in <double>[0.2, 0.4, 0.6, 0.8, 0.95, 1.0, 1.05]) {
      final int at = math.max(200, (median * fraction).round());
      final int? o = await _deadlineOvershoot(fixtures, w, stack: stackCeiling, atMicros: at);
      if (o != null) overshoots.add(o);
    }
    overshoots.sort();
    peakHeap = math.max(peakHeap, minHeap ?? heap);
    peakStack = math.max(peakStack, minStack ?? stackCeiling);
    final int p95 = _percentile(times, 0.95);
    if (p95 > slowest) {
      slowest = p95;
      slowestName = w.name;
    }
    if (overshoots.isNotEmpty) maxOvershoot = math.max(maxOvershoot, overshoots.last);
    results[w.name] = <String, Object?>{
      'medianMicros': median,
      'p95Micros': p95,
      'peakAllocatedBytes': heap,
      'minimalHeapLimitBytes': minHeap,
      'minimalStackLimitBytes': minStack,
      'deadlineOvershootMicros': overshoots,
    };
  }

  // Native stack per JS call frame, measured the same way as U5.
  final SourceJsRuntime probe = _runtime(stack: stackCeiling, heap: 1 << 28);
  final depth = (await probe.evaluate('var d = 0; function f() { d++; f(); } try { f(); } catch (e) {} d'))! as int;
  probe.dispose();
  final int frameBytes = stackCeiling ~/ depth;

  final (int toDartMicros, int encodeMicros) = await _replyTail(fixtures);

  final profile = QuickJsWorkloadProfile(
    source:
        'U6 real Paperback bundles (${bundleWorkloads.length} workloads, replayed captures), '
        '${Platform.operatingSystem}, ${Platform.resolvedExecutable.split(Platform.pathSeparator).last}',
    peakHeapBytes: peakHeap,
    peakStackBytes: peakStack,
    slowestOperation: Duration(microseconds: slowest),
    referenceCalibration: device.calibration,
  );
  return <String, Object?>{
    'benchmark': 'paperback-bundles-v1',
    'engine': QuickJs.engineVersion,
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'dartVersion': Platform.version.split(' ').first,
    'executable': Platform.resolvedExecutable.split(Platform.pathSeparator).last,
    'device': device.toJson(),
    'threadStackAvailableBytes': threadStack,
    'stackCeilingBytes': stackCeiling,
    'jsFrameStackBytes': frameBytes,
    'maxRecursionDepthAtStackCeiling': depth,
    'workloads': results,
    'slowestOperation': slowestName,
    'maxDeadlineOvershootMicros': maxOvershoot,
    'largestReplyToDartMicros': toDartMicros,
    'largestReplyEncodeMicros': encodeMicros,
    'profile': profile.toJson(),
  };
}

final class _Run {
  const _Run(this.micros, this.peakBytes);

  final int micros;
  final int peakBytes;
}

SourceJsRuntime _runtime({required int stack, required int heap}) => SourceJsRuntime(
  limits: PaperbackRuntimeLimits(
    memoryLimitBytes: heap,
    maxStackBytes: stack,
    operationDeadline: const Duration(minutes: 2),
    jobSlice: const Duration(milliseconds: 20),
  ),
);

/// Loads [w]'s bundle in a fresh runtime with the given limits; for search
/// and details, then runs the operation. Times the measured step only, with
/// the bundle's rate-limiter sleeps made instant (they are host waits, sized
/// by the host-wait allowance, not QuickJS CPU). Null on failure.
Future<_Run?> _runOnce(String fixtures, BundleWorkload w, {required int stack, required int heap}) async {
  final SourceJsRuntime runtime;
  try {
    runtime = _runtime(stack: stack, heap: heap);
  } on Object {
    return null;
  }
  try {
    final PaperbackSourceHost host = _host(fixtures, w, runtime);
    final watch = Stopwatch();
    if (w.op == 'load') {
      runtime.engine.resetPeakAllocated();
      watch.start();
      await _load(fixtures, w, host);
    } else {
      await _load(fixtures, w, host);
      _instantSleeps(runtime);
      runtime.engine.resetPeakAllocated();
      watch.start();
      await _op(w, host);
    }
    watch.stop();
    return _Run(watch.elapsedMicroseconds, runtime.isClosed ? 0 : runtime.engine.peakAllocatedBytes);
  } on PaperbackRuntimeException {
    return null;
  } finally {
    runtime.dispose();
  }
}

/// How long [w] keeps running after its engine deadline fires, with the
/// deadline placed [atMicros] into the operation: the interrupt handler's
/// polling delay inside JS, the Dart deadline timer while JS waits on the
/// host, and the reply conversion that runs after JS settles. A late
/// success (JS finished just before the deadline, conversion just after)
/// counts too. Null when the operation finished before its deadline.
Future<int?> _deadlineOvershoot(String fixtures, BundleWorkload w, {required int stack, required int atMicros}) async {
  final SourceJsRuntime runtime = _runtime(stack: stack, heap: 1 << 30);
  try {
    final PaperbackSourceHost host = _host(fixtures, w, runtime);
    if (w.op != 'load') {
      await _load(fixtures, w, host);
      _instantSleeps(runtime);
    }
    // ignore: invalid_use_of_visible_for_testing_member
    runtime.operationDeadlineOverride = Duration(microseconds: atMicros);
    final watch = Stopwatch()..start();
    try {
      if (w.op == 'load') {
        await _load(fixtures, w, host);
      } else {
        await _op(w, host);
      }
    } on PaperbackRuntimeException {
      // Stopped by the deadline (or a load step exceeded it).
    }
    final int over = watch.elapsedMicroseconds - atMicros;
    return over > 0 ? over : null;
  } finally {
    runtime.dispose();
  }
}

PaperbackSourceHost _host(String fixtures, BundleWorkload w, SourceJsRuntime runtime) => PaperbackSourceHost(
  runtime: runtime,
  http: PaperbackHttp(MultiReplayHttpClient.load(<Directory>[Directory('$fixtures/${w.site}')])),
);

Future<void> _load(String fixtures, BundleWorkload w, PaperbackSourceHost host) {
  final Uint8List bytes = _bundle(fixtures, w);
  return host.load(
    bytes,
    ArtifactBinding(sha256: bundleDigest(bytes), kind: w.family.artifactKind, version: 'bench'),
    SettingsPayload.fromSnapshot(SettingsSnapshot()),
  );
}

Future<void> _op(BundleWorkload w, PaperbackSourceHost host) async {
  if (w.op == 'search') {
    await host.search(w.sourceId, _query, null);
  } else {
    await host.details(w.sourceId, w.mangaId!);
  }
}

/// Makes timers fire on the next microtask, so the bundles' rate-limiter
/// sleeps (`Application.sleep`, `requestsPerSecond` spacing) cost no wall
/// time: they are host waits, sized by the host-wait allowance, not QuickJS
/// CPU. Applied after the load, so the load itself is unchanged.
void _instantSleeps(SourceJsRuntime runtime) {
  final JsValue v = runtime.context.eval(
    'globalThis.setTimeout = (fn, ms, ...args) => { Promise.resolve().then(() => fn(...args)); return 0; }; void 0;',
  );
  v.dispose();
}

Uint8List _bundle(String fixtures, BundleWorkload w) {
  final manifest = jsonDecode(File('$fixtures/${w.repoDir}/artifacts.json').readAsStringSync()) as Map<String, Object?>;
  final Map<String, Object?> pin = (manifest['bundles']! as List<Object?>).cast<Map<String, Object?>>().firstWhere(
    (Map<String, Object?> b) => b['sourceId'] == w.sourceId,
  );
  return File('$fixtures/${w.repoDir}/${pin['path']}').readAsBytesSync();
}

/// The post-JS tail of the largest reply (MangaDex details, 223 chapters):
/// converting the settled JS value to Dart and encoding the protocol frame.
/// Both run after JS settles, so the engine deadline cannot stop them; the
/// supervisor's deadline must leave room for them.
Future<(int, int)> _replyTail(String fixtures) async {
  const w = BundleWorkload('inkdex-0.9', 'MangaDex', _v09, 'mangadex', 'details', mangaId: _onimaiMd);
  final SourceJsRuntime runtime = _runtime(stack: 256 * 1024, heap: 1 << 30);
  try {
    final PaperbackSourceHost host = _host(fixtures, w, runtime);
    await _load(fixtures, w, host);
    _instantSleeps(runtime);
    final Map<String, Object?> details = await host.details(w.sourceId, w.mangaId!);
    await runtime.evaluate('globalThis.__benchReply = ${jsonEncode(details)}; void 0;');
    final toDart = Stopwatch()..start();
    await runtime.evaluate('__benchReply');
    toDart.stop();
    final encode = Stopwatch()..start();
    final reply = WorkerDetailsResponse(
      metadata: metadataOf(details),
      chapters: chaptersOf(details, PaperbackApiFamily.v09),
    );
    encodeFrame(ProtocolFrame(type: FrameType.response, id: '1-1', generation: 1, ok: reply.toJson()));
    encode.stop();
    return (toDart.elapsedMicroseconds, encode.elapsedMicroseconds);
  } finally {
    runtime.dispose();
  }
}

Future<int?> _minimal(int low, int high, int step, Future<bool> Function(int) ok) async {
  if (!await ok(high)) return null;
  var lo = low;
  var hi = high;
  while (hi - lo > step) {
    final int mid = lo + (hi - lo) ~/ 2;
    if (await ok(mid)) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi;
}

int _percentile(List<int> sorted, double p) => sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];
