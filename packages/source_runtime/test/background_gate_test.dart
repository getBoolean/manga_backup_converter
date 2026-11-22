// App-lifecycle gate (KTD12, KTD18): the provider decorator and the worker
// supervisor hook, against a fake provider and the fake-worker subprocess.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import 'support/fake_worker_launch.dart';

const _identity = SourceIdentity(
  ecosystem: 'fake',
  packageId: 'pkg',
  sourceId: 'src',
  artifact: ArtifactBinding(sha256: 'digest', kind: 'test', version: '1'),
);

/// A session whose calls wait for [release] unless cancelled first, like the
/// Aidoku adapter (which races its call against the token).
final class _HeldSession implements SourceSession {
  Completer<SourceOutcome<SearchPage>> release = Completer<SourceOutcome<SearchPage>>();
  bool honourCancel = true;
  int calls = 0;
  bool closed = false;

  @override
  SourceIdentity get identity => _identity;

  @override
  String get displayName => 'Held';

  @override
  SourceCapabilities get capabilities => SourceCapabilities(operations: SourceOperation.values.toSet());

  @override
  String get settingsRevision => 'r1';

  @override
  Future<SourceOutcome<SearchPage>> search(SearchRequest request, {CancellationToken? cancel}) {
    calls++;
    if (!honourCancel || cancel == null) return release.future;
    return Future.any(<Future<SourceOutcome<SearchPage>>>[
      release.future,
      cancel.whenCancelled.then((_) => SourceFailed<SearchPage>(CancelledFailure(cancel.reason ?? 'cancelled'))),
    ]);
  }

  @override
  Future<SourceOutcome<MangaSnapshot>> fetchManga(NativeMangaRef ref, {CancellationToken? cancel}) async =>
      const SourceFailed<MangaSnapshot>(SourceErrorFailure('unused'));

  @override
  Future<void> close() async => closed = true;
}

final class _Package implements SourcePackage {
  _Package(this.session);

  final _HeldSession session;
  bool closed = false;

  @override
  String get packageId => 'pkg';

  @override
  List<SourceSession> get sessions => <SourceSession>[session];

  @override
  Future<void> close() async => closed = true;
}

final class _Provider implements SourceProvider {
  final _HeldSession session = _HeldSession();
  Completer<void>? holdOpen;
  final List<_Package> opened = <_Package>[];

  @override
  String get ecosystem => 'fake';

  @override
  Future<SourceOutcome<List<PackageListing>>> discoverPackages(Uri repository, {CancellationToken? cancel}) async =>
      const SourceSuccess<List<PackageListing>>(<PackageListing>[]);

  @override
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async {
    await holdOpen?.future;
    final package = _Package(session);
    opened.add(package);
    return SourceSuccess<SourcePackage>(package);
  }
}

final class _Artifact implements VerifiedArtifact {
  @override
  ArtifactBinding get binding => _identity.artifact;

  @override
  Future<Uint8List> readVerified() async => Uint8List(0);
}

