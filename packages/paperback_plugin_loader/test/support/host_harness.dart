import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

/// Generous test limits; resource-limit behaviour has its own tests.
PaperbackRuntimeLimits testLimits({Duration deadline = const Duration(seconds: 60)}) => PaperbackRuntimeLimits(
  memoryLimitBytes: 256 << 20,
  maxStackBytes: 512 << 10,
  operationDeadline: deadline,
  jobSlice: const Duration(milliseconds: 20),
);

SettingsPayload emptySettings() => SettingsPayload.fromSnapshot(SettingsSnapshot());

/// A handwritten 0.9 bundle: [body] runs inside the module function and must
/// set `e.<id>` to the source instance, exactly like a rolldown bundle.
Uint8List bundle09(String body) => utf8.encode('var source=(function(e){$body\nreturn e})({});');

/// A handwritten 0.8 bundle exporting `Sources.<id>` and `Sources.<id>Info`,
/// assigned the way an esbuild 0.8.7 bundle does.
Uint8List bundle08(String body) =>
    utf8.encode('var _Sources=(function(){var exports={};$body\nreturn exports})();this.Sources=_Sources;');

ArtifactBinding bindingFor(Uint8List bytes, PaperbackApiFamily family) =>
    ArtifactBinding(sha256: bundleDigest(bytes), kind: family.artifactKind, version: 'test');

/// A loaded host over a fake HTTP handler, with the runtime it owns.
final class HostUnderTest {
  HostUnderTest._(this.runtime, this.host, this.requests, this.logs);

  static Future<HostUnderTest> load(
    Uint8List bytes,
    PaperbackApiFamily family, {
    Future<http.Response> Function(http.Request request)? handler,
    http.Client? client,
    PaperbackBrowserChannel? browser,
    SettingsPayload? settings,
    Duration deadline = const Duration(seconds: 60),
    Duration cloudflareAutoSolveWait = Duration.zero,
  }) async {
    final requests = <http.Request>[];
    final logs = <String>[];
    final runtime = SourceJsRuntime(
      limits: testLimits(deadline: deadline),
      log: logs.add,
    );
    final http.Client c =
        client ??
        MockClient((http.Request r) async {
          requests.add(r);
          return handler == null ? http.Response('not stubbed', 404) : handler(r);
        });
    final host = PaperbackSourceHost(
      runtime: runtime,
      http: PaperbackHttp(c),
      browser: browser,
      cloudflareAutoSolveWait: cloudflareAutoSolveWait,
      log: logs.add,
    );
    try {
      await host.load(bytes, bindingFor(bytes, family), settings ?? emptySettings());
    } on Object {
      runtime.dispose();
      rethrow;
    }
    return HostUnderTest._(runtime, host, requests, logs);
  }

  final SourceJsRuntime runtime;
  final PaperbackSourceHost host;
  final List<http.Request> requests;
  final List<String> logs;

  String get sourceId => host.sources.keys.single;

  Future<PaperbackSearchPage> search(String query, [String? cursor]) => host.search(sourceId, query, cursor);

  Future<Map<String, Object?>> details(String mangaId) => host.details(sourceId, mangaId);

  void dispose() => runtime.dispose();
}
