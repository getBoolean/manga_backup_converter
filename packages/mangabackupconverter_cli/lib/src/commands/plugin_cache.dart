import 'dart:io';
import 'dart:typed_data';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:path/path.dart' as p;
import 'package:source_loaders/source_loaders.dart';

/// Plugin bytes cached on disk between runs, one file per
/// [ExtensionEntry.cacheKey]; putting a version deletes the entry's others.
class PluginCache implements PluginByteCache {
  PluginCache({Directory? cacheDir})
    : cacheDir =
          cacheDir ??
          Directory(
            p.join(
              Directory.systemTemp.path,
              'manga_backup_converter',
              'plugins',
            ),
          );

  final Directory cacheDir;

  File cacheFileFor(ExtensionEntry entry) => File(p.join(cacheDir.path, entry.cacheKey));

  @override
  Uint8List? get(ExtensionEntry entry) {
    final File file = cacheFileFor(entry);
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  @override
  void put(ExtensionEntry entry, Uint8List bytes) {
    _cleanOldVersions(entry.id, entry.cacheKey);
    final File file = cacheFileFor(entry);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  /// Deletes the cached bytes for [entry], if any.
  @override
  void remove(ExtensionEntry entry) {
    final File file = cacheFileFor(entry);
    if (file.existsSync()) file.deleteSync();
  }

  void _cleanOldVersions(String id, String currentCacheKey) {
    if (!cacheDir.existsSync()) return;
    final prefix = '$id-';
    final currentName = currentCacheKey;
    for (final FileSystemEntity entity in cacheDir.listSync()) {
      if (entity is File) {
        final String name = p.basename(entity.path);
        if (name.startsWith(prefix) && name != currentName) {
          entity.deleteSync();
        }
      }
    }
  }
}
