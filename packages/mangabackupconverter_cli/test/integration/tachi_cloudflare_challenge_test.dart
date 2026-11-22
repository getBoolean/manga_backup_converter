// A Cloudflare-style challenge solved through the real desktop WebView
// helper from the real Tachi JVM worker (protocol 1.3 `host.browser.show`).
//
// The site is a loopback server (tests never contact a server): every
// request without its clearance cookie gets a 403 challenge page (`Server:
// cloudflare`, `cf-mitigated: challenge`). The page sets `cf_clearance` and
// reloads only once its window is visible, after a scripted delay, so it
// stands in for a challenge a person solves. The server binds the clearance
// to the user agent that first presents it, as Cloudflare does, so the
// worker's retry must carry the browser's user agent. The `cloudflare`
// fixture extension (`./gradlew fixtureJar_cloudflare`) only calls
// `network.client`; the solve is the host's interceptor.
//
// Interactive runs pass the worker `--interactive-challenges` (as the CLI
// does) and show the helper's window (it appears briefly on screen);
// unattended runs never open a session.
@TestOn('vm')
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:desktop_webview/desktop_webview.dart';
import 'package:mangabackupconverter_cli/src/commands/desktop_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';
import 'package:test/scaffolding.dart';

const String _packageId = 'fixture.cloudflare';
const String _sourceId = '301';

final ({TachiWorkerLocation? location, String? skip}) _worker = testWorkerLocation();

File _fixtureJar() =>
    File(p.join(repositoryRoot().path, 'tools', 'tachi-source-runner', 'build', 'fx', 'fixture-cloudflare.jar'));

/// How the challenge page behaves.
enum _Page {
  /// Solves 1 s after its window becomes visible.
  solvesWhenVisible,

  /// Solves [_slowSolve] after its window becomes visible: longer than the operation deadline.
  solvesSlowly,

  /// Never solves.
  never,
}

/// Longer than the slow test's operation deadline (10 s), which still has
/// to cover opening the session and loading the page before the show.
const Duration _slowSolve = Duration(seconds: 15);

/// The loopback "site".
final class _ChallengeSite {
  _ChallengeSite(this.page);

  final _Page page;
  late final HttpServer _server;
  final List<String> log = <String>[];
  int _issued = 0;
  final Map<String, String?> _boundUserAgents = <String, String?>{};

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  Future<void> close() => _server.close(force: true);

  void _serve(HttpRequest request) {
    final String ua = request.headers.value('user-agent') ?? '';
    final String? token = request.cookies
        .where((Cookie c) => c.name == 'cf_clearance')
        .map((Cookie c) => c.value)
        .firstOrNull;
    final bool known = token != null && _boundUserAgents.containsKey(token);
    if (known) _boundUserAgents[token] ??= ua;
    final bool cleared = known && _boundUserAgents[token] == ua;
    log.add('${request.uri.path} cleared=$cleared');
    final HttpResponse response = request.response;
    if (cleared && request.uri.path == '/search') {
      response
        ..headers.contentType = ContentType.text
        ..write('/m/1|Solved title\n');
    } else if (cleared) {
      response
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><title>ok</title>passed');
    } else {
      final issued = 'clear-${++_issued}';
      _boundUserAgents[issued] = null;
      final int? delayMs = switch (page) {
        _Page.solvesWhenVisible => 1000,
        _Page.solvesSlowly => _slowSolve.inMilliseconds,
        _Page.never => null,
      };
      response
        ..statusCode = HttpStatus.forbidden
        ..headers.set('Server', 'cloudflare')
        ..headers.set('cf-mitigated', 'challenge')
        ..headers.contentType = ContentType.html
        ..write(_challengeHtml(issued, delayMs));
    }
    unawaited(response.close());
  }

