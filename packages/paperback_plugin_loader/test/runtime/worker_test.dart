@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import '../e2e/settings_echo_worker.dart' show SettingsEchoAdapter;
import '../support/paperback_scenarios.dart' show PinnedRepository;
import 'test_support.dart';

/// A stand-in adapter (U6 supplies the real 0.8/0.9 adapters): it evaluates
/// the staged file as a script and answers `search` by awaiting the script's
/// global `search(query)` through the promise bridge.
final class ScriptAdapter implements PaperbackPackageAdapter {
  ScriptAdapter(this.client);

  final http.Client client;

  @override
  Set<String> get apiFamilies => const <String>{'test-script'};

  @override
  Future<PackageLoadResponse> load(
    SourceJsRuntime runtime,
    PackageLoadRequest request,
    CancellationToken cancel,
  ) async {
    installHttpHost(runtime, client);
    await runtime.evaluate(File(request.path).readAsStringSync(), filename: request.path, cancel: cancel);
    return PackageLoadResponse(
      sources: <LoadedSource>[
        LoadedSource(
          sourceId: 'script',
          name: 'Script source',
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
    final Object? result = await runtime.call('search', <Object?>[request.request.query], cancel: cancel);
    return WorkerSearchResponse(hits: const <WorkerSearchHit>[], warnings: <String>['$result']);
  }
}

/// Drives a worker in-process over injected streams.
final class WorkerHarness {
  WorkerHarness({
    PaperbackPackageAdapter? adapter,
    PaperbackPackageAdapter Function(PaperbackBrowserChannel browser)? adapterFactory,
    PaperbackRuntimeLimits? limits,
  }) {
    worker = PaperbackSourceWorker(
      input: _input.stream,
      output: _output,
      limits: limits ?? testLimits(),
      adapter: adapter,
      adapterFactory: adapterFactory,
      browserEnabled: adapterFactory != null,
      pid: 4242,
      log: logs.add,
    );
    done = worker.run();
    _output.stream.transform(const FrameDecoder()).listen(_frames.add);
  }

  final StreamController<List<int>> _input = StreamController<List<int>>();
  final StreamController<List<int>> _output = StreamController<List<int>>();
  final StreamController<ProtocolFrame> _frames = StreamController<ProtocolFrame>.broadcast();
  final List<String> logs = <String>[];
  late final PaperbackSourceWorker worker;
  late final Future<void> done;
  int _next = 0;

  String send(String op, {String? pkg, Map<String, Object?> payload = const <String, Object?>{}}) {
    final id = '1-${++_next}';
    _input.add(
      encodeFrame(
        ProtocolFrame(type: FrameType.request, id: id, generation: 1, op: op, packageId: pkg, payload: payload),
      ),
    );
    return id;
  }

  void cancel(String id) => _input.add(encodeFrame(ProtocolFrame(type: FrameType.cancel, id: id, generation: 1)));

  int _nextEvent = 0;

  /// The next reverse request the worker sends.
  Future<ProtocolFrame> reverseRequest() =>
      _frames.stream.firstWhere((ProtocolFrame f) => f.type == FrameType.reverseRequest);

  /// Answers reverse request [id] with [error].
  void reverseError(String id, Map<String, Object?> error) => _input.add(
    encodeFrame(ProtocolFrame(type: FrameType.reverseResponse, id: id, generation: 1, error: error)),
  );

  /// Sends a supervisor `event` frame.
  void event(String op, Map<String, Object?> payload) => _input.add(
    encodeFrame(
      ProtocolFrame(type: FrameType.event, id: 'e1-${++_nextEvent}', generation: 1, op: op, payload: payload),
    ),
  );

  Future<ProtocolFrame> reply(String id) =>
      _frames.stream.firstWhere((ProtocolFrame f) => f.type == FrameType.response && f.id == id);

  Future<ProtocolFrame> request(String op, {String? pkg, Map<String, Object?> payload = const <String, Object?>{}}) {
    final id = '1-${_next + 1}';
    final Future<ProtocolFrame> pending = _frames.stream.firstWhere(
      (ProtocolFrame f) => f.type == FrameType.response && f.id == id,
    );
    send(op, pkg: pkg, payload: payload);
    return pending;
  }

  Future<void> close() async {
    await _input.close();
    await done;
  }
}

Map<String, Object?> loadPayload(String path) => PackageLoadRequest(
  artifact: const ArtifactBinding(sha256: 'ab12', kind: 'paperback-bundle', version: '1.0.0'),
  path: path,
  settings: SettingsPayload(values: const <String, Object>{}, secrets: const <String, String>{}, revision: 'r1'),
).toJson();

Map<String, Object?> searchPayload(String query) => WorkerSearchRequest(
  source: const SourceIdentity(
    ecosystem: 'paperback',
    packageId: 'pkg.test',
    sourceId: 'script',
    artifact: ArtifactBinding(sha256: 'ab12', kind: 'paperback-bundle', version: '1.0.0'),
  ),
  settingsRevision: 'r1',
  request: SearchRequest(query: query),
).toJson();

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('pb_worker_'));
  tearDown(() => temp.deleteSync(recursive: true));

  String script(String body) {
    final file = File('${temp.path}/bundle.js')..writeAsStringSync(body);
    return file.path;
  }

  test('handshake reports the offered minor, no API families yet, and the limits in effect', () async {
    final harness = WorkerHarness();
    final ProtocolFrame reply = await harness.request(
      'handshake',
      payload: const HandshakeRequest(
        protocolVersions: <int>[1],
        protocolMinor: 1,
        maxFrameBytes: protocolMaxFrameBytes,
      ).toJson(),
    );
    final response = HandshakeResponse.fromJson(reply.ok!);
    check(response.protocolVersion).equals(1);
    check(response.protocolMinor).equals(1);
    check(response.worker).equals('paperback');
    check(response.pid).equals(4242);
    check(response.capabilities.apiFamilies).isEmpty();
    final WorkerReportedLimits limits = response.limits!;
    check(limits.fields).containsKey('memoryLimitBytes');
    check(limits.operationDeadline).equals(const Duration(seconds: 30));
    // No benchmark evidence for these, so they are not reported.
    check(limits.poolSize).isNull();
    check(limits.cancelGrace).isNull();
    check(limits.interactionTimeout).isNull();
    check(limits.shutdownGrace).isNull();
    await harness.close();
  });

  test('handshake answers the lower of the offered minor and 3', () async {
    check(paperbackProtocolMinor).equals(3);
    for (final (int offer, int expected) in const <(int, int)>[(0, 0), (1, 1), (2, 2), (3, 3), (5, 3)]) {
      final harness = WorkerHarness();
      final ProtocolFrame reply = await harness.request(
        'handshake',
        payload: HandshakeRequest(
          protocolVersions: const <int>[1],
          protocolMinor: offer,
          maxFrameBytes: protocolMaxFrameBytes,
        ).toJson(),
      );
      check(HandshakeResponse.fromJson(reply.ok!).protocolMinor).equals(expected);
      await harness.close();
    }
  });

  test('the reported operation deadline rounds up to whole milliseconds', () {
    final WorkerReportedLimits limits = reportedLimits(
      testLimits(operationDeadline: const Duration(microseconds: 1200001)),
    );
    check(limits.operationDeadline).equals(const Duration(milliseconds: 1201));
    check(limits.fields['operationDeadlineMicros']).equals(1200001);
  });

  test('a handshake without protocol 1 is refused', () async {
    final harness = WorkerHarness();
    final ProtocolFrame reply = await harness.request(
      'handshake',
      payload: const HandshakeRequest(protocolVersions: <int>[2], maxFrameBytes: protocolMaxFrameBytes).toJson(),
    );
    check(reply.error!['code']).equals('protocol-violation');
    await harness.close();
  });

  test('without an adapter, package.load is unsupported-api', () async {
    final harness = WorkerHarness();
    final ProtocolFrame reply = await harness.request('package.load', pkg: 'pkg.test', payload: loadPayload('x.js'));
    check(reply.error!['code']).equals('unsupported-api');
    await harness.close();
  });

  test('loads a package and serves search through the promise bridge', () async {
    final harness = WorkerHarness(adapter: ScriptAdapter(fakeHttp()));
    final String path = script('''
      async function search(q) {
        const res = await __paperbackHost.request({ url: 'https://example.test/search?q=' + encodeURIComponent(q) });
        return JSON.parse(res.text).title + ':' + q;
      }
    ''');
    final ProtocolFrame load = await harness.request('package.load', pkg: 'pkg.test', payload: loadPayload(path));
    check(PackageLoadResponse.fromJson(load.ok!).sources.single.sourceId).equals('script');
    final ProtocolFrame search = await harness.request('search', pkg: 'pkg.test', payload: searchPayload('onimai'));
    check(WorkerSearchResponse.fromJson(search.ok!).warnings).deepEquals(<String>['Onimai:onimai']);
    await harness.close();
  });

  test('a busy loop replies timeout at the deadline, and the package keeps serving', () async {
    final harness = WorkerHarness(
      adapter: ScriptAdapter(fakeHttp()),
      limits: testLimits(operationDeadline: const Duration(milliseconds: 500)),
    );
    final String path = script('function search(q) { if (q === "spin") for (;;) {} return q; }');
    await harness.request('package.load', pkg: 'pkg.test', payload: loadPayload(path));
    final ProtocolFrame spin = await harness.request('search', pkg: 'pkg.test', payload: searchPayload('spin'));
    check(spin.error!['code']).equals('timeout');
    final ProtocolFrame ok = await harness.request('search', pkg: 'pkg.test', payload: searchPayload('fine'));
    check(WorkerSearchResponse.fromJson(ok.ok!).warnings).deepEquals(<String>['fine']);
    await harness.close();
  });

  group('interaction events (protocol 1.3) pause the engine deadline', () {
    const deadline = Duration(milliseconds: 400);
    const slowUser = Duration(milliseconds: 1200);

    Future<(WorkerHarness, ControlledHttp)> started() async {
      final http = ControlledHttp();
      final harness = WorkerHarness(
        adapter: ScriptAdapter(http),
        limits: testLimits(operationDeadline: deadline),
      );
      await harness.request(
        'package.load',
        pkg: 'pkg.test',
        payload: loadPayload(
          script(
            'function search(q) { return __paperbackHost.request({ url: "https://example.test/" + q }).then(function (r) { return r.text; }); }',
          ),
        ),
      );
      return (harness, http);
    }

    test('a slow user interaction does not trip the deadline', () async {
      final (WorkerHarness harness, ControlledHttp http) = await started();
      final String id = harness.send('search', pkg: 'pkg.test', payload: searchPayload('q'));
      final Future<ProtocolFrame> reply = harness.reply(id);
      harness.event(WorkerInteractionStarted.op, WorkerInteractionStarted(of: id, timeout: slowUser * 2).toJson());
      await Future<void>.delayed(slowUser);
      harness.event(WorkerInteractionEnded.op, WorkerInteractionEnded(of: id, paused: slowUser).toJson());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      http.completeAll('solved');
      check(WorkerSearchResponse.fromJson((await reply).ok!).warnings).deepEquals(<String>['solved']);
      await harness.close();
    });

    test('without the events the same wait times out (control)', () async {
      final (WorkerHarness harness, ControlledHttp http) = await started();
      final String id = harness.send('search', pkg: 'pkg.test', payload: searchPayload('q'));
      final Future<ProtocolFrame> reply = harness.reply(id);
      await Future<void>.delayed(slowUser);
      http.completeAll('solved');
      check((await reply).error!['code']).equals('timeout');
      await harness.close();
    });

    test('the remaining budget still applies after interaction.ended', () async {
      final (WorkerHarness harness, ControlledHttp _) = await started();
      final String id = harness.send('search', pkg: 'pkg.test', payload: searchPayload('q'));
      final Future<ProtocolFrame> reply = harness.reply(id);
      harness.event(WorkerInteractionStarted.op, WorkerInteractionStarted(of: id, timeout: slowUser * 2).toJson());
      await Future<void>.delayed(slowUser);
      final watch = Stopwatch()..start();
      harness.event(WorkerInteractionEnded.op, WorkerInteractionEnded(of: id, paused: slowUser).toJson());
      check((await reply).error!['code']).equals('timeout');
      // Resumed with what was left (under 400 ms), not a fresh deadline.
      check(watch.elapsed).isLessThan(deadline + const Duration(milliseconds: 300));
      await harness.close();
    });

    test('events for another operation, or malformed ones, change nothing', () async {
      final (WorkerHarness harness, ControlledHttp _) = await started();
      final String id = harness.send('search', pkg: 'pkg.test', payload: searchPayload('q'));
      final Future<ProtocolFrame> reply = harness.reply(id);
      harness.event(
        WorkerInteractionStarted.op,
        const WorkerInteractionStarted(of: '1-99', timeout: slowUser).toJson(),
      );
      harness.event(WorkerInteractionStarted.op, const <String, Object?>{'of': 7});
      check((await reply).error!['code']).equals('timeout');
      check(harness.logs).any((Subject<String> it) => it.contains('malformed interaction.started'));
      await harness.close();
    });
  });

  group('failures keep their wire fields (protocol 1.3 trust)', () {
    test('bundle bytes that differ from the admitted digest reply artifact-incompatible with trust changed', () async {
      final harness = WorkerHarness(adapter: PaperbackApiAdapter(http: PaperbackHttp(fakeHttp())));
      final path = '${temp.path}/bundle.bin';
      File(path).writeAsBytesSync(PinnedRepository.load('inkdex-0.9').bundle('MangaDex'));
      final ProtocolFrame reply = await harness.request(
        'package.load',
        pkg: 'pkg.test',
        payload: PackageLoadRequest(
          artifact: ArtifactBinding(sha256: 'ab' * 32, kind: 'paperback-bundle-0.9', version: '1'),
          path: path,
          settings: SettingsPayload(values: const <String, Object>{}, secrets: const <String, String>{}, revision: 'r'),
          apiFamily: 'paperback-0.9',
        ).toJson(),
      );
      check(reply.error!).containsKey('trust');
      check(SourceFailure.fromJson(reply.error!))
          .isA<TrustFailure>()
          .has((TrustFailure f) => f.reason, 'reason')
          .equals(TrustFailureReason.changed);
      await harness.close();
    });

    test('a reverse-request error is rebuilt with every field', () async {
      final harness = WorkerHarness(adapterFactory: _ReverseEchoAdapter.new);
      await harness.request('package.load', pkg: 'pkg.test', payload: loadPayload('unused'));
      final Future<ProtocolFrame> search = harness.request('search', pkg: 'pkg.test', payload: searchPayload('q'));
      final ProtocolFrame rreq = await harness.reverseRequest();
      final Map<String, Object?> wire = const TrustFailure(TrustFailureReason.refused, 'nope').toWire();
      harness.reverseError(rreq.id, wire);
      check(WorkerSearchResponse.fromJson((await search).ok!).warnings.single).equals(jsonEncode(wire));
      await harness.close();
    });
  });

  test('a cancel frame during a host wait replies cancelled', () async {
    final harness = WorkerHarness(adapter: ScriptAdapter(ControlledHttp()));
    final String path = script(
      'function search(q) { return __paperbackHost.request({ url: "https://example.test/" + q }); }',
    );
    await harness.request('package.load', pkg: 'pkg.test', payload: loadPayload(path));
    final String id = harness.send('search', pkg: 'pkg.test', payload: searchPayload('hang'));
    final Future<ProtocolFrame> reply = harness.reply(id);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    harness.cancel(id);
    check((await reply).error!['code']).equals('cancelled');
    await harness.close();
  });

  test('operations on an unloaded package fail as runtime-unavailable', () async {
    final harness = WorkerHarness(adapter: ScriptAdapter(fakeHttp()));
    final ProtocolFrame reply = await harness.request('search', pkg: 'pkg.none', payload: searchPayload('x'));
    check(reply.error!['code']).equals('runtime-unavailable');
    await harness.close();
  });

  test('unloading an absent package is runtime-unavailable; unloading a loaded one succeeds once', () async {
    final harness = WorkerHarness(adapter: ScriptAdapter(fakeHttp()));
    final ProtocolFrame absent = await harness.request('package.unload', pkg: 'pkg.none');
    check(absent.error!['code']).equals('runtime-unavailable');
    await harness.request(
      'package.load',
      pkg: 'pkg.test',
      payload: loadPayload(script('function search(q) { return q; }')),
    );
    check((await harness.request('package.unload', pkg: 'pkg.test')).ok).isNotNull().isEmpty();
    check((await harness.request('package.unload', pkg: 'pkg.test')).error!['code']).equals('runtime-unavailable');
    await harness.close();
  });

  test('a per-package operation without pkg is a protocol violation', () async {
    final harness = WorkerHarness(adapter: ScriptAdapter(fakeHttp()));
    final ProtocolFrame reply = await harness.request('search', payload: searchPayload('x'));
    check(reply.error!['code']).equals('protocol-violation');
    await harness.close();
  });

  test('artifact.prepare needs no loaded package and is unsupported-api for Paperback', () async {
    final harness = WorkerHarness(adapter: ScriptAdapter(fakeHttp()));
    final ProtocolFrame reply = await harness.request(
      'artifact.prepare',
      pkg: 'pkg.none',
      payload: ArtifactPrepareRequest(
        artifact: const ArtifactBinding(sha256: 'ab12', kind: 'paperback-bundle', version: '1.0.0'),
        inputPath: 'in',
        outputPath: 'out',
        trustedSigners: <String>['ab' * 32],
      ).toJson(),
    );
    check(reply.error!['code']).equals('unsupported-api');
    await harness.close();
  });

  test('string-set and source-scoped settings reach the adapter on load and settings.update', () async {
    final harness = WorkerHarness(adapter: SettingsEchoAdapter());
    Future<List<String>> echo(String sourceId) async {
      final ProtocolFrame reply = await harness.request(
        'search',
        pkg: 'pkg.test',
        payload: WorkerSearchRequest(
          source: SourceIdentity(
            ecosystem: 'paperback',
            packageId: 'pkg.test',
            sourceId: sourceId,
            artifact: const ArtifactBinding(sha256: 'ab12', kind: 'paperback-bundle', version: '1.0.0'),
          ),
          settingsRevision: 'r1',
          request: const SearchRequest(query: 'q'),
        ).toJson(),
      );
      return WorkerSearchResponse.fromJson(reply.ok!).warnings;
    }

    final settings = SettingsSnapshot(
      values: const <String, Object>{
        'lang': 'en',
        'tags': <String>['b', 'a', 'b'],
      },
      sources: <String, SourceScopedSettings>{
        'two': SourceScopedSettings(
          values: const <String, Object>{
            'tags': <String>['z'],
          },
          secrets: const <String, String>{'token': 't'},
        ),
      },
    );
    final ProtocolFrame load = await harness.request(
      'package.load',
      pkg: 'pkg.test',
      payload: PackageLoadRequest(
        artifact: const ArtifactBinding(sha256: 'ab12', kind: 'paperback-bundle', version: '1.0.0'),
        path: 'unused',
        settings: SettingsPayload.fromSnapshot(settings),
      ).toJson(),
    );
    check(load.error).isNull();
    check(await echo('one')).deepEquals(<String>['values={"lang":"en","tags":["a","b"]}', 'secrets=']);
    check(await echo('two')).deepEquals(<String>['values={"lang":"en","tags":["z"]}', 'secrets=token']);
    final ProtocolFrame update = await harness.request(
      'settings.update',
      pkg: 'pkg.test',
      payload: SettingsUpdateRequest(
        settings: SettingsPayload.fromSnapshot(
          SettingsSnapshot(
            sources: <String, SourceScopedSettings>{
              'one': SourceScopedSettings(
                values: const <String, Object>{
                  'tags': <String>['c'],
                },
              ),
            },
          ),
        ),
      ).toJson(),
    );
    check(update.ok).isNotNull().isEmpty();
    check(await echo('one')).deepEquals(<String>['values={"tags":["c"]}', 'secrets=']);
    check(await echo('two')).deepEquals(<String>['values={}', 'secrets=']);
    await harness.close();
  });

  test('shutdown replies, then the worker stops', () async {
    final harness = WorkerHarness(adapter: ScriptAdapter(fakeHttp()));
    final ProtocolFrame reply = await harness.request('shutdown');
    check(reply.ok).isNotNull().isEmpty();
    await harness.done;
  });

  test('stdout carries only frames; console output goes to the log', () async {
    final harness = WorkerHarness(adapter: ScriptAdapter(fakeHttp()));
    final String path = script('console.log("hello from source"); function search(q) { return q; }');
    await harness.request('package.load', pkg: 'pkg.test', payload: loadPayload(path));
    check(harness.logs).any((Subject<String> it) => it.contains('hello from source'));
    await harness.close();
  });

  test('the worker binary requires every limit', () {
    check(() => parseWorkerArguments(const <String>[])).throws<FormatException>();
    check(
      () => parseWorkerArguments(const <String>['--memory-limit-bytes=1', '--max-stack-bytes=1', '--job-slice-ms=1']),
    ).throws<FormatException>();
    final WorkerArguments parsed = parseWorkerArguments(const <String>[
      '--memory-limit-bytes=1048576',
      '--max-stack-bytes=65536',
      '--operation-deadline-ms=100',
      '--job-slice-ms=2',
      '--deadline-headroom-ms=7',
    ]);
    final PaperbackRuntimeLimits limits = parsed.limits;
    check(limits.operationDeadline).equals(const Duration(milliseconds: 100));
    check(parsed.deadlineHeadroom).equals(const Duration(milliseconds: 7));
    check(parsed.network).isA<LiveNetwork>();
    check(
      () => parseWorkerArguments(const <String>[
        '--memory-limit-bytes=1',
        '--max-stack-bytes=1',
        '--operation-deadline-ms=1',
        '--job-slice-ms=1',
        '--deadline-headroom-ms=1',
        '--record=x',
        '--record-source=s',
        '--record-min-interval-ms=100',
        '--record-licence=l',
      ]),
    ).throws<FormatException>();
    check(jsonEncode(limits.toJson())).contains('1048576');
  });

  test('record mode takes a Set-Cookie allow-list (capture format setCookieAllowList)', () {
    const base = <String>[
      '--memory-limit-bytes=1',
      '--max-stack-bytes=1',
      '--operation-deadline-ms=1',
      '--job-slice-ms=1',
      '--deadline-headroom-ms=1',
      '--record=x',
      '--record-source=s',
      '--record-min-interval-ms=1500',
      '--record-licence=l',
    ];
    final PaperbackNetworkMode network = parseWorkerArguments(<String>[
      ...base,
      '--record-cookie=mhub_access:redact',
      '--record-cookie=lang:keep',
    ]).network;
    check(network).isA<RecordNetwork>().has((RecordNetwork r) => r.setCookieAllowList, 'allow-list').deepEquals(
      <String, CapturedCookieValue>{'mhub_access': CapturedCookieValue.redact, 'lang': CapturedCookieValue.keep},
    );
    check(
      parseWorkerArguments(base).network,
    ).isA<RecordNetwork>().has((RecordNetwork r) => r.setCookieAllowList, 'allow-list').isEmpty();
    check(() => parseWorkerArguments(<String>[...base, '--record-cookie=mhub_access'])).throws<FormatException>();
    check(() => parseWorkerArguments(<String>[...base, '--record-cookie=a:drop'])).throws<FormatException>();
    // Only with --record.
    check(
      () => parseWorkerArguments(<String>[...base.take(5), '--record-cookie=a:keep']),
    ).throws<FormatException>();
  });
}

/// Sends one browser reverse request per search and reports the failure it
/// got back, as wire JSON.
final class _ReverseEchoAdapter implements PaperbackPackageAdapter {
  _ReverseEchoAdapter(this.browser);

  final PaperbackBrowserChannel browser;

  @override
  Set<String> get apiFamilies => const <String>{'test-echo'};

  @override
  Future<PackageLoadResponse> load(
    SourceJsRuntime runtime,
    PackageLoadRequest request,
    CancellationToken cancel,
  ) async => PackageLoadResponse(
    sources: <LoadedSource>[
      LoadedSource(
        sourceId: 'echo',
        name: 'Echo',
        capabilities: SourceCapabilities(operations: const <SourceOperation>{SourceOperation.search}),
      ),
    ],
  );

  @override
  Future<ProtocolPayload> handle(
    SourceJsRuntime runtime,
    WorkerRequest<ProtocolPayload> request,
    CancellationToken cancel,
  ) async {
    final SourceOutcome<Map<String, Object?>> outcome = await browser.send(
      const HostBrowserOpen(sourceId: 'echo'),
      cancel,
    );
    final String text = switch (outcome) {
      SourceSuccess<Map<String, Object?>>() => 'ok',
      SourceFailed<Map<String, Object?>>(:final SourceFailure failure) => jsonEncode(failure.toWire()),
    };
    return WorkerSearchResponse(hits: const <WorkerSearchHit>[], warnings: <String>[text]);
  }
}
