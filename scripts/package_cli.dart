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

import 'licenses/notices.dart';

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

  final String runner = p.join(_root, 'tools', 'tachi-source-runner');
  print('== pinned Corretto JDK');
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

  print('== Tachi worker (installDist)');
  final String gradle = p.join(
    runner,
    Platform.isWindows ? 'gradlew.bat' : 'gradlew',
  );
  final String jdk = _buildJdk(extractedJdk);
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
  final nativeLibs = <String>[
    for (final FileSystemEntity e in Directory(
      p.join(out.path, 'lib'),
    ).listSync())
      if (e is File) p.basename(e.path),
  ];
  for (final MapEntry<String, String?> l in _nativeLicences(
    nativeLibs,
  ).entries) {
    if (l.value == null) {
      missing.add(l.key);
    } else {
      File(l.value!).copySync(p.join(licenses.path, l.key));
    }
  }
  for (final (String label, String manifest) in _rustTrees) {
    // The scraper bridge is bundled only where jsoup uses it (not macOS).
    if (label == 'scraper_bridge' &&
        !nativeLibs.any((String l) => l.contains('scraper'))) {
      continue;
    }
    File(
      p.join(licenses.path, '$label-crates.txt'),
    ).writeAsStringSync(await _crateLicenses(label, manifest, licenses));
  }
  File(p.join(licenses.path, 'NOTICE.md'))
      .writeAsStringSync(_notice(javaVersion, pins, nativeLibs));
  if (missing.isNotEmpty) throw StateError('Missing licence sources: $missing');

  if (Platform.isMacOS) {
    print('== macOS code signatures (local runs; no distribution signing)');
    print('   ${await _macosSignatures(out)}');
  }

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

