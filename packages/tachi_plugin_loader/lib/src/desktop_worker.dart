import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';

/// Main class of the desktop Tachi worker (`tools/tachi-source-runner`).
const String tachiWorkerMainClass = 'mangabackup.tachi.MainKt';

/// Install layout `./gradlew installDist` produces, relative to the
/// repository root; used only by development discovery.
const String tachiWorkerDevelopmentInstall = 'tools/tachi-source-runner/build/install/tachi-source-runner';

/// Where the desktop JVM worker is and how long its handshake may take.
///
/// Resolved from a runtime artifact manifest (`tachi-runtime.json`, written
/// by packaging) or from explicitly configured paths. Every value has a named
/// source; nothing is guessed (KTD25). In particular the handshake deadline
/// is the one limit the worker cannot report (the supervisor needs it before
/// the worker has said anything), so it must be configured: when it is not,
/// resolution fails with [RuntimeUnavailableFailure] naming it.
@immutable
final class TachiWorkerLocation {
  const TachiWorkerLocation({
    required this.java,
    required this.classpathDirectory,
    required this.handshakeDeadline,
    this.mainClass = tachiWorkerMainClass,
  });

  /// The `java` executable (Amazon Corretto 21.0.13.1 or later; the worker
  /// refuses older runtimes).
  final String java;

  /// Directory holding the worker's JARs (`lib/` of the install).
  final String classpathDirectory;
  final String mainClass;

  /// Bound on the worker's handshake reply.
  final Duration handshakeDeadline;

  /// Manifest format this code reads.
  static const int manifestFormat = 1;

  /// Resolves the worker location.
  ///
  /// Sources, in order: the manifest at [manifestPath] (relative paths are
  /// relative to it); then [installDirectory] (an `installDist` output) or,
  /// failing that, the development install found by walking up from
  /// [searchFrom]; `java` from [javaHome], else `TACHI_JAVA_HOME`, else
  /// `JAVA_HOME` in [environment]. [handshakeDeadline] overrides the
  /// manifest's `handshakeDeadlineMs`.
  static SourceOutcome<TachiWorkerLocation> resolve({
    String? manifestPath,
    String? installDirectory,
    String? javaHome,
    Duration? handshakeDeadline,
    Directory? searchFrom,
    Map<String, String>? environment,
  }) {
    final Map<String, String> env = environment ?? Platform.environment;
    String? java;
    String? classpath;
    String mainClass = tachiWorkerMainClass;
    var deadline = handshakeDeadline;

    if (manifestPath != null) {
      final SourceOutcome<_Manifest> manifest = _Manifest.read(manifestPath);
      switch (manifest) {
        case SourceFailed<_Manifest>(:final SourceFailure failure):
          return SourceFailed<TachiWorkerLocation>(failure);
        case SourceSuccess<_Manifest>(:final _Manifest value):
          java = value.java;
          classpath = value.classpath;
          mainClass = value.mainClass ?? mainClass;
          deadline ??= value.handshakeDeadline;
      }
    }

    final String? home = javaHome ?? env['TACHI_JAVA_HOME'] ?? env['JAVA_HOME'];
    java ??= home == null ? null : p.join(home, 'bin', Platform.isWindows ? 'java.exe' : 'java');
    classpath ??= switch (installDirectory) {
      final String dir => p.join(dir, 'lib'),
      null => _developmentInstall(searchFrom ?? Directory.current),
    };

    final missing = <String>[
      if (java == null) 'java (set TACHI_JAVA_HOME or JAVA_HOME, or a runtime manifest)',
      if (classpath == null)
        'worker classpath (a runtime manifest, a configured install directory, or $tachiWorkerDevelopmentInstall)',
      if (deadline == null) 'handshakeDeadline (handshakeDeadlineMs in the runtime manifest, or explicit configuration)',
    ];
    if (missing.isNotEmpty) {
      return SourceFailed<TachiWorkerLocation>(
        RuntimeUnavailableFailure('Tachi worker is not configured: no ${missing.join('; no ')}'),
      );
    }
    if (!File(java!).existsSync()) {
      return SourceFailed<TachiWorkerLocation>(RuntimeUnavailableFailure('Java executable not found: $java'));
    }
    if (!Directory(classpath!).existsSync()) {
      return SourceFailed<TachiWorkerLocation>(
        RuntimeUnavailableFailure('Tachi worker classpath not found: $classpath (run ./gradlew installDist)'),
      );
    }
    return SourceSuccess<TachiWorkerLocation>(
      TachiWorkerLocation(java: java, classpathDirectory: classpath, handshakeDeadline: deadline!, mainClass: mainClass),
    );
  }

