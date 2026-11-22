// QuickJS limit benchmark (KTD25). Measures what synthetic Paperback-like
// workloads need on this device and applies the sizing rule.
//
// Run from the repository root:
//   flutter test packages/paperback_plugin_loader/benchmark/quickjs_limits_benchmark.dart
// Set QJS_BENCH_OUT=<file> to also write the JSON results to a file.
//
// The workloads are synthetic stand-ins until U6 supplies real Paperback
// bundles; no network is used (host calls are served in-process).
@TestOn('vm')
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

/// Repetitions per timed workload.
const int runs = 7;

/// Generous measurement-only limits; never shipped.
const int harnessHeap = 1024 * 1024 * 1024;

/// One synthetic workload.
final class Workload {
  const Workload(this.name, this.description, this.setup, this.script);

  final String name;
  final String description;

  /// Code evaluated before timing (not measured).
  final String setup;

  /// The measured operation; may return a promise.
  final String script;
}

/// A deterministic ~1 MiB bundle: many functions, closures and a large
/// object table, like a bundled source with its dependencies.
String syntheticBundle({int functions = 2500}) {
  final b = StringBuffer('var Bundle = (function(){ var exports = {}; var table = [');
  for (var i = 0; i < functions; i++) {
    b.write('{id:$i,name:"entry-$i",tags:["a$i","b${i % 7}"],score:${i * 31 % 997}},');
  }
  b.write('];');
  for (var i = 0; i < functions; i++) {
    b.write(
      'exports.f$i = function(x){ var s = 0; for (var k = 0; k < 3; k++) { s += (x + k * $i) % 13; } '
      'return table[(s + $i) % table.length].name + ":" + s; };',
    );
  }
  b.write('exports.count = table.length; return exports; })();');
  return b.toString();
}

/// A deterministic HTML page of [items] result cards.
String syntheticHtml(int items) {
  final b = StringBuffer('<html><head><title>Search</title></head><body><div class="results">');
  for (var i = 0; i < items; i++) {
    b
      ..write('<div class="card" data-id="$i"><a href="/manga/$i" title="Title $i">')
      ..write('<img src="/covers/$i.jpg" alt="cover"></a><h3 class="name">Manga title number $i</h3>')
      ..write('<span class="chapters">${i % 300} chapters</span><p class="desc">${'lorem ipsum ' * 6}</p></div>');
  }
  b.write('</div></body></html>');
  return b.toString();
}

/// A regex tokenizer that builds a DOM-like tree and runs a selector-style
/// query, standing in for Cheerio parsing.
const String parserSource = r'''
function parseHtml(html) {
  var root = { tag: '#root', attrs: {}, children: [], parent: null }, cur = root;
  var re = /<\/?([a-zA-Z0-9]+)([^>]*)>|([^<]+)/g, m;
  var voids = { img: 1, br: 1, meta: 1, link: 1, input: 1 };
  while ((m = re.exec(html)) !== null) {
    if (m[3] !== undefined) { cur.children.push({ text: m[3] }); continue; }
    if (m[0][1] === '/') { if (cur.parent) cur = cur.parent; continue; }
    var attrs = {}, a, ar = /([a-zA-Z-]+)="([^"]*)"/g;
    while ((a = ar.exec(m[2])) !== null) attrs[a[1]] = a[2];
    var node = { tag: m[1].toLowerCase(), attrs: attrs, children: [], parent: cur };
    cur.children.push(node);
    if (!voids[node.tag]) cur = node;
  }
  return root;
}
function selectAll(node, cls, out) {
  if (node.attrs && (' ' + (node.attrs['class'] || '') + ' ').indexOf(' ' + cls + ' ') >= 0) out.push(node);
  if (node.children) for (var i = 0; i < node.children.length; i++) selectAll(node.children[i], cls, out);
  return out;
}
function textOf(node) {
  if (node.text !== undefined) return node.text;
  var s = ''; for (var i = 0; i < node.children.length; i++) s += textOf(node.children[i]); return s;
}
''';

