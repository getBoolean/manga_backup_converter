// Supervisor contract tests against a real fake-worker subprocess (KTD4,
// AE5). Limits are small overrides (KTD25), not shipped values.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_testing/source_runtime_testing.dart';
import 'package:test/scaffolding.dart';

import 'support/fake_worker_launch.dart';

void main() {
  late String workerExe;
  late Directory temp;
  late ArtifactCache cache;
  late RecordingLauncher launcher;
  final supervisors = <WorkerSupervisor>[];
  final logs = <String>[];

  setUpAll(() async {
    workerExe = await compileFakeWorker();
  });

  setUp(() {
    temp = Directory.systemTemp.createTempSync('supervisor_test');
    cache = ArtifactCache(Directory(p.join(temp.path, 'cache')));
    launcher = RecordingLauncher();
    logs.clear();
  });

  tearDown(() async {
    for (final s in supervisors) {
      await s.close();
    }
    supervisors.clear();
    check(because: 'no worker process may outlive the test', await launcher.waitAllExited()).isTrue();
    temp.deleteSync(recursive: true);
  });

  WorkerSupervisor supervisor({
    List<String> arguments = const <String>[],
    SupervisorLimitsPolicy? limits,
    ReverseRequestHandler? onReverseRequest,
    FutureOr<void> Function(int generation)? onGenerationFenced,
  }) {
    final s = WorkerSupervisor(
      spec: fakeWorkerSpec(workerExe, arguments: arguments),
      limits: limits ?? testLimits(),
      launcher: launcher.call,
      onReverseRequest: onReverseRequest,
      onLog: logs.add,
      onGenerationFenced: onGenerationFenced,
    );
    supervisors.add(s);
    return s;
  }

  Future<WorkerPackage> package(
    String id, {
    Map<String, String> secrets = const <String, String>{},
    SettingsSnapshot? settings,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode('artifact for $id'));
    final binding = ArtifactBinding(sha256: sha256.convert(bytes).toString(), kind: 'test', version: '1');
    final ArtifactLease lease = await cache.admit(
      bytes,
      binding: binding,
      profile: const ArtifactProfile(producer: 'test', converterVersion: '1', hostCompatibility: '1'),
      verifier: (_, _) {},
    );
    return WorkerPackage(
      packageId: id,
      artifact: lease,
      settings: settings ?? SettingsSnapshot(secrets: secrets),
    );
  }

  var markers = 0;
  Map<String, Object?> crashOnce() => <String, Object?>{
    'crashOnce': p.join(temp.path, 'crash-marker-${++markers}'),
  };

  Future<Map<String, Object?>> stats(WorkerSupervisor s) async =>
      (await s.call('stats', 'stats', const <String, Object?>{})).valueOrNull!;

  group('framing', () {
    test('round-trips UTF-8 and int64 source IDs beyond 2^53 exactly', () async {
      final WorkerSupervisor s = supervisor();
      const value = <String, Object?>{'text': 'naïve 漫画 🎌', 'sourceId': '9223372036854775807'};
      final SourceOutcome<Map<String, Object?>> out = await s.call('pkg', 'echo', <String, Object?>{'value': value});
      check(out.valueOrNull!['echo']).isA<Map<String, Object?>>().deepEquals(value);
      check(
        Int64Id.fromJson((out.valueOrNull!['echo']! as Map<String, Object?>)['sourceId']).decimal,
      ).equals('9223372036854775807');
    });

    test('reassembles a reply split into 3-byte writes', () async {
      final WorkerSupervisor s = supervisor();
      final SourceOutcome<Map<String, Object?>> out = await s.call('pkg', 'echo', <String, Object?>{
        'value': 'é漫🎌 split',
        'fake': <String, Object?>{'split': true},
      });
      check(out.valueOrNull!['echo']).equals('é漫🎌 split');
    });

    test('decodes two frames delivered in one read', () async {
      final WorkerSupervisor s = supervisor();
      final List<SourceOutcome<Map<String, Object?>>> outs = await Future.wait(
        <Future<SourceOutcome<Map<String, Object?>>>>[
          s.call('a', 'echo', <String, Object?>{
            'value': 'first',
            'fake': <String, Object?>{'batch': 't'},
          }),
          s.call('b', 'echo', <String, Object?>{
            'value': 'second',
            'fake': <String, Object?>{'batch': 't'},
          }),
        ],
      );
      check(outs.map((SourceOutcome<Map<String, Object?>> o) => o.valueOrNull!['echo'])).deepEquals(<String>[
        'first',
        'second',
      ]);
    });

    test('a request larger than the frame limit fails visibly without truncation', () async {
      final WorkerSupervisor s = supervisor(limits: testLimits(maxFrameBytes: 2048));
      final SourceOutcome<Map<String, Object?>> out = await s.call('pkg', 'echo', <String, Object?>{
        'value': 'x' * 4096,
      });
      check(out.failureOrNull).isA<ProtocolViolationFailure>();
      check(s.state).equals(WorkerState.ready);
      check((await s.call('pkg', 'echo', <String, Object?>{'value': 'ok'})).valueOrNull!['echo']).equals('ok');
    });
  });

  group('protocol violations fail the session visibly', () {
    Future<void> expectViolation(WorkerSupervisor s, Map<String, Object?> fake) async {
      final SourceOutcome<Map<String, Object?>> out = await s.call('pkg', 'echo', <String, Object?>{
        'value': 1,
        'fake': fake,
      });
      check(out.failureOrNull).isA<ProtocolViolationFailure>();
      check(s.state).equals(WorkerState.failed);
      check(s.events.whereType<WorkerFailedEvent>()).length.equals(1);
      check(await launcher.waitAllExited()).isTrue();
      // Later calls fail immediately with the same failure.
      check((await s.call('pkg', 'echo', const <String, Object?>{})).failureOrNull).isA<ProtocolViolationFailure>();
    }

    test('unknown protocol version', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--bad-version']);
      check((await s.start()).failureOrNull).isA<ProtocolViolationFailure>();
      check(s.state).equals(WorkerState.failed);
    });

    test('unexpected stdout text at startup', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--startup-garbage']);
      check((await s.start()).failureOrNull).isA<ProtocolViolationFailure>();
    });

    test('unexpected stdout text', () => expectViolation(supervisor(), <String, Object?>{'stdoutGarbage': true}));

    test('malformed frame', () => expectViolation(supervisor(), <String, Object?>{'malformed': true}));

    test(
      'oversized frame',
      () => expectViolation(supervisor(limits: testLimits(maxFrameBytes: 4096)), <String, Object?>{'oversized': 10000}),
    );

    test('wrong generation', () => expectViolation(supervisor(), <String, Object?>{'wrongGen': true}));

    test('orphaned reverse request', () => expectViolation(supervisor(), <String, Object?>{'orphanReverse': true}));

    test('reply for an unknown request', () => expectViolation(supervisor(), <String, Object?>{'unknownReply': true}));
  });

  group('redaction', () {
    test('seeded cookies, tokens and passwords in worker stderr never reach the log file', () async {
      final logFile = File(p.join(temp.path, 'user.log'));
      final IOSink sink = logFile.openWrite();
      final s = WorkerSupervisor(
        spec: fakeWorkerSpec(workerExe),
        limits: testLimits(),
        launcher: launcher.call,
        onLog: sink.writeln,
      );
      supervisors.add(s);
      check(
        await s.loadPackage(await package('pkg', secrets: <String, String>{'password': 'hunter2-Pa55'})),
      ).isA<SourceSuccess<PackageLoadResponse>>();
      for (final line in <String>[
        'Cookie: sid=cookie-value-123; cf_clearance=clear-456',
        'set-cookie: refresh=set-cookie-789; Path=/',
        'Authorization: Bearer bearer-token-abc',
        'GET https://alice:url-password@example.org/api?token=query-token-def&page=2',
        'login failed for password hunter2-Pa55',
        '{"cookie": "json-cookie-ghi", "ok": true}',
      ]) {
        check(
          await s.call('pkg', 'echo', <String, Object?>{
            'value': 1,
            'fake': <String, Object?>{'stderr': line, 'stderrSplit': true},
          }),
        ).isA<SourceSuccess<Map<String, Object?>>>();
      }
      await s.close();
      await sink.close();
      final String log = logFile.readAsStringSync();
      for (final secret in <String>[
        'cookie-value-123',
        'clear-456',
        'set-cookie-789',
        'bearer-token-abc',
        'url-password',
        'alice',
        'query-token-def',
        'hunter2-Pa55',
        'json-cookie-ghi',
      ]) {
        check(because: 'log must not contain $secret', log).not((Subject<String> it) => it.contains(secret));
      }
      check(log).contains(redactedPlaceholder);
      check(log).contains('page=2');
    });
  });

  group('cancellation and cleanup (AE5)', () {
    test('a startup that completes after cancellation is killed and awaited', () async {
      launcher.gate = Completer<void>();
      final WorkerSupervisor s = supervisor();
      final Future<SourceOutcome<HandshakeResponse>> starting = s.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final Future<void> closing = s.close();
      launcher.gate!.complete();
      await closing;
      check((await starting).failureOrNull).isNotNull();
      check(launcher.launched).length.equals(1);
      check(launcher.allExited).isTrue();
    });

    test('cancelling during the handshake leaves no process', () async {
      final waitFile = File(p.join(temp.path, 'release-handshake'));
      final WorkerSupervisor s = supervisor(arguments: <String>['--handshake-wait=${waitFile.path}']);
      final Future<SourceOutcome<HandshakeResponse>> starting = s.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await s.close();
      check((await starting).failureOrNull).isNotNull();
      check(launcher.allExited).isTrue();
    });

    test('cancelling mid-request answers at once and keeps the worker', () async {
      final WorkerSupervisor s = supervisor();
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      final int? pid = s.pid;
      final cancel = CancellationSource();
      final Future<SourceOutcome<Map<String, Object?>>> pending = s.call('pkg', 'echo', <String, Object?>{
        'fake': <String, Object?>{'hangUntilCancel': true},
      }, cancel: cancel.token);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      cancel.cancel('user cancelled');
      check((await pending).failureOrNull).isA<CancelledFailure>();
      check((await s.call('pkg', 'echo', <String, Object?>{'value': 'next'})).valueOrNull!['echo']).equals('next');
      check(s.pid).equals(pid);
      check(s.generation).equals(1);
    });

    test('closing during an in-flight request cancels it and leaves no process', () async {
      final WorkerSupervisor s = supervisor();
      final Future<SourceOutcome<Map<String, Object?>>> pending = s.call('pkg', 'echo', <String, Object?>{
        'fake': <String, Object?>{'hang': true},
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await s.close();
      check((await pending).failureOrNull).isA<CancelledFailure>();
      check(launcher.allExited).isTrue();
      check(s.state).equals(WorkerState.closed);
    });

    test('a worker that ignores shutdown is killed after the shutdown bound', () async {
      final WorkerSupervisor s = supervisor(
        arguments: <String>['--ignore-shutdown'],
        limits: testLimits(shutdownGrace: const Duration(milliseconds: 300)),
      );
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      final watch = Stopwatch()..start();
      await s.close();
      check(launcher.allExited).isTrue();
      check(watch.elapsed).isLessThan(const Duration(seconds: 5));
    });

    test('one package loads before a second fails; the scope awaits worker exit before returning', () async {
      final scope = ConversionRuntimeScope(
        workers: <WorkerKind, WorkerSpec>{
          WorkerKind.jvm: fakeWorkerSpec(workerExe, arguments: <String>['--fail-package=bad']),
        },
        limits: testLimits(),
        launcher: launcher.call,
      );
      final WorkerPackage good = await package('good');
      final WorkerPackage bad = await package('bad');
      Object? error;
      try {
        await ConversionRuntimeScope.run(scope, (ConversionRuntimeScope scope) async {
          final WorkerSupervisor jvm = (await scope.worker(WorkerKind.jvm)).valueOrNull!;
          check(await jvm.loadPackage(good)).isA<SourceSuccess<PackageLoadResponse>>();
          final SourceOutcome<PackageLoadResponse> failed = await jvm.loadPackage(bad);
          throw _LoadFailed('${failed.failureOrNull}');
        });
      } on _LoadFailed catch (e) {
        error = e;
        // Checked synchronously on failure delivery: cleanup already finished.
        check(launcher.launched).isNotEmpty();
        check(launcher.allExited).isTrue();
      }
      check(error).isNotNull();
    });
  });

  group('deadlines and restart (AE5)', () {
    test('a cooperative cancel within the grace period fails the call without a restart', () async {
      final WorkerSupervisor s = supervisor();
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      final int? pid = s.pid;
      final SourceOutcome<Map<String, Object?>> out = await s.call('pkg', 'echo', <String, Object?>{
        'fake': <String, Object?>{'delayMs': 5000},
      }, deadline: const Duration(milliseconds: 200));
      check(out.failureOrNull).isA<TimeoutFailure>();
      check(s.pid).equals(pid);
      check(s.events.whereType<WorkerRestartedEvent>()).isEmpty();
    });

    test('an operation that ignores cancel restarts the worker; others re-queue once', () async {
      final WorkerSupervisor s = supervisor();
      check(await s.loadPackage(await package('a'))).isA<SourceSuccess<PackageLoadResponse>>();
      check(await s.loadPackage(await package('b'))).isA<SourceSuccess<PackageLoadResponse>>();
      final int? firstPid = s.pid;
      final Future<SourceOutcome<Map<String, Object?>>> other = s.call('b', 'echo', <String, Object?>{
        'value': 'survivor',
        'fake': <String, Object?>{'delayMs': 1500},
      });
      final SourceOutcome<Map<String, Object?>> hung = await s.call('a', 'echo', <String, Object?>{
        'fake': <String, Object?>{'hang': true},
      }, deadline: const Duration(milliseconds: 300));
      check(hung.failureOrNull).isA<TimeoutFailure>();
      check((await other).valueOrNull!['echo']).equals('survivor');
      check(s.generation).equals(2);
      check(s.pid).not((Subject<int?> it) => it.equals(firstPid));
      check(s.events.whereType<OperationRequeuedEvent>().map((OperationRequeuedEvent e) => e.packageId)).deepEquals(
        <String>['b'],
      );
      final WorkerRestartedEvent restart = s.events.whereType<WorkerRestartedEvent>().single;
      check(restart.requeued).deepEquals(<String>['b']);
      // Every package was reloaded from its verified artifact.
      check((await stats(s))['loaded']).isA<Map<String, Object?>>().keys.unorderedEquals(<String>['a', 'b']);
    });

    test('an operation interrupted by a second restart fails as worker-restarted', () async {
      final WorkerSupervisor s = supervisor();
      check(await s.loadPackage(await package('crashy'))).isA<SourceSuccess<PackageLoadResponse>>();
      // The worker exits while running this call; it is re-queued once, runs
      // again, crashes again, and is then reported failed.
      final SourceOutcome<Map<String, Object?>> out = await s.call('crashy', 'echo', <String, Object?>{
        'fake': <String, Object?>{'crash': true},
      });
      check(out.failureOrNull).isA<WorkerRestartedFailure>();
      // Restart events are recorded once reloading finishes; wait for it.
      check((await s.call('crashy', 'echo', <String, Object?>{'value': 'after'})).valueOrNull!['echo']).equals('after');
      check(s.events.whereType<OperationRequeuedEvent>()).length.equals(1);
      check(s.events.whereType<WorkerRestartedEvent>()).length.equals(2);
      check(s.state).equals(WorkerState.ready);
    });

    test('queue wait does not consume the execution deadline', () async {
      final WorkerSupervisor s = supervisor();
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      // Each call executes for 500 ms within a 900 ms deadline, but the third
      // waits ~1000 ms in the package queue first.
      final List<SourceOutcome<Map<String, Object?>>> outs = await Future.wait(
        <Future<SourceOutcome<Map<String, Object?>>>>[
          for (var i = 0; i < 3; i++)
            s.call('pkg', 'echo', <String, Object?>{
              'value': i,
              'fake': <String, Object?>{'delayMs': 500},
            }, deadline: const Duration(milliseconds: 900)),
        ],
      );
      check(outs.map((SourceOutcome<Map<String, Object?>> o) => o.valueOrNull?['echo'])).deepEquals(<int>[0, 1, 2]);
    });

    test('a restart re-verifies artifacts and fails a package whose staged bytes changed', () async {
      final WorkerSupervisor s = supervisor();
      final WorkerPackage tampered = await package('tampered');
      check(await s.loadPackage(tampered)).isA<SourceSuccess<PackageLoadResponse>>();
      check(await s.loadPackage(await package('intact'))).isA<SourceSuccess<PackageLoadResponse>>();
      File(tampered.artifact.path).writeAsStringSync('changed bytes');
      final Future<SourceOutcome<Map<String, Object?>>> queued = s.call('tampered', 'echo', <String, Object?>{
        'fake': <String, Object?>{'delayMs': 2000},
      });
      // Crash the worker from the other package.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final SourceOutcome<Map<String, Object?>> crash = await s.call('intact', 'echo', <String, Object?>{
        'value': 'retried',
        'fake': crashOnce(),
      });
      check(crash.valueOrNull!['echo']).equals('retried');
      check((await queued).failureOrNull).isA<ArtifactIncompatibleFailure>();
      check(s.packageIds).not((Subject<Iterable<String>> it) => it.contains('tampered'));
      check(s.events.whereType<WorkerRestartedEvent>().first.reloadFailures).contains('tampered');
    });

    test('visible interaction time is excluded from the deadline and bounded separately', () async {
      final release = Completer<void>();
      final WorkerSupervisor s = supervisor(
        onReverseRequest: (ReverseRequest r) async {
          check(r.isInteraction).isTrue();
          await release.future;
          return const SourceSuccess<Map<String, Object?>>(<String, Object?>{'shown': true});
        },
      );
      final Future<SourceOutcome<Map<String, Object?>>> out = s.call('pkg', 'echo', <String, Object?>{
        'fake': <String, Object?>{
          'reverse': <String, Object?>{'op': 'host.browser.show'},
        },
      }, deadline: const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      release.complete();
      check(
        (await out).valueOrNull!['reverse'],
      ).isA<Map<String, Object?>>().deepEquals(<String, Object?>{'shown': true});
    });

    test('an interaction beyond its own bound escalates like a deadline', () async {
      final WorkerSupervisor s = supervisor(
        limits: testLimits(
          interactionTimeout: const Duration(milliseconds: 300),
        ),
        onReverseRequest: (ReverseRequest r) async {
          await r.cancel.whenCancelled;
          return SourceFailed<Map<String, Object?>>(CancelledFailure(r.cancel.reason ?? 'cancelled'));
        },
      );
      final SourceOutcome<Map<String, Object?>> out = await s.call('pkg', 'echo', <String, Object?>{
        'fake': <String, Object?>{
          'reverse': <String, Object?>{'op': 'host.browser.show'},
        },
      });
      check(out.failureOrNull).isA<TimeoutFailure>();
    });
  });

  group('review regressions', () {
    test('closing while a restart stops the old worker answers every call and starts nothing', () async {
      late WorkerSupervisor s;
      s = supervisor(onGenerationFenced: (_) => unawaited(s.close()));
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      final Future<SourceOutcome<Map<String, Object?>>> other = s.call('b', 'echo', <String, Object?>{
        'fake': <String, Object?>{'delayMs': 5000},
      });
      final SourceOutcome<Map<String, Object?>> hung = await s.call('a', 'echo', <String, Object?>{
        'fake': <String, Object?>{'hang': true},
      }, deadline: const Duration(milliseconds: 300));
      check(hung.failureOrNull).isA<TimeoutFailure>();
      check((await other).failureOrNull).isA<CancelledFailure>();
      await s.close();
      check(launcher.launched).length.equals(1);
      check(launcher.allExited).isTrue();
      check(s.state).equals(WorkerState.closed);
    });

    test('worker text echoed into failures and supervisor log lines is redacted', () async {
      final WorkerSupervisor s = supervisor();
      check(
        await s.loadPackage(await package('pkg', secrets: <String, String>{'token': 'tok-SECRET-1'})),
      ).isA<SourceSuccess<PackageLoadResponse>>();
      final SourceOutcome<Map<String, Object?>> err = await s.call('pkg', 'echo', <String, Object?>{
        'fake': <String, Object?>{'errorMessage': 'login failed with tok-SECRET-1'},
      });
      check(err.failureOrNull!.message).not((Subject<String> it) => it.contains('tok-SECRET-1'));
      final SourceOutcome<Map<String, Object?>> garbage = await s.call('pkg', 'echo', <String, Object?>{
        'fake': <String, Object?>{'stdoutText': 'debug tok-SECRET-1 Cookie: a=b'},
      });
      check(garbage.failureOrNull).isA<ProtocolViolationFailure>();
      check(garbage.failureOrNull!.message).not((Subject<String> it) => it.contains('tok-SECRET-1'));
      check(s.events.whereType<WorkerFailedEvent>().single.failure.message).not(
        (Subject<String> it) => it.contains('tok-SECRET-1'),
      );
      check(logs).isNotEmpty();
      check(logs.join('\n')).not((Subject<String> it) => it.contains('tok-SECRET-1'));
    });

    test('writes to a worker that died before its exit was observed are not fatal', () async {
      final s = WorkerSupervisor(
        spec: fakeWorkerSpec(workerExe),
        limits: testLimits(),
        launcher: DelayedExitLauncher(launcher, delay: const Duration(milliseconds: 600)).call,
        onLog: logs.add,
      );
      supervisors.add(s);
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      final Future<SourceOutcome<Map<String, Object?>>> crash = s.call('a', 'echo', <String, Object?>{
        'value': 'a',
        'fake': crashOnce(),
      });
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final more = <Future<SourceOutcome<Map<String, Object?>>>>[
        for (var i = 0; i < 4; i++) s.call('p$i', 'echo', <String, Object?>{'value': i}),
      ];
      check((await crash).valueOrNull!['echo']).equals('a');
      for (var i = 0; i < 4; i++) {
        check((await more[i]).valueOrNull!['echo']).equals(i);
      }
      check(s.events.whereType<WorkerRestartedEvent>()).length.equals(1);
    });
  });

  group('scheduling', () {
    test('calls to one package serialise while different packages run within the pool bound', () async {
      final WorkerSupervisor s = supervisor(limits: testLimits());
      await Future.wait(<Future<SourceOutcome<Map<String, Object?>>>>[
        for (final pkg in <String>['p1', 'p2', 'p3'])
          for (var i = 0; i < 2; i++)
            s.call(pkg, 'echo', <String, Object?>{
              'value': i,
              'fake': <String, Object?>{'delayMs': 150, 'stderr': 'log noise from $pkg $i'},
            }),
      ]);
      final Map<String, Object?> st = await stats(s);
      check(st['maxActive']! as int).equals(2);
      check((st['maxPerPackage']! as Map<String, Object?>).values).every((Subject<Object?> it) => it.equals(1));
      check(because: logs.join('\n'), logs.where((String l) => l.contains('log noise'))).length.equals(6);
      check(s.events.whereType<WorkerRestartedEvent>()).isEmpty();
    });

    test('debounced queries drop obsolete queued and in-flight searches without a restart', () async {
      final WorkerSupervisor s = supervisor();
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      final int? pid = s.pid;
      Future<SourceOutcome<Map<String, Object?>>> search(String q) => s.call('pkg', 'echo', <String, Object?>{
        'value': q,
        'fake': <String, Object?>{'delayMs': 300},
      }, coalesceKey: 'search:src');
      final Future<SourceOutcome<Map<String, Object?>>> first = search('o');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final Future<SourceOutcome<Map<String, Object?>>> second = search('on');
      final Future<SourceOutcome<Map<String, Object?>>> confirmed = s.call('other', 'echo', <String, Object?>{
        'value': 'confirmed manga',
      });
      final Future<SourceOutcome<Map<String, Object?>>> third = search('oni');
      check((await first).failureOrNull).isA<CancelledFailure>();
      check((await second).failureOrNull).isA<CancelledFailure>();
      check((await third).valueOrNull!['echo']).equals('oni');
      check((await confirmed).valueOrNull!['echo']).equals('confirmed manga');
      check(s.pid).equals(pid);
      check(s.generation).equals(1);
    });
  });

  group('reverse browser requests', () {
    test('host.browser.* requests reach the BrowserPort and replies return to the worker', () async {
      final browser = FakeBrowserPort(
        pages: (Uri url) => url.host == 'example.org' ? const FakeWebPage(html: '<title>ok</title>') : null,
      );
      final bridge = BrowserReverseBridge(
        port: browser,
        interactionTimeout: const Duration(seconds: 1),
        resolveSource: (String? pkg, String sourceId) => SourceIdentity(
          ecosystem: 'test',
          packageId: pkg!,
          sourceId: sourceId,
          artifact: const ArtifactBinding(sha256: 'ab', kind: 'test', version: '1'),
        ),
      );
      final WorkerSupervisor s = supervisor(onReverseRequest: bridge.handle);
      Future<Map<String, Object?>> reverse(String op, Map<String, Object?> payload) async {
        final SourceOutcome<Map<String, Object?>> out = await s.call('pkg', 'echo', <String, Object?>{
          'fake': <String, Object?>{
            'reverse': <String, Object?>{'op': op, 'payload': payload},
          },
        });
        return out.valueOrNull!;
      }

      final Map<String, Object?> opened = await reverse('host.browser.open', <String, Object?>{'sourceId': '42'});
      final session = (opened['reverse']! as Map<String, Object?>)['session']! as String;
      final Map<String, Object?> loaded = await reverse('host.browser.load', <String, Object?>{
        'session': session,
        'url': 'https://example.org/',
      });
      check((loaded['reverse']! as Map<String, Object?>)['finalUrl']).equals('https://example.org/');
      final Map<String, Object?> refused = await reverse('host.browser.load', <String, Object?>{
        'session': session,
        'url': 'file:///etc/passwd',
      });
      check((refused['reverseError']! as Map<String, Object?>)['code']).equals(CapabilityUnavailableFailure.wireCode);
      final Map<String, Object?> title = await reverse('host.browser.evaluate', <String, Object?>{
        'session': session,
        'script': 'document.title',
      });
      check((title['reverse']! as Map<String, Object?>)['result']).equals('"ok"');
    });

    test('a reverse reply that settles after a generation change is discarded', () async {
      final releases = <Completer<void>>[];
      final WorkerSupervisor s = supervisor(
        onReverseRequest: (ReverseRequest r) async {
          final release = Completer<void>();
          releases.add(release);
          final int n = releases.length;
          await release.future;
          return SourceSuccess<Map<String, Object?>>(<String, Object?>{'n': n, 'gen': r.generation});
        },
      );
      final Future<SourceOutcome<Map<String, Object?>>> pending = s.call('a', 'echo', <String, Object?>{
        'fake': <String, Object?>{
          'reverse': <String, Object?>{'op': 'host.browser.evaluate'},
        },
      });
      while (releases.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // Restart the worker from another package; the call above is re-queued.
      final Future<SourceOutcome<Map<String, Object?>>> crash = s.call('b', 'echo', <String, Object?>{
        'fake': crashOnce(),
      });
      while (releases.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      releases.first.complete(); // late: generation 1 was fenced
      await Future<void>.delayed(const Duration(milliseconds: 100));
      releases[1].complete();
      final reply = (await pending).valueOrNull!['reverse']! as Map<String, Object?>;
      check(reply['n']).equals(2);
      check(reply['gen']).equals(s.generation);
      check(await crash).isA<SourceSuccess<Map<String, Object?>>>();
    });
  });

  group('native references across restart', () {
    test('confirmed references stay usable after restart; old handles do not', () async {
      final fenced = <int>[];
      final WorkerSupervisor s = supervisor(onGenerationFenced: fenced.add);
      final WorkerPackage pkg = await package('tachi.pkg');
      final SourceOutcome<PackageLoadResponse> loaded = await s.loadPackage(pkg);
      final String sourceId = loaded.valueOrNull!.sources.single.sourceId;
      final session = WorkerSourceSession(
        supervisor: s,
        identity: SourceIdentity(
          ecosystem: 'tachi',
          packageId: 'tachi.pkg',
          sourceId: Int64Id.fromJson(sourceId).decimal,
          artifact: pkg.artifact.binding,
        ),
        displayName: 'Fake',
        capabilities: SourceCapabilities(
          operations: const <SourceOperation>{SourceOperation.search, SourceOperation.mangaDetails},
        ),
        settingsRevision: pkg.settings.revision,
      );
      final SearchHit hit = (await session.search(const SearchRequest(query: 'onimai'))).valueOrNull!.hits.single;
      check(hit.ref.handle?.generation).equals(1);
      check(hit.ref.source.sourceId).equals('9223372036854775807');
      final MangaSnapshot before = (await session.fetchManga(hit.ref)).valueOrNull!;
      check(before.metadata.title).equals('Details of manga-for-onimai');

      final SourceOutcome<Map<String, Object?>> crash = await s.call('other', 'echo', <String, Object?>{
        'fake': crashOnce(),
      });
      check(crash).isA<SourceSuccess<Map<String, Object?>>>();
      check(fenced).deepEquals(<int>[2]);

      // Through the session, the durable reference still works.
      final SourceOutcome<MangaSnapshot> after = await session.fetchManga(hit.ref);
      check(after.valueOrNull!.metadata.title).equals('Details of manga-for-onimai');
      // Sent directly, the old handle is refused by the new worker.
      final SourceOutcome<Map<String, Object?>> direct = await s.call('tachi.pkg', 'details', <String, Object?>{
        'ref': hit.ref.toJson(),
        'handle': hit.ref.handle!.value,
      });
      check(direct.failureOrNull).isA<StaleReferenceFailure>();
      // A reference confirmed under another settings revision is stale.
      final stale = NativeMangaRef(source: hit.ref.source, mangaId: hit.ref.mangaId, settingsRevision: 'other');
      check((await session.fetchManga(stale)).failureOrNull).isA<StaleReferenceFailure>();
    });
  });

  group('conversion scope', () {
    test('owns at most one worker per kind and reports missing kinds as capability-unavailable', () async {
      final scope = ConversionRuntimeScope(
        workers: <WorkerKind, WorkerSpec>{WorkerKind.paperback: fakeWorkerSpec(workerExe, label: 'paperback')},
        limits: testLimits(),
        launcher: launcher.call,
      );
      final WorkerSupervisor a = (await scope.worker(WorkerKind.paperback)).valueOrNull!;
      final WorkerSupervisor b = (await scope.worker(WorkerKind.paperback)).valueOrNull!;
      check(identical(a, b)).isTrue();
      final SourceOutcome<WorkerSupervisor> jvm = await scope.worker(WorkerKind.jvm);
      check(jvm.failureOrNull)
          .isA<CapabilityUnavailableFailure>()
          .has((f) => f.operation, 'operation')
          .equals(
            'worker.jvm',
          );
      await scope.close();
      check(launcher.launched).length.equals(1);
      check(launcher.allExited).isTrue();
      check((await scope.worker(WorkerKind.paperback)).failureOrNull).isA<RuntimeUnavailableFailure>();
    });
  });

  group('typed handshake', () {
    test('the handshake reply is decoded and kept', () async {
      final WorkerSupervisor s = supervisor();
      final HandshakeResponse hello = (await s.start()).valueOrNull!;
      check(hello.worker).equals('fake');
      check(hello.pid).equals(s.pid);
      check(s.handshake!.capabilities.browser).isTrue();
      check(s.handshake!.capabilities.apiFamilies).deepEquals(<String>{'fake-1'});
    });

    test('a handshake reply missing its capabilities fails the session as a protocol violation', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--bad-handshake']);
      check(
        (await s.start()).failureOrNull,
      ).isA<ProtocolViolationFailure>().has((f) => f.message, 'message').contains('capabilities');
      check(s.state).equals(WorkerState.failed);
    });

    test('a reply that does not match its payload type fails the whole session', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--malformed-load=bad']);
      check(await s.loadPackage(await package('good'))).isA<SourceSuccess<PackageLoadResponse>>();
      check(
        (await s.loadPackage(await package('bad'))).failureOrNull,
      ).isA<ProtocolViolationFailure>().has((f) => f.message, 'message').contains('package.load');
      await _eventually(() => s.state == WorkerState.failed);
      check(s.packageIds).isEmpty();
      check((await s.call('good', 'echo', const <String, Object?>{})).failureOrNull).isA<ProtocolViolationFailure>();
      check(s.events.whereType<WorkerFailedEvent>()).length.equals(1);
    });
  });

  group('package settings and unload', () {
    Map<String, Object?> workerSettings(Map<String, Object?> stats, String pkg) =>
        (stats['settings']! as Map<String, Object?>)[pkg]! as Map<String, Object?>;

    test('a restart reloads each package with its current settings, not its original ones', () async {
      final WorkerSupervisor s = supervisor();
      final original = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en', 'nsfw': false, 'pageSize': 20},
        secrets: const <String, String>{'token': 'tok-ORIGINAL'},
      );
      final updated = SettingsSnapshot(
        values: const <String, Object>{'lang': 'fr', 'nsfw': true, 'pageSize': 50},
        secrets: const <String, String>{'token': 'tok-UPDATED'},
      );
      check(await s.loadPackage(await package('pkg', settings: original))).isA<SourceSuccess<PackageLoadResponse>>();
      check(await s.updateSettings('pkg', updated)).isA<SourceSuccess<EmptyPayload>>();
      check(s.settingsOf('pkg')!.revision).equals(updated.revision);
      check(workerSettings(await stats(s), 'pkg')['revision']).equals(updated.revision);

      final int? before = s.pid;
      check(
        await s.call('other', 'echo', <String, Object?>{'fake': crashOnce()}),
      ).isA<SourceSuccess<Map<String, Object?>>>();
      check(s.pid).not((Subject<int?> it) => it.equals(before));
      final Map<String, Object?> reloaded = workerSettings(await stats(s), 'pkg');
      check(reloaded['revision']).equals(updated.revision);
      check(reloaded['values']).isA<Map<String, Object?>>().deepEquals(<String, Object?>{
        'lang': 'fr',
        'nsfw': true,
        'pageSize': 50,
      });
      check(reloaded['secrets']).isA<Map<String, Object?>>().deepEquals(<String, Object?>{'token': 'tok-UPDATED'});
    });

    test('a failed settings update keeps the previous settings, including across a restart', () async {
      final WorkerSupervisor s = supervisor();
      final original = SettingsSnapshot(values: const <String, Object>{'lang': 'en'});
      check(await s.loadPackage(await package('pkg', settings: original))).isA<SourceSuccess<PackageLoadResponse>>();
      final SourceOutcome<EmptyPayload> refused = await s.updateSettings(
        'pkg',
        SettingsSnapshot(values: const <String, Object>{'failUpdate': true}),
      );
      check(refused.failureOrNull).isA<SourceErrorFailure>();
      check(s.settingsOf('pkg')!.revision).equals(original.revision);
      await s.call('other', 'echo', <String, Object?>{'fake': crashOnce()});
      check(workerSettings(await stats(s), 'pkg')['revision']).equals(original.revision);
    });

    test('an unloaded package is not reloaded after a restart', () async {
      final WorkerSupervisor s = supervisor();
      check(await s.loadPackage(await package('a'))).isA<SourceSuccess<PackageLoadResponse>>();
      check(await s.loadPackage(await package('b'))).isA<SourceSuccess<PackageLoadResponse>>();
      check(await s.unloadPackage('a')).isA<SourceSuccess<EmptyPayload>>();
      check(s.packageIds).deepEquals(<String>['b']);
      check(((await stats(s))['loaded']! as Map<String, Object?>).keys).deepEquals(<String>['b']);

      await s.call('other', 'echo', <String, Object?>{'fake': crashOnce()});
      check(((await stats(s))['loaded']! as Map<String, Object?>).keys).deepEquals(<String>['b']);
      check(s.events.whereType<WorkerRestartedEvent>().single.reloadFailures).isEmpty();
      check((await s.unloadPackage('a')).failureOrNull).isA<StaleReferenceFailure>();
      check((await s.updateSettings('a', SettingsSnapshot())).failureOrNull).isA<StaleReferenceFailure>();
    });

    test('secrets supplied by a settings update are redacted from worker stderr', () async {
      final WorkerSupervisor s = supervisor();
      check(await s.loadPackage(await package('pkg'))).isA<SourceSuccess<PackageLoadResponse>>();
      check(
        await s.updateSettings('pkg', SettingsSnapshot(secrets: const <String, String>{'password': 'NEW-pa55-word'})),
      ).isA<SourceSuccess<EmptyPayload>>();
      await s.call('pkg', 'echo', <String, Object?>{
        'fake': <String, Object?>{'stderr': 'logging in with NEW-pa55-word'},
      });
      await s.close();
      check(logs.join('\n')).not((Subject<String> it) => it.contains('NEW-pa55-word'));
      check(logs.join('\n')).contains('logging in with');
    });

    test('sessions follow the current revision: references confirmed before an update are stale', () async {
      final WorkerSupervisor s = supervisor();
      final WorkerPackage pkg = await package('tachi.pkg');
      final LoadedSource loaded = (await s.loadPackage(pkg)).valueOrNull!.sources.single;
      final session = WorkerSourceSession(
        supervisor: s,
        identity: SourceIdentity(
          ecosystem: 'tachi',
          packageId: 'tachi.pkg',
          sourceId: loaded.sourceId,
          artifact: pkg.artifact.binding,
        ),
        displayName: loaded.name,
        capabilities: loaded.capabilities,
        settingsRevision: pkg.settings.revision,
      );
      final SearchHit before = (await session.search(const SearchRequest(query: 'onimai'))).valueOrNull!.hits.single;
      final updated = SettingsSnapshot(values: const <String, Object>{'lang': 'fr'});
      check(await s.updateSettings('tachi.pkg', updated)).isA<SourceSuccess<EmptyPayload>>();
      check(session.settingsRevision).equals(updated.revision);
      check((await session.fetchManga(before.ref)).failureOrNull).isA<StaleReferenceFailure>();

      final SearchHit after = (await session.search(const SearchRequest(query: 'onimai'))).valueOrNull!.hits.single;
      check(after.ref.settingsRevision).equals(updated.revision);
      check((await session.fetchManga(after.ref)).valueOrNull?.metadata.title).equals('Details of manga-for-onimai');

      await session.close();
      check((await stats(s))['disposed']! as List<Object?>).deepEquals(<Object?>[
        <String, Object?>{'pkg': 'tachi.pkg', 'handles': null},
      ]);
    });
  });

  group('browser bridge fencing', () {
    SourceIdentity identityFor(String? pkg, String sourceId) => SourceIdentity(
      ecosystem: 'test',
      packageId: pkg!,
      sourceId: sourceId,
      artifact: const ArtifactBinding(sha256: 'ab', kind: 'test', version: '1'),
    );

    BrowserReverseBridge bridgeFor(BrowserPort port) =>
        BrowserReverseBridge(port: port, interactionTimeout: const Duration(seconds: 1), resolveSource: identityFor);

    WorkerSupervisor bridged(BrowserReverseBridge bridge) {
      final WorkerSupervisor s = supervisor(onReverseRequest: bridge.handle, onGenerationFenced: bridge.fence);
      bridge.emitEvent = s.sendEvent;
      return s;
    }

    Future<Map<String, Object?>> reverse(
      WorkerSupervisor s,
      String pkg,
      String op,
      Map<String, Object?> payload,
    ) async => (await s.call(pkg, 'echo', <String, Object?>{
      'fake': <String, Object?>{
        'reverse': <String, Object?>{'op': op, 'payload': payload},
      },
    })).valueOrNull!;

    Future<String> open(WorkerSupervisor s, String pkg) async {
      final Map<String, Object?> opened = await reverse(s, pkg, 'host.browser.open', <String, Object?>{
        'sourceId': '42',
      });
      return (opened['reverse']! as Map<String, Object?>)['session']! as String;
    }

    test('a restart closes the sessions of the fenced generation; their late requests are refused', () async {
      final port = FakeBrowserPort(pages: (_) => const FakeWebPage());
      final BrowserReverseBridge bridge = bridgeFor(port);
      final WorkerSupervisor s = bridged(bridge);
      final String session = await open(s, 'pkg');
      check(port.openSessions).equals(1);

      check(
        await s.call('other', 'echo', <String, Object?>{'fake': crashOnce()}),
      ).isA<SourceSuccess<Map<String, Object?>>>();
      check(port.openSessions).equals(0);
      check(bridge.openSessionIds).isEmpty();

      final Map<String, Object?> late = await reverse(s, 'pkg', 'host.browser.load', <String, Object?>{
        'session': session,
        'url': 'https://example.org/',
      });
      check((late['reverseError']! as Map<String, Object?>)['code']).equals(CancelledFailure.wireCode);
    });

    test('closing the supervisor closes its browser sessions', () async {
      final port = FakeBrowserPort();
      final WorkerSupervisor s = bridged(bridgeFor(port));
      await open(s, 'pkg');
      await open(s, 'pkg');
      check(port.openSessions).equals(2);
      await s.close();
      check(port.openSessions).equals(0);
    });

    test('a failed session closes its browser sessions', () async {
      final port = FakeBrowserPort();
      final WorkerSupervisor s = bridged(bridgeFor(port));
      await open(s, 'pkg');
      final SourceOutcome<Map<String, Object?>> broken = await s.call('pkg', 'echo', <String, Object?>{
        'fake': <String, Object?>{'stdoutGarbage': true},
      });
      check(broken.failureOrNull).isA<ProtocolViolationFailure>();
      await _eventually(() => port.openSessions == 0);
    });

    test('an open that completes after its generation was fenced is closed, never leaked', () async {
      final port = _GatedBrowserPort(FakeBrowserPort());
      final BrowserReverseBridge bridge = bridgeFor(port);
      final WorkerSupervisor s = bridged(bridge);
      final Future<SourceOutcome<Map<String, Object?>>> pending = s.call('a', 'echo', <String, Object?>{
        'fake': <String, Object?>{
          'reverse': <String, Object?>{
            'op': 'host.browser.open',
            'payload': <String, Object?>{'sourceId': '1'},
          },
        },
      });
      await _eventually(() => port.requested.length == 1);
      // Restart from another package while generation 1's open is pending;
      // the interrupted call is re-queued and opens again in generation 2.
      final Future<SourceOutcome<Map<String, Object?>>> crash = s.call('b', 'echo', <String, Object?>{
        'fake': crashOnce(),
      });
      await _eventually(() => port.requested.length == 2);
      check(port.requested).deepEquals(<int>[1, 2]);
      port.gate.complete();

      final reply = (await pending).valueOrNull!['reverse']! as Map<String, Object?>;
      check(await crash).isA<SourceSuccess<Map<String, Object?>>>();
      await _eventually(() => port.inner.openSessions == 1);
      final BrowserSession current = port.opened.singleWhere((BrowserSession x) => x.generation == 2);
      check(port.opened.map((BrowserSession x) => x.generation).toSet()).deepEquals(<int>{1, 2});
      check(reply['session']).equals(current.id);
      check(bridge.openSessionIds).deepEquals(<String>[current.id]);
    });

    test('a session the bridge closes itself reports storage deletion it could not confirm', () async {
      final store = FakeBrowserStore();
      final port = FakeBrowserPort(store: store);
      final lines = <String>[];
      final bridge = BrowserReverseBridge(
        port: port,
        interactionTimeout: const Duration(seconds: 1),
        resolveSource: identityFor,
        onLog: lines.add,
      );
      final SourceOutcome<Map<String, Object?>> opened = await bridge.handle(
        ReverseRequest(
          op: 'host.browser.open',
          payload: const <String, Object?>{'sourceId': '1'},
          packageId: 'p',
          generation: 1,
          cancel: CancellationToken.none,
        ),
      );
      check(opened.isSuccess).isTrue();
      store.failDeletes = true;
      await bridge.fence(2);
      check(bridge.openSessionIds).isEmpty();
      check(lines.single)
        ..contains('generation 1 fenced')
        ..contains('BrowserCapabilityUnavailable');
    });

    test('a closed bridge refuses requests and a malformed request is a protocol violation', () async {
      final port = FakeBrowserPort();
      final BrowserReverseBridge bridge = bridgeFor(port);
      ReverseRequest request(String op, Map<String, Object?> payload) => ReverseRequest(
        op: op,
        payload: payload,
        packageId: 'p',
        generation: 1,
        cancel: CancellationToken.none,
      );
      check(
        (await bridge.handle(request('host.browser.load', <String, Object?>{'session': 's'}))).failureOrNull,
      ).isA<ProtocolViolationFailure>();
      check(
        (await bridge.handle(request('host.browser.open', <String, Object?>{'sourceId': '1'}))).isSuccess,
      ).isTrue();
      await bridge.close();
      check(port.openSessions).equals(0);
      check(
        (await bridge.handle(request('host.browser.open', <String, Object?>{'sourceId': '1'}))).failureOrNull,
      ).isA<CancelledFailure>();
      check(port.openSessions).equals(0);
    });

    test('replace tier end to end: a 1.2 worker answers a held request while its evaluate is in flight', () async {
      final Uri page = Uri.parse('https://site.test/page');
      var networkCalls = 0;
      final port = FakeBrowserPort(
        pages: (Uri url) => url == page ? const FakeWebPage(html: '<title>page</title>') : null,
        requests: (BrowserRequest r) {
          networkCalls++;
          return const FakeWebPage(html: 'from network');
        },
      );
      ConversionRuntimeScope scopeWith(Duration? replacementTimeout) => ConversionRuntimeScope(
        workers: <WorkerKind, WorkerSpec>{
          WorkerKind.jvm: fakeWorkerSpec(workerExe, arguments: <String>['--minor=2', '--respond-requests']),
        },
        limits: testLimits(),
        launcher: launcher.call,
        browserPort: port,
        resolveBrowserSource: (WorkerKind kind, String? pkg, String id) => identityFor(pkg, id),
        browserReplacementTimeout: replacementTimeout,
      );

      // Without a configured bound the scope refuses the replace tier.
      final ConversionRuntimeScope unbounded = scopeWith(null);
      final WorkerSupervisor plain = (await unbounded.worker(WorkerKind.jvm)).valueOrNull!;
      final String s0 = await open(plain, 'pkg');
      final Map<String, Object?> refused = await reverse(
        plain,
        'pkg',
        'host.browser.setRequestInterception',
        <String, Object?>{'session': s0, 'mode': 'replace'},
      );
      check((refused['reverseError']! as Map<String, Object?>)['code']).equals(CapabilityUnavailableFailure.wireCode);
      await unbounded.close();

      final ConversionRuntimeScope scope = scopeWith(const Duration(seconds: 10));
      addTearDown(scope.close);
      final WorkerSupervisor jvm = (await scope.worker(WorkerKind.jvm)).valueOrNull!;
      check(jvm.protocolMinor).equals(2);
      final String session = await open(jvm, 'pkg');
      for (final (String op, Map<String, Object?> payload) in <(String, Map<String, Object?>)>[
        ('host.browser.load', <String, Object?>{'session': session, 'url': '$page'}),
        ('host.browser.setMessageHandler', <String, Object?>{'session': session, 'name': 'out', 'enabled': true}),
        ('host.browser.setRequestInterception', <String, Object?>{'session': session, 'mode': 'replace'}),
      ]) {
        check((await reverse(jvm, 'pkg', op, payload))['reverseError']).isNull();
      }
      final Map<String, Object?> evaluated = await reverse(jvm, 'pkg', 'host.browser.evaluate', <String, Object?>{
        'session': session,
        'script': BrowserContractScripts.fetchAndPost('out', Uri.parse('https://site.test/api'), method: 'POST'),
      });
      check(evaluated['reverseError']).isNull();
      // The worker's replacement was served: the request never reached the
      // network (a timed-out hold would have proceeded to it).
      check(networkCalls).equals(0);
      check(scope.bridges[WorkerKind.jvm]!.heldRequests).equals(0);
    });

    test('the conversion scope fences each worker separately and closes every session when it closes', () async {
      final port = FakeBrowserPort();
      final scope = ConversionRuntimeScope(
        workers: <WorkerKind, WorkerSpec>{
          WorkerKind.jvm: fakeWorkerSpec(workerExe, label: 'jvm'),
          WorkerKind.paperback: fakeWorkerSpec(workerExe, label: 'paperback'),
        },
        limits: testLimits(),
        launcher: launcher.call,
        browserPort: port,
        resolveBrowserSource: (WorkerKind kind, String? pkg, String id) => identityFor(pkg, id),
      );
      final WorkerSupervisor jvm = (await scope.worker(WorkerKind.jvm)).valueOrNull!;
      final WorkerSupervisor paperback = (await scope.worker(WorkerKind.paperback)).valueOrNull!;
      await open(jvm, 'tachi.pkg');
      await open(paperback, 'pb.pkg');
      check(port.openSessions).equals(2);

      // Both workers are at generation 1; restarting the JVM worker must not
      // close the Paperback worker's session.
      await jvm.call('other', 'echo', <String, Object?>{'fake': crashOnce()});
      check(jvm.generation).equals(2);
      check(port.openSessions).equals(1);
      check(scope.bridges[WorkerKind.jvm]!.openSessionIds).isEmpty();
      check(scope.bridges[WorkerKind.paperback]!.openSessionIds).length.equals(1);

      await scope.close();
      check(port.openSessions).equals(0);
      check(launcher.allExited).isTrue();
      final SourceOutcome<Map<String, Object?>> late = await scope.bridges[WorkerKind.paperback]!.handle(
        ReverseRequest(
          op: 'host.browser.open',
          payload: const <String, Object?>{'sourceId': '42'},
          packageId: 'pb.pkg',
          generation: paperback.generation,
          cancel: CancellationToken.none,
        ),
      );
      check(late.failureOrNull).isA<CancelledFailure>();
      check(port.openSessions).equals(0);
    });
  });

  group('protocol 1.1', () {
    const signer = '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2';
    final trust = ArtifactTrustAnchor(signerFingerprints: const <String>[signer]);
    final String tachiLimits = jsonEncode(<String, Object?>{
      'poolSize': 3,
      'operationDeadlineMs': 7000,
      'cancelGraceMs': 900,
      'interactionTimeoutMs': 60000,
      'shutdownGraceMs': 1500,
    });
    final String tachiSizing = jsonEncode(<String, Object?>{
      'rule': <String, Object?>{'source': 'docs/validation/source-runners/desktop/bench.md'},
      'inputs': <String, Object?>{'cores': 8, 'maxHeapMiB': 1024},
      'derived': <String, Object?>{'poolSize': 3},
      'overridden': <String>[],
    });

    test('negotiates minor 1 and records worker limits and sizing', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--limits=$tachiLimits', '--sizing=$tachiSizing']);
      final HandshakeResponse hello = (await s.start()).valueOrNull!;
      check(hello.protocolMinor).equals(1);
      check(s.protocolMinor).equals(1);
      check(hello.limits!.poolSize).equals(3);
      check(hello.sizing!.inputs['cores']).equals(8);
      // Fixed caller limits are never replaced by reported ones.
      check(s.limits!.maxConcurrentPackages).equals(testLimits().maxConcurrentPackages);
    });

    test('a 1.0 worker (no protocolMinor) is accepted as minor 0', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--omit-minor']);
      check((await s.start()).valueOrNull!.protocolMinor).equals(0);
      check(await s.loadPackage(await package('plain'))).isA<SourceSuccess<PackageLoadResponse>>();
    });

    test('a worker that owns a higher minor replies with the offered one', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--minor=7']);
      check((await s.start()).valueOrNull!.protocolMinor).equals(protocolMinorVersion);
    });

    test('reverse requests carry the negotiated minor, so 1.2 browser operations are gated per worker', () async {
      for (final (List<String> args, int minor) in <(List<String>, int)>[
        (<String>['--minor=2'], 2),
        (<String>[], 1),
      ]) {
        final seen = <int>[];
        final WorkerSupervisor s = supervisor(
          arguments: args,
          onReverseRequest: (ReverseRequest r) async {
            seen.add(r.protocolMinor);
            return const SourceSuccess<Map<String, Object?>>(<String, Object?>{});
          },
        );
        check((await s.start()).valueOrNull!.protocolMinor).equals(minor);
        await s.call('pkg', 'echo', <String, Object?>{
          'fake': <String, Object?>{
            'reverse': <String, Object?>{'op': 'host.browser.evaluate'},
          },
        });
        check(seen).deepEquals(<int>[minor]);
        await s.close();
      }
    });

    test('a worker that answers with a higher minor than offered fails the session', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--force-minor=${protocolMinorVersion + 1}']);
      check(
        (await s.start()).failureOrNull,
      ).isA<ProtocolViolationFailure>().has((f) => f.message, 'message').contains('1.${protocolMinorVersion + 1}');
      check(s.state).equals(WorkerState.failed);
    });

    test('adopts worker-reported limits when the caller opts in', () async {
      final WorkerSupervisor s = supervisor(
        arguments: <String>['--limits=$tachiLimits'],
        limits: const AdoptWorkerLimits(handshakeDeadline: Duration(seconds: 10)),
      );
      check(s.limits).isNull();
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      final SupervisorLimits limits = s.limits!;
      check(limits.maxConcurrentPackages).equals(3);
      check(limits.operationDeadline).equals(const Duration(seconds: 7));
      check(limits.cancelGrace).equals(const Duration(milliseconds: 900));
      check(limits.interactionTimeout).equals(const Duration(minutes: 1));
      check(limits.shutdownGrace).equals(const Duration(milliseconds: 1500));
      check(await s.loadPackage(await package('adopted'))).isA<SourceSuccess<PackageLoadResponse>>();
    });

    test('caller-supplied limits take precedence over worker-reported ones', () async {
      final WorkerSupervisor s = supervisor(
        arguments: <String>['--limits=$tachiLimits'],
        limits: const AdoptWorkerLimits(
          handshakeDeadline: Duration(seconds: 10),
          maxConcurrentPackages: 1,
          cancelGrace: Duration(milliseconds: 250),
        ),
      );
      await s.start();
      check(s.limits!.maxConcurrentPackages).equals(1);
      check(s.limits!.cancelGrace).equals(const Duration(milliseconds: 250));
      check(s.limits!.operationDeadline).equals(const Duration(seconds: 7));
    });

    test('a limit neither side supplies fails the start; nothing is invented', () async {
      final WorkerSupervisor s = supervisor(
        arguments: <String>[
          '--limits=${jsonEncode(<String, Object?>{'poolSize': 2, 'memoryLimitBytes': 1024})}',
        ],
        limits: const AdoptWorkerLimits(handshakeDeadline: Duration(seconds: 10), cancelGrace: Duration(seconds: 1)),
      );
      final SourceFailure? failure = (await s.start()).failureOrNull;
      check(failure).isA<RuntimeUnavailableFailure>().has((f) => f.message, 'message')
        ..contains('operationDeadlineMs')
        ..contains('interactionTimeoutMs')
        ..contains('shutdownGraceMs')
        ..not((Subject<String> it) => it.contains('poolSize'))
        ..not((Subject<String> it) => it.contains('cancelGraceMs'));
      check(s.state).equals(WorkerState.failed);
    });

    test('a worker reporting no limits cannot start under adoption without caller values', () async {
      final WorkerSupervisor s = supervisor(
        limits: const AdoptWorkerLimits(handshakeDeadline: Duration(seconds: 10)),
      );
      check((await s.start()).failureOrNull).isA<RuntimeUnavailableFailure>();
    });

    test('AdoptWorkerLimits resolves each limit from the caller first', () {
      final reported = WorkerReportedLimits(
        poolSize: 4,
        operationDeadline: const Duration(seconds: 3),
        cancelGrace: const Duration(seconds: 1),
        interactionTimeout: const Duration(seconds: 30),
        shutdownGrace: const Duration(seconds: 2),
      );
      const policy = AdoptWorkerLimits(
        handshakeDeadline: Duration(seconds: 5),
        operationDeadline: Duration(seconds: 9),
      );
      final SupervisorLimits resolved = policy.resolve(reported);
      check(resolved.operationDeadline).equals(const Duration(seconds: 9));
      check(resolved.maxConcurrentPackages).equals(4);
      check(policy.missing(null)).length.equals(4);
      check(() => policy.resolve(null)).throws<ArgumentError>();
    });

    test('string-set and source-scoped settings reach a 1.1 worker', () async {
      final WorkerSupervisor s = supervisor();
      final settings = SettingsSnapshot(
        values: const <String, Object>{
          'genres': <String>['b', 'a'],
        },
        sources: <String, SourceScopedSettings>{
          '9223372036854775807': SourceScopedSettings(
            values: const <String, Object>{'lang': 'ja'},
            secrets: const <String, String>{'password': 'scoped-SECRET'},
          ),
        },
      );
      check(await s.loadPackage(await package('multi', settings: settings))).isA<SourceSuccess<PackageLoadResponse>>();
      final sent = (await stats(s))['settings']! as Map<String, Object?>;
      final multi = sent['multi']! as Map<String, Object?>;
      check((multi['values']! as Map<String, Object?>)['genres']).isA<List<Object?>>().deepEquals(<String>['a', 'b']);
      check(
        ((multi['sources']! as Map<String, Object?>)['9223372036854775807']! as Map<String, Object?>)['secrets'],
      ).isA<Map<String, Object?>>().deepEquals(<String, Object?>{'password': 'scoped-SECRET'});
      check(s.redactor.redact('leak scoped-SECRET')).not((Subject<String> it) => it.contains('scoped-SECRET'));
    });

    test('a 1.0 worker is refused string-set and source-scoped settings before anything is sent', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--omit-minor']);
      final scoped = SettingsSnapshot(
        sources: <String, SourceScopedSettings>{
          '1': SourceScopedSettings(values: const <String, Object>{'lang': 'ja'}),
        },
      );
      check((await s.loadPackage(await package('scoped', settings: scoped))).failureOrNull)
          .isA<UnsupportedApiFailure>();
      check(await s.loadPackage(await package('plain'))).isA<SourceSuccess<PackageLoadResponse>>();
      final withSet = SettingsSnapshot(
        values: const <String, Object>{
          'genres': <String>['a'],
        },
      );
      check((await s.updateSettings('plain', withSet)).failureOrNull).isA<UnsupportedApiFailure>();
      check((await stats(s))['loaded']! as Map<String, Object?>).not((it) => it.containsKey('scoped'));
    });

    test('prepareArtifact sends the stored trust anchor without a loaded package and admits the output', () async {
      final WorkerSupervisor s = supervisor();
      final WorkerPackage input = await package('eu.kanade.prepare');
      final SourceOutcome<ArtifactLease> prepared = await s.prepareArtifact(
        packageId: 'eu.kanade.prepare',
        input: input.artifact,
        trust: trust,
        cache: cache,
        hostCompatibility: 'host-1',
      );
      final ArtifactLease lease = prepared.valueOrNull!;
      check(lease.binding.sha256).equals(input.artifact.binding.sha256);
      check(lease.binding.kind).equals('jar');
      check(await lease.readVerified()).deepEquals(await input.artifact.readVerified());
      check(
        cache.leaseCount(
          lease.binding,
          const ArtifactProfile(producer: 'fake-prepare', converterVersion: 'fake.1', hostCompatibility: 'host-1'),
        ),
      ).equals(1);
      final prepareCalls = (await stats(s))['prepared']! as List<Object?>;
      check(prepareCalls).length.equals(1);
      final call = prepareCalls.single! as Map<String, Object?>;
      check(call['loaded']).equals(false);
      check(call['trustedSigners']).isA<List<Object?>>().deepEquals(<String>[signer]);
      check(s.packageIds).isEmpty();
      check(Directory(p.join(cache.root.path, 'prepare')).listSync()).isEmpty();
    });

    test('prepareArtifact rejects an output whose digest differs from the report', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--prepare-lie']);
      final WorkerPackage input = await package('eu.kanade.lie');
      final SourceFailure? failure = (await s.prepareArtifact(
        packageId: 'eu.kanade.lie',
        input: input.artifact,
        trust: trust,
        cache: cache,
        hostCompatibility: 'host-1',
      )).failureOrNull;
      check(failure).isA<ArtifactIncompatibleFailure>().has((f) => f.message, 'message').contains('does not match');
      check(Directory(p.join(cache.root.path, 'prepare')).listSync()).isEmpty();
    });

    test('prepareArtifact refuses an empty trust anchor and a 1.0 worker without sending', () async {
      final WorkerSupervisor s = supervisor(arguments: <String>['--omit-minor']);
      final WorkerPackage input = await package('eu.kanade.refused');
      check(
        (await s.prepareArtifact(
          packageId: 'eu.kanade.refused',
          input: input.artifact,
          trust: ArtifactTrustAnchor(signerFingerprints: const <String>[]),
          cache: cache,
          hostCompatibility: 'host-1',
        )).failureOrNull,
      ).isA<ArtifactIncompatibleFailure>();
      check(
        (await s.prepareArtifact(
          packageId: 'eu.kanade.refused',
          input: input.artifact,
          trust: trust,
          cache: cache,
          hostCompatibility: 'host-1',
        )).failureOrNull,
      ).isA<UnsupportedApiFailure>();
      check((await stats(s))['prepared']! as List<Object?>).isEmpty();
    });

    test('the bridge bounds host.browser.show with the supervisor interaction timeout', () async {
      final port = FakeBrowserPort();
      final bridge = BrowserReverseBridge(
        port: port,
        resolveSource: (String? pkg, String sourceId) => SourceIdentity(
          ecosystem: 'test',
          packageId: pkg!,
          sourceId: sourceId,
          artifact: const ArtifactBinding(sha256: 'ab', kind: 'test', version: '1'),
        ),
      );
      ReverseRequest request(String op, Map<String, Object?> payload, {Duration? interactionTimeout}) => ReverseRequest(
        op: op,
        payload: payload,
        packageId: 'pkg',
        generation: 1,
        cancel: CancellationToken.none,
        interactionTimeout: interactionTimeout,
      );
      final session =
          (await bridge.handle(
                request('host.browser.open', const <String, Object?>{'sourceId': 's'}),
              )).valueOrNull!['session']!
              as String;
      // Without any bound the show is refused rather than unbounded.
      check(
        (await bridge.handle(request('host.browser.show', <String, Object?>{'session': session}))).failureOrNull,
      ).isA<CapabilityUnavailableFailure>();
      // With the supervisor's bound the platform answer comes through.
      check(
        (await bridge.handle(
          request('host.browser.show', <String, Object?>{
            'session': session,
          }, interactionTimeout: const Duration(seconds: 1)),
        )).failureOrNull,
      ).isA<InteractionRequiredFailure>();
      await bridge.close();
    });
  });
}

Future<void> _eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) throw StateError('Condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Holds every `openSession` until [gate] completes, recording the requested
/// generations and the sessions opened.
final class _GatedBrowserPort implements BrowserPort {
  _GatedBrowserPort(this.inner);

  final FakeBrowserPort inner;
  final Completer<void> gate = Completer<void>();
  final List<int> requested = <int>[];
  final List<BrowserSession> opened = <BrowserSession>[];

  @override
  Future<BrowserOutcome<void>> wipeAllSourceData() => inner.wipeAllSourceData();

  @override
  Future<void> fence(int generation) => inner.fence(generation);

  @override
  Future<BrowserOutcome<BrowserSession>> openSession(BrowserSessionRequest request, {CancellationToken? cancel}) async {
    requested.add(request.generation);
    await gate.future;
    final BrowserOutcome<BrowserSession> outcome = await inner.openSession(request);
    if (outcome case BrowserCompleted<BrowserSession>(:final BrowserSession value)) opened.add(value);
    return outcome;
  }
}

final class _LoadFailed implements Exception {
  const _LoadFailed(this.message);

  final String message;
}
