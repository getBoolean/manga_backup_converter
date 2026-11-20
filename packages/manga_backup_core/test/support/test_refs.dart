import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';

/// A test source identity for [sourceId].
SourceIdentity testIdentity(String sourceId, {String ecosystem = 'test', String digest = 'digest'}) => SourceIdentity(
  ecosystem: ecosystem,
  packageId: sourceId,
  sourceId: sourceId,
  artifact: ArtifactBinding(sha256: digest, kind: 'test', version: '1'),
);

/// A native reference for [mangaKey] on [sourceId].
NativeMangaRef testRef(String sourceId, String mangaKey, {String settingsRevision = 'rev'}) =>
    NativeMangaRef(source: testIdentity(sourceId), mangaId: mangaKey, settingsRevision: settingsRevision);

/// A search result built from the pre-reference field names.
PluginSearchResult testResult({
  required String pluginSourceId,
  required String mangaKey,
  required String title,
  String? pluginSourceName,
  String? coverUrl,
  List<String> authors = const <String>[],
  PluginMangaDetails? details,
  List<PluginChapter> chapters = const <PluginChapter>[],
}) => PluginSearchResult(
  ref: testRef(pluginSourceId, mangaKey),
  title: title,
  pluginSourceName: pluginSourceName,
  coverUrl: coverUrl,
  authors: authors,
  details: details,
  chapters: chapters,
);

/// Builds [confirmations] through reconciliation plans, as the pipeline does.
ConvertableBackup buildFrom(
  TargetBackupBuilder builder,
  List<MangaMatchConfirmation> confirmations, {
  ConversionReport? report,
  String? sourceFormatAlias,
}) => builder.build(
  <MangaConversionPlan>[for (final MangaMatchConfirmation c in confirmations) planConversion(c)],
  report: report,
  sourceFormatAlias: sourceFormatAlias,
);