List<Workload> workloads() => <Workload>[
  Workload('bundle-eval', 'Evaluate a ~1 MiB synthetic bundle and call into it', '', '''
    (function(){ ${syntheticBundle()}; var r = 0; for (var i = 0; i < 2500; i += 7) r += Bundle['f' + i](i).length; return r; })()
  '''),
  Workload(
    'html-parse',
    'Parse a ~600 KiB results page into a tree and extract 1000 cards',
    '$parserSource var PAGE = ${jsonEncode(syntheticHtml(1000))};',
    '''
    (function(){ var doc = parseHtml(PAGE); var cards = selectAll(doc, 'card', []);
      return cards.map(function(c){ return { id: c.attrs['data-id'], title: textOf(selectAll(c, 'name', [])[0]) }; }).length; })()
  ''',
  ),
  const Workload('json-response', 'Fetch a ~2 MiB JSON response through the promise bridge and map it', '', '''
    (async function(){ var res = await __bench.fetchJson(); var data = JSON.parse(res);
      return data.results.map(function(r){ return { id: r.id, title: r.attributes.title.en, n: r.relationships.length }; }).length; })()
  '''),
  const Workload('deep-tree', 'Recursive descent over a 64-level nested structure (deep DOM nesting)', '''
    var DEEP = (function(){ var n = { v: 0 }; for (var i = 1; i < 64; i++) n = { v: i, child: n }; return n; })();
    function walk(n) { return n.child ? walk(n.child) + n.v : n.v; }
  ''', 'walk(DEEP)'),
  const Workload('await-loop', '2000 sequential awaits on host calls', '', '''
    (async function(){ var s = 0; for (var i = 0; i < 2000; i++) s += await __bench.echo(i); return s; })()
  '''),
];

/// ~2 MiB of JSON shaped like a manga API search response.
final String jsonPayload = jsonEncode(<String, Object?>{
  'results': <Object?>[
    for (var i = 0; i < 4000; i++)
      <String, Object?>{
        'id': 'id-$i',
        'attributes': <String, Object?>{
          'title': <String, Object?>{'en': 'Title $i'},
          'description': <String, Object?>{'en': 'description ' * 20},
          'tags': <Object?>[for (var t = 0; t < 5; t++) 'tag-$t'],
        },
        'relationships': <Object?>[
          for (var r = 0; r < 3; r++) <String, Object?>{'id': 'rel-$r', 'type': 'author'},
        ],
      },
  ],
});

SourceJsRuntime newRuntime({required int stack, int heap = harnessHeap, Duration? deadline}) {
  final runtime = SourceJsRuntime(
    limits: PaperbackRuntimeLimits(
      memoryLimitBytes: heap,
      maxStackBytes: stack,
      operationDeadline: deadline ?? const Duration(minutes: 2),
      jobSlice: const Duration(milliseconds: 20),
    ),
    name: 'bench',
  );
  try {
    runtime.bridge
      ..registerAsync('__bench.fetchJson', (List<Object?> _) async => jsonPayload)
      ..registerAsync('__bench.echo', (List<Object?> a) async => a.first);
  } on JsException catch (e) {
    runtime.dispose();
    throw PaperbackRuntimeException(
      RuntimeUnavailableFailure('host functions did not fit: $e'),
      reason: PaperbackFailureReason.memoryLimit,
    );
  }
  return runtime;
}

/// Runs [w] once in a fresh runtime; returns (micros, peak bytes) or null if
/// it failed under the given limits.
Future<(int, int)?> runOnce(Workload w, {required int stack, int heap = harnessHeap}) async {
  final SourceJsRuntime runtime;
  try {
    runtime = newRuntime(stack: stack, heap: heap);
  } on PaperbackRuntimeException {
    return null;
  }
  try {
    if (w.setup.isNotEmpty) await runtime.evaluate(w.setup);
    runtime.engine.resetPeakAllocated();
    final watch = Stopwatch()..start();
    await runtime.evaluate(w.script);
    final int micros = watch.elapsedMicroseconds;
    return (micros, runtime.isClosed ? 0 : runtime.engine.peakAllocatedBytes);
  } on PaperbackRuntimeException {
    return null;
  } finally {
    runtime.dispose();
  }
}

/// Smallest value in [lo, hi] (to [step] precision) for which [ok] holds.
Future<int?> minimal(int low, int high, int step, Future<bool> Function(int) ok) async {
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

int percentile(List<int> sorted, double p) => sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];

