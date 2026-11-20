import 'dart:typed_data';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/plugin_cache.dart';
import 'package:source_runtime/source_contracts.dart';

class CachingPluginLoader extends PluginLoader {
  const CachingPluginLoader(this._inner, {required this.cache});

  final PluginLoader _inner;
  final PluginCache cache;

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) => _inner.fetchExtensionLists(repoUrls, onWarning: onWarning, trust: trust);

  @override
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async {
    final plugins = <PluginSource>[];
    for (final (int i, ExtensionEntry entry) in extensions.indexed) {
      void fail(SourceFailure failure) {
        onFailure?.call(PluginLoadFailure(extensionId: entry.id, failure: failure));
        onProgress?.call(i + 1, extensions.length, 'Warning: failed to load ${entry.name}: ${failure.message}');
      }

      try {
        Uint8List? bytes = cache.get(entry);
        final cached = bytes != null;
        if (!cached) {
          onProgress?.call(i + 1, extensions.length, 'Loading plugin: ${entry.name}');
          bytes = await _inner.downloadPluginBytes(entry);
          if (bytes == null) {
            // Inner loader doesn't support per-entry download; fall through.
            plugins.addAll(
              await _inner.loadPlugins(
                <ExtensionEntry>[entry],
                onProgress: onProgress,
                owner: owner,
                onFailure: onFailure,
              ),
            );
            continue;
          }
          cache.put(entry, bytes);
        } else {
          onProgress?.call(i + 1, extensions.length, 'Loading plugin: ${entry.name} (cached)');
        }
        final SourceOutcome<PluginSource>? loaded = await _inner.loadPluginFromBytes(entry, bytes, owner: owner);
        switch (loaded) {
          case SourceSuccess<PluginSource>(:final PluginSource value):
            plugins.add(value);
          case SourceFailed<PluginSource>(:final SourceFailure failure):
            fail(failure);
          case null:
            fail(const UnsupportedApiFailure('unsupported plugin format'));
        }
      } on Exception catch (e) {
        fail(SourceErrorFailure('$e'));
      }
    }
    return plugins;
  }
}
