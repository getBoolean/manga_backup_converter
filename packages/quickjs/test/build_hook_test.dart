@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:code_assets/code_assets.dart';
import 'package:quickjs/src/quickjs_build_spec.dart';
import 'package:test/scaffolding.dart';

Directory packageDir() {
  if (File('hook/build.dart').existsSync() && File('src/quickjs_dart.c').existsSync()) {
    return Directory.current;
  }
  return Directory('packages/quickjs');
}

String read(String relative) => File('${packageDir().path}/$relative').readAsStringSync();

void main() {
  group('target table', () {
    test('every advertised target has a configuration', () {
      for (final MapEntry<OS, Set<Architecture>> entry in quickJsSupportedTargets.entries) {
        for (final Architecture arch in entry.value) {
          check(quickJsTargetConfig(entry.key, arch).defines).containsKey('_GNU_SOURCE');
        }
      }
    });

    test('an unadvertised target fails the build, not the first call', () {
      check(
        () => quickJsTargetConfig(OS.android, Architecture.ia32),
      ).throws<UnsupportedQuickJsTarget>();
      check(() => quickJsTargetConfig(OS.fuchsia, Architecture.x64)).throws<UnsupportedQuickJsTarget>();
      check(() => quickJsTargetConfig(OS.windows, Architecture.ia32)).throws<UnsupportedQuickJsTarget>();
    });

    test('MSVC gets C11 atomics', () {
      final QuickJsTargetConfig windows = quickJsTargetConfig(OS.windows, Architecture.x64);
      check(windows.std).equals('c11');
      check(windows.flags).contains('/experimental:c11atomics');
      check(quickJsTargetConfig(OS.linux, Architecture.x64).std).equals('gnu11');
    });
  });

  group('sources', () {
    test('compiles the pinned submodule sources and no libc module', () {
      for (final source in <String>[...quickJsEngineSources, ...quickJsWrapperSources]) {
        check(File('${packageDir().path}/$source').existsSync()).isTrue();
      }
      check(quickJsEngineSources).not((Subject<List<String>> it) => it.any((Subject<String> s) => s.contains('libc')));
    });

    test('the hook downloads nothing', () {
      final String hook = read('hook/build.dart');
      for (final banned in <String>[
        'HttpClient',
        'package:http',
        'Uri.https',
        "Uri.parse('http",
        'Process.run',
      ]) {
        check(hook.contains(banned)).isFalse();
      }
    });

    test('the submodule is checked out at the pinned commit', () {
      final String? commit = readSubmoduleCommit(Directory('${packageDir().path}/vendor/quickjs'));
      check(commit).equals(quickJsPinnedCommit);
      check(read('hook/build.dart')).contains('quickJsPinnedCommit');
    });

    test('the hook fails clearly when the submodule is missing', () {
      check(read('hook/build.dart')).contains('git submodule update --init --recursive');
    });
  });

  group('native symbols', () {
    test('every @Native function is exported by the built library', () {
      final List<String> symbols = RegExp(r'external [^\n]*? (qjsd_\w+)\(')
          .allMatches(read('lib/src/quickjs_bindings_generated.dart'))
          .map((RegExpMatch m) => m.group(1)!)
          .toList();
      check(symbols.length).isGreaterThan(40);
      final File? library = _findBuiltLibrary();
      if (library == null) {
        markTestSkipped('built library not found under .dart_tool');
        return;
      }
      final lib = DynamicLibrary.open(library.path);
      final List<String> missing = symbols.where((String s) => !lib.providesSymbol(s)).toList();
      check(missing).isEmpty();
    });
  });
}

/// The most recently built host library in the hooks runner cache.
File? _findBuiltLibrary() {
  final name = Platform.isWindows
      ? 'quickjs.dll'
      : Platform.isMacOS
      ? 'libquickjs.dylib'
      : 'libquickjs.so';
  final candidates = <File>[];
  for (final root in <String>['.dart_tool', '../../.dart_tool']) {
    final dir = Directory('$root/hooks_runner/shared/quickjs/build');
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is File && e.uri.pathSegments.last == name) candidates.add(e);
    }
  }
  if (candidates.isEmpty) return null;
  // Only libraries for this host can be opened; try newest first.
  candidates.sort((File a, File b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  for (final f in candidates) {
    try {
      DynamicLibrary.open(f.path);
      return f;
    } on Object {
      // A library for another target: not loadable on this host.
      continue;
    }
  }
  return null;
}
