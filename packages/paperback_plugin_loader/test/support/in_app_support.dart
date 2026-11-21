// ignore_for_file: avoid_print
// Shared by test/in_app_backend_contract_test.dart (desktop VM) and the iOS
// device cases in integration_test/source_runners_ios_paperback_test.dart:
// the in-app worker-isolate path (`isolatePaperbackLauncher`) driven with
// raw protocol frames, and the site scenarios over the supervisor. No
// dependency on package:test, so a Flutter integration test can import it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

import 'paperback_scenarios.dart';

/// Spec for an in-app worker: there is no executable.
const WorkerSpec inAppPaperbackSpec = WorkerSpec(label: 'paperback', executable: 'in-app-isolate');

/// A test adapter whose `search` never yields to Dart on its own: `sync`
/// spins in one JS call, `jobs` chains promise jobs forever, `host` awaits a
/// host call that never completes, `memory` allocates in one JS call until
/// the engine's memory limit stops it. Built inside the worker isolate.
final class LoopingAdapter implements PaperbackPackageAdapter {
  const LoopingAdapter();

  @override
  Set<String> get apiFamilies => const <String>{'test-loop'};

  @override
  Future<PackageLoadResponse> load(
    SourceJsRuntime runtime,
    PackageLoadRequest request,
    CancellationToken cancel,
  ) async {
    runtime.bridge.registerAsync('never', (List<Object?> _) => Completer<Object?>().future);
    await runtime.evaluate('''
globalThis.spin = function (mode) {
  if (mode === 'sync') { for (;;) {} }
  if (mode === 'jobs') { return new Promise(function () { (function f() { Promise.resolve().then(f); })(); }); }
  if (mode === 'host') { return never(); }
  if (mode === 'memory') { var a = []; for (;;) { a.push(new Array(4096).fill(a.length)); } }
  return 'ok:' + mode;
};
void 0;
''', cancel: cancel);
    return PackageLoadResponse(
      sources: <LoadedSource>[
        LoadedSource(
          sourceId: 'loop',
          name: 'Loop',
          capabilities: SourceCapabilities(operations: const <SourceOperation>{SourceOperation.search}),
        ),
      ],
    );
  }

  @override
  Future<ProtocolPayload> handle(
    SourceJsRuntime runtime,
    WorkerRequest<ProtocolPayload> request,
    CancellationToken cancel,
  ) async {
    if (request is! WorkerSearchRequest) throw UnsupportedError('${request.operation}');
    final Object? result = await runtime.call('spin', <Object?>[request.request.query], cancel: cancel);
    return WorkerSearchResponse(hits: const <WorkerSearchHit>[], warnings: <String>['$result']);
  }
}

/// Drives one worker isolate from [isolatePaperbackLauncher] with raw
/// protocol frames, as the supervisor would.
final class IsolateWorkerHarness {
  IsolateWorkerHarness._(this.process) {
    process.stdout.transform(const FrameDecoder()).listen(_frames.add);
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(logs.add);
  }

  static Future<IsolateWorkerHarness> start(PaperbackIsolateWorkerConfig config) async =>
      IsolateWorkerHarness._(await isolatePaperbackLauncher(config)(inAppPaperbackSpec));

  final WorkerProcess process;
  final StreamController<ProtocolFrame> _frames = StreamController<ProtocolFrame>.broadcast();
  final List<String> logs = <String>[];
  int _next = 0;

  String send(String op, {String? pkg, Map<String, Object?> payload = const <String, Object?>{}}) {
    final id = '1-${++_next}';
    process.stdin.add(
      encodeFrame(
        ProtocolFrame(type: FrameType.request, id: id, generation: 1, op: op, packageId: pkg, payload: payload),
      ),
    );
    return id;
  }

  void cancel(String id) =>
      process.stdin.add(encodeFrame(ProtocolFrame(type: FrameType.cancel, id: id, generation: 1)));

  int _nextEvent = 0;

  /// Sends a supervisor `event` frame (for example `interaction.started`).
  void event(String op, Map<String, Object?> payload) => process.stdin.add(
    encodeFrame(
      ProtocolFrame(type: FrameType.event, id: 'e1-${++_nextEvent}', generation: 1, op: op, payload: payload),
    ),
  );

  Future<ProtocolFrame> reply(String id) =>
      _frames.stream.firstWhere((ProtocolFrame f) => f.type == FrameType.response && f.id == id);

  Future<ProtocolFrame> request(String op, {String? pkg, Map<String, Object?> payload = const <String, Object?>{}}) {
    final id = '1-${_next + 1}';
    final Future<ProtocolFrame> pending = reply(id);
    send(op, pkg: pkg, payload: payload);
    return pending;
  }

  Future<HandshakeResponse> handshake() async => HandshakeResponse.fromJson(
    (await request(
      'handshake',
      payload: const HandshakeRequest(
        protocolVersions: <int>[1],
        protocolMinor: 1,
        maxFrameBytes: protocolMaxFrameBytes,
      ).toJson(),
    )).ok!,
  );

  /// Loads the looping test package (its adapter ignores the path).
  Future<ProtocolFrame> loadLoopPackage() => request(
    'package.load',
    pkg: loopPackageId,
    payload: PackageLoadRequest(
      artifact: _loopArtifact,
      path: '/nonexistent',
      settings: SettingsPayload(values: const <String, Object>{}, secrets: const <String, String>{}, revision: 'r1'),
    ).toJson(),
  );