void main() {
  group('BackgroundGate provider', () {
    late _Provider inner;
    late BackgroundGate gate;
    late SourceSession session;

    setUp(() async {
      inner = _Provider();
      gate = BackgroundGate();
      final SourcePackage package =
          (await gate.provider(inner).openPackage(_Artifact(), SettingsSnapshot())).valueOrNull!;
      session = package.sessions.single;
    });

    const request = SearchRequest(query: 'q');

    test('an in-flight call answers app-backgrounded once, at the transition', () async {
      final Future<SourceOutcome<SearchPage>> pending = session.search(request);
      await Future<void>.delayed(Duration.zero);
      check(gate.pendingCalls).equals(1);
      gate.setBackgrounded(true);
      final SourceOutcome<SearchPage> outcome = await pending;
      check(outcome.failureOrNull)
          .isA<CancelledFailure>()
          .has((f) => f.message, 'message')
          .equals(appBackgroundedReason);
      check(gate.pendingCalls).equals(0);
    });

    test('new calls and package opens are refused while backgrounded, without reaching the runtime', () async {
      gate.setBackgrounded(true);
      check((await session.search(request)).failureOrNull)
          .isA<CancelledFailure>()
          .has((f) => f.message, 'message')
          .equals(appBackgroundedReason);
      check(
        (await gate.provider(inner).openPackage(_Artifact(), SettingsSnapshot())).failureOrNull,
      ).isA<CancelledFailure>();
      check(inner.session.calls).equals(0);
      check(inner.opened.length).equals(1);
    });

    test('a success that raced the transition is fenced', () async {
      inner.session.honourCancel = false;
      final Future<SourceOutcome<SearchPage>> pending = session.search(request);
      await Future<void>.delayed(Duration.zero);
      gate.setBackgrounded(true);
      inner.session.release.complete(const SourceSuccess<SearchPage>(SearchPage(hits: <SearchHit>[])));
      check((await pending).failureOrNull).isA<CancelledFailure>();
    });

    test('the foreground re-admits work on the same session', () async {
      gate
        ..setBackgrounded(true)
        ..setBackgrounded(false);
      inner.session.release.complete(const SourceSuccess<SearchPage>(SearchPage(hits: <SearchHit>[])));
      check(await session.search(request)).isA<SourceSuccess<SearchPage>>();
      check(gate.isBackgrounded).isFalse();
    });

    test('a package that opens after backgrounding is closed and reported cancelled', () async {
      inner.holdOpen = Completer<void>();
      final Future<SourceOutcome<SourcePackage>> opening = gate
          .provider(inner)
          .openPackage(
            _Artifact(),
            SettingsSnapshot(),
          );
      await Future<void>.delayed(Duration.zero);
      gate.setBackgrounded(true);
      inner.holdOpen!.complete();
      check((await opening).failureOrNull).isA<CancelledFailure>();
      check(inner.opened.last.closed).isTrue();
    });

    test('a caller cancellation keeps its own reason', () async {
      final cancel = CancellationSource();
      final Future<SourceOutcome<SearchPage>> pending = session.search(request, cancel: cancel.token);
      await Future<void>.delayed(Duration.zero);
      cancel.cancel('user');
      check((await pending).failureOrNull).isA<CancelledFailure>().has((f) => f.message, 'message').equals('user');
    });

    test('a non-interruptible call runs to completion once admitted', () async {
      final release = Completer<SourceOutcome<int>>();
      final Future<SourceOutcome<int>> pending = gate.run<int>(null, (_) => release.future, interruptible: false);
      gate.setBackgrounded(true);
      release.complete(const SourceSuccess<int>(1));
      check((await pending).valueOrNull).equals(1);
      check((await gate.run<int>(null, (_) async => const SourceSuccess<int>(2), interruptible: false)).failureOrNull)
          .isA<CancelledFailure>();
    });
  });

  group('WorkerSupervisor gate', () {
    late String workerExe;
    late RecordingLauncher launcher;
    late BackgroundGate gate;
    late WorkerSupervisor s;

    setUpAll(() async => workerExe = await compileFakeWorker());

    setUp(() {
      launcher = RecordingLauncher();
      gate = BackgroundGate();
      s = WorkerSupervisor(
        spec: fakeWorkerSpec(workerExe),
        limits: testLimits(),
        launcher: launcher.call,
        gate: gate,
      );
    });

    tearDown(() async {
      await s.close();
      check(await launcher.waitAllExited()).isTrue();
    });

    test('an in-flight search answers app-backgrounded at once and the worker stays', () async {
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      final int? pid = s.pid;
      final Future<SourceOutcome<Map<String, Object?>>> pending = s.call('pkg', 'search', <String, Object?>{
        'fake': <String, Object?>{'hangUntilCancel': true},
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final watch = Stopwatch()..start();
      gate.setBackgrounded(true);
      check((await pending).failureOrNull)
          .isA<CancelledFailure>()
          .has((f) => f.message, 'message')
          .equals(appBackgroundedReason);
      check(watch.elapsed).isLessThan(const Duration(seconds: 1));
      check((await s.call('pkg', 'details', const <String, Object?>{})).failureOrNull)
          .isA<CancelledFailure>()
          .has((f) => f.message, 'message')
          .equals(appBackgroundedReason);
      gate.setBackgrounded(false);
      check((await s.call('pkg', 'echo', <String, Object?>{'value': 'next'})).valueOrNull!['echo']).equals('next');
      check(s.pid).equals(pid);
      check(s.generation).equals(1);
    });

    test('loads finish once sent; new loads are refused; cleanup and other ops are never gated', () async {
      check(await s.start()).isA<SourceSuccess<HandshakeResponse>>();
      final Future<SourceOutcome<Map<String, Object?>>> loading = s.call('pkg', 'package.load', <String, Object?>{
        'fake': <String, Object?>{'delayMs': 200},
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.setBackgrounded(true);
      // The load reached the worker and was not cancelled.
      check((await loading).failureOrNull is CancelledFailure).isFalse();
      check((await s.call('pkg', 'package.load', const <String, Object?>{})).failureOrNull).isA<CancelledFailure>();
      check((await s.call('pkg', 'artifact.prepare', const <String, Object?>{})).failureOrNull).isA<CancelledFailure>();
      check((await s.call('pkg', 'dispose', const <String, Object?>{})).failureOrNull is CancelledFailure).isFalse();
      check((await s.call('pkg', 'echo', <String, Object?>{'value': 'x'})).valueOrNull!['echo']).equals('x');
    });

    test('a scope refuses to start a new worker while backgrounded', () async {
      final scope = ConversionRuntimeScope(
        workers: <WorkerKind, WorkerSpec>{WorkerKind.jvm: fakeWorkerSpec(workerExe)},
        limits: testLimits(),
        launcher: launcher.call,
        gate: gate,
      );
      gate.setBackgrounded(true);
      check((await scope.worker(WorkerKind.jvm)).failureOrNull).isA<CancelledFailure>();
      check(scope.supervisors).isEmpty();
      gate.setBackgrounded(false);
      final WorkerSupervisor started = (await scope.worker(WorkerKind.jvm)).valueOrNull!;
      check(started.gate).identicalTo(gate);
      await scope.close();
    });
  });
}