  /// The worker process spec.
  ///
  /// [replay] capture directories put the worker in replay mode: it serves
  /// only committed captures and fails every other request, so no request
  /// reaches a server. [stateDirectory] holds the worker's per-run state.
  /// Limits are never passed: the worker derives them from its benchmarked
  /// sizing rule and reports them in the handshake.
  WorkerSpec spec({
    String? stateDirectory,
    List<String> replay = const <String>[],
    bool browser = true,
    Map<String, String>? environment,
  }) => WorkerSpec(
    label: 'jvm',
    executable: java,
    arguments: <String>[
      '-cp',
      p.join(classpathDirectory, '*'),
      mainClass,
      if (stateDirectory != null) ...<String>['--state-dir', stateDirectory],
      for (final String dir in replay) ...<String>['--replay', dir],
      if (!browser) '--no-browser',
    ],
    environment: environment ?? scrubbedEnvironment(),
  );

  /// Limits for a supervisor of this worker: every limit is adopted from the
  /// worker's handshake; only the handshake deadline comes from here.
  AdoptWorkerLimits get limits => AdoptWorkerLimits(handshakeDeadline: handshakeDeadline);

  static String? _developmentInstall(Directory from) {
    Directory dir = from.absolute;
    while (true) {
      final lib = Directory(p.join(dir.path, tachiWorkerDevelopmentInstall, 'lib'));
      if (lib.existsSync()) return lib.path;
      final Directory parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }
}

/// `tachi-runtime.json`:
/// `{"format": 1, "worker": "tachi-jvm", "java": "...", "classpath": "lib",
///   "mainClass": "...", "handshakeDeadlineMs": n}`.
final class _Manifest {
  const _Manifest({this.java, this.classpath, this.mainClass, this.handshakeDeadline});

  final String? java;
  final String? classpath;
  final String? mainClass;
  final Duration? handshakeDeadline;

  static SourceOutcome<_Manifest> read(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return SourceFailed<_Manifest>(RuntimeUnavailableFailure('Tachi runtime manifest not found: $path'));
    }
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      return SourceFailed<_Manifest>(RuntimeUnavailableFailure('Tachi runtime manifest $path is not JSON: ${e.message}'));
    }
    if (json is! Map<String, Object?> ||
        json['format'] != TachiWorkerLocation.manifestFormat ||
        json['worker'] != 'tachi-jvm') {
      return SourceFailed<_Manifest>(
        RuntimeUnavailableFailure(
          'Tachi runtime manifest $path is not format ${TachiWorkerLocation.manifestFormat} for tachi-jvm',
        ),
      );
    }
    final Map<String, Object?> fields = json;
    final String base = p.dirname(p.absolute(path));
    String? resolved(String key) => switch (fields[key]) {
      final String value => p.normalize(p.join(base, value)),
      _ => null,
    };
    final Object? deadline = fields['handshakeDeadlineMs'];
    if (deadline != null && (deadline is! int || deadline <= 0)) {
      return SourceFailed<_Manifest>(
        RuntimeUnavailableFailure('Tachi runtime manifest $path: handshakeDeadlineMs must be a positive integer'),
      );
    }
    return SourceSuccess<_Manifest>(
      _Manifest(
        java: resolved('java'),
        classpath: resolved('classpath'),
        mainClass: fields['mainClass'] as String?,
        handshakeDeadline: deadline is int ? Duration(milliseconds: deadline) : null,
      ),
    );
  }
}
