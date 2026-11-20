import 'dart:typed_data';

import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';

/// Lists and loads the source plugins a migration searches. Concrete loaders
/// (Aidoku, and later Paperback and Tachi) live in the composition root, not
/// in the core (KTD15).
abstract class PluginLoader {
  const PluginLoader();

  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
  });

  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
  });

  /// Downloads raw plugin bytes for [entry]. Returns null if not downloadable.
  Future<Uint8List?> downloadPluginBytes(ExtensionEntry entry) async => null;

  /// Loads a plugin from raw [bytes] for [entry]. Returns null if not supported.
  Future<PluginSource?> loadPluginFromBytes(
    ExtensionEntry entry,
    Uint8List bytes,
  ) async => null;
}
