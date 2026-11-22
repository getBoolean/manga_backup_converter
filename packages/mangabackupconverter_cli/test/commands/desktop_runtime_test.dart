@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:desktop_webview/desktop_webview.dart';
import 'package:mangabackupconverter_cli/src/commands/desktop_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:test/scaffolding.dart';

/// M1: a compiled CLI never uses development layouts planted in a parent
/// folder (a `tachi-runtime.json` whose `java`/`classpath`, or a helper
/// manifest whose binary, would run as the victim).
void main() {
  late Directory temp;
  late Directory shared;
  late String javaExe;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mbc_dev_layout_');
    // A folder another local user can write to, holding a planted checkout
    // layout: workspace markers, a helper manifest and a Tachi install.
    shared = Directory(p.join(temp.path, 'shared'));
    _markRepository(shared);
    File(
      p.join(shared.path, 'packages', 'desktop_webview', 'build', 'helper', RuntimeArtifactManifest.fileName),
    ).createSync(recursive: true);
    final install = Directory(p.join(shared.path, tachiWorkerDevelopmentInstall));
    Directory(p.join(install.path, 'lib')).createSync(recursive: true);
    javaExe = p.join(temp.path, 'evil', 'bin', Platform.isWindows ? 'java.exe' : 'java');
    File(javaExe).createSync(recursive: true);
    File(p.join(install.path, 'tachi-runtime.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'format': 1,
        'worker': 'tachi-jvm',
        'java': javaExe,
        'classpath': 'lib',
        'handshakeDeadlineMs': 1000,
      }),
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('a compiled CLI below a planted layout uses no development layout', () {
    // A released bundle unpacked below the planted folder (no runtime/).
    final String exe = p.join(shared.path, 'downloads', 'cli', 'bin', 'mangabackupconverter_cli');
    File(exe).createSync(recursive: true);

    final Directory? root = developmentRepositoryRoot(script: exe, environment: const <String, String>{});
    check(root).isNull();
    check(locateWebViewHelperManifest(developmentRoot: root, executable: exe)).isNull();
    final SourceOutcome<TachiWorkerLocation> tachi = TachiWorkerLocation.resolve(
      developmentRoot: root,
      handshakeDeadline: const Duration(seconds: 1),
      environment: const <String, String>{},
    );
    check(tachi).isA<SourceFailed<TachiWorkerLocation>>();
    check((tachi as SourceFailed<TachiWorkerLocation>).failure.message).not((it) => it.contains(javaExe));
  });

  test('a source run stops at its own checkout and never reads the planted parent layout', () {
    // The user's own checkout lives below the planted folder.
    final checkout = Directory(p.join(shared.path, 'home', 'checkout'));
    _markRepository(checkout);
    final String script = p.join(checkout.path, 'packages', 'mangabackupconverter_cli', 'bin', 'cli.dart');
    File(script).createSync(recursive: true);

    final Directory? root = developmentRepositoryRoot(script: script, environment: const <String, String>{});
    check(root?.path).equals(checkout.absolute.path);
    // The checkout has no build outputs; the planted ones above it are ignored.
    check(locateWebViewHelperManifest(developmentRoot: root, executable: script)).isNull();
    check(
      TachiWorkerLocation.resolve(
        developmentRoot: root,
        handshakeDeadline: const Duration(seconds: 1),
        environment: const <String, String>{},
      ),
    ).isA<SourceFailed<TachiWorkerLocation>>();
  });

  test('a source run outside any checkout finds none', () {
    final String script = p.join(temp.path, 'scratch', 'cli.dart');
    File(script).createSync(recursive: true);
    check(developmentRepositoryRoot(script: script, environment: const <String, String>{})).isNull();
  });

  test('an explicit development root is used as given, with no search', () {
    final Directory? root = developmentRepositoryRoot(
      script: p.join(temp.path, 'bin', 'mangabackupconverter_cli'),
      environment: <String, String>{developmentRootVariable: shared.path},
    );
    check(root?.path).equals(p.normalize(shared.absolute.path));
    check(locateWebViewHelperManifest(developmentRoot: root, executable: p.join(temp.path, 'x'))?.path).equals(
      p.join(shared.path, 'packages', 'desktop_webview', 'build', 'helper', RuntimeArtifactManifest.fileName),
    );
  });
}

void _markRepository(Directory dir) {
  File(p.join(dir.path, 'pubspec.yaml')).createSync(recursive: true);
  File(p.join(dir.path, 'packages', 'mangabackupconverter_cli', 'pubspec.yaml')).createSync(recursive: true);
}
