import 'package:manga_backup_core/src/conversion/manga_details.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

class MangaMatchConfirmation {
  const MangaMatchConfirmation({
    required this.sourceManga,
    this.confirmedMatch,
    this.targetMangaDetails,
    this.targetChapters = const <PluginChapter>[],
  });

  final SourceMangaData sourceManga;
  final PluginSearchResult? confirmedMatch;
  final PluginMangaDetails? targetMangaDetails;
  final List<PluginChapter> targetChapters;
}

class MangaMatchProposal {
  const MangaMatchProposal({
    required this.sourceManga,
    required this.candidates,
    this.bestMatch,
    this.failures = const <PluginSearchFailure>[],
  });

  final MangaSearchDetails sourceManga;
  final List<PluginSearchResult> candidates;
  final PluginSearchResult? bestMatch;
  final List<PluginSearchFailure> failures;
}

class PluginSearchFailure {
  const PluginSearchFailure({required this.pluginId, required this.error});

  final String pluginId;
  final Object error;

  @override
  String toString() => 'PluginSearchFailure(pluginId: $pluginId, error: $error)';
}

class PluginLoadFailure {
  const PluginLoadFailure({required this.extensionId, required this.error});

  final String extensionId;
  final Object error;

  @override
  String toString() => 'PluginLoadFailure(extensionId: $extensionId, error: $error)';
}
