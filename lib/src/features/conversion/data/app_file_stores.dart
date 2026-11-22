import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:manga_backup_core/manga_backup_core.dart';

/// Writes [bytes] to [path] through a temporary sibling and a rename, so
/// [path] holds either its previous content or all of [bytes].
Future<void> writeAppFileAtomically(String path, List<int> bytes) async {
  final target = File(path);
  await target.parent.create(recursive: true);
  final temp = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
  try {
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(path);
  } on Object {
    if (temp.existsSync()) await temp.delete();
    rethrow;
  }
}

/// App-local publication of a conversion's output (inside the app's
/// sandbox): atomic, so a failed or interrupted conversion leaves no
/// partial file.
final class AppFileConversionOutput implements ConversionOutput {
  const AppFileConversionOutput(this.path);

  final String path;

  @override
  Future<void> publish(Uint8List bytes) => writeAppFileAtomically(path, bytes);
}

/// The conversion journal as one JSON file in the app's sandbox, so a job
/// killed with the app resumes at the next launch. It holds decisions only;
/// the core never journals secrets.
final class AppFileJournalStore implements JournalStore {
  const AppFileJournalStore(this.path);

  final String path;

  @override
  Future<Map<String, Object?>?> read() async {
    final file = File(path);
    if (!file.existsSync()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, Object?>;
  }

  @override
  Future<void> write(Map<String, Object?> journal) =>
      writeAppFileAtomically(path, utf8.encode(jsonEncode(journal)));

  @override
  Future<void> clear() async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}
