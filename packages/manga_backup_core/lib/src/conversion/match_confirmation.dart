import 'package:manga_backup_core/src/conversion/details_outcome.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:source_runtime/source_contracts.dart';

/// The selection UI's decision for one source manga, plus everything the
/// pipeline later learned about it.
class MangaMatchConfirmation {
  const MangaMatchConfirmation({
    required this.sourceManga,
    this.confirmedMatch,
    this.targetMangaDetails,
    this.targetChapters = const <PluginChapter>[],
    this.excluded = false,
    this.searchFailures = const <PluginSearchFailure>[],
    this.destination,
    this.detailsFailure,
  });

  final SourceMangaData sourceManga;
  final PluginSearchResult? confirmedMatch;
  final PluginMangaDetails? targetMangaDetails;
  final List<PluginChapter> targetChapters;

  /// The user explicitly skipped this manga (an exclusion, not a loss).
  final bool excluded;

  /// Search failures seen while matching this manga, from any source —
  /// including sources other than the one that produced [confirmedMatch].
  final List<PluginSearchFailure> searchFailures;

  /// The confirmed destination snapshot, once fetched.
  final FetchedManga? destination;

  /// Why fetching the confirmed match's details failed, when it did. Such a
  /// match is never built with an empty chapter list.
  final SourceFailure? detailsFailure;

  /// A copy with the fetched destination applied.
  MangaMatchConfirmation withDestination(FetchedManga fetched) => MangaMatchConfirmation(
    sourceManga: sourceManga,
    confirmedMatch: confirmedMatch?.enrichedWith(fetched),
    targetMangaDetails: fetched.details,
    targetChapters: fetched.chapters,
    excluded: excluded,
    searchFailures: searchFailures,
    destination: fetched,
  );

  /// A copy recording that the details fetch failed.
  MangaMatchConfirmation withDetailsFailure(SourceFailure failure) => MangaMatchConfirmation(
    sourceManga: sourceManga,
    confirmedMatch: confirmedMatch,
    excluded: excluded,
    searchFailures: searchFailures,
    detailsFailure: failure,
  );
}

/// One source's search failure, with its typed reason.
class PluginSearchFailure {
  const PluginSearchFailure({required this.pluginId, required this.failure, this.pluginName});

  final String pluginId;
  final String? pluginName;
  final SourceFailure failure;

  @override
  String toString() => 'PluginSearchFailure(pluginId: $pluginId, failure: $failure)';
}

/// One extension that could not be loaded, with its typed reason.
class PluginLoadFailure {
  const PluginLoadFailure({required this.extensionId, required this.failure});

  final String extensionId;
  final SourceFailure failure;

  @override
  String toString() => 'PluginLoadFailure(extensionId: $extensionId, failure: $failure)';
}
