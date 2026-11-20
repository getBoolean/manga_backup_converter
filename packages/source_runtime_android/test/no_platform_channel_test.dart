// KTD23: no method channel, event channel, basic message channel, or Pigeon
// layer carries source runtime calls. Checks every Dart and Kotlin source of
// this package (generated bindings included).

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

final RegExp _channelApi = RegExp(
  'MethodChannel|EventChannel|BasicMessageChannel|BinaryMessenger|FlutterPlugin|pigeon',
  caseSensitive: false,
);

void main() {
  test('no platform channel or plugin registrant in the package sources', () {
    final List<File> sources = <Directory>[Directory('lib'), Directory('android/src')]
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
