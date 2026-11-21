// ignore_for_file: avoid_print
// Builds the desktop CLI package for this host (U8): the `dart build cli`
// bundle plus the runtime it needs, so the package runs with no system Java,
// Dart, Gradle or Rust.
//
//   dart run scripts/package_cli.dart [--out <dir>] [--cache <dir>] [--offline-gradle]
//
// Output (default build/package/<os>-<arch>/):
//   bin/        the CLI executable (also the Paperback worker: `__paperback-worker`)
//   lib/        native code assets from `dart build cli` (QuickJS, wasm3, scraper, ...)
//   runtime/tachi/            the JVM worker (installDist) and tachi-runtime.json
//   runtime/jre/              Corretto 21 jlinked from the pinned archive
//   runtime/desktop_webview/  the WebView helper (cargo --release) and its manifest
//   runtime/runtime-manifest.json  every shipped file's SHA-256, the JRE pin, host commit
//   licenses/   licence and notice files
//
// The JDK archive is downloaded once into the cache (default
// build/runtime-cache/, git-ignored) and checked against
// tools/tachi-source-runner/runtime/jre-pins.json. Nothing here downloads an
// extension, a repository or a source artifact: those stay the user's.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

final String _root = p.normalize(
  p.join(p.dirname(Platform.script.toFilePath()), '..'),
);

String get _os => Platform.operatingSystem;

String get _arch {
  final String v = Platform.version;
  if (v.contains('arm64')) return 'arm64';
  if (v.contains('x64')) return 'x64';
  throw StateError('Unsupported host architecture: $v');
}

String get _exe => Platform.isWindows ? '.exe' : '';

