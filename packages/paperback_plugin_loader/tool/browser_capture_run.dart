// The browser recorder of `capture_paperback_sources.dart --browser`
// (manual capture runs only; no test runs it).
//
// The worker's `executeInWebView` calls go to the desktop WebView helper in
// record mode (`--record`, WebView2), and every main-frame and subresource
// exchange the page makes (page scripts, XHR, fetch) is written through the
// capture format into `<out>/browser/`, sanitised like the worker's capture
// (allowed response headers and allow-listed cookies only). The worker's
// HTTP and the browser are recorded in the same session, because tokens the
// page computes end up in the worker's request URLs. Then, in the same
// invocation and fully offline, the scenario is replayed from `<out>`
// (worker `--replay`, helper offline with `BrowserCaptureReplay`) and every
// miss is printed: a recording that does not replay is never merged.
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview/desktop_webview.dart';
import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

import '../test/support/paperback_scenarios.dart';
import 'sanitize_captures.dart';

/// Limits of the capture worker (generous: a capture is never time-critical).
const List<String> captureWorkerLimits = <String>[
  '--memory-limit-bytes=${256 << 20}',
  '--max-stack-bytes=${512 << 10}',
  '--operation-deadline-ms=600000',
  '--job-slice-ms=20',
  '--deadline-headroom-ms=1000',
];

/// The capture worker's recording arguments for [site] into [dir].
List<String> recordArguments(String site, Directory dir) => <String>[
  '--record=${dir.path}',
  '--record-source=$site',
  '--record-min-interval-ms=1500',
  '--record-licence=${captureTerms[site]}',
  for (final MapEntry<String, CapturedCookieValue> c
      in (captureSetCookies[site] ?? const <String, CapturedCookieValue>{}).entries)
    '--record-cookie=${c.key}:${c.value.name}',
];

/// The desktop helper and the bridge that serves the worker's
/// `host.browser.*` requests from it.
final class _Browser {
  _Browser._(this.port, this.bridge);

  final DesktopBrowserPort port;
  final BrowserReverseBridge bridge;

  factory _Browser.start({
    required Directory dataRoot,
    required SourceIdentity? Function(String? packageId, String sourceId) resolve,
    BrowserCaptureRecorder? recorder,
    BrowserCaptureReplay? replay,
  }) {
    final manifest = File('${repoRootDir().path}/packages/desktop_webview/build/helper/runtime-artifacts.json');
    final RuntimeArtifact? helper = manifest.existsSync()
        ? RuntimeArtifactManifest.load(manifest).findForHost(RuntimeArtifactManifest.webviewHelper)
        : null;
    if (helper == null) {
      throw StateError('desktop WebView helper not built: dart run tool/build_helper.dart in packages/desktop_webview');
    }
    final port = DesktopBrowserPort(
      DesktopWebViewConfig(
        helperExecutable: helper.verifiedFile(),
        dataRoot: dataRoot,
        startupTimeout: const Duration(seconds: 60),
        shutdownGrace: const Duration(seconds: 10),
        allowVisibleWindows: false,
        offline: replay != null,
        replay: replay,
        onExchange: recorder?.call,
        onLog: stderr.writeln,
      ),
    );
    final bridge = BrowserReverseBridge(
      port: port,
      resolveSource: resolve,
      interactionTimeout: const Duration(seconds: 10),
      replacementTimeout: const Duration(seconds: 30),
      onLog: stderr.writeln,
    );
    return _Browser._(port, bridge);
  }

  Future<void> close() async {
    await bridge.close();
    await port.dispose();
  }
}

/// Runs the site scenario through a fresh worker (`exe` with [workerArgs])
/// joined to a desktop helper (recording with [recorder], or offline over
/// [replay]).
Future<List<BundleRun>> _runWithBrowser(
  String site,
  String exe, {
  required String? only,
  required List<String> workerArgs,
  BrowserCaptureRecorder? recorder,
  BrowserCaptureReplay? replay,
}) async {
  final Directory scratch = Directory.systemTemp.createTempSync('paperback_capture_');
  late final PaperbackSourceProvider provider;
  final browser = _Browser.start(
    dataRoot: Directory('${scratch.path}/webview')..createSync(),
    resolve: (String? packageId, String sourceId) => provider.browserIdentity(packageId, sourceId),
    recorder: recorder,
    replay: replay,
  );
  final supervisor = WorkerSupervisor(
    spec: WorkerSpec(
      label: 'paperback-capture',
      executable: exe,
      arguments: <String>[...captureWorkerLimits, ...workerArgs],
      environment: scrubbedEnvironment(),
    ),
    limits: const SupervisorLimits(
      maxConcurrentPackages: 1,
      operationDeadline: Duration(minutes: 11),
      cancelGrace: Duration(seconds: 10),
      interactionTimeout: Duration(seconds: 10),
      shutdownGrace: Duration(minutes: 1),
    ),
    onLog: stderr.writeln,
    onReverseRequest: browser.bridge.handle,
    onGenerationFenced: browser.bridge.fence,
  );
  browser.bridge.emitEvent = supervisor.sendEvent;
  final repos = <PinnedRepository>[
    for (final PinnedBundle b in captureSites[site]!)
      if (only == null || b.label == only) PinnedRepository.load(b.repoDir),
  ];
  final client = http.Client();
  provider = PaperbackSourceProvider(
    // Catalogs and bundles come from the fixtures; the scenario never uses it.
    client: client,
    cache: ArtifactCache(Directory('${scratch.path}/cache')),
    trust: PinnedRepository.pinnedTrust(repos),
    worker: () async => (await supervisor.start()).map((_) => supervisor),
  );
  try {
    return await runSiteScenario(provider, site, only: only);
  } finally {
    // The worker writes its capture on shutdown.
    await supervisor.close();
    await browser.close();
    client.close();
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // The browser may still hold its data directory; the next helper start wipes it.
    }
  }
}

