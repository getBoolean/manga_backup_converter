import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

Directory _fixtures(String kind) {
  Directory dir = Directory.current.absolute;
  while (true) {
    for (final base in <String>[dir.path, p.join(dir.path, 'packages', 'source_runtime')]) {
      final candidate = Directory(p.join(base, 'test', 'fixtures', 'receipts', kind));
      if (candidate.existsSync()) return candidate;
    }
    if (dir.parent.path == dir.path) throw StateError('receipt fixtures not found');
    dir = dir.parent;
  }
}

Object? _load(File f) => jsonDecode(f.readAsStringSync());

void main() {
  const evidence = EvidenceCheck();

  // Each failing fixture and the rule that must reject it.
  const expected = <String, String>{
    'password.json': 'secret-field',
    'token.json': 'secret-value',
    'cookie.json': 'secret-value',
    'private-title.json': 'private-text',
    'credential-url.json': 'credential-url',
    'raw-diagnostic.json': 'raw-diagnostic',
    'worker-stderr.json': 'raw-diagnostic',
    'settings-key.json': 'settings-key',
    'seeded-marker.json': 'seeded-marker',
  };

  group('evidence-publication check', () {
    for (final MapEntry<String, String> e in expected.entries) {
      test('rejects ${e.key} (${e.value})', () {
        final List<EvidenceViolation> found = evidence.check(_load(File(p.join(_fixtures('fail').path, e.key))));
        check(found.map((EvidenceViolation v) => v.rule)).contains(e.value);
      });
    }

    test('every failing fixture is covered', () {
      final files = <String>[
        for (final File f in _fixtures('fail').listSync().whereType<File>()) p.basename(f.path),
      ]..sort();
      check(files).deepEquals(expected.keys.toList()..sort());
    });

    test('sanitised public-query receipts pass', () {
      final List<File> files = _fixtures('pass').listSync().whereType<File>().toList();
      check(files).isNotEmpty();
      for (final f in files) {
        check(because: p.basename(f.path), evidence.check(_load(f))).isEmpty();
      }
    });

    test('a SHA-256 digest and a public artifact URL are not secrets', () {
      check(
        evidence.check(<String, Object?>{
          'sha256': 'b7dda66c5c901aa23d172173d54c12f04d64bdc20bd0da58748ce7f095da28d0',
          'url': 'https://github.com/keiyoushi/extensions/releases/download/3cf15bc/x.jar',
        }),
      ).isEmpty();
    });

    test('an empty secret-named field passes; a filled one does not', () {
      check(evidence.check(<String, Object?>{'cookies': <Object?>[]})).isEmpty();
      check(
        evidence.check(<String, Object?>{
          'cookies': <Object?>['a=b'],
        }),
      ).isNotEmpty();
    });
  });
}
