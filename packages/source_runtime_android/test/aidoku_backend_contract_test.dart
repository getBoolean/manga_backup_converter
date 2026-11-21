// U13: the Android Aidoku backend admits the injected desktop adapter
// unchanged, and refuses it with a typed failure when a native library of
// the Aidoku host does not load. Host-only: imports the backend file
// directly so no JNI binding loads. The real adapter runs on the device in
// integration_test/source_runners_android_test.dart.

// ignore_for_file: depend_on_referenced_packages, the pubspec line is reported in U13's handoff.

import 'package:checks/checks.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_android/src/aidoku_backend.dart';
import 'package:test/scaffolding.dart';

final class _Provider implements SourceProvider {
  _Provider(this.ecosystem);

  @override
  final String ecosystem;

  @override
  Future<SourceOutcome<List<PackageListing>>> discoverPackages(Uri repository, {CancellationToken? cancel}) async =>
      const SourceSuccess<List<PackageListing>>(<PackageListing>[]);

  @override
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async => const SourceFailed<SourcePackage>(ArtifactIncompatibleFailure('fake'));
}

void main() {
  test('both native libraries are checked, wasm3 first', () {
    final loaded = <String>[];
    AndroidAidokuBackend.register(_Provider('aidoku'), loadLibrary: loaded.add);
    check(loaded).deepEquals(<String>['libwasm3.so', 'libscraper.so']);
  });

  test('admits the injected provider itself, not a wrapper', () {
    final provider = _Provider('aidoku');
    final SourceOutcome<AndroidAidokuBackend> outcome = AndroidAidokuBackend.register(
      provider,
      loadLibrary: (_) {},
    );
    check(outcome.valueOrNull)
        .isNotNull()
        .has((AndroidAidokuBackend b) => b.provider, 'provider')
        .identicalTo(provider);
  });

  for (final String missing in aidokuNativeLibraries) {
    test('a library that does not load ($missing) is a typed runtime failure', () {
      final SourceOutcome<AndroidAidokuBackend> outcome = AndroidAidokuBackend.register(
        _Provider('aidoku'),
        loadLibrary: (String name) {
          if (name == missing) throw ArgumentError('dlopen failed: library "$name" not found');
        },
      );
      check(outcome)
          .isA<SourceFailed<AndroidAidokuBackend>>()
          .has((SourceFailed<AndroidAidokuBackend> f) => f.failure, 'failure')
          .isA<RuntimeUnavailableFailure>()
          .has((RuntimeUnavailableFailure f) => f.message, 'message')
          .contains(missing);
    });
  }

  test('a provider for another ecosystem is refused before loading anything', () {
    final loaded = <String>[];
    final SourceOutcome<AndroidAidokuBackend> outcome = AndroidAidokuBackend.register(
      _Provider('tachi'),
      loadLibrary: loaded.add,
    );
    check(loaded).isEmpty();
    check(outcome)
        .isA<SourceFailed<AndroidAidokuBackend>>()
        .has((SourceFailed<AndroidAidokuBackend> f) => f.failure, 'failure')
        .isA<RuntimeUnavailableFailure>();
  });

  test('on a host without the Android libraries the real loader refuses', () {
    // Runs on the desktop VM, where libwasm3.so/libscraper.so do not resolve
    // by those names: the default loader must fail visibly, not succeed.
    final SourceOutcome<AndroidAidokuBackend> outcome = AndroidAidokuBackend.register(_Provider('aidoku'));
    check(outcome).isA<SourceFailed<AndroidAidokuBackend>>();
  }, testOn: 'windows || mac-os');
}
