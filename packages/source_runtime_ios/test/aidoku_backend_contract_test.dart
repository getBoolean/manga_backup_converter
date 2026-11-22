// U18: the iOS Aidoku backend admits the injected desktop adapter, refuses
// it with a typed failure when a framework of the Aidoku host does not load,
// and gates its sessions on app backgrounding (KTD12). Host-only: imports
// the backend file directly so no JVM binding loads. The real adapter runs
// on the simulator in integration_test/source_runners_ios_aidoku_test.dart.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart' show TestWidgetsFlutterBinding, test, testWidgets, group, setUp;
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_ios/src/aidoku_backend.dart';

const SourceIdentity _identity = SourceIdentity(
  ecosystem: 'aidoku',
  packageId: 'multi.fake',
  sourceId: 'multi.fake',
  artifact: ArtifactBinding(sha256: 'fake', kind: 'aix', version: '1'),
);

/// A session whose calls stay pending until the test answers them.
final class _Session implements SourceSession {
  final List<(Completer<SourceOutcome<SearchPage>>, CancellationToken?)> searches =
      <(Completer<SourceOutcome<SearchPage>>, CancellationToken?)>[];
  bool closed = false;

  @override
  SourceIdentity get identity => _identity;

  @override
  String get displayName => 'Fake';

  @override
  final SourceCapabilities capabilities = SourceCapabilities(
    operations: const <SourceOperation>{SourceOperation.search},
  );

  @override
  String get settingsRevision => 'r1';

  @override
  Future<SourceOutcome<SearchPage>> search(SearchRequest request, {CancellationToken? cancel}) {
    final completer = Completer<SourceOutcome<SearchPage>>();
    searches.add((completer, cancel));
    // Like the desktop adapter: cancellation answers the caller at once.
    if (cancel == null) return completer.future;
    return Future.any(<Future<SourceOutcome<SearchPage>>>[
      completer.future,
      cancel.whenCancelled.then((_) => SourceFailed<SearchPage>(CancelledFailure(cancel.reason ?? 'cancelled'))),
    ]);
  }

  @override
  Future<SourceOutcome<MangaSnapshot>> fetchManga(NativeMangaRef ref, {CancellationToken? cancel}) async =>
      SourceSuccess<MangaSnapshot>(
        MangaSnapshot(
          ref: ref,
          metadata: const MangaMetadata(title: 'T'),
          chapters: const <NativeChapter>[],
        ),
      );

  @override
  Future<void> close() async => closed = true;
}

final class _Package implements SourcePackage {
  _Package(this.session);
  final _Session session;
  bool closed = false;

  @override
  String get packageId => 'multi.fake';

  @override
  List<SourceSession> get sessions => <SourceSession>[session];

  @override
  Future<void> close() async => closed = true;
}

final class _Artifact implements VerifiedArtifact {
  @override
  ArtifactBinding get binding => _identity.artifact;

  @override
  Future<Uint8List> readVerified() async => Uint8List(0);
}

final class _Provider implements SourceProvider {
  _Provider(this.ecosystem);

  @override
  final String ecosystem;

  final _Session session = _Session();
  final List<_Package> opened = <_Package>[];

  /// When set, `openPackage` waits for it.
  Completer<void>? openGate;

  @override
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async {
    await openGate?.future;
    final package = _Package(session);
    opened.add(package);
    return SourceSuccess<SourcePackage>(package);
  }
}

const SourceSuccess<SearchPage> _hits = SourceSuccess<SearchPage>(SearchPage(hits: <SearchHit>[]));

IosAidokuBackend _admit(_Provider provider) => IosAidokuBackend.register(provider, loadLibrary: (_) {}).valueOrNull!;

