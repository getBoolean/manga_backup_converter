// Regenerates lib/src/bindings/source_runtime_bindings.g.dart from the
// compiled Kotlin facade classes (KTD23).
//
// Prerequisite: build the host app once so the plugin's Kotlin classes exist,
// e.g. from the repo root:
//   flutter build apk --debug --target-platform android-x64
// Then, from packages/source_runtime_android:
//   dart run tool/jnigen.dart
//
// JAVA_HOME must point at a JDK 17+ (the project uses Amazon Corretto 21).
// ANDROID_SDK_ROOT (or ANDROID_HOME) must point at the Android SDK.

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:jnigen/jnigen.dart';

/// Facade classes Dart calls or implements. Nothing else is bound: Android
/// framework types (Context) appear as plain `JObject`.
const List<String> _facadeClasses = <String>[
  'dev.getboolean.sourceruntime.SourceRuntimeClient',
  'dev.getboolean.sourceruntime.SourceRuntimeListener',
  'dev.getboolean.sourceruntime.ArtifactStaging',
  'dev.getboolean.sourceruntime.AppWebViewProbe',
  'dev.getboolean.sourceruntime.ProbeListener',
  'dev.getboolean.sourceruntime.RuntimeDiagnostics',
];

void main(List<String> args) {
  final Uri packageRoot = Platform.script.resolve('../');
  final Uri repoRoot = packageRoot.resolve('../../');
  final String? sdkRoot = Platform.environment['ANDROID_SDK_ROOT'] ?? Platform.environment['ANDROID_HOME'];
  if (sdkRoot == null) {
    stderr.writeln('Set ANDROID_SDK_ROOT or ANDROID_HOME to the Android SDK.');
    exit(2);
  }
  // Flutter builds plugin modules under <app>/build/<plugin name>/.
  final classes = Directory.fromUri(
    repoRoot.resolve('build/source_runtime_android/tmp/kotlin-classes/debug/'),
  );
  if (!classes.existsSync()) {
    stderr.writeln('Missing ${classes.path}. Build the host app first (see header).');
    exit(2);
  }

  final Uri output = packageRoot.resolve('lib/src/bindings/source_runtime_bindings.g.dart');
  generateJniBindings(
    Config(
      outputConfig: OutputConfig(
        dartConfig: DartCodeOutputConfig(
          path: output,
          structure: OutputStructure.singleFile,
        ),
      ),
      androidSdkConfig: AndroidSdkConfig(versions: <int>[36], sdkRoot: sdkRoot),
      summarizerOptions: SummarizerOptions(backend: SummarizerBackend.asm),
      classPath: <Uri>[classes.uri],
      classes: _facadeClasses,
    ),
  );
  // Format with the package's page width so `melos run verify_format` and
  // a drift check see the committed form.
  final ProcessResult format = Process.runSync('dart', <String>['format', output.toFilePath()], runInShell: true);
  stdout.write(format.stdout);
  if (format.exitCode != 0) {
    stderr.write(format.stderr);
    exit(format.exitCode);
  }
}