  static String _challengeHtml(String token, int? delayMs) =>
      '''
<!doctype html><html><head><title>Just a moment...</title></head>
<body><div id="challenge-platform">cf-chl simulated</div>
<script>
const delayMs = ${delayMs ?? 'null'};
function solve() {
  setTimeout(() => { document.cookie = 'cf_clearance=$token; path=/'; location.reload(); }, delayMs);
}
if (delayMs !== null) {
  if (document.visibilityState === 'visible') solve();
  else document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') solve(); }, {once: true});
}
</script></body></html>''';
}

/// A [BrowserPort] that keeps every session it opened, so a test can act as
/// the user (close the window).
final class _KeepingPort implements BrowserPort {
  _KeepingPort(this.inner);

  final DesktopBrowserPort inner;
  final List<DesktopBrowserSession> sessions = <DesktopBrowserSession>[];

  @override
  Future<BrowserOutcome<BrowserSession>> openSession(BrowserSessionRequest request, {CancellationToken? cancel}) async {
    final BrowserOutcome<BrowserSession> opened = await inner.openSession(request, cancel: cancel);
    if (opened case BrowserCompleted<BrowserSession>(:final BrowserSession value)) {
      sessions.add(value as DesktopBrowserSession);
    }
    return opened;
  }

  @override
  Future<BrowserOutcome<void>> wipeAllSourceData() => inner.wipeAllSourceData();

  @override
  Future<void> fence(int generation) => inner.fence(generation);
}

