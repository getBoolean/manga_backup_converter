// The worker refuses to start on a JRE below its security floor (KTD1,
// 21.0.13.1): the real installDist worker launched by a real older java.
@TestOn('vm')
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';
import 'package:test/scaffolding.dart';

const List<int> _floor = <int>[21, 0, 13, 1];

/// `java -version` of [home] as numbers, or `null`.
List<int>? _versionOf(String home) {
  final String java = p.join(home, 'bin', Platform.isWindows ? 'java.exe' : 'java');
  if (!File(java).existsSync()) return null;
  final ProcessResult r = Process.runSync(java, <String>['-version']);
  final RegExpMatch? m = RegExp('version "([0-9.]+)').firstMatch(r.stderr as String);
  return m?.group(1)!.split('.').map(int.parse).toList();
}

bool _below(List<int> v) {
  for (var i = 0; i < _floor.length; i++) {
    final int have = i < v.length ? v[i] : 0;
    if (have != _floor[i]) return have < _floor[i];
  }
  return false;
}

/// A JDK below the floor: `TACHI_BELOW_FLOOR_JAVA_HOME`, else `JAVA_HOME`
/// when it is older than the floor.
String? _belowFloorHome() {
  for (final home in <String?>[
    Platform.environment['TACHI_BELOW_FLOOR_JAVA_HOME'],
    Platform.environment['JAVA_HOME'],
  ]) {
    if (home == null) continue;
    final List<int>? v = _versionOf(home);
    if (v != null && _below(v)) return home;
  }
  return null;
}

void main() {
  final ({TachiWorkerLocation? location, String? skip}) worker = testWorkerLocation();
  final String? old = _belowFloorHome();

  test(
    'the installed worker refuses a JRE below 21.0.13.1 and starts on the floor JRE',
    () async {
      final TachiWorkerLocation floor = worker.location!;
      final String oldJava = p.join(old!, 'bin', Platform.isWindows ? 'java.exe' : 'java');
      final WorkerSpec spec = floor.spec();
      final ProcessResult refused = await Process.run(
        oldJava,
        spec.arguments,
        environment: spec.environment,
        includeParentEnvironment: false,
      );
      check(refused.exitCode).equals(3);
      check(refused.stderr as String).contains('below the security floor 21.0.13.1');
      check(refused.stdout as String).isEmpty();

      // The same worker on the floor JRE answers its handshake.
      final supervisor = WorkerSupervisor(spec: spec, limits: floor.limits);
      try {
        check(await supervisor.start()).isA<SourceSuccess<HandshakeResponse>>();
      } finally {
        await supervisor.close();
      }
    },
    skip:
        worker.skip ??
        (old == null
            ? 'no JRE below the floor here (set TACHI_BELOW_FLOOR_JAVA_HOME to an older JDK, e.g. 21.0.4)'
            : null),
  );
}
