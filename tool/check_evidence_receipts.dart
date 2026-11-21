// ignore_for_file: avoid_print
// Evidence-publication check (plan, *Evidence Identity*): run before a
// qualification receipt is committed, and in CI.
//
//   dart run tool/check_evidence_receipts.dart [file-or-directory ...]
//
// Without arguments it checks every JSON file under
// docs/validation/source-runners/*/receipts/ and every
// docs/validation/source-runners/*/qualification-manifest.json. A receipt
// holding a secret, a credential-bearing URL, a private title or query, or a
// raw worker diagnostic fails (exit code 1) with the offending JSON path.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart'
    show EvidenceCheck, EvidenceViolation;

void main(List<String> args) {
  final String root = p.normalize(
    p.join(p.dirname(Platform.script.toFilePath()), '..'),
  );
  final List<File> files = args.isEmpty
      ? _defaultReceipts(root)
      : <File>[for (final String a in args) ..._jsonUnder(a)];
  const check = EvidenceCheck();
  var failed = 0;
  for (final f in files) {
    final List<EvidenceViolation> found;
    try {
      found = check.check(jsonDecode(f.readAsStringSync()));
    } on FormatException catch (e) {
      print('FAIL ${p.relative(f.path, from: root)}: not JSON (${e.message})');
      failed++;
      continue;
    }
    if (found.isEmpty) continue;
    failed++;
    print('FAIL ${p.relative(f.path, from: root)}');
    for (final v in found) {
      print('  $v');
    }
  }
  print('${files.length} receipt(s) checked, $failed rejected');
  exitCode = failed == 0 ? 0 : 1;
}

List<File> _defaultReceipts(String root) {
  final base = Directory(p.join(root, 'docs', 'validation', 'source-runners'));
  return <File>[
    for (final Directory platform
        in base.listSync().whereType<Directory>()) ...<File>[
      if (File(p.join(platform.path, 'qualification-manifest.json'))
          case final File m when m.existsSync())
        m,
      if (Directory(p.join(platform.path, 'receipts')) case final Directory d
          when d.existsSync())
        ..._jsonUnder(d.path),
    ],
  ];
}

List<File> _jsonUnder(String path) {
  if (File(path).existsSync()) return <File>[File(path)];
  return <File>[
    for (final FileSystemEntity e in Directory(path).listSync(recursive: true))
      if (e is File && e.path.endsWith('.json')) e,
  ]..sort((File a, File b) => a.path.compareTo(b.path));
}
