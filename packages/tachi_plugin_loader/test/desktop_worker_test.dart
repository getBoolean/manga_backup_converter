@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:test/scaffolding.dart';

void main() {
  late Directory temp;
  late Directory install;
  late Directory javaHome;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tachi_location_');
    install = Directory(p.join(temp.path, 'runtime'));
    Directory(p.join(install.path, 'lib')).createSync(recursive: true);
    javaHome = Directory(p.join(temp.path, 'jdk'));
    File(p.join(javaHome.path, 'bin', Platform.isWindows ? 'java.exe' : 'java')).createSync(recursive: true);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  String writeManifest(Map<String, Object?> json) {
    final file = File(p.join(install.path, 'tachi-runtime.json'))..writeAsStringSync(jsonEncode(json));
    return file.path;
  }

  test('a manifest supplies java, classpath and the handshake deadline, relative to itself', () {
    final String manifest = writeManifest(<String, Object?>{
      'format': 1,
      'worker': 'tachi-jvm',
      'java': p.relative(p.join(javaHome.path, 'bin', Platform.isWindows ? 'java.exe' : 'java'), from: install.path),
      'classpath': 'lib',
      'handshakeDeadlineMs': 1234,
    });
    final TachiWorkerLocation location = (TachiWorkerLocation.resolve(
      manifestPath: manifest,
      environment: const <String, String>{},
    ) as SourceSuccess<TachiWorkerLocation>).value;
    check(location.classpathDirectory).equals(p.join(install.path, 'lib'));
    check(location.handshakeDeadline).equals(const Duration(milliseconds: 1234));
    check(location.limits.handshakeDeadline).equals(const Duration(milliseconds: 1234));
    // Every other limit is adopted from the worker's handshake.
    check(location.limits.operationDeadline).isNull();
    check(location.limits.maxConcurrentPackages).isNull();

    final WorkerSpec spec = location.spec(replay: <String>['captures/a']);
    check(spec.arguments).deepEquals(<String>[
      '-cp',
      p.join(install.path, 'lib', '*'),
      tachiWorkerMainClass,
      '--replay',
      'captures/a',
    ]);
  });

  test('without a handshake deadline the location is a typed failure naming it', () {
    final SourceOutcome<TachiWorkerLocation> outcome = TachiWorkerLocation.resolve(
      installDirectory: install.path,
      javaHome: javaHome.path,
      environment: const <String, String>{},
    );
    final SourceFailure failure = (outcome as SourceFailed<TachiWorkerLocation>).failure;
    check(failure).isA<RuntimeUnavailableFailure>();
    check(failure.message).contains('handshakeDeadline');
  });

  test('an explicit deadline and TACHI_JAVA_HOME complete a configured install', () {
    final SourceOutcome<TachiWorkerLocation> outcome = TachiWorkerLocation.resolve(
      installDirectory: install.path,
      handshakeDeadline: const Duration(seconds: 5),
      environment: <String, String>{'TACHI_JAVA_HOME': javaHome.path},
    );
    check(outcome).isA<SourceSuccess<TachiWorkerLocation>>();
  });

  test('a missing classpath or a wrong manifest is a typed failure', () {
    check(
      TachiWorkerLocation.resolve(
        installDirectory: p.join(temp.path, 'absent'),
        javaHome: javaHome.path,
        handshakeDeadline: const Duration(seconds: 5),
        environment: const <String, String>{},
      ),
    ).isA<SourceFailed<TachiWorkerLocation>>();
    check(
      TachiWorkerLocation.resolve(manifestPath: writeManifest(<String, Object?>{'format': 2, 'worker': 'tachi-jvm'})),
    ).isA<SourceFailed<TachiWorkerLocation>>();
    check(
      TachiWorkerLocation.resolve(
        manifestPath: writeManifest(<String, Object?>{'format': 1, 'worker': 'tachi-jvm', 'handshakeDeadlineMs': -1}),
      ),
    ).isA<SourceFailed<TachiWorkerLocation>>();
  });
}