void main() {
  group('registration', () {
    test('both frameworks are checked, wasm3 first, each with its symbol', () {
      final loaded = <AidokuNativeLibrary>[];
      IosAidokuBackend.register(_Provider('aidoku'), loadLibrary: loaded.add);
      check(loaded).deepEquals(<AidokuNativeLibrary>[
        (framework: 'wasm3.framework/wasm3', symbol: 'm3_NewEnvironment'),
        (framework: 'SwiftSoupWrapper.framework/SwiftSoupWrapper', symbol: 'swiftsoup_init'),
      ]);
    });

    test('keeps the injected provider itself and offers its sessions', () async {
      final provider = _Provider('aidoku');
      final IosAidokuBackend backend = _admit(provider);
      check(backend.aidoku).identicalTo(provider);
      check(backend.provider.ecosystem).equals('aidoku');
      final SourcePackage package = (await backend.provider.openPackage(_Artifact(), SettingsSnapshot())).valueOrNull!;
      final SourceSession session = package.sessions.single;
      check(session.identity).equals(_identity);
      check(session.settingsRevision).equals('r1');
      check(session.displayName).equals('Fake');
      const ref = NativeMangaRef(source: _identity, mangaId: 'm', settingsRevision: 'r1');
      check((await session.fetchManga(ref)).valueOrNull).isNotNull();
      await package.close();
      check(provider.opened.single.closed).isTrue();
    });

    for (final AidokuNativeLibrary missing in aidokuNativeLibraries) {
      test('a framework that does not load (${missing.framework}) is a typed runtime failure', () {
        final SourceOutcome<IosAidokuBackend> outcome = IosAidokuBackend.register(
          _Provider('aidoku'),
          loadLibrary: (AidokuNativeLibrary l) {
            if (l == missing) throw ArgumentError('dlopen failed: image not found');
          },
        );
        check(outcome)
            .isA<SourceFailed<IosAidokuBackend>>()
            .has((SourceFailed<IosAidokuBackend> f) => f.failure, 'failure')
            .isA<RuntimeUnavailableFailure>()
            .has((RuntimeUnavailableFailure f) => f.message, 'message')
            .contains(missing.framework);
      });
    }

    test('a provider for another ecosystem is refused before loading anything', () {
      final loaded = <AidokuNativeLibrary>[];
      final SourceOutcome<IosAidokuBackend> outcome = IosAidokuBackend.register(
        _Provider('tachi'),
        loadLibrary: loaded.add,
      );
      check(loaded).isEmpty();
      check(outcome.failureOrNull).isA<RuntimeUnavailableFailure>();
    });

    test('outside an iOS app bundle the real loader refuses', () {
      // The host VM has no Runner.app/Frameworks: the default loader must
      // fail visibly, not succeed.
      check(IosAidokuBackend.register(_Provider('aidoku')).failureOrNull).isA<RuntimeUnavailableFailure>();
    });
  });

  group('backgrounding (KTD12)', () {
    late _Provider provider;
    late IosAidokuBackend backend;
    late SourceSession session;

    setUp(() async {
      provider = _Provider('aidoku');
      backend = _admit(provider);
      session = (await backend.provider.openPackage(_Artifact(), SettingsSnapshot())).valueOrNull!.sessions.single;
    });

    test('pending calls are cancelled once and new calls are refused', () async {
      final Future<SourceOutcome<SearchPage>> a = session.search(const SearchRequest(query: 'a'));
      final Future<SourceOutcome<SearchPage>> b = session.search(const SearchRequest(query: 'b'));
      await Future<void>.delayed(Duration.zero);
      check(backend.pendingCalls).equals(2);

      backend.setBackgrounded(true);
      for (final o in <SourceOutcome<SearchPage>>[await a, await b]) {
        check(o.failureOrNull)
            .isA<CancelledFailure>()
            .has((CancelledFailure f) => f.message, 'message')
            .equals(appBackgroundedReason);
      }
      check(backend.pendingCalls).equals(0);

      final int before = provider.session.searches.length;
      final SourceOutcome<SearchPage> refused = await session.search(const SearchRequest(query: 'c'));
      check(refused.failureOrNull).isA<CancelledFailure>();
      check(provider.session.searches.length).equals(before);
      check(
        (await backend.provider.openPackage(_Artifact(), SettingsSnapshot())).failureOrNull,
      ).isA<CancelledFailure>();
    });

    test('the session is usable again in the foreground', () async {
      backend
        ..setBackgrounded(true)
        ..setBackgrounded(false);
      final Future<SourceOutcome<SearchPage>> pending = session.search(const SearchRequest(query: 'a'));
      await Future<void>.delayed(Duration.zero);
      provider.session.searches.last.$1.complete(_hits);
      check((await pending).isSuccess).isTrue();
    });

    test('a result that arrives after the transition is fenced', () async {
      final Future<SourceOutcome<SearchPage>> pending = session.search(const SearchRequest(query: 'a'));
      await Future<void>.delayed(Duration.zero);
      final (Completer<SourceOutcome<SearchPage>> inner, CancellationToken? token) = provider.session.searches.last;
      backend.setBackgrounded(true);
      check(token!.isCancelled).isTrue();
      inner.complete(_hits); // late: the caller has already been answered
      check((await pending).failureOrNull).isA<CancelledFailure>();
    });

    test('a caller cancellation still reaches the session', () async {
      final cancel = CancellationSource();
      final Future<SourceOutcome<SearchPage>> pending = session.search(
        const SearchRequest(query: 'a'),
        cancel: cancel.token,
      );
      await Future<void>.delayed(Duration.zero);
      cancel.cancel('user');
      check((await pending).failureOrNull)
          .isA<CancelledFailure>()
          .has((CancelledFailure f) => f.message, 'message')
          .equals('user');
      check(provider.session.searches.last.$2!.reason).equals('user');
      check(backend.isBackgrounded).isFalse();
    });

    test('a package that opens after backgrounding is closed, not leaked', () async {
      provider.openGate = Completer<void>();
      final Future<SourceOutcome<SourcePackage>> opening = backend.provider.openPackage(
        _Artifact(),
        SettingsSnapshot(),
      );
      await Future<void>.delayed(Duration.zero);
      backend.setBackgrounded(true);
      provider.openGate!.complete();
      check((await opening).failureOrNull).isA<CancelledFailure>();
      await Future<void>.delayed(Duration.zero);
      check(provider.opened.last.closed).isTrue();
    });
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bindToAppLifecycle follows hidden/paused and resumed', (tester) async {
    final IosAidokuBackend backend = _admit(_Provider('aidoku'))..bindToAppLifecycle();
    try {
      for (final s in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      check(backend.isBackgrounded).isTrue();
      for (final s in <AppLifecycleState>[
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      check(backend.isBackgrounded).isFalse();
    } finally {
      backend.dispose();
    }
  });
}
