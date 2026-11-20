import 'dart:typed_data';

import 'package:manga_backup_core/src/conversion/conversion_owner.dart';
import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/repository_trust.dart';
import 'package:source_runtime/source_contracts.dart';

/// Lists and loads the source plugins a migration searches. Concrete loaders
/// (Aidoku, and later Paperback and Tachi) live in the composition root, not
/// in the core (KTD15).
abstract class PluginLoader {
  const PluginLoader();

  /// Lists the extensions published by [repoUrls]. Loaders whose
  /// repositories carry a signing identity must pass each first-seen or
  /// changed fingerprint through [trust] and drop rejected repositories.
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  });

  /// Loads [extensions]. Each plugin is adopted by [owner] as soon as it is
  /// opened, so plugins loaded before a later failure are still closed.
  /// Per-extension failures are reported through [onFailure] (typed) and do
  /// not stop the remaining extensions.
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  });

  /// Downloads raw plugin bytes for [entry]. Returns null if not downloadable.
  Future<Uint8List?> downloadPluginBytes(ExtensionEntry entry) async => null;

  /// Loads a plugin from raw [bytes] for [entry], adopting it into [owner]
  /// as soon as it opens. Returns null if not supported; a failed load is a
  /// typed failure.
  Future<SourceOutcome<PluginSource>?> loadPluginFromBytes(
    ExtensionEntry entry,
    Uint8List bytes, {
    ConversionOwner? owner,
  }) async => null;
}
