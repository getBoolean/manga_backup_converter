import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';

/// A selected source whose ecosystem has no runtime on this host yet. Every
/// operation answers with a typed [CapabilityUnavailableFailure], never an
/// empty result (KTD15).
class StubPluginSource implements PluginSource {
  StubPluginSource({required this.sourceId, required this.sourceName, this.ecosystem = 'stub'});

  @override
  final String sourceId;

  @override
  final String sourceName;

  final String ecosystem;

  @override
  late final SourceIdentity identity = SourceIdentity(
    ecosystem: ecosystem,
    packageId: sourceId,
    sourceId: sourceId,
    artifact: const ArtifactBinding(sha256: '', kind: 'stub', version: '0'),
  );

  @override
  String get settingsRevision => '';

  @override
  String? get language => null;

  @override
  Future<SourceOutcome<PluginSearchPageResult>> search(String query, int page) async =>
      SourceFailed<PluginSearchPageResult>(
        CapabilityUnavailableFailure('search', '$ecosystem sources cannot run on this host yet'),
      );

  @override
  Future<DetailsOutcome> fetchDetails(NativeMangaRef ref) async => DetailsFailed(
    CapabilityUnavailableFailure('mangaDetails', '$ecosystem sources cannot run on this host yet'),
  );

  @override
  Future<void> dispose() async {}
}
