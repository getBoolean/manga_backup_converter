@TestOn('vm')
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/scaffolding.dart';

/// Locates `packages/manga_backup_core` whether tests run from the package or
/// the repository root.
Directory _packageDir() {
  for (final candidate in <String>['.', 'packages/manga_backup_core']) {
    final dir = Directory(candidate);
    if (File(p.join(dir.path, 'pubspec.yaml')).readAsStringSync().contains('name: manga_backup_core')) return dir;
  }
  throw StateError('manga_backup_core package directory not found from ${Directory.current.path}');
}

void main() {
  final Directory pkg = _packageDir();

  test('core lib imports no CLI, Flutter, dart:io, loader, HTTP, SQLite or desktop backend code (KTD14)', () {
    final forbidden = RegExp(
      r'''^\s*(import|export)\s+['"]('''
      'dart:io|dart:ffi|dart:isolate|package:flutter|package:mangabackupconverter_cli|'
      r'package:aidoku_plugin_loader|package:http/|package:sqflite|package:source_runtime/source_runtime\.dart|'
      '''package:source_runtime/src/)''',
      multiLine: true,
    );
    final offenders = <String>[];
    for (final FileSystemEntity f in Directory(p.join(pkg.path, 'lib')).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      for (final Match m in forbidden.allMatches(f.readAsStringSync())) {
        offenders.add('${p.relative(f.path, from: pkg.path)}: ${m[0]!.trim()}');
      }
    }
    check(offenders).isEmpty();
  });

  test('pubspec declares no Flutter, CLI, loader or HTTP dependency', () {
    final String pubspec = File(p.join(pkg.path, 'pubspec.yaml')).readAsStringSync();
    for (final dep in <String>['flutter:', 'mangabackupconverter_cli:', 'aidoku_plugin_loader:', 'http:', 'sqflite']) {
      check(pubspec).not((it) => it.contains('  $dep'));
    }
  });

  test('update-schemas workflow writes generated Tachi protobuf code only to the core path', () {
    final workflow = File(p.join(pkg.path, '..', '..', '.github', 'workflows', 'update-schemas.yml'));
    final String yml = workflow.readAsStringSync();
    final List<String> prefixes = RegExp(
      'OUTPUT_DIR_PREFIX="([^"]+)"',
    ).allMatches(yml).map((Match m) => m[1]!).toList();
    check(prefixes).deepEquals(<String>['packages/manga_backup_core/lib/src/formats/tachi/proto/']);
    check(yml).not((it) => it.contains('mangabackupconverter_cli/lib/src/proto'));

    final String repo = p.join(pkg.path, '..', '..');
    for (final schema in <String>['j2k', 'mihon', 'neko', 'sy', 'yokai']) {
      final generated = File(p.join(repo, prefixes.single, 'schema_$schema.proto', 'proto', 'schema_$schema.pb.dart'));
      check(generated.existsSync()).isTrue();
    }
    check(Directory(p.join(repo, 'packages', 'mangabackupconverter_cli', 'lib', 'src', 'proto')).existsSync())
        .isFalse();
  });
}
