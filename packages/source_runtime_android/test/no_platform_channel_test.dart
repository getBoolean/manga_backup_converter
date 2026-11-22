// KTD23: no method channel, event channel, basic message channel, or Pigeon
// layer carries source runtime calls. Checks every Dart and Kotlin source of
// this package (generated bindings included).

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

final RegExp _channelApi = RegExp(
  'MethodChannel|EventChannel|BasicMessageChannel|BinaryMessenger|FlutterPlugin|pigeon',
  caseSensitive: false,
);

/// Locates this package's root through the workspace package config, so the
/// test passes from the package directory and from the repository root.
/// (`Isolate.resolvePackageUri` is unsupported under `flutter test`.)
Directory _packageRoot() {
  for (Directory dir = Directory.current.absolute; ; dir = dir.parent) {
    final config = File('${dir.path}/.dart_tool/package_config.json');
    if (config.existsSync()) {
      final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
      final List<Map<String, dynamic>> packages = (json['packages'] as List<dynamic>).cast<Map<String, dynamic>>();
      final Map<String, dynamic> self = packages.firstWhere(
        (Map<String, dynamic> p) => p['name'] == 'source_runtime_android',
      );
      final rootUri = self['rootUri'] as String;
      return Directory.fromUri(config.uri.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/'));
    }
    if (dir.parent.path == dir.path) {
      throw StateError('No .dart_tool/package_config.json above ${Directory.current.path}');
    }
  }
}

void main() {
  test('no platform channel or plugin registrant in the package sources', () {
    final Directory root = _packageRoot();
    final List<File> sources =
        <Directory>[
              Directory('${root.path}/lib'),
              Directory('${root.path}/android/src'),
            ]
            .expand((Directory d) => d.listSync(recursive: true))
            .whereType<File>()
            .where((File f) => f.path.endsWith('.dart') || f.path.endsWith('.kt'))
            .toList();
    check(sources).isNotEmpty();
    final offenders = <String>[
      for (final File f in sources)
        if (_channelApi.hasMatch(f.readAsStringSync())) f.path,
    ];
    check(offenders).isEmpty();
  });
}
