// Host tests of the Android Paperback backend's admission (U12). The
// in-app worker-isolate contract itself (search/details/chapters of real
// 0.8 and 0.9 bundles, native deadline, memory limit, kill, deadline pause)
// is shared with U10 in
// packages/paperback_plugin_loader/test/in_app_backend_contract_test.dart
// and runs on the device from integration_test/android_u12_cases.dart.
@TestOn('vm')
library;

import 'package:checks/checks.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:source_runtime_android/source_runtime_android.dart';
import 'package:test/scaffolding.dart';

final class _Provider implements SourceProvider {
  _Provider(this.ecosystem);

  @override
  final String ecosystem;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('admits a Paperback provider once QuickJS loads, and hands back the same instance', () {
    final loaded = <String>[];
    final provider = _Provider('paperback');
    final SourceOutcome<AndroidPaperbackBackend> backend = AndroidPaperbackBackend.register(
      provider,
      loadLibrary: loaded.add,
    );
    check(loaded).deepEquals(<String>[paperbackNativeLibrary]);
    check(backend.valueOrNull!.provider).identicalTo(provider);
    check(backend.valueOrNull!.browser).isNull();
  });

  test('a QuickJS library that does not load fails registration by name', () {
    final SourceOutcome<AndroidPaperbackBackend> backend = AndroidPaperbackBackend.register(
      _Provider('paperback'),
      loadLibrary: (String name) => throw ArgumentError('dlopen failed: $name'),
    );
    check(backend)
        .isA<SourceFailed<AndroidPaperbackBackend>>()
        .has((SourceFailed<AndroidPaperbackBackend> f) => f.failure, 'failure')
        .isA<RuntimeUnavailableFailure>()
        .has((RuntimeUnavailableFailure f) => f.message, 'message')
        .contains(paperbackNativeLibrary);
  });

  test('a provider of another ecosystem is refused', () {
    check(
      AndroidPaperbackBackend.register(_Provider('tachi'), loadLibrary: (_) {}),
    ).isA<SourceFailed<AndroidPaperbackBackend>>();
  });
}
