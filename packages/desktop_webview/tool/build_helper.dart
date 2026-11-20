// Builds desktop_webview_helper with cargo (`--locked`, so the committed
// Cargo.lock is the dependency pin) and records it in the runtime artifact
// manifest. Run by the package tests and by desktop packaging (U8).
//
//   dart run tool/build_helper.dart [--release] [--target <rust-triple>] [--out <dir>]
//
// Output: <out>/<os>-<arch>/desktop_webview_helper[.exe] and
// <out>/runtime-artifacts.json (default <out>: build/helper).
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:desktop_webview/desktop_webview.dart';
import 'package:path/path.dart' as p;

/// Result of [buildHelper].
final class HelperBuild {
  const HelperBuild(this.manifestFile, this.artifact);

  final File manifestFile;
  final RuntimeArtifact artifact;
}

/// Thrown when cargo is missing or the build fails.
final class HelperBuildException implements Exception {
  const HelperBuildException(this.message);

  final String message;

  @override
  String toString() => 'HelperBuildException: $message';
}

/// Maps a Rust target triple to the manifest's `os` and `arch`.
(String, String) platformOfTriple(String triple) {
  final String os;
  if (triple.contains('windows')) {
    os = 'windows';
  } else if (triple.contains('apple-darwin')) {
    os = 'macos';
  } else if (triple.contains('linux')) {
    os = 'linux';
  } else {
    throw HelperBuildException('unsupported target $triple');
  }
  final String arch = triple.startsWith('aarch64')
      ? 'arm64'
      : (triple.startsWith('x86_64') ? 'x64' : triple.split('-').first);
  return (os, arch);
}

/// Host triple, from `rustc -vV`.
Future<String> hostTriple() async {
  final ProcessResult r = await Process.run('rustc', <String>['-vV']);
  if (r.exitCode != 0) throw HelperBuildException('rustc -vV failed: ${r.stderr}');
  for (final String line in (r.stdout as String).split('\n')) {
    if (line.startsWith('host: ')) return line.substring('host: '.length).trim();
  }
  throw const HelperBuildException('cannot read the host triple from rustc -vV');
}

/// Builds the helper for [target] (default: host) and updates the manifest
/// in [outDir]. [packageDir] is `packages/desktop_webview`.
Future<HelperBuild> buildHelper({
  required Directory packageDir,
  bool release = false,
  String? target,
  Directory? outDir,
  void Function(String line)? log,
}) async {
  final String crate = p.join(packageDir.path, 'helper');
  final String triple = target ?? await hostTriple();
  final (String os, String arch) = platformOfTriple(triple);
  final args = <String>[
    'build',
    '--locked',
    '--manifest-path',
    p.join(crate, 'Cargo.toml'),
    '--target',
    triple,
    if (release) '--release',
  ];
  log?.call('cargo ${args.join(' ')}');
  final ProcessResult r;
  try {
    r = await Process.run('cargo', args);
  } on ProcessException catch (e) {
    throw HelperBuildException('cargo is not available: ${e.message}');
  }
  if (r.exitCode != 0) throw HelperBuildException('cargo build failed (${r.exitCode}):\n${r.stderr}');

  final exe = os == 'windows' ? 'desktop_webview_helper.exe' : 'desktop_webview_helper';
  final built = File(p.join(crate, 'target', triple, release ? 'release' : 'debug', exe));
  final Directory out = outDir ?? Directory(p.join(packageDir.path, 'build', 'helper'));
  final dest = File(p.join(out.path, '$os-$arch', exe));
  await dest.parent.create(recursive: true);
  final builtSha = crypto.sha256.convert(await built.readAsBytes()).toString();
  // A running helper (another test file, a live conversion) locks its binary
  // on Windows: only replace it when the bytes changed.
  if (!dest.existsSync() || crypto.sha256.convert(await dest.readAsBytes()).toString() != builtSha) {
    await built.copy(dest.path);
  }
  if (os != 'windows') await Process.run('chmod', <String>['+x', dest.path]);

  final String cargoToml = File(p.join(crate, 'Cargo.toml')).readAsStringSync();
  final String version = RegExp('^version = "([^"]+)"', multiLine: true).firstMatch(cargoToml)?.group(1) ?? 'unknown';
  final artifact = RuntimeArtifact(
    name: RuntimeArtifactManifest.webviewHelper,
    os: os,
    arch: arch,
    path: '$os-$arch/$exe',
    sha256: builtSha,
    version: version,
    target: triple,
  );
  final manifestFile = File(p.join(out.path, RuntimeArtifactManifest.fileName));
  final current = manifestFile.existsSync()
      ? RuntimeArtifactManifest.load(manifestFile)
      : const RuntimeArtifactManifest(<RuntimeArtifact>[]);
  await manifestFile.writeAsString(current.withArtifact(artifact).encode());
  return HelperBuild(manifestFile, RuntimeArtifactManifest.load(manifestFile).find(artifact.name, os: os, arch: arch)!);
}

Future<void> main(List<String> argv) async {
  var release = false;
  String? target;
  String? out;
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--release':
        release = true;
      case '--target':
        target = argv[++i];
      case '--out':
        out = argv[++i];
      default:
        stderr.writeln('usage: dart run tool/build_helper.dart [--release] [--target <triple>] [--out <dir>]');
        exit(64);
    }
  }
  final packageDir = Directory(p.dirname(p.dirname(Platform.script.toFilePath())));
  try {
    final HelperBuild b = await buildHelper(
      packageDir: packageDir,
      release: release,
      target: target,
      outDir: out == null ? null : Directory(out),
      log: stdout.writeln,
    );
    stdout.writeln('built ${b.artifact.file.path} (sha256 ${b.artifact.sha256})');
    stdout.writeln('manifest ${b.manifestFile.path}');
  } on HelperBuildException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}