  String search(String query) => send(
    'search',
    pkg: loopPackageId,
    payload: WorkerSearchRequest(
      source: const SourceIdentity(
        ecosystem: 'paperback',
        packageId: loopPackageId,
        sourceId: 'loop',
        artifact: _loopArtifact,
      ),
      settingsRevision: 'r1',
      request: SearchRequest(query: query),
    ).toJson(),
  );

  Future<int> shutdown() async {
    await request('shutdown');
    await process.stdin.close();
    return process.exitCode;
  }
}

const String loopPackageId = 'pkg.loop';
const ArtifactBinding _loopArtifact = ArtifactBinding(sha256: 'ab12', kind: 'paperback-bundle', version: '1.0.0');

/// Serves captures from `dirs` and prints each served or missed request
/// (`[replay] served GET <url>` / `[replay] miss ...`), so the launching
/// isolate sees them in the worker log.
final class LoggingReplayClient extends http.BaseClient {
  LoggingReplayClient(List<String> dirs)
    : _inner = MultiReplayHttpClient.load(<Directory>[for (final String d in dirs) Directory(d)]);

  final MultiReplayHttpClient _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      final http.StreamedResponse r = await _inner.send(request);
      print('[replay] served ${request.method} ${request.url}');
      return r;
    } on CaptureMissException {
      print('[replay] miss ${request.method} ${request.url}');
      rethrow;
    }
  }
}

/// What one site scenario produced through the in-app worker.
final class InAppSiteRun {
  InAppSiteRun(this.runs, this.log);

  final List<BundleRun> runs;

  /// Redacted worker and supervisor log lines.
  final List<String> log;

  List<String> get served => <String>[
    for (final String l in log)
      if (RegExp(r'\[replay\] served \S+ (\S+)').firstMatch(l) case final RegExpMatch m) m.group(1)!,
  ];

  List<String> get misses => <String>[
    for (final String l in log)
      if (l.contains('[replay] miss')) l,
  ];
}

/// The identity the browser bridge may open sessions for: exactly the
/// pinned bundles of [site].
SourceIdentity? Function(String? packageId, String sourceId) pinnedBrowserSources(String site) {
  final repos = <PinnedRepository>[for (final PinnedBundle b in captureSites[site]!) PinnedRepository.load(b.repoDir)];
  return (String? packageId, String sourceId) {
    for (final r in repos) {
      for (final MapEntry<String, Map<String, Object?>> pin in r.pins.entries) {
        final PaperbackCatalogEntry e = r.entry(pin.key);
        if (e.packageId == packageId && e.sourceId == sourceId) {
          return SourceIdentity(
            ecosystem: 'paperback',
            packageId: e.packageId,
            sourceId: sourceId,
            artifact: ArtifactBinding(
              sha256: pin.value['sha256']! as String,
              kind: e.family.artifactKind,
              version: e.version,
            ),
          );
        }
      }
    }
    return null;
  };
}

/// Runs [site]'s qualification scenario (`runSiteScenario`) through
/// provider → supervisor → in-app worker isolate → adapter → QuickJS,
/// replaying the committed capture. [port] serves browser reverse requests.
Future<InAppSiteRun> runSiteInIsolate(
  String site, {
  required PaperbackRuntimeLimits limits,
  required SupervisorLimits supervisorLimits,
  Duration deadlineHeadroom = Duration.zero,
  BrowserPort? port,
}) async {
  final captures = '${paperbackFixtures().path}/$site';
  final log = <String>[];
  final repos = <PinnedRepository>[for (final PinnedBundle b in captureSites[site]!) PinnedRepository.load(b.repoDir)];
  final BrowserReverseBridge? bridge = port == null
      ? null
      : BrowserReverseBridge(
          port: port,
          interactionTimeout: supervisorLimits.interactionTimeout,
          resolveSource: pinnedBrowserSources(site),
          onLog: log.add,
        );
  final supervisor = WorkerSupervisor(
    spec: inAppPaperbackSpec,
    limits: supervisorLimits,
    launcher: isolatePaperbackLauncher(
      PaperbackIsolateWorkerConfig(
        limits: limits,
        deadlineHeadroom: deadlineHeadroom,
        clientFactory: () => LoggingReplayClient(<String>[captures]),
      ),
    ),
    onReverseRequest: bridge?.handle,
    onLog: log.add,
    onGenerationFenced: (int generation) async => bridge?.fence(generation),
  );
  bridge?.emitEvent = supervisor.sendEvent;
  final Directory cache = Directory.systemTemp.createTempSync('paperback_in_app');
  final provider = PaperbackSourceProvider(
    client: MultiReplayHttpClient.load(<Directory>[Directory(captures)]),
    cache: ArtifactCache(cache),
    trust: PinnedRepository.pinnedTrust(repos),
    worker: () async => (await supervisor.start()).map((_) => supervisor),
  );
  try {
    return InAppSiteRun(await runSiteScenario(provider, site), log);
  } finally {
    await supervisor.close();
    await bridge?.close();
    cache.deleteSync(recursive: true);
  }
}

/// Bytes of [length] for binary round-trip checks.
Uint8List byteRamp(int length) => Uint8List.fromList(List<int>.generate(length, (int i) => i & 0xff));
