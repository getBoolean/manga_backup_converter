// U11: the Android Tachi backend presents a `:source_runtime` worker as the
// WorkerProcess the desktop WorkerSupervisor drives, so deadlines, kill by
// PID, restart with reload of hosted packages and fencing are the
// supervisor's tested behaviour. Host-only: a fake service channel stands in
// for the JNIgen-bound TachiWorkerConnection (nothing touches JNI). The real
// service runs on the device in integration_test/source_runners_android_test.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_android/src/tachi_backend.dart';
import 'package:test/scaffolding.dart';

/// A scripted worker behind the fake channel: answers the protocol like the
/// service, never answers a search for `loop`, and exits when killed.
final class _FakeServiceWorker implements TachiServiceWorker {
  _FakeServiceWorker(this.pid, this.log);

  @override
  final int pid;
  final List<Map<String, Object?>> log;
  final StreamController<String> _frames = StreamController<String>();
  final Completer<int> _exit = Completer<int>();

  @override
  Stream<String> get frames => _frames.stream;

  @override
  Stream<String> get logs => const Stream<String>.empty();

  @override
  Future<int> get exitCode => _exit.future;

  void _reply(Map<String, Object?> request, Map<String, Object?> ok) => _frames.add(
    jsonEncode(<String, Object?>{'v': 1, 't': 'res', 'id': request['id'], 'gen': request['gen'], 'ok': ok}),
  );

  @override
  bool send(String frame) {
    if (_exit.isCompleted) return false;
    final request = jsonDecode(frame) as Map<String, Object?>;
    log.add(<String, Object?>{...request, 'pid': pid});
    if (request['t'] != 'req') return true;
    final Map<String, Object?> payload = (request['payload'] as Map<String, Object?>?) ?? const <String, Object?>{};
    switch (request['op']) {
      case 'handshake':
        _reply(request, <String, Object?>{
          'protocolVersion': 1,
          'protocolMinor': 3,
          'worker': 'tachi-android',
          'pid': pid,
          'capabilities': <String, Object?>{
            'apiFamilies': <String>['tachi-1.6'],
            'browser': false,
          },
          'limits': <String, Object?>{
            'poolSize': 1,
            'operationDeadlineMs': 300,
            'cancelGraceMs': 100,
            'interactionTimeoutMs': 1000,
            'shutdownGraceMs': 200,
          },
        });
      case 'package.load':
        _reply(request, <String, Object?>{
          'sources': <Object?>[
            <String, Object?>{
              'sourceId': '42',
              'name': 'Fake',
              'capabilities': <String, Object?>{
                'operations': <String>['search'],
                'apiFamilies': <String>['tachi-1.6'],
                'requiresBrowser': false,
              },
            },
          ],
        });
      case 'search':
        if (payload['query'] == 'loop') return true; // a wedged source: never answers, ignores cancel
        _reply(request, <String, Object?>{'hits': <Object?>[], 'warnings': <Object?>[]});
      case 'shutdown':
        _reply(request, const <String, Object?>{});
        unawaited(Future<void>(() => _end(0)));
      default:
        _reply(request, const <String, Object?>{});
    }
    return true;
  }

  void _end(int code) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
    unawaited(_frames.close());
  }

  @override
  bool kill() {
    _end(137);
    return true;
  }
}

final class _FakeChannel implements TachiServiceChannel {
  final List<List<String>> starts = <List<String>>[];
  final List<_FakeServiceWorker> workers = <_FakeServiceWorker>[];
  final List<Map<String, Object?>> log = <Map<String, Object?>>[];
  String? failWith;

  @override
  Future<TachiServiceWorker> start(List<String> arguments) async {
    starts.add(arguments);
    if (failWith case final String message) throw StateError(message);
    final worker = _FakeServiceWorker(1000 + workers.length, log);
    workers.add(worker);
    return worker;
  }
}