void main() {
  test('QuickJS limits benchmark', () async {
    final int threadStack = QuickJs.threadStackAvailable()!;
    final int stackCeiling = threadStack ~/ 2;
    final device = DeviceCapability.measure(processors: Platform.numberOfProcessors, calibrationRuns: 15);
    final results = <String, Object?>{};
    var peakHeap = 0;
    var peakStack = 0;
    var slowest = 0;

    for (final Workload w in workloads()) {
      final times = <int>[];
      var heap = 0;
      for (var i = 0; i < runs; i++) {
        final (int, int)? r = await runOnce(w, stack: stackCeiling);
        if (r == null) throw StateError('${w.name} failed under harness limits');
        times.add(r.$1);
        heap = math.max(heap, r.$2);
      }
      times.sort();
      // Smallest heap and stack limits under which the workload still passes.
      final int? minHeap = await minimal(
        64 * 1024,
        heap * 4,
        64 * 1024,
        (int h) async => await runOnce(w, stack: stackCeiling, heap: h) != null,
      );
      final int? minStack = await minimal(
        8 * 1024,
        stackCeiling,
        4 * 1024,
        (int s) async => await runOnce(w, stack: s) != null,
      );
      peakHeap = math.max(peakHeap, minHeap ?? heap);
      peakStack = math.max(peakStack, minStack ?? stackCeiling);
      slowest = math.max(slowest, percentile(times, 0.95));
      results[w.name] = <String, Object?>{
        'description': w.description,
        'medianMicros': percentile(times, 0.5),
        'p95Micros': percentile(times, 0.95),
        'peakAllocatedBytes': heap,
        'minimalHeapLimitBytes': minHeap,
        'minimalStackLimitBytes': minStack,
      };
    }

    // Native stack per JS call frame: how deep recursion can go per byte.
    final SourceJsRuntime frameProbe = newRuntime(stack: stackCeiling);
    final depth =
        await frameProbe.evaluate('var d = 0; function f() { d++; f(); } try { f(); } catch (e) {} d') as int?;
    frameProbe.dispose();
    final int frameBytes = stackCeiling ~/ depth!;

    // How far past a 50 ms deadline a busy loop actually stops.
    final overshoots = <int>[];
    for (var i = 0; i < runs; i++) {
      final SourceJsRuntime r = newRuntime(stack: stackCeiling, deadline: const Duration(milliseconds: 50));
      final watch = Stopwatch()..start();
      try {
        await r.evaluate('for (;;) {}');
      } on PaperbackRuntimeException {
        overshoots.add(watch.elapsedMicroseconds - 50000);
      } finally {
        r.dispose();
      }
    }
    overshoots.sort();

    final profile = QuickJsWorkloadProfile(
      source: 'synthetic workloads, ${Platform.operatingSystem} ${QuickJs.valueSize * 8 ~/ 2}-bit JSValue build',
      peakHeapBytes: peakHeap,
      peakStackBytes: peakStack,
      slowestOperation: Duration(microseconds: slowest),
      referenceCalibration: device.calibration,
    );
    final sizing = <String, Object?>{
      for (final int concurrent in <int>{1, 4, Platform.numberOfProcessors})
        'concurrent-$concurrent': deriveQuickJsLimits(
          device: device,
          profile: profile,
          policy: provisionalSizingPolicy,
          concurrentRuntimes: concurrent,
          hostWaitAllowance: Duration.zero,
        ).toJson(),
    };
    final report = <String, Object?>{
      'benchmark': 'quickjs-limits-v1',
      'engine': QuickJs.engineVersion,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version.split(' ').first,
      'device': device.toJson(),
      'workloads': results,
      'jsFrameStackBytes': frameBytes,
      'maxRecursionDepthAtStackCeiling': depth,
      'stackCeilingBytes': stackCeiling,
      'interruptOvershootMicros': <String, Object?>{
        'median': percentile(overshoots, 0.5),
        'max': overshoots.last,
      },
      'profile': profile.toJson(),
      'sizing': sizing,
    };
    final String json = const JsonEncoder.withIndent('  ').convert(report);
    stdout.writeln(json);
    final String? out = Platform.environment['QJS_BENCH_OUT'];
    if (out != null) File(out).writeAsStringSync('$json\n');
  });
}
