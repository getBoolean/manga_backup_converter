// Helpers shared by the desktop packaging scripts (package_cli.dart and
// smoke_packaged_cli.dart).
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

/// Parses [args] with [parser] (which gains `--help`); prints the usage and
/// exits 0 for `--help`, or 64 for an unknown or malformed option.
ArgResults parseScriptArgs(ArgParser parser, List<String> args, String usage) {
  parser.addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');
  try {
    final ArgResults results = parser.parse(args);
    if (!results.flag('help')) return results;
    stdout.writeln('$usage\n\n${parser.usage}');
    exit(0);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$usage\n\n${parser.usage}');
    exit(64);
  }
}

/// The repository root (the scripts live in `<root>/scripts/`).
final String repoRoot = p.normalize(
  p.join(p.dirname(Platform.script.toFilePath()), '..'),
);

/// This host's architecture as the package names it.
String get hostArch {
  final String v = Platform.version;
  if (v.contains('arm64')) return 'arm64';
  if (v.contains('x64')) return 'x64';
  throw StateError('Unsupported host architecture: $v');
}

/// The default package directory for this host, `build/package/<os>-<arch>`.
String get defaultPackageDir => p.join(
  repoRoot,
  'build',
  'package',
  '${Platform.operatingSystem}-$hostArch',
);

/// The executable suffix on this host.
String get exeSuffix => Platform.isWindows ? '.exe' : '';

/// The SHA-256 of [file], hex.
String sha256Of(File file) =>
    crypto.sha256.convert(file.readAsBytesSync()).toString();

/// Copies every file under [from] into [to], keeping relative paths; throws
/// [StateError] with [missing] when [from] does not exist.
void copyTree(Directory from, Directory to, {required String missing}) {
  if (!from.existsSync()) throw StateError(missing);
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
