import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Runtime artifact manifest (`runtime-artifacts.json`): where each native
/// runtime binary lives relative to the manifest, and its SHA-256.
///
/// `tool/build_helper.dart` writes it next to the binaries it builds; desktop
/// packaging (U8) ships it beside the CLI. The client launches only a binary
/// whose digest matches its entry.
@immutable
final class RuntimeArtifactManifest {
  const RuntimeArtifactManifest(this.artifacts);

  factory RuntimeArtifactManifest.fromJson(Map<String, Object?> json) {
    if (json['format'] != formatVersion) {
      throw FormatException('Unsupported runtime artifact manifest format ${json['format']} (expected $formatVersion)');
    }
    return RuntimeArtifactManifest(<RuntimeArtifact>[
      for (final Object? a in json['artifacts']! as List<Object?>) RuntimeArtifact.fromJson(a! as Map<String, Object?>),
    ]);
  }

  /// Reads [file]; artifact paths resolve against its directory.
  factory RuntimeArtifactManifest.load(File file) {
    final manifest = RuntimeArtifactManifest.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, Object?>);
    return RuntimeArtifactManifest(<RuntimeArtifact>[
      for (final RuntimeArtifact a in manifest.artifacts) a._withBase(file.parent.path),
    ]);
  }

  static const int formatVersion = 1;
  static const String fileName = 'runtime-artifacts.json';

  /// Artifact name of the WebView helper.
  static const String webviewHelper = 'desktop_webview_helper';

  final List<RuntimeArtifact> artifacts;

  /// The entry for [name] built for [os] and [arch], or `null`.
  RuntimeArtifact? find(String name, {required String os, required String arch}) {
    for (final RuntimeArtifact a in artifacts) {
      if (a.name == name && a.os == os && a.arch == arch) return a;
    }
    return null;
  }

  /// The entry for [name] on the running host, or `null`.
  RuntimeArtifact? findForHost(String name) => find(name, os: hostOs, arch: hostArch);

  /// Returns a manifest with [artifact] replacing any entry with the same
  /// name, OS and architecture.
  RuntimeArtifactManifest withArtifact(RuntimeArtifact artifact) => RuntimeArtifactManifest(<RuntimeArtifact>[
    for (final RuntimeArtifact a in artifacts)
      if (!(a.name == artifact.name && a.os == artifact.os && a.arch == artifact.arch)) a,
    artifact,
  ]);

  Map<String, Object?> toJson() => <String, Object?>{
    'format': formatVersion,
    'artifacts': <Object?>[for (final RuntimeArtifact a in artifacts) a.toJson()],
  };

  String encode() => '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  /// `windows`, `macos` or `linux`.
  static String get hostOs => Platform.operatingSystem;

  /// `x64` or `arm64`, from the Dart VM's ABI.
  static String get hostArch {
    final abi = Abi.current().toString();
    return abi.endsWith('arm64') ? 'arm64' : (abi.endsWith('x64') ? 'x64' : abi.split('_').last);
  }
}

/// One binary in a [RuntimeArtifactManifest].
@immutable
final class RuntimeArtifact {
  const RuntimeArtifact({
    required this.name,
    required this.os,
    required this.arch,
    required this.path,
    required this.sha256,
    this.version,
    this.target,
    this.baseDir,
  });

  factory RuntimeArtifact.fromJson(Map<String, Object?> json) => RuntimeArtifact(
    name: json['name']! as String,
    os: json['os']! as String,
    arch: json['arch']! as String,
    path: json['path']! as String,
    sha256: json['sha256']! as String,
    version: json['version'] as String?,
    target: json['target'] as String?,
  );

  final String name;
  final String os;
  final String arch;

  /// Path relative to the manifest, with `/` separators.
  final String path;

  /// Lowercase hex SHA-256 of the binary.
  final String sha256;
  final String? version;

  /// Rust target triple it was built for.
  final String? target;

  /// Directory the manifest was loaded from (not serialized).
  final String? baseDir;

  RuntimeArtifact _withBase(String dir) => RuntimeArtifact(
    name: name,
    os: os,
    arch: arch,
    path: path,
    sha256: sha256,
    version: version,
    target: target,
    baseDir: dir,
  );

  /// The binary on disk.
  File get file => File(p.normalize(p.join(baseDir ?? '.', path)));

  /// Returns the binary if it exists and matches [sha256], otherwise throws
  /// [RuntimeArtifactException].
  File verifiedFile() {
    final File f = file;
    if (!f.existsSync()) throw RuntimeArtifactException('$name is missing at ${f.path}');
    final actual = crypto.sha256.convert(f.readAsBytesSync()).toString();
    if (actual != sha256) {
      throw RuntimeArtifactException('$name at ${f.path} has SHA-256 $actual, manifest expects $sha256');
    }
    return f;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'os': os,
    'arch': arch,
    'path': path,
    'sha256': sha256,
    if (version != null) 'version': version,
    if (target != null) 'target': target,
  };
}

/// A runtime artifact is missing, unlisted, or does not match its digest.
final class RuntimeArtifactException implements Exception {
  const RuntimeArtifactException(this.message);

  final String message;

  @override
  String toString() => 'RuntimeArtifactException: $message';
}