Future<void> main() async {
  final String? skip =
      _worker.skip ??
      (_fixtureJar().existsSync() ? null : 'fixture-cloudflare.jar not built: run ./gradlew fixtureJar_cloudflare');
  final File? manifest = locateWebViewHelperManifest(developmentRoot: repositoryRoot());
  final String? helperSkip = manifest == null
      ? 'desktop WebView helper not built: dart run tool/build_helper.dart'
      : null;
  // The desktop_webview convention: DWV_NO_DISPLAY=1 (or Linux without a
  // display) means no window can be shown, so the interactive cases skip.
  final String? displaySkip =
      Platform.environment['DWV_NO_DISPLAY'] == '1' ||
          (Platform.isLinux &&
              Platform.environment['DISPLAY'] == null &&
              Platform.environment['WAYLAND_DISPLAY'] == null)
      ? 'no display for an interaction window (DWV_NO_DISPLAY or no DISPLAY/WAYLAND_DISPLAY)'
      : null;

  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('tachi-cf-'));
  tearDown(() => deleteTestDirectory(temp));

  /// Runs one search through a fresh worker and helper.
  Future<({SourceOutcome<WorkerSearchResponse> result, _ChallengeSite site, _KeepingPort port, Duration elapsed})>
  search({
    required _Page page,
    required bool interactive,
    int operationDeadlineMs = 60000,
    int interactionTimeoutMs = 30000,
    Future<void> Function(_KeepingPort port, CancellationSource cancel)? whileShowing,
  }) async {
    final site = _ChallengeSite(page);
    await site.start();
    // The CLI's own policy values; only the test hooks (debugRequestClose) differ.
    final desktop = DesktopBrowserPort(
      DesktopWebViewConfig(
        helperExecutable: RuntimeArtifactManifest.load(manifest!)
            .findForHost(RuntimeArtifactManifest.webviewHelper)!
            .verifiedFile(),
        dataRoot: Directory(p.join(temp.path, 'webview'))..createSync(),
        startupTimeout: CliBrowserPolicy.helperStartup,
        shutdownGrace: CliBrowserPolicy.helperShutdownGrace,
        allowVisibleWindows: interactive,
        offline: true,
        testHooks: true,
        onLog: (String line) => stderr.writeln('[helper] $line'),
        wipeRetry: CliBrowserPolicy.wipeRetry,
      ),
    );
    final port = _KeepingPort(desktop);
    final TachiWorkerLocation location = _worker.location!;
    final WorkerSpec base = location.spec(
      // As the CLI does: interactive runs let the worker show challenges.
      interactiveChallenges: interactive ? Duration(milliseconds: interactionTimeoutMs) : null,
      stateDirectory: (Directory(p.join(temp.path, 'state'))..createSync()).path,
    );
    final scope = ConversionRuntimeScope(
      workers: <WorkerKind, WorkerSpec>{
        WorkerKind.jvm: WorkerSpec(
          label: base.label,
          executable: base.executable,
          environment: base.environment,
          arguments: <String>[
            ...base.arguments,
            for (final String limit in <String>[
              'poolSize=1',
              'operationDeadlineMs=$operationDeadlineMs',
              'cancelGraceMs=2000',
              'interactionTimeoutMs=$interactionTimeoutMs',
              'shutdownGraceMs=5000',
            ]) ...<String>['--limit', limit],
          ],
        ),
      },
      limits: location.limits,
      browserPort: port,
      resolveBrowserSource: (WorkerKind kind, String? packageId, String sourceId) => packageId == _packageId
          ? SourceIdentity(
              ecosystem: 'tachi',
              packageId: _packageId,
              sourceId: sourceId,
              artifact: const ArtifactBinding(sha256: 'fixture', kind: 'jar', version: '1'),
            )
          : null,
      onLog: (String line) => stderr.writeln('[worker] $line'),
    );
    try {
      final WorkerSupervisor supervisor = switch (await scope.worker(WorkerKind.jvm)) {
        SourceSuccess<WorkerSupervisor>(:final WorkerSupervisor value) => value,
        SourceFailed<WorkerSupervisor>(:final SourceFailure failure) => throw StateError(failure.message),
      };
      final cache = ArtifactCache(Directory(p.join(temp.path, 'cache')));
      final Uint8List bytes = _fixtureJar().readAsBytesSync();
      final ArtifactLease lease = await cache.admit(
        bytes,
        binding: ArtifactBinding(sha256: sha256Hex(bytes), kind: 'jar', version: '1'),
        profile: const ArtifactProfile(producer: 'test', converterVersion: '1', hostCompatibility: 'test'),
        verifier: (Uint8List b, ArtifactBinding a) {},
      );
      final settings = SettingsSnapshot(values: <String, Object>{'baseUrl': site.base.toString()});
      final SourceOutcome<PackageLoadResponse> loaded = await supervisor.loadPackage(
        WorkerPackage(packageId: _packageId, artifact: lease, settings: settings),
      );
      check(loaded).isA<SourceSuccess<PackageLoadResponse>>();
      // Start the helper before the timed operation: its cold start
      // (WebView2 environment creation) must not count against a deadline.
      check(await desktop.wipeAllSourceData()).isA<BrowserCompleted<void>>();
      final cancel = CancellationSource();
      final clock = Stopwatch()..start();
      final Future<SourceOutcome<WorkerSearchResponse>> pending = supervisor.send(
        _packageId,
        WorkerSearchRequest(
          source: SourceIdentity(
            ecosystem: 'tachi',
            packageId: _packageId,
            sourceId: _sourceId,
            artifact: lease.binding,
          ),
          settingsRevision: settings.revision,
          request: const SearchRequest(query: 'onimai'),
        ),
        cancel: cancel.token,
      );
      if (whileShowing != null) {
        await _until(() => port.sessions.any((DesktopBrowserSession s) => s.isShowing));
        await whileShowing(port, cancel);
      }
      final SourceOutcome<WorkerSearchResponse> result = await pending;
      clock.stop();
      return (result: result, site: site, port: port, elapsed: clock.elapsed);
    } finally {
      await scope.close();
      await desktop.dispose();
      await site.close();
    }
  }

  group('Tachi Cloudflare challenge through the desktop helper', skip: skip ?? helperSkip, () {
    test(
      'interactive: the page signals completion, cookies and user agent reach the worker, the retry passes',
      skip: displaySkip,
      () async {
        final ({Duration elapsed, _KeepingPort port, SourceOutcome<WorkerSearchResponse> result, _ChallengeSite site})
        r = await search(page: _Page.solvesWhenVisible, interactive: true);
        check(r.result).isA<SourceSuccess<WorkerSearchResponse>>();
        final WorkerSearchResponse value = (r.result as SourceSuccess<WorkerSearchResponse>).value;
        check(value.hits.single.hit.title).equals('Solved title');
        // The worker's first request was challenged, the browser solved, and the retry was cleared.
        check(r.site.log.first).equals('/search cleared=false');
        check(r.site.log.last).equals('/search cleared=true');
        // Every session the solver opened was closed.
        check(r.port.sessions.every((DesktopBrowserSession s) => s.isClosed)).isTrue();
      },
    );

    test('interactive: the operation deadline is paused while the window is shown', skip: displaySkip, () async {
      final ({Duration elapsed, _KeepingPort port, SourceOutcome<WorkerSearchResponse> result, _ChallengeSite site}) r =
          await search(page: _Page.solvesSlowly, interactive: true, operationDeadlineMs: 10000);
      check(r.result).isA<SourceSuccess<WorkerSearchResponse>>();
      check(r.elapsed).isGreaterThan(_slowSolve);
    });

    test('interactive: closing the window without a clearance is interaction-required', skip: displaySkip, () async {
      final ({Duration elapsed, _KeepingPort port, SourceOutcome<WorkerSearchResponse> result, _ChallengeSite site}) r =
          await search(
            page: _Page.never,
            interactive: true,
            whileShowing: (_KeepingPort port, _) async {
              await Future<void>.delayed(const Duration(milliseconds: 500));
              final DesktopBrowserSession shown = port.sessions.firstWhere((DesktopBrowserSession s) => s.isShowing);
              check(await shown.debugRequestClose()).isA<BrowserCompleted<void>>();
            },
          );
      check(r.result).isA<SourceFailed<WorkerSearchResponse>>().has((f) => f.failure, 'failure')
        ..isA<InteractionRequiredFailure>()
        ..has((SourceFailure f) => f.message, 'message').contains('closed');
    });

    test('interactive: the interaction bound is interaction-required', skip: displaySkip, () async {
      final ({Duration elapsed, _KeepingPort port, SourceOutcome<WorkerSearchResponse> result, _ChallengeSite site}) r =
          await search(page: _Page.never, interactive: true, interactionTimeoutMs: 3000);
      check(r.result)
          .isA<SourceFailed<WorkerSearchResponse>>()
          .has((f) => f.failure, 'failure')
          .isA<InteractionRequiredFailure>();
      check(r.site.log.where((String l) => l.endsWith('cleared=true'))).isEmpty();
    });

    test('interactive: cancelling the operation while the window is shown cancels it', skip: displaySkip, () async {
      final ({Duration elapsed, _KeepingPort port, SourceOutcome<WorkerSearchResponse> result, _ChallengeSite site}) r =
          await search(
            page: _Page.never,
            interactive: true,
            whileShowing: (_, CancellationSource cancel) async => cancel.cancel('user cancelled'),
          );
      check(r.result)
          .isA<SourceFailed<WorkerSearchResponse>>()
          .has((f) => f.failure, 'failure')
          .isA<CancelledFailure>();
      check(r.elapsed).isLessThan(const Duration(seconds: 20));
    });

    test('unattended: no window is shown and the challenge is interaction-required', () async {
      final ({Duration elapsed, _KeepingPort port, SourceOutcome<WorkerSearchResponse> result, _ChallengeSite site}) r =
          await search(page: _Page.solvesWhenVisible, interactive: false);
      check(r.result)
          .isA<SourceFailed<WorkerSearchResponse>>()
          .has((f) => f.failure, 'failure')
          .isA<InteractionRequiredFailure>();
      // Without --interactive-challenges the worker opens no browser session at all.
      check(r.port.sessions).isEmpty();
      check(r.site.log.where((String l) => l.endsWith('cleared=true'))).isEmpty();
    });
  });
}

Future<void> _until(bool Function() condition, {Duration timeout = const Duration(seconds: 60)}) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > timeout) throw TimeoutException('condition not met', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
