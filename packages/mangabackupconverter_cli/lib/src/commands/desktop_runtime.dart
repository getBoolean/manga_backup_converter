import 'dart:io';

import 'package:desktop_webview/desktop_webview.dart';
import 'package:path/path.dart' as p;

/// Where the packaged runtime lives, relative to the CLI executable: the
/// `runtime/` directory beside `bin/` in a `dart build cli` bundle (and in
/// the Windows installer's layout, which keeps `bin/`, `lib/` and
/// `runtime/` together), or `null` when this is not a packaged build.
///
/// Layout (written by `scripts/package_cli.dart`):
/// - `runtime/runtime-manifest.json`: every bundled component, its SHA-256
///   and, for the JRE, its download URL and digest;
/// - `runtime/tachi/`: the JVM worker (`installDist` output) and its
///   `tachi-runtime.json`, whose `java` points at `runtime/jre`;
/// - `runtime/jre/`: the pinned Corretto 21 runtime;
/// - `runtime/desktop_webview/`: the helper and its `runtime-artifacts.json`.
Directory? packagedRuntimeDirectory({String? executable}) {
  final String exeDir = p.dirname(executable ?? Platform.resolvedExecutable);
  for (final candidate in <String>[p.join(exeDir, '..', 'runtime'), p.join(exeDir, 'runtime')]) {
    final dir = Directory(p.normalize(candidate));
    if (File(p.join(dir.path, packagedRuntimeManifestName)).existsSync()) return dir;
  }
  return null;
}

/// The bundle-level manifest's file name.
const String packagedRuntimeManifestName = 'runtime-manifest.json';

/// The packaged Tachi runtime manifest (`runtime/tachi/tachi-runtime.json`),
/// or `null` outside a packaged build.
String? packagedTachiManifest({String? executable}) {
  final Directory? runtime = packagedRuntimeDirectory(executable: executable);
  if (runtime == null) return null;
  final String path = p.join(runtime.path, 'tachi', 'tachi-runtime.json');
  return File(path).existsSync() ? path : null;
}

/// Finds the WebView helper's runtime artifact manifest: [explicit] if
/// given; else the packaged `runtime/desktop_webview/runtime-artifacts.json`;
/// else the development build (`packages/desktop_webview/build/helper/`)
/// found by walking up from [searchFrom]. `null` when there is none.
File? locateWebViewHelperManifest({String? explicit, Directory? searchFrom, String? executable}) {
  if (explicit != null) return File(explicit);
  final Directory? runtime = packagedRuntimeDirectory(executable: executable);
  if (runtime != null) {
    final packaged = File(p.join(runtime.path, 'desktop_webview', RuntimeArtifactManifest.fileName));
    if (packaged.existsSync()) return packaged;
  }
  Directory dir = (searchFrom ?? Directory.current).absolute;
  while (true) {
    final dev = File(
      p.join(dir.path, 'packages', 'desktop_webview', 'build', 'helper', RuntimeArtifactManifest.fileName),
    );
    if (dev.existsSync()) return dev;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// The desktop browser policy of the CLI (KTD20, KTD25). Every value here is
/// a policy choice of this composition root, documented in
/// `docs/source-runners.md` (*Desktop browser join*):
abstract final class CliBrowserPolicy {
  /// A visible browser interaction (a Cloudflare challenge) may stay open
  /// this long before it fails as interaction-required. The same bound the
  /// Paperback desktop worker already used; a person solving a challenge
  /// needs minutes, not seconds.
  static const Duration interactionTimeout = Duration(minutes: 5);

  /// How long a request held for the worker's replacement
  /// (`shouldInterceptRequest`, replace tier) waits before it proceeds
  /// unchanged: the hosts' own per-request network timeout (30 s), so a
  /// held request never waits longer than the request itself could.
  static const Duration replacementTimeout = Duration(seconds: 30);

  /// How long the helper may take to report ready (WebView2 environment
  /// creation included). The contract and desktop suites use the same bound.
  static const Duration helperStartup = Duration(seconds: 60);

  /// How long the helper may take to exit after `shutdown` before it is
  /// killed (its sessions' storage deletion runs first).
  static const Duration helperShutdownGrace = Duration(seconds: 10);

  /// Budget for `wipeAllSourceData` retrying a dead helper's data directory
  /// that a terminating WebView2 browser process still holds. Measured
  /// releases took 1-110 s on WebView2 157 (`docs/source-runners.md`), so the
  /// budget covers the slowest measured release with margin. The CLI never
  /// calls `wipeAllSourceData` on a conversion's path: the helper's own
  /// start-up wipe is a single attempt, so a held directory never delays a
  /// conversion; it is left whole, logged, and removed by a later start.
  static const Duration wipeRetry = Duration(seconds: 120);
}

/// The conversion's desktop `BrowserPort`, or `null` with a reason when the
/// helper is not available (browser requests then fail as
/// capability-unavailable, which the report names).
///
/// [interactive] decides what a visible interaction does: an interactive run
/// shows the helper's window to the user; an unattended run never opens a
/// window, and the show returns interaction-required at once.
(DesktopBrowserPort?, String?) createCliBrowserPort({
  required bool interactive,
  required Directory dataRoot,
  File? manifest,
  bool offline = false,
  void Function(String line)? onLog,
}) {
  if (manifest == null || !manifest.existsSync()) {
    return (null, 'the desktop WebView helper is not installed (no ${RuntimeArtifactManifest.fileName})');
  }
  final File helper;
  try {
    final RuntimeArtifact? artifact = RuntimeArtifactManifest.load(
      manifest,
    ).findForHost(RuntimeArtifactManifest.webviewHelper);
    if (artifact == null) {
      return (
        null,
        '${manifest.path} lists no helper for ${RuntimeArtifactManifest.hostOs}-${RuntimeArtifactManifest.hostArch}',
      );
    }
    helper = artifact.verifiedFile();
  } on RuntimeArtifactException catch (e) {
    return (null, e.message);
  } on FormatException catch (e) {
    return (null, 'unreadable ${manifest.path}: ${e.message}');
  }
  return (
    DesktopBrowserPort(
      DesktopWebViewConfig(
        helperExecutable: helper,
        dataRoot: dataRoot,
        startupTimeout: CliBrowserPolicy.helperStartup,
        shutdownGrace: CliBrowserPolicy.helperShutdownGrace,
        allowVisibleWindows: interactive,
        offline: offline,
        onLog: onLog,
        wipeRetry: CliBrowserPolicy.wipeRetry,
      ),
    ),
    null,
  );
}
