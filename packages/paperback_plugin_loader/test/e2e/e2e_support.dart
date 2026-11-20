import 'dart:io';

/// The repository root: the first ancestor of the current directory holding
/// `tools/tachi-source-runner`.
Directory repoRoot() {
  Directory dir = Directory.current.absolute;
  while (true) {
    if (Directory('${dir.path}/tools/tachi-source-runner').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) throw StateError('Repository root not found from ${Directory.current.path}');
    dir = parent;
  }
}

/// The SDK's real `dart` executable (never the `dart.bat` shim, whose kill
/// would orphan the worker). Under `flutter test` the resolved executable is
/// `flutter_tester`, so walk up to the Flutter cache's `dart-sdk`.
String dartExecutable() {
  final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
  final String exe = Platform.resolvedExecutable;
  if (exe.endsWith(exeName) && File(exe).uri.pathSegments.last == exeName) return exe;
  Directory dir = File(exe).parent;
  while (true) {
    final candidate = File('${dir.path}/dart-sdk/bin/$exeName');
    if (candidate.existsSync()) return candidate.path;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final candidate = File('$flutterRoot/bin/cache/dart-sdk/bin/$exeName');
    if (candidate.existsSync()) return candidate.path;
  }
  throw StateError('Cannot locate the Dart SDK executable from $exe');
}