/// The `dart build cli` bundle directory name for this host.
String get _cliTarget => '${_os}_$_arch';

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    final int i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final out = Directory(
    option('--out', p.join(_root, 'build', 'package', '$_os-$_arch')),
  );
  final cache = Directory(
    option('--cache', p.join(_root, 'build', 'runtime-cache')),
  );
  final bool offlineGradle = args.contains('--offline-gradle');

  if (out.existsSync()) out.deleteSync(recursive: true);
  out.createSync(recursive: true);
  cache.createSync(recursive: true);

  print('== dart build cli');
  final String cli = p.join(_root, 'packages', 'mangabackupconverter_cli');
  await _run(Platform.resolvedExecutable, <String>['build', 'cli'], cwd: cli);
  final bundle = Directory(p.join(cli, 'build', 'cli', _cliTarget, 'bundle'));
  await _copyTree(bundle, out);

  print('== Tachi worker (installDist)');
  final String runner = p.join(_root, 'tools', 'tachi-source-runner');
  final String gradle = p.join(
    runner,
    Platform.isWindows ? 'gradlew.bat' : 'gradlew',
  );
  final String jdk = _buildJdk();
  await _run(
    gradle,
    <String>[if (offlineGradle) '--offline', 'installDist'],
    cwd: runner,
    environment: <String, String>{'JAVA_HOME': jdk},
  );
  final install = Directory(
    p.join(runner, 'build', 'install', 'tachi-source-runner'),
  );
  final tachiOut = Directory(p.join(out.path, 'runtime', 'tachi'));
  await _copyTree(
    Directory(p.join(install.path, 'lib')),
    Directory(p.join(tachiOut.path, 'lib')),
  );
  final devManifest = jsonDecode(
    File(p.join(install.path, 'tachi-runtime.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  // The packaged manifest points at the bundled JRE, relative to itself.
  final packagedManifest = <String, Object?>{
    ...devManifest,
    'java': p.join('..', 'jre', 'bin', 'java$_exe').replaceAll(r'\', '/'),
    'classpath': 'lib',
  };
  File(p.join(tachiOut.path, 'tachi-runtime.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(packagedManifest)}\n',
  );

  print('== JRE (jlink from the pinned Corretto archive)');
  final pins = jsonDecode(
    File(p.join(runner, 'runtime', 'jre-pins.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  final Map<String, Object?> archive = (pins['archives']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .firstWhere(
        (Map<String, Object?> a) => a['os'] == _os && a['arch'] == _arch,
        orElse: () => throw StateError(
          'No pinned JDK archive for $_os-$_arch in jre-pins.json',
        ),
      );
  final File archiveFile = await _download(
    Uri.parse(archive['url']! as String),
    archive['sha256']! as String,
    cache,
  );
  final String extractedJdk = await _extractJdk(archiveFile, cache);
  final String jreOut = p.join(out.path, 'runtime', 'jre');
  await _run(p.join(extractedJdk, 'bin', 'jlink$_exe'), <String>[
    '--module-path',
    p.join(extractedJdk, 'jmods'),
    '--add-modules',
    (pins['modules']! as List<Object?>).join(','),
    '--strip-debug',
    '--no-header-files',
    '--no-man-pages',
    '--compress',
    'zip-6',
    '--output',
    jreOut,
  ]);
  final ProcessResult version = await Process.run(
    p.join(jreOut, 'bin', 'java$_exe'),
    <String>['-version'],
  );
  final String javaVersion = (version.stderr as String)
      .split('\n')
      .first
      .trim();
  print('   $javaVersion');

  print('== desktop WebView helper (cargo --release)');
  final helperBuild = Directory(p.join(_root, 'build', 'package-helper'));
  if (helperBuild.existsSync()) helperBuild.deleteSync(recursive: true);
  await _run(Platform.resolvedExecutable, <String>[
    'run',
    'tool/build_helper.dart',
    '--release',
    '--out',
    helperBuild.path,
  ], cwd: p.join(_root, 'packages', 'desktop_webview'));
  final helperOut = Directory(p.join(out.path, 'runtime', 'desktop_webview'));
  await _copyTree(helperBuild, helperOut);

  print('== licences and notices');
  final licenses = Directory(p.join(out.path, 'licenses'))
    ..createSync(recursive: true);
  final copies = <String, String>{
    'LICENSE.md': 'LICENSE.md',
    'tools/tachi-source-runner/THIRD_PARTY.md':
        'tachi-source-runner-THIRD_PARTY.md',
    'packages/quickjs/vendor/quickjs/LICENSE': 'quickjs-ng-LICENSE',
    'packages/wasm3/vendor/wasm3/LICENSE': 'wasm3-LICENSE',
    'packages/paperback_plugin_loader/assets/paperback_host_lib.LICENSES.txt':
        'paperback-host-lib-LICENSES.txt',
  };
  final missing = <String>[];
  for (final MapEntry<String, String> c in copies.entries) {
    final source = File(p.join(_root, c.key));
    if (source.existsSync()) {
      source.copySync(p.join(licenses.path, c.value));
    } else {
      missing.add(c.key);
    }
  }
  File(p.join(licenses.path, 'desktop_webview_helper-crates.txt'))
      .writeAsStringSync(await _crateLicenses());
  File(p.join(licenses.path, 'NOTICE.md'))
      .writeAsStringSync(_notice(javaVersion, pins));
  if (missing.isNotEmpty) print('   missing licence sources: $missing');

  print('== runtime manifest');
  final manifest = <String, Object?>{
    'format': 1,
    'os': _os,
    'arch': _arch,
    'hostCommit': await _git(<String>['rev-parse', 'HEAD']),
    'hostDirty': (await _git(<String>['status', '--porcelain'])).isNotEmpty,
    'jre': <String, Object?>{
      'vendor': pins['vendor'],
      'version': pins['version'],
      'securityFloor': pins['securityFloor'],
      'javaVersion': javaVersion,
      'archiveUrl': archive['url'],
      'archiveSha256': archive['sha256'],
      'modules': pins['modules'],
    },
    'files': await _hashTree(out),
  };
  File(p.join(out.path, 'runtime', 'runtime-manifest.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  _checkNoFixtures(out);
  print('Package written to ${out.path}');
}

/// A JDK for Gradle: TACHI_JAVA_HOME, the documented Corretto install, then
/// JAVA_HOME (the floor applies; Gradle's toolchain also checks it).
String _buildJdk() {
  for (final home in <String?>[
    Platform.environment['TACHI_JAVA_HOME'],
    if (Platform.isWindows) r'C:\Program Files\Amazon Corretto\jdk21.0.13_1',
    Platform.environment['JAVA_HOME'],
  ]) {
    if (home != null && File(p.join(home, 'bin', 'java$_exe')).existsSync()) {
      return home;
    }
  }
  throw StateError('No JDK 21 for the Gradle build (set TACHI_JAVA_HOME)');
}

Future<void> _run(
  String executable,
  List<String> args, {
  String? cwd,
  Map<String, String>? environment,
}) async {
  final Process process = await Process.start(
    executable,
    args,
    workingDirectory: cwd,
    environment: environment,
    runInShell: Platform.isWindows && executable.endsWith('.bat'),
    mode: ProcessStartMode.inheritStdio,
  );
  final int code = await process.exitCode;
  if (code != 0) {
    throw StateError(
      '$executable ${args.join(' ')} failed with exit code $code',
    );
  }
}

Future<String> _git(List<String> args) async {
  final ProcessResult r = await Process.run(
    'git',
    args,
    workingDirectory: _root,
  );
  return (r.stdout as String).trim();
}

/// Downloads [url] into [cache] once; the file must hash to [sha256].
Future<File> _download(Uri url, String sha256, Directory cache) async {
  final file = File(p.join(cache.path, url.pathSegments.last));
  if (!file.existsSync() || _sha256(file) != sha256) {
    print('   downloading $url');
    final client = HttpClient();
    try {
      final HttpClientResponse response = await (await client.getUrl(url))
          .close();
      if (response.statusCode != 200) {
        throw StateError('GET $url: HTTP ${response.statusCode}');
      }
      final partial = File('${file.path}.part');
      await response.pipe(partial.openWrite());
      partial.renameSync(file.path);
    } finally {
      client.close();
    }
  }
  final String actual = _sha256(file);
  if (actual != sha256) {
    file.deleteSync();
    throw StateError(
      '${file.path} has SHA-256 $actual; jre-pins.json pins $sha256',
    );
  }
  print('   ${p.basename(file.path)} sha256 ok');
  return file;
}

String _sha256(File f) => crypto.sha256.convert(f.readAsBytesSync()).toString();

/// Extracts the JDK archive once into the cache; returns the JDK home.
Future<String> _extractJdk(File archive, Directory cache) async {
  final dest = Directory(
    p.join(cache.path, '${p.basenameWithoutExtension(archive.path)}-extracted'),
  );
  if (!dest.existsSync()) {
    final tmp = Directory('${dest.path}.tmp');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    await extractFileToDisk(archive.path, tmp.path);
    tmp.renameSync(dest.path);
  }
  // The JDK home is the directory holding bin/java (macOS: Contents/Home).
  for (final FileSystemEntity e in dest.listSync(recursive: true)) {
    if (e is File &&
        p.basename(e.path) == 'jlink$_exe' &&
        p.basename(p.dirname(e.path)) == 'bin') {
      final String home = p.dirname(p.dirname(e.path));
      if (!Platform.isWindows) {
        await Process.run('chmod', <String>['-R', 'u+x', p.join(home, 'bin')]);
      }
      return home;
    }
  }
  throw StateError('No jlink in ${archive.path}');
}

Future<void> _copyTree(Directory from, Directory to) async {
  if (!from.existsSync()) throw StateError('Missing build output ${from.path}');
  for (final FileSystemEntity e in from.listSync(recursive: true)) {
    final String target = p.join(to.path, p.relative(e.path, from: from.path));
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      e.copySync(target);
    }
  }
}

/// SHA-256 of every file under [dir], keyed by its `/`-separated relative path.
Future<Map<String, String>> _hashTree(Directory dir) async {
  final files = <String, String>{};
  final List<File> all =
      dir.listSync(recursive: true).whereType<File>().toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final f in all) {
    final String rel = p.relative(f.path, from: dir.path).replaceAll(r'\', '/');
    if (rel == 'runtime/runtime-manifest.json') continue;
    files[rel] = _sha256(f);
  }
  return files;
}

/// The helper's crates and their declared licences (`cargo metadata`).
Future<String> _crateLicenses() async {
  final ProcessResult r = await Process.run('cargo', <String>[
    'metadata',
    '--locked',
    '--format-version',
    '1',
    '--manifest-path',
    p.join(_root, 'packages', 'desktop_webview', 'helper', 'Cargo.toml'),
  ]);
  if (r.exitCode != 0) return 'cargo metadata failed: ${r.stderr}\n';
  final meta = jsonDecode(r.stdout as String) as Map<String, Object?>;
  final lines = <String>[
    'Crates linked into desktop_webview_helper (from helper/Cargo.lock), with their declared licences.',
    "Every target platform is listed; only the host platform's crates are linked into this build.",
    '',
  ];
  final List<Map<String, Object?>> packages =
      (meta['packages']! as List<Object?>).cast<Map<String, Object?>>()..sort(
        (Map<String, Object?> a, Map<String, Object?> b) =>
            (a['name']! as String).compareTo(b['name']! as String),
      );
  for (final pkg in packages) {
    lines.add(
      '${pkg['name']} ${pkg['version']}: ${pkg['license'] ?? pkg['license_file'] ?? 'UNDECLARED'}',
    );
  }
  return '${lines.join('\n')}\n';
}

String _notice(String javaVersion, Map<String, Object?> pins) =>
    '''
# Third-party components in this package

| Component | Where | Licence |
|---|---|---|
| Amazon Corretto $javaVersion (jlinked) | `runtime/jre/` | ${pins['license']}; texts in `runtime/jre/legal/` |
| Tachi source runner and its JVM libraries | `runtime/tachi/lib/` | see `tachi-source-runner-THIRD_PARTY.md` |
| desktop_webview_helper (wry, tao and their crates) | `runtime/desktop_webview/` | MIT (helper); crates in `desktop_webview_helper-crates.txt` |
| QuickJS-ng | `lib/` (native asset) | MIT, `quickjs-ng-LICENSE` |
| wasm3 | `lib/` (native asset) | MIT, `wasm3-LICENSE` |
| Paperback host library (Cheerio and its dependencies) | inside the CLI executable | `paperback-host-lib-LICENSES.txt` |

No extension, repository or source artifact is bundled: repositories, extensions and
settings are always supplied by the user.

Platform WebView prerequisites are not bundled: WebView2 Runtime on Windows (preinstalled on
Windows 11), WebKitGTK 4.1 on Linux, WKWebView on macOS (part of the OS).
''';

/// Fails if anything from the repository's test fixtures was copied.
void _checkNoFixtures(Directory out) {
  final bad = <String>[
    for (final FileSystemEntity e in out.listSync(recursive: true))
      if (e is File &&
          (e.path.contains('${p.separator}fixtures${p.separator}') ||
              e.path.endsWith('.aix') ||
              p.basename(e.path).startsWith('tachiyomi-')))
        e.path,
  ];
  if (bad.isNotEmpty) throw StateError('Test fixtures in the package: $bad');
}
