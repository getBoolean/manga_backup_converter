// KTD25 evidence for the Tachi worker's browser close wait: how long closing a
// browser session takes on this machine, storage deletion included (the
// helper's `close` replies only once the session's data is deleted, KTD9).
//
//   dart run tool/benchmark_browser_close.dart [--samples N] [--warmup N] [--out <file>]
//
// Each sample opens a session, loads a loopback page that writes a cookie
// (script and Set-Cookie), localStorage and IndexedDB, and times
// `BrowserSession.close()` until it completes. The release helper is built
// first. Writes a result with the machine's identity and
// `rule.p99BrowserCloseMs`, the coefficient the Tachi sizing rule
// (`tachi-worker-sizing.json`) cites; `tool/check_benchmark_results.dart`
// checks the rule still equals it. Run on an idle machine.
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview/desktop_webview.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_contracts.dart';

import 'build_helper.dart';

const String _page = '''
<!doctype html><title>close benchmark</title><script>
document.cookie = 'script_cookie=1; path=/; max-age=3600';
localStorage.setItem('k', 'v'.repeat(1024));
window.ready = new Promise((resolve, reject) => {
  const open = indexedDB.open('bench', 1);
  open.onupgradeneeded = () => open.result.createObjectStore('s');
  open.onerror = () => reject(open.error);
  open.onsuccess = () => {
    const tx = open.result.transaction('s', 'readwrite');
    tx.objectStore('s').put('v'.repeat(4096), 'k');
    tx.oncomplete = () => resolve('stored');
    tx.onerror = () => reject(tx.error);
  };
});
</script>''';

Future<void> main(List<String> argv) async {
  var samples = 50;
  var warmup = 3;
  String? out;
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--samples':
        samples = int.parse(argv[++i]);
      case '--warmup':
        warmup = int.parse(argv[++i]);
      case '--out':
        out = argv[++i];
      default:
        stderr.writeln('usage: dart run tool/benchmark_browser_close.dart [--samples N] [--warmup N] [--out <file>]');
        exit(64);
    }
  }
  final packageDir = Directory(p.dirname(p.dirname(Platform.script.toFilePath())));
  final HelperBuild build = await buildHelper(packageDir: packageDir, release: true, log: stderr.writeln);
  final File helper = build.artifact.verifiedFile();

  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest r) {
    r.response.headers
      ..contentType = ContentType.html
      ..add('set-cookie', 'server_cookie=1; Path=/; Max-Age=3600');
    r.response.write(_page);
    r.response.close();
  });
  final Uri page = Uri.parse('http://127.0.0.1:${server.port}/page');
  final Directory dataRoot = Directory.systemTemp.createTempSync('dwv-close-bench');
  final port = DesktopBrowserPort(
    DesktopWebViewConfig(
      helperExecutable: helper,
      dataRoot: dataRoot,
      startupTimeout: const Duration(seconds: 60),
      shutdownGrace: const Duration(seconds: 30),
      allowVisibleWindows: false,
      offline: true,
      onLog: stderr.writeln,
    ),
  );
  const source = SourceIdentity(
    ecosystem: 'benchmark',
    packageId: 'benchmark.close',
    sourceId: 'close',
    artifact: ArtifactBinding(sha256: '00', kind: 'benchmark', version: '1'),
  );

  final measured = <double>[];
  try {
    for (var i = 0; i < warmup + samples; i++) {
      final BrowserOutcome<BrowserSession> opened = await port.openSession(
        const BrowserSessionRequest(source: source, generation: 1),
      );
      final BrowserSession session = switch (opened) {
        BrowserCompleted<BrowserSession>(:final BrowserSession value) => value,
        final BrowserOutcome<BrowserSession> other => throw StateError('open failed: $other'),
      };
      final BrowserOutcome<BrowserPage> loaded = await session.loadUrl(page);
      if (loaded is! BrowserCompleted<BrowserPage>) throw StateError('load failed: $loaded');
      final BrowserOutcome<String> stored = await session.evaluate('window.ready');
      if (stored case BrowserCompleted<String>(:final String value) when value != '"stored"') {
        throw StateError('storage was not written: $value');
      }
      final watch = Stopwatch()..start();
      final BrowserOutcome<void> closed = await session.close();
      watch.stop();
      if (closed is! BrowserCompleted<void>) throw StateError('close did not confirm deletion: $closed');
      if (i >= warmup) measured.add(watch.elapsedMicroseconds / 1000);
    }
  } finally {
    final HelperInfo? info = port.helperInfo;
    await port.dispose();
    await server.close(force: true);
    try {
      dataRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // The next start-up wipe removes it.
    }
    if (measured.length == samples) _write(out, measured, info, samples, warmup);
  }
}

double _round(double ms) => (ms * 10).roundToDouble() / 10;

/// Nearest-rank percentile of sorted [values].
double _percentile(List<double> values, double q) =>
    values[((q * values.length).ceil() - 1).clamp(0, values.length - 1)];

void _write(String? out, List<double> measured, HelperInfo? info, int samples, int warmup) {
  final sorted = List<double>.of(measured)..sort();
  final double p99 = _round(_percentile(sorted, 0.99));
  final String os = Platform.operatingSystem;
  final result = <String, Object?>{
    'recordedAt': DateTime.now().toUtc().toIso8601String(),
    'benchmark': 'packages/desktop_webview/tool/benchmark_browser_close.dart',
    'measures':
        'BrowserSession.close() on DesktopBrowserPort, from the call to its completion: the helper deletes the '
        "session's cookies, localStorage and IndexedDB, confirms, and destroys the WebView",
    'machine': <String, Object?>{
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'cpu': Platform.environment['PROCESSOR_IDENTIFIER'] ?? 'unknown',
      'logicalCores': Platform.numberOfProcessors,
      'engine': info?.engine,
      'engineVersion': info?.engineVersion,
      'helperVersion': info?.helperVersion,
      'helperBuild': 'release',
    },
    'warmupSessions': warmup,
    'samples': samples,
    'closeMs': <String, Object?>{
      'p50': _round(_percentile(sorted, 0.5)),
      'p99': p99,
      'max': _round(sorted.last),
      'all': <double>[for (final double v in sorted) _round(v)],
    },
    'rule': <String, Object?>{'p99BrowserCloseMs': p99},
  };
  final String path =
      out ??
      p.join(
        'docs',
        'validation',
        'source-runners',
        'desktop',
        'browser-close-$os-${DateTime.now().toUtc().toIso8601String().substring(0, 10)}.json',
      );
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(result)}\n');
  stdout.writeln('p50 ${result['closeMs']} -> $path');
}