/// A JDK for Gradle: TACHI_JAVA_HOME, the documented Windows Corretto
/// install, then the pinned Corretto JDK the package's JRE is jlinked from
/// ([pinned]; it is at the security floor by construction). JAVA_HOME is not
/// used: it may be any version.
String _buildJdk(String pinned) {
  for (final home in <String?>[
    Platform.environment['TACHI_JAVA_HOME'],
    if (Platform.isWindows) r'C:\Program Files\Amazon Corretto\jdk21.0.13_1',
    pinned,
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

/// Apple silicon refuses to run unsigned code: every Mach-O file must carry a
/// valid signature. Vendor and linker (ad-hoc) signatures are kept; a file
/// whose signature does not verify is signed ad hoc (`codesign -s -`). Any
/// quarantine attribute is removed. No Developer ID signing or notarization.
Future<String> _macosSignatures(Directory out) async {
  var machO = 0;
  final resigned = <String>[];
  for (final File f in out.listSync(recursive: true).whereType<File>()) {
    final ProcessResult kind = await Process.run('file', <String>[
      '-b',
      f.path,
    ]);
    if (!(kind.stdout as String).startsWith('Mach-O')) continue;
    machO++;
    final ProcessResult verify = await Process.run('codesign', <String>[
      '-v',
      f.path,
    ]);
    if (verify.exitCode == 0) continue;
    final ProcessResult sign = await Process.run('codesign', <String>[
      '-s',
      '-',
      '-f',
      f.path,
    ]);
    if (sign.exitCode != 0) {
      throw StateError('codesign -s - ${f.path}: ${sign.stderr}');
    }
    resigned.add(p.relative(f.path, from: out.path));
  }
  await Process.run('xattr', <String>['-dr', 'com.apple.quarantine', out.path]);
  return '$machO Mach-O files verified; signed ad hoc: ${resigned.isEmpty ? 'none' : resigned.join(', ')}';
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

/// Licence texts for native libraries that `dart build cli` bundled from
/// outside the repository's vendored sources, keyed by their name under
/// `licenses/` (value `null`: not found). SwiftSoup (iOS/macOS jsoup
/// backend) and its Swift packages come from the swiftsoup build hook's SPM
/// checkouts for this host; `objective_c` from its pub package.
Map<String, String?> _nativeLicences(List<String> libs) {
  final result = <String, String?>{};
  if (libs.any((String l) => l.contains('objective_c'))) {
    final config = jsonDecode(
      File(p.join(_root, '.dart_tool', 'package_config.json'))
          .readAsStringSync(),
    ) as Map<String, Object?>;
    final Map<String, Object?>? pkg = (config['packages']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((Map<String, Object?> e) => e['name'] == 'objective_c')
        .firstOrNull;
    final String? license = pkg == null
        ? null
        : p.join(Uri.parse(pkg['rootUri']! as String).toFilePath(), 'LICENSE');
    result['objective_c-LICENSE'] =
        license != null && File(license).existsSync() ? license : null;
  }
  if (libs.any((String l) => l.contains('SwiftSoup'))) {
    final triple = _arch == 'arm64' ? 'arm64' : 'x86_64';
    final build = Directory(
      p.join(
        _root,
        '.dart_tool',
        'hooks_runner',
        'shared',
        'swiftsoup',
        'build',
      ),
    );
    final Directory? checkouts = build.existsSync()
        ? build
              .listSync()
              .whereType<Directory>()
              .where(
                (Directory d) =>
                    p.basename(d.path).startsWith('swiftsoup-macosx-$triple'),
              )
              .map((Directory d) => Directory(p.join(d.path, 'checkouts')))
              .where((Directory d) => d.existsSync())
              .firstOrNull
        : null;
    for (final MapEntry<String, String> f in <String, String>{
      'swiftsoup-LICENSE': 'SwiftSoup/LICENSE',
      'swift-atomics-LICENSE.txt': 'swift-atomics/LICENSE.txt',
      'lrucache-LICENSE.md': 'LRUCache/LICENSE.md',
    }.entries) {
      final String? path = checkouts == null
          ? null
          : p.join(checkouts.path, f.value);
      result[f.key] = path != null && File(path).existsSync() ? path : null;
    }
  }
  return result;
}

/// The Rust trees compiled into the package: the WebView helper executable
/// and the scraper bridge native asset.
const List<(String, String)> _rustTrees = <(String, String)>[
  ('desktop_webview_helper', 'packages/desktop_webview/helper/Cargo.toml'),
  ('scraper_bridge', 'packages/scraper/rust/Cargo.toml'),
];

/// The Rust host triple of this machine.
String get _rustHost => switch ((_os, _arch)) {
  ('windows', 'x64') => 'x86_64-pc-windows-msvc',
  ('windows', 'arm64') => 'aarch64-pc-windows-msvc',
  ('linux', 'x64') => 'x86_64-unknown-linux-gnu',
  ('linux', 'arm64') => 'aarch64-unknown-linux-gnu',
  ('macos', 'arm64') => 'aarch64-apple-darwin',
  ('macos', 'x64') => 'x86_64-apple-darwin',
  _ => throw StateError('No Rust host triple for $_os-$_arch'),
};

/// The crates of [label]'s tree linked for this host
/// (`scripts/licenses/notices.dart`, the mechanism the app notices use too),
/// listed with their declared licences, and each crate's licence texts
/// copied to `licenses/rust/<label>/<crate>-<version>/`: the files the crate
/// publishes, or, for a crate that publishes none, the canonical text of each
/// licence in its SPDX expression (`scripts/licenses/`; MIT with the crate's
/// authors as holders). This repository's own crates get its `LICENSE.md`.
/// Fails when a declared licence has no text.
Future<String> _crateLicenses(
  String label,
  String manifest,
  Directory licenses,
) async {
  final List<Component> crates = await rustComponents(
    root: _root,
    manifest: p.join(_root, manifest),
    triples: <String>[_rustHost],
  );
  final lines = <String>[
    'Crates linked into $label for $_rustHost (from ${p.dirname(manifest)}/Cargo.lock), with their',
    "declared licences. Each crate's licence texts are in rust/$label/<crate>-<version>/.",
    '',
  ];
  for (final crate in crates) {
    final dest = Directory(
      p.join(licenses.path, 'rust', label, '${crate.name}-${crate.version}'),
    )..createSync(recursive: true);
    for (final LicenseText t in crate.texts) {
      final String to = p.join(dest.path, t.fileName);
      if (t.source case final File source) {
        source.copySync(to);
      } else {
        File(to).writeAsStringSync(t.content);
      }
    }
    lines.add(
      '${crate.name} ${crate.version}: ${crate.license} (${crate.origin})',
    );
  }
  return '${lines.join('\n')}\n';
}

String _notice(
  String javaVersion,
  Map<String, Object?> pins,
  List<String> libs,
) {
  bool has(String part) => libs.any((String l) => l.contains(part));
  return '''
# Third-party components in this package

| Component | Where | Licence |
|---|---|---|
| Amazon Corretto $javaVersion (jlinked) | `runtime/jre/` | ${pins['license']}; texts in `runtime/jre/legal/` |
| Tachi source runner and its JVM libraries | `runtime/tachi/lib/` | see `tachi-source-runner-THIRD_PARTY.md` |
| desktop_webview_helper (wry, tao and their crates) | `runtime/desktop_webview/` | MIT (helper); crates in `desktop_webview_helper-crates.txt`, texts in `rust/desktop_webview_helper/` |
| QuickJS-ng | `lib/` (native asset) | MIT, `quickjs-ng-LICENSE` |
| wasm3 | `lib/` (native asset) | MIT, `wasm3-LICENSE` |
${has('scraper') ? '| Rust scraper bridge (scraper 0.25, html5ever) | `lib/scraper_bridge` (native asset) | MIT/Apache-2.0 and MPL-2.0 crates in `scraper_bridge-crates.txt`, texts in `rust/scraper_bridge/` |\n' : ''}${has('SwiftSoup') ? '| SwiftSoup and its Swift packages (swift-atomics, LRUCache) | `lib/libSwiftSoupWrapper.dylib` (native asset) | MIT, Apache-2.0, MIT: `swiftsoup-LICENSE`, `swift-atomics-LICENSE.txt`, `lrucache-LICENSE.md` |\n' : ''}${has('objective_c') ? '| Dart `objective_c` runtime support | `lib/objective_c.dylib` (native asset) | BSD-3-Clause, `objective_c-LICENSE` |\n' : ''}| SQLite | `lib/sqlite3` (native asset, `sqlite3` package) | public domain |
| Paperback host library (Cheerio and its dependencies) | inside the CLI executable | `paperback-host-lib-LICENSES.txt` |

No extension, repository or source artifact is bundled: repositories, extensions and
settings are always supplied by the user.

Platform WebView prerequisites are not bundled: WebView2 Runtime on Windows (preinstalled on
Windows 11), WebKitGTK 4.1 on Linux, WKWebView on macOS (part of the OS).
''';
}

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
