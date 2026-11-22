// Regenerates lib/src/bindings/ from the pinned Jsoup Maven artifact.
//
// Run through `dart run tool/generate_jni_bindings.dart` (or
// `melos run jnigen`), which puts a JDK on PATH first. Running this file
// directly works when JAVA_HOME already points at a JDK 17+.

import 'dart:io';

import 'package:jnigen/jnigen.dart';
import 'package:jsoup_jni/src/jsoup_version.dart';

/// Classes `JsoupParser` calls. `LeafNode` is listed so `TextNode` implements
/// `Node` in the generated extension types instead of an empty stub.
const List<String> _classes = <String>[
  'org.jsoup.Jsoup',
  'org.jsoup.nodes.Document',
  'org.jsoup.nodes.Element',
  'org.jsoup.nodes.LeafNode',
  'org.jsoup.nodes.Node',
  'org.jsoup.nodes.TextNode',
  'org.jsoup.select.Elements',
];

Future<void> main() async {
  final Uri packageRoot = Platform.script.resolve('../');
  await JniGenerator(
    input: Input(
      classes: _classes,
      mavenDownloads: MavenDownloads(
        sourceDeps: <String>['org.jsoup:jsoup:$jsoupVersion'],
        sourceDir: packageRoot.resolve('mvn_java/'),
        jarOnlyDeps: <String>['org.jspecify:jspecify:1.0.0'],
        jarDir: packageRoot.resolve('mvn_jar/'),
      ),
    ),
    output: Output(dart: DartOutput(path: packageRoot.resolve('lib/src/bindings/'))),
  ).generate();
}
