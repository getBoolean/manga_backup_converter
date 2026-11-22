/// The shared golden wire vectors in `fixtures/wire_vectors/` (see its
/// README): Dart writes them from its own encoders, and the Kotlin worker and
/// the Rust helper decode, re-encode and compare.
///
/// VM only (`dart:io`), so it is not part of the `source_runtime_testing`
/// barrel.
library;

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';

/// Environment variable that makes [checkWireVectors] rewrite the files.
const String updateWireVectorsVariable = 'UPDATE_WIRE_VECTORS';

/// `fixtures/wire_vectors` of the repository, found upward from the current
/// directory (the first ancestor with a `fixtures` directory).
Directory wireVectorsDir() {
  final String sep = Platform.pathSeparator;
  Directory dir = Directory.current.absolute;
  while (!Directory('${dir.path}${sep}fixtures').existsSync()) {
    final Directory parent = dir.parent;
    if (parent.path == dir.path) throw StateError('no fixtures directory above ${Directory.current.path}');
    dir = parent;
  }
  return Directory('${dir.path}${sep}fixtures${sep}wire_vectors');
}

/// Compares [content] with the committed vector file [name], or rewrites the
/// file when `UPDATE_WIRE_VECTORS=1`. Files are pretty-printed JSON with a
/// trailing newline; the comparison is on parsed JSON.
Future<void> checkWireVectors(String name, Map<String, Object?> content) async {
  final file = File('${wireVectorsDir().path}${Platform.pathSeparator}$name');
  final encoded = '${const JsonEncoder.withIndent('  ').convert(content)}\n';
  if (Platform.environment[updateWireVectorsVariable] == '1') {
    await file.parent.create(recursive: true);
    await file.writeAsString(encoded);
    return;
  }
  check(file.existsSync(), because: '${file.path} is missing; run with $updateWireVectorsVariable=1').isTrue();
  final committed = jsonDecode(await file.readAsString()) as Map<String, Object?>;
  check(
    committed,
    because: '${file.path} is stale; regenerate it with $updateWireVectorsVariable=1 and commit the result',
  ).deepEquals(jsonDecode(encoded) as Map<String, Object?>);
}
