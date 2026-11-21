// Regenerates lib/src/bindings/source_runtime_bindings.g.dart from the
// compiled Kotlin facade classes (KTD23).
//
// Prerequisite: build the host app once so the plugin's Kotlin classes exist,
// e.g. from the repo root:
//   flutter build apk --debug --target-platform android-x64
// Then run `melos run jnigen:android`, or from packages/source_runtime_android:
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

Future<void> main() async {
  final Uri packageRoot = Platform.script.resolve('../');
  final Uri repoRoot = packageRoot.resolve('../../');
  final String? sdkRoot = Platform.environment['ANDROID_SDK_ROOT'] ?? Platform.environment['ANDROID_HOME'];
  if (sdkRoot == null) {
    stderr.writeln('Set ANDROID_SDK_ROOT or ANDROID_HOME to the Android SDK.');
    exit(2);
  }
  // Flutter builds plugin modules under <app>/build/<plugin name>/. Either
  // variant works: the bindings depend only on the facade's public API, and
  // CI's drift check runs after a release build.
  final Directory? classes = <String>['debug', 'release']
      .map(
        (String variant) => Directory.fromUri(
          repoRoot.resolve('build/source_runtime_android/tmp/kotlin-classes/$variant/'),
        ),
      )
      .where((Directory d) => d.existsSync())
      .firstOrNull;
  if (classes == null) {
    stderr.writeln('Missing build/source_runtime_android/tmp/kotlin-classes/. Build the host app first (see header).');
    exit(2);
  }

  final Uri output = packageRoot.resolve('lib/src/bindings/source_runtime_bindings.g.dart');
  // jnigen formats the output with `dart format`, which picks up the
  // package's page width, so `verify_format` and the drift check see the
  // committed form.
  await JniGenerator(
    input: Input(
      classes: _facadeClasses,
      classPath: <Uri>[classes.uri],
      backend: SummarizerBackend.asm,
      androidSdk: AndroidSdk(versions: <int>[36], sdkRoot: Directory(sdkRoot).uri),
    ),
    // No stubs: Android framework types the facade takes (Context) stay
    // plain `JObject`, which is what jni_flutter's context getter returns.
    output: Output(
      dart: DartOutput(path: output, structure: OutputStructure.singleFile),
      generateStubs: false,
    ),
  ).generate();
}
