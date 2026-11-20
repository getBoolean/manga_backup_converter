import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

import '../../bin/paperback_source_worker.dart' show parseLimitArguments;

/// A test adapter (U6 supplies the real Paperback adapters): `package.load`
/// hosts sources `one` and `two` and keeps the settings it was given;
/// `settings.update` replaces them; `search` echoes the searched source's
/// effective settings in `warnings` (secret key names only, never values).
final class SettingsEchoAdapter implements PaperbackPackageAdapter {
  late SettingsPayload _settings;

  @override
  Set<String> get apiFamilies => const <String>{'test-settings-echo'};

  @override
  Future<PackageLoadResponse> load(
    SourceJsRuntime runtime,
    PackageLoadRequest request,
    CancellationToken cancel,
  ) async {
    _settings = request.settings;
    return PackageLoadResponse(
      sources: <LoadedSource>[
        for (final id in const <String>['one', 'two'])
          LoadedSource(
            sourceId: id,
            name: 'Echo $id',
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
    switch (request) {
      case SettingsUpdateRequest(:final SettingsPayload settings):
        _settings = settings;
        return const EmptyPayload();
      case WorkerSearchRequest(:final SourceIdentity source):
        final SettingsPayload settings = _settings;
        return WorkerSearchResponse(
          hits: const <WorkerSearchHit>[],
          warnings: <String>[
            'values=${jsonEncode(settings.valuesFor(source.sourceId))}',
            'secrets=${(settings.secretsFor(source.sourceId).keys.toList()..sort()).join(',')}',
          ],
        );
      default:
        throw UnsupportedError('${request.operation.wire} is not served by the echo adapter');
    }
  }
}

/// The real [PaperbackSourceWorker] over stdio with [SettingsEchoAdapter],
/// for the supervisor end-to-end tests. Takes the same limit arguments as
/// `bin/paperback_source_worker.dart`.
Future<void> main(List<String> args) async {
  final PaperbackRuntimeLimits limits = parseLimitArguments(args);
  await runZoned(
    () => PaperbackSourceWorker(
      input: stdin,
      output: stdout,
      limits: limits,
      adapter: SettingsEchoAdapter(),
      pid: pid,
      log: stderr.writeln,
    ).run(),
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) => stderr.writeln(line),
    ),
  );
}