void main() {
  late Directory temp;
  late ArtifactCache cache;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tachi_backend_contract');
    cache = ArtifactCache(Directory('${temp.path}/cache'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<ArtifactLease> lease() async {
    final bytes = Uint8List.fromList(utf8.encode('fake apk'));
    return cache.admit(
      bytes,
      binding: ArtifactBinding(sha256: sha256Hex(bytes), kind: 'apk', version: '1'),
      profile: const ArtifactProfile(producer: 'test', converterVersion: '1', hostCompatibility: '1'),
      verifier: (_, _) {},
    );
  }

  WorkerSearchRequest search(ArtifactLease artifact, String query) => WorkerSearchRequest(
    source: SourceIdentity(ecosystem: 'tachi', packageId: 'pkg', sourceId: '42', artifact: artifact.binding),
    settingsRevision: SettingsSnapshot().revision,
    request: SearchRequest(query: query),
  );

  test('the supervisor speaks protocol v1 to the service worker through the backend', () async {
    final channel = _FakeChannel();
    final backend = AndroidTachiBackend(
      channel: channel,
      arguments: const <String>['--replay', 'all.mangadex'],
      handshakeDeadline: const Duration(seconds: 5),
    );
    final WorkerSupervisor supervisor = backend.supervisor();
    try {
      final SourceOutcome<HandshakeResponse> started = await supervisor.start();
      check(started.valueOrNull?.worker).equals('tachi-android');
      check(channel.starts.single).deepEquals(<String>['--replay', 'all.mangadex']);
      check(supervisor.limits!.operationDeadline).equals(const Duration(milliseconds: 300));

      final ArtifactLease artifact = await lease();
      final SourceOutcome<PackageLoadResponse> loaded = await supervisor.loadPackage(
        WorkerPackage(packageId: 'pkg', artifact: artifact, settings: SettingsSnapshot()),
      );
      check(loaded.valueOrNull!.sources.single.sourceId).equals('42');
      check((await supervisor.send('pkg', search(artifact, 'ok'))).valueOrNull).isNotNull();
    } finally {
      await supervisor.close();
    }
    check(await channel.workers.single.exitCode).equals(0);
  });

  test('a wedged call is killed by PID, the package reloads in a new worker, and the call is not retried', () async {
    final channel = _FakeChannel();
    final WorkerSupervisor supervisor = AndroidTachiBackend(
      channel: channel,
      handshakeDeadline: const Duration(seconds: 5),
    ).supervisor();
    try {
      await supervisor.start();
      final ArtifactLease artifact = await lease();
      await supervisor.loadPackage(WorkerPackage(packageId: 'pkg', artifact: artifact, settings: SettingsSnapshot()));
      final SourceOutcome<WorkerSearchResponse> looped = await supervisor.send('pkg', search(artifact, 'loop'));
      check(looped.failureOrNull).isA<TimeoutFailure>();
      // The restart completes in the background; the next call waits for it.
      check((await supervisor.send('pkg', search(artifact, 'after'))).valueOrNull).isNotNull();

      check(channel.workers).length.equals(2);
      check(await channel.workers.first.exitCode).equals(137);
      final List<Map<String, Object?>> loads = channel.log
          .where((Map<String, Object?> f) => f['op'] == 'package.load')
          .toList();
      check(loads.map((Map<String, Object?> f) => f['pid'])).deepEquals(<Object?>[1000, 1001]);
      final Iterable<Map<String, Object?>> loops = channel.log.where(
        (Map<String, Object?> f) => (f['payload'] as Map<String, Object?>?)?['query'] == 'loop' && f['op'] == 'search',
      );
      check(loops).length.equals(1);
      check(supervisor.events.whereType<WorkerRestartedEvent>()).length.equals(1);
    } finally {
      await supervisor.close();
    }
  });

  test('a worker that cannot start fails the supervisor with runtime-unavailable', () async {
    final channel = _FakeChannel()..failWith = 'a worker is already running in this process';
    final WorkerSupervisor supervisor = AndroidTachiBackend(
      channel: channel,
      handshakeDeadline: const Duration(seconds: 5),
    ).supervisor();
    try {
      final SourceOutcome<HandshakeResponse> started = await supervisor.start();
      check(started.failureOrNull).isA<RuntimeUnavailableFailure>();
      check(started.failureOrNull!.message).contains('already running');
    } finally {
      await supervisor.close();
    }
  });

  test('stdin bytes are split into one frame per newline, across chunk boundaries', () async {
    final channel = _FakeChannel();
    final process = ServiceWorkerProcess(await channel.start(const <String>[]));
    final String a = jsonEncode(<String, Object?>{'v': 1, 't': 'cancel', 'id': 'a', 'gen': 1});
    final String b = jsonEncode(<String, Object?>{'v': 1, 't': 'cancel', 'id': 'b', 'gen': 1});
    final List<int> bytes = utf8.encode('$a\n$b\n');
    process.stdin
      ..add(bytes.sublist(0, 10))
      ..add(bytes.sublist(10, a.length + 5))
      ..add(bytes.sublist(a.length + 5));
    await process.stdin.flush();
    check(channel.log.map((Map<String, Object?> f) => f['id'])).deepEquals(<Object?>['a', 'b']);
    check(process.pid).equals(1000);
  });
}