/// Records [site] (one bundle, [only]) into the empty scratch [dir]: the
/// worker's HTTP into `dir`, the browser into `dir/browser`; then replays both
/// offline and reports every miss.
Future<void> captureWithBrowser(String site, String exe, {required String only, required Directory dir}) async {
  stdout.writeln('== $site (browser recorder) -> ${dir.path}');
  final recorder = BrowserCaptureRecorder(
    CaptureRecorder(
      licence: captureTerms[site]!,
      setCookieAllowList: captureSetCookies[site] ?? const <String, CapturedCookieValue>{},
    ),
    // The site's own hosts only (browserCaptureHosts); never Cloudflare's /cdn-cgi/.
    include: (Uri url) => keepBrowserExchange(site, url),
  );
  final List<BundleRun> recorded = await _runWithBrowser(
    site,
    exe,
    only: only,
    workerArgs: recordArguments(site, dir),
    recorder: recorder,
  );
  final browserDir = Directory('${dir.path}/browser')..createSync(recursive: true);
  recorder.recorder.writeTo(
    browserDir,
    ecosystem: 'paperback',
    source: '$site-browser',
    notes: 'Recorded by capture_paperback_sources.dart --browser (desktop helper --record); sanitized',
  );
  sanitizeCaptureDir(dir);
  sanitizeCaptureDir(browserDir);
  final String report = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    'site': site,
    'query': queryFor(site),
    'recordedAt': DateTime.now().toUtc().toIso8601String(),
    'runs': <Object?>[for (final BundleRun r in recorded) r.toJson()],
    'browser': <String, Object?>{
      'recorded': recorder.recorder.length,
      'skipped': recorder.skipped,
      'dropped': recorder.dropped.length,
      'hosts': <String>{for (final CaptureExchange e in recorder.recorder.exchanges) Uri.parse(e.key.url).host}
          .toList(),
    },
  });
  stdout.writeln(report);
  File('${dir.path}/scenario.json').writeAsStringSync('$report\n');
  await minimiseBrowserCapture(site, exe, only: only, dir: dir);
}

/// Prunes the browser capture in `<dir>/browser` to what replay needs, with
/// no network: the site's hosts only ([keepBrowserExchange], for a recording
/// made before that rule), then only the exchanges an offline replay of the
/// scenario served (the recorder also sees the documents the source itself
/// generated for `loadData`, which replay never asks for), and replays it
/// once more to confirm.
Future<void> minimiseBrowserCapture(String site, String exe, {required String only, required Directory dir}) async {
  _pruneBrowserCapture(
    dir,
    (CaptureExchange e) => keepBrowserExchange(site, Uri.parse(e.key.url)),
    'kept only ${browserCaptureHosts[site]!.join(', ')} outside /cdn-cgi/',
  );
  final Set<CaptureKey> served = await verifyBrowserCapture(site, exe, only: only, dir: dir);
  _pruneBrowserCapture(dir, (CaptureExchange e) => served.contains(e.key), 'kept only what an offline replay served');
  await verifyBrowserCapture(site, exe, only: only, dir: dir);
}

/// Removes from the browser capture in `<dir>/browser` every exchange [keep]
/// rejects, with their bodies, and sanitises it again. No network.
void _pruneBrowserCapture(Directory dir, bool Function(CaptureExchange e) keep, String note) {
  final browserDir = Directory('${dir.path}/browser');
  final manifestFile = File('${browserDir.path}/$captureManifestFileName');
  final manifest = CaptureManifest.fromJson(jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>);
  final kept = <CaptureExchange>[
    for (final CaptureExchange e in manifest.exchanges)
      if (keep(e)) e,
  ];
  final bodies = <String>{for (final CaptureExchange e in kept) e.bodyFile};
  for (final CaptureExchange e in manifest.exchanges) {
    final body = File('${browserDir.path}/${e.bodyFile}');
    if (!bodies.contains(e.bodyFile) && body.existsSync()) body.deleteSync();
  }
  manifestFile.writeAsStringSync(
    CaptureManifest(
      ecosystem: manifest.ecosystem,
      source: manifest.source,
      recordedAt: manifest.recordedAt,
      notes: manifest.notes.contains(note) ? manifest.notes : '${manifest.notes}; $note',
      volatileQueryParameters: manifest.volatileQueryParameters,
      setCookieAllowList: manifest.setCookieAllowList,
      exchanges: kept,
    ).encode(),
  );
  sanitizeCaptureDir(browserDir);
  stdout.writeln('pruned ${browserDir.path}: kept ${kept.length} of ${manifest.exchanges.length} exchanges');
}

/// Replays the recording in [dir] offline (worker `--replay`, the helper
/// offline over `<dir>/browser`), prints the results and every miss, and
/// returns the browser requests it served.
Future<Set<CaptureKey>> verifyBrowserCapture(
  String site,
  String exe, {
  required String only,
  required Directory dir,
}) async {
  stdout.writeln('== offline replay of ${dir.path}');
  final replay = BrowserCaptureReplay(loadCaptureSet(Directory('${dir.path}/browser')));
  final List<BundleRun> replayed = await _runWithBrowser(
    site,
    exe,
    only: only,
    workerArgs: <String>['--replay=${dir.path}'],
    replay: replay,
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(<Object?>[for (final BundleRun r in replayed) r.toJson()]));
  stdout.writeln('browser replay: ${replay.served.length} served, ${replay.misses.length} missed');
  for (final CaptureKey k in replay.misses) {
    stdout.writeln('  miss ${k.method} ${k.url}');
  }
  return replay.served.toSet();
}
