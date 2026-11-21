// The WASM isolate boundary with hand-built modules (no fixture, no
// network): traps, isolate death, calls after dispose, the response-header
// round trip through the native shared-state slots, and rate limiting.
// integration_test/source_runners_android_test.dart runs the same cases on
// Android.
//
// Run: flutter test packages/aidoku_plugin_loader/test/wasm/isolate_failure_test.dart --reporter expanded
@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/aidoku_plugin_loader.dart';
import 'package:aidoku_plugin_loader/source_adapter.dart';
import 'package:aidoku_plugin_loader/testing.dart';
import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';
import 'package:wasm_runner/wasm_runner.dart';

/// A client that fails every request: these modules must not touch the net.
final http.Client _noNetwork = MockClient((http.Request r) async => throw StateError('unexpected request ${r.url}'));

final class _Artifact implements VerifiedArtifact {
  _Artifact(this.bytes);
  final Uint8List bytes;
  @override
  ArtifactBinding get binding => const ArtifactBinding(sha256: 'synthetic', kind: 'aix', version: '1');
  @override
  Future<Uint8List> readVerified() async => bytes;
}

const Duration _noHang = Duration(seconds: 20);

void main() {
  test('a trap in a source call is a typed source error and the plugin survives', () async {
    final AidokuPlugin plugin = await AidokuPlugin.fromAix(SyntheticAix.trapInSearch(), httpClient: _noNetwork);
    addTearDown(plugin.dispose);
    for (var i = 0; i < 2; i++) {
      await check(plugin.searchManga('x', 1).timeout(_noHang)).throws<WasmRuntimeException>(
        (Subject<WasmRuntimeException> e) =>
            e.has((WasmRuntimeException e) => e.message, 'message').contains('unreachable'),
      );
    }
  });

  test('a trap in start kills the isolate; calls fail instead of hanging', () async {
    final AidokuPlugin plugin = await AidokuPlugin.fromAix(SyntheticAix.trapInStart(), httpClient: _noNetwork);
    addTearDown(plugin.dispose);
    // Sent while the isolate is still starting, then dies.
    await check(plugin.searchManga('x', 1).timeout(_noHang)).throws<AidokuIsolateExitedException>(
      (Subject<AidokuIsolateExitedException> e) =>
          e.has((AidokuIsolateExitedException e) => e.error, 'error').isNotNull().contains('unreachable'),
    );
    // Once dead, every call fails at once.
    await check(plugin.getMangaDetails('k').timeout(_noHang)).throws<AidokuIsolateExitedException>();
  });

  test('calls after dispose fail instead of hanging', () async {
    final AidokuPlugin plugin = await AidokuPlugin.fromAix(SyntheticAix.trapInSearch(), httpClient: _noNetwork);
    plugin.dispose();
    await check(plugin.searchManga('x', 1).timeout(_noHang)).throws<AidokuIsolateExitedException>();
  });

  test('response headers reach net::get_header (case-insensitive) and the rate limit spaces requests', () async {
    final sent = <DateTime>[];
    final client = MockClient((http.Request r) async {
      sent.add(DateTime.now());
      return http.Response('ok', 200, headers: <String, String>{'X-Probe': 'value-${sent.length}'});
    });
    final printed = <String>[];
    final AidokuPlugin plugin = await runZoned(
      () => AidokuPlugin.fromAix(SyntheticAix.headerProbe(), httpClient: client),
      zoneSpecification: ZoneSpecification(print: (_, _, _, String line) => printed.add(line)),
    );
    addTearDown(plugin.dispose);
    const calls = 5;
    for (var i = 0; i < calls; i++) {
      await plugin.searchManga('x', 1).timeout(_noHang);
    }
    // The log message travels on the same port after the reply; let it land.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    check(
      printed.where((String l) => l.startsWith('[wasm] [aidoku] ')).map((String l) => l.split('\n').first),
    ).deepEquals(<String>[for (var i = 1; i <= calls; i++) '[wasm] [aidoku] value-$i']);

    // 2 permits per second: request i waits for request i-2 to leave the window.
    check(sent).length.equals(calls);
    for (int i = SyntheticAix.probePermits; i < calls; i++) {
      check(
        because: 'request $i vs ${i - SyntheticAix.probePermits}',
        sent[i].difference(sent[i - SyntheticAix.probePermits]).inMilliseconds,
      ).isGreaterOrEqual(SyntheticAix.probePeriodSeconds * 1000 - 20);
    }
  });

  group('through the source contract', () {
    Future<SourceSession> open(Uint8List aix) async {
      final provider = AidokuSourceProvider(httpClient: _noNetwork);
      final SourceOutcome<SourcePackage> opened = await provider.openPackage(_Artifact(aix), SettingsSnapshot());
      final SourcePackage package = opened.valueOrNull!;
      addTearDown(package.close);
      return package.sessions.single;
    }

    test('trap -> SourceErrorFailure', () async {
      final SourceSession session = await open(SyntheticAix.trapInSearch());
      final SourceOutcome<SearchPage> outcome = await session.search(const SearchRequest(query: 'x')).timeout(_noHang);
      check(outcome).isA<SourceFailed<SearchPage>>().has((SourceFailed<SearchPage> f) => f.failure, 'failure')
        ..isA<SourceErrorFailure>()
        ..has((SourceFailure f) => f.message, 'message').contains('unreachable');
    });

    test('isolate death -> RuntimeUnavailableFailure', () async {
      final SourceSession session = await open(SyntheticAix.trapInStart());
      for (var i = 0; i < 2; i++) {
        final SourceOutcome<SearchPage> outcome = await session
            .search(const SearchRequest(query: 'x'))
            .timeout(_noHang);
        check(outcome)
            .isA<SourceFailed<SearchPage>>()
            .has((SourceFailed<SearchPage> f) => f.failure, 'failure')
            .isA<RuntimeUnavailableFailure>();
      }
    });
  });
}
