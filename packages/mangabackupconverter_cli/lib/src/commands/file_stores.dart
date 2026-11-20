import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:path/path.dart' as p;

/// Writes [bytes] to a temporary sibling of [path] and renames it into place,
/// so a failed or killed write never leaves partial output and the previous
/// file stays untouched until the new one is complete (KTD8, R10).
Future<void> writeFileAtomically(String path, List<int> bytes) async {
  final target = File(path);
  await target.parent.create(recursive: true);
  final temp = File(p.join(target.parent.path, '.${p.basename(path)}.$pid.tmp'));
  try {
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
  } on Object {
    if (temp.existsSync()) await temp.delete();
    rethrow;
  }
}

/// The CLI's conversion journal: one JSON file, replaced atomically after
/// each completed step and deleted after publication.
final class FileJournalStore implements JournalStore {
  FileJournalStore(this.path);

  final String path;

  @override
  Future<Map<String, Object?>?> read() async {
    final file = File(path);
    if (!file.existsSync()) return null;
    final Object? json = jsonDecode(await file.readAsString());
    return json is Map<String, Object?> ? json : null;
  }

  @override
  Future<void> write(Map<String, Object?> journal) =>
      writeFileAtomically(path, Uint8List.fromList(utf8.encode(jsonEncode(journal))));

  @override
  Future<void> clear() async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}

/// Remembered repository signing fingerprints, in one JSON file.
final class FileTrustStore implements TrustStore {
  FileTrustStore(this.path);

  final String path;

  Future<Map<String, String>> _load() async {
    final file = File(path);
    if (!file.existsSync()) return <String, String>{};
    final Object? json = jsonDecode(await file.readAsString());
    return json is Map<String, Object?>
        ? <String, String>{
            for (final MapEntry<String, Object?> e in json.entries)
              if (e.value is String) e.key: e.value! as String,
          }
        : <String, String>{};
  }

  @override
  Future<String?> fingerprintFor(String ecosystem, Uri repository) async =>
      (await _load())[InMemoryTrustStore.keyOf(ecosystem, repository)];

  @override
  Future<void> remember(String ecosystem, Uri repository, String fingerprint) async {
    final Map<String, String> all = await _load();
    all[InMemoryTrustStore.keyOf(ecosystem, repository)] = fingerprint;
    await writeFileAtomically(path, utf8.encode(jsonEncode(all)));
  }
}
