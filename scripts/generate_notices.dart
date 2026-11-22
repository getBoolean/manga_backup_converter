// ignore_for_file: avoid_print

// Generates the third-party notices asset of one app build target from what
// that build ships (scripts/licenses/components.json, "targets"):
//
//   dart run scripts/generate_notices.dart android|ios [--check]
//
//   android  packages/source_runtime_android/notices/third_party_notices.json:
//            every artifact of the app's releaseRuntimeClasspath
//            (android/app/gradle.lockfile), the Rust crates of the scraper
//            bridge and the Rust-based plugins for the Android ABIs, and the
//            vendored native code (QuickJS-ng, Wasm3, Zstandard) and the
//            extracted Mihon source API
//   ios      packages/source_runtime_ios/notices/third_party_notices.json:
//            the Tachi host class path the iOS runtime stages (the worker's
//            runtimeClasspath without the replay server), the Rust-based
//            plugin crates for iOS, libffi, SwiftSoup and its packages, and
//            the vendored native code
//
//   --check  fail (exit 1) when the committed asset differs from a fresh
//            generation instead of writing it
//
// Maven inputs come from Gradle's own resolution of the shipped configuration
// (scripts/licenses/license-inputs.gradle, run through the build's wrapper;
// android/gradlew exists after a `flutter build apk`). Gradle and cargo may
// download POMs and crate sources (package metadata) on the first run. The app registers every component on its licence
// page; scripts/android_package_check.py and scripts/ios_package_check.sh fail
// when a shipped library has no entry with a text.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'licenses/notices.dart';

final String _root = p.normalize(
  p.join(p.dirname(Platform.script.toFilePath()), '..'),
);

Future<void> main(List<String> args) async {
  final String? target = args
      .where((String a) => !a.startsWith('--'))
      .firstOrNull;
  if (target == null) {
    stderr.writeln(
      'usage: dart run scripts/generate_notices.dart android|ios [--check]',
    );
    exit(2);
  }
  final bool check = args.contains('--check');
  final config = NoticesConfig.load(_root)..verifyUpstreamTexts();
  final Map<String, Object?> t = config.target(target);
  final String json = encodeNotices(
    target,
    await components(config, target, t),
  );
  final file = File(p.join(_root, t['output']! as String));
  final String current = file.existsSync()
      ? file.readAsStringSync().replaceAll('\r\n', '\n')
      : '';
  final int count =
      ((jsonDecode(json) as Map<String, Object?>)['components']!
              as List<Object?>)
          .length;
  if (check) {
    if (current != json) {
      stderr.writeln(
        '${t['output']} is stale; run `dart run scripts/generate_notices.dart $target` and commit the result.',
      );
      exit(1);
    }
    print('${t['output']}: current ($count components)');
    return;
  }
  file
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(json);
  print('wrote ${t['output']} ($count components)');
}

/// Every component [target] ships.
Future<List<Component>> components(
  NoticesConfig config,
  String name,
  Map<String, Object?> target,
) async {
  final maven = target['maven']! as Map<String, Object?>;
  final GradleInputs inputs = await resolveGradleInputs(
    root: _root,
    buildDir: p.join(_root, maven['gradle']! as String),
    task: maven['task']! as String,
    configuration: maven['configuration']! as String,
    output: p.join(_root, 'build', 'notices', '$name-maven.json'),
  );
  final result = <Component>[
    ...mavenComponents(
      root: _root,
      coordinates: inputs.coordinates(
        exclude: (maven['exclude']! as List<Object?>).cast<String>().toSet(),
      ),
      inputs: inputs,
      overrides: config.mavenOverrides,
    ),
    ...config.vendored((target['vendored']! as List<Object?>).cast<String>()),
  ];
  final crates = <String, Component>{};
  for (final Map<String, Object?> tree
      in (target['rust']! as List<Object?>).cast<Map<String, Object?>>()) {
    final pub = tree['pub'] as String?;
    final String base = pub == null ? _root : pubPackageRoot(pub);
    final List<Component> found = await rustComponents(
      root: _root,
      manifest: p.join(base, tree['manifest']! as String),
      triples: (tree['triples']! as List<Object?>).cast<String>(),
      // A plugin's own crates are under the plugin's licence.
      ownCrates: pub == null
          ? const <String, String>{}
          : <String, String>{base: p.join(base, 'LICENSE')},
    );
    for (final c in found) {
      crates[c.id] = c;
    }
  }
  return result..addAll(crates.values);
}

/// The root of pub package [name] as resolved for this workspace.
String pubPackageRoot(String name) {
  final config = jsonDecode(
    File(p.join(_root, '.dart_tool', 'package_config.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  final Map<String, Object?> pkg = (config['packages']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .firstWhere(
        (Map<String, Object?> e) => e['name'] == name,
        orElse: () => throw StateError(
          '$name is not in .dart_tool/package_config.json (run flutter pub get)',
        ),
      );
  final Uri uri = Uri.parse(pkg['rootUri']! as String);
  return uri.isAbsolute
      ? uri.toFilePath()
      : p.normalize(p.join(_root, '.dart_tool', uri.toFilePath()));
}
