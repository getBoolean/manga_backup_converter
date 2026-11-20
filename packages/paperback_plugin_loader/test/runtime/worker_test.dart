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

import '../../bin/paperback_source_worker.dart' show parseLimitArguments;
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
  WorkerHarness({PaperbackPackageAdapter? adapter, PaperbackRuntimeLimits? limits}) {
    worker = PaperbackSourceWorker(
      input: _input.stream,
      output: _output,
      limits: limits ?? testLimits(operationDeadline: const Duration(milliseconds: 500)),
      adapter: adapter,
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

  test('handshake reports protocol 1, no API families yet, and the limits in effect', () async {
    final harness = WorkerHarness();
    final ProtocolFrame reply = await harness.request(
      'handshake',
      payload: const HandshakeRequest(protocolVersions: <int>[1], maxFrameBytes: protocolMaxFrameBytes).toJson(),
    );
    final response = HandshakeResponse.fromJson(reply.ok!);
    check(response.protocolVersion).equals(1);
    check(response.worker).equals('paperback');
    check(response.pid).equals(4242);
    check(response.capabilities.apiFamilies).isEmpty();
    check(reply.ok!['limits']).isA<Map<String, Object?>>().containsKey('memoryLimitBytes');
    await harness.close();
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
    final harness = WorkerHarness(adapter: ScriptAdapter(fakeHttp()));
    final String path = script('function search(q) { if (q === "spin") for (;;) {} return q; }');
    await harness.request('package.load', pkg: 'pkg.test', payload: loadPayload(path));
    final ProtocolFrame spin = await harness.request('search', pkg: 'pkg.test', payload: searchPayload('spin'));
    check(spin.error!['code']).equals('timeout');
    final ProtocolFrame ok = await harness.request('search', pkg: 'pkg.test', payload: searchPayload('fine'));
    check(WorkerSearchResponse.fromJson(ok.ok!).warnings).deepEquals(<String>['fine']);
    await harness.close();
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
    check(() => parseLimitArguments(const <String>[])).throws<FormatException>();
    check(
      () => parseLimitArguments(const <String>['--memory-limit-bytes=1', '--max-stack-bytes=1', '--job-slice-ms=1']),
    ).throws<FormatException>();
    final PaperbackRuntimeLimits limits = parseLimitArguments(const <String>[
      '--memory-limit-bytes=1048576',
      '--max-stack-bytes=65536',
      '--operation-deadline-ms=100',
      '--job-slice-ms=2',
    ]);
    check(limits.operationDeadline).equals(const Duration(milliseconds: 100));
    check(jsonEncode(limits.toJson())).contains('1048576');
  });
}
