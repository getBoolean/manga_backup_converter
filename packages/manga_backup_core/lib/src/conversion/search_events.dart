import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';

/// Streaming search events, per plugin.
sealed class PluginSearchEvent {}

class PluginSearchStarted extends PluginSearchEvent {
  PluginSearchStarted({required this.pluginId, this.pluginName});

  final String pluginId;
  final String? pluginName;
}

class PluginSearchResults extends PluginSearchEvent {
  PluginSearchResults({required this.pluginId, required this.results, this.pluginName});

  final String pluginId;
  final String? pluginName;
  final List<PluginSearchResult> results;
}

class PluginSearchError extends PluginSearchEvent {
  PluginSearchError({required this.failure});

  final PluginSearchFailure failure;
}
