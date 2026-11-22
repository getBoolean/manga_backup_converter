/// Build specification for the vendored QuickJS-ng engine (KTD24).
///
/// Pure Dart with no FFI imports so `hook/build.dart` and the hook tests can
/// share one definition of the supported targets, sources and flags.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';

/// The QuickJS-ng commit the `vendor/quickjs` submodule is pinned to: v0.18.0
/// plus the use-after-free fixes that followed it (KTD1's security-update
/// rule). Bump together with the submodule gitlink; the hook refuses a
/// checkout at any other commit.
const String quickJsPinnedCommit = 'dce8c0bb3b5ddbfbae05c4cd5c1345b05719c0df';

/// Reads the commit checked out in the submodule at [submoduleDir] without
/// spawning git: follows `.git` (a `gitdir:` file in a submodule) to `HEAD`.
/// Returns `null` when there is no git metadata (for example a source copy).
String? readSubmoduleCommit(Directory submoduleDir) {
  final dotGit = File('${submoduleDir.path}/.git');
  final Directory gitDir;
  if (dotGit.existsSync()) {
    final String text = dotGit.readAsStringSync().trim();
    if (!text.startsWith('gitdir:')) return null;
    final String target = text.substring('gitdir:'.length).trim();
    final bool absolute = target.startsWith('/') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(target);
    gitDir = absolute ? Directory(target) : Directory('${submoduleDir.path}/$target');
  } else if (Directory('${submoduleDir.path}/.git').existsSync()) {
    gitDir = Directory('${submoduleDir.path}/.git');
  } else {
    return null;
  }
  final head = File('${gitDir.path}/HEAD');
  if (!head.existsSync()) return null;
  final String ref = head.readAsStringSync().trim();
  if (!ref.startsWith('ref:')) return ref;
  final refFile = File('${gitDir.path}/${ref.substring(4).trim()}');
  return refFile.existsSync() ? refFile.readAsStringSync().trim() : null;
}

/// Vendored engine sources, relative to the package root. No `quickjs-libc.c`:
/// source code must never get the `std`/`os` modules (KTD6).
const List<String> quickJsEngineSources = <String>[
  'vendor/quickjs/dtoa.c',
  'vendor/quickjs/libregexp.c',
  'vendor/quickjs/libunicode.c',
  'vendor/quickjs/quickjs.c',
];

/// The Dart FFI wrapper, compiled into the same library.
const List<String> quickJsWrapperSources = <String>['src/quickjs_dart.c'];

/// Include directories, relative to the package root.
const List<String> quickJsIncludes = <String>['vendor/quickjs/', 'src/'];

/// Every (OS, architecture) pair the package advertises.
///
/// Android x86 (`ia32`) is not advertised until it is built and run (KTD24).
const Map<OS, Set<Architecture>> quickJsSupportedTargets = <OS, Set<Architecture>>{
  OS.android: <Architecture>{Architecture.arm, Architecture.arm64, Architecture.x64},
  OS.iOS: <Architecture>{Architecture.arm64, Architecture.x64},
  OS.macOS: <Architecture>{Architecture.arm64, Architecture.x64},
  OS.linux: <Architecture>{Architecture.arm64, Architecture.x64},
  OS.windows: <Architecture>{Architecture.arm64, Architecture.x64},
};

/// Thrown by the hook for a target the package does not advertise, so the
/// build fails instead of the first source call.
final class UnsupportedQuickJsTarget implements Exception {
  const UnsupportedQuickJsTarget(this.os, this.architecture);

  final OS os;
  final Architecture architecture;

  @override
  String toString() =>
      'UnsupportedQuickJsTarget: quickjs is not built for $os/$architecture. '
      'Supported targets: $quickJsSupportedTargets';
}

/// Compiler settings for one target.
final class QuickJsTargetConfig {
  const QuickJsTargetConfig({required this.defines, required this.flags, required this.libraries, this.std});

  final Map<String, String?> defines;
  final List<String> flags;
  final List<String> libraries;
  final String? std;
}

/// Returns the compiler settings for [os]/[architecture], or throws
/// [UnsupportedQuickJsTarget].
QuickJsTargetConfig quickJsTargetConfig(OS os, Architecture architecture) {
  final Set<Architecture>? arches = quickJsSupportedTargets[os];
  if (arches == null || !arches.contains(architecture)) {
    throw UnsupportedQuickJsTarget(os, architecture);
  }
  final windows = os == OS.windows;
  return QuickJsTargetConfig(
    defines: <String, String?>{
      '_GNU_SOURCE': null,
      if (windows) ...<String, String?>{
        'WIN32_LEAN_AND_MEAN': null,
        '_WIN32_WINNT': '0x0602',
        '_CRT_SECURE_NO_WARNINGS': null,
      },
    },
    // MSVC: QuickJS-ng needs C11 atomics, which cl.exe gates behind an
    // experimental switch. Clang/GCC: the CMake build's GNU C11 mode.
    std: windows ? 'c11' : 'gnu11',
    flags: <String>[
      if (windows) ...<String>['/experimental:c11atomics', '/wd4996', '/wd4244', '/wd4267', '/wd4018'],
      if (!windows) ...<String>['-funsigned-char', '-Wno-implicit-fallthrough', '-Wno-sign-compare'],
    ],
    libraries: <String>[
      if (os == OS.linux || os == OS.android) 'm',
      if (os == OS.linux) 'pthread',
      // The former fork's 32-bit ARM fixes are not needed: QuickJS-ng enables
      // NaN boxing for 32-bit targets itself, and its armv7 build references
      // no `__atomic_*` helpers, so `-latomic` is not linked.
    ],
  );
}
