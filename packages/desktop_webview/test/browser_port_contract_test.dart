// Runs the reusable BrowserPort contract suite (source_runtime_testing)
// against the real desktop helper on this host's engine.
@TestOn('vm')
// Each test starts real WebView2 processes; parallel test files slow them.
@Timeout.factor(4)
library;

import 'dart:io';

import 'package:source_runtime_testing/source_runtime_testing.dart';
import 'package:test/scaffolding.dart';

import 'support/helper_fixture.dart';

Future<void> main() async {
  final File? helper = await builtHelper();
  if (helper == null) {
    test('desktop helper contract suite', () {}, skip: 'helper not built: $helperUnavailableReason');
    return;
  }
  late FixtureServer server;
  late Directory dataRoot;
  setUpAll(() async {
    server = await FixtureServer.start();
    dataRoot = await Directory.systemTemp.createTemp('dwv-contract-');
  });
  tearDownAll(() async {
    await server.close();
    try {
      await dataRoot.delete(recursive: true);
    } on FileSystemException {
      // A helper's browser process may still hold its directory briefly.
    }
  });
  runBrowserPortContractSuite(
    'desktop helper (${Platform.operatingSystem})',
    () => DesktopBrowserPortHarness(helper, server, dataRoot),
    // Protocol 1.2 behaviour the helper's protocol 1.1 transport cannot
    // provide; the desktop helper transport lane (off wry's built-in IPC,
    // with a way to fail a held request) removes these entries.
    knownFailures: const <String, String>{
      'accepts "ipc" as a channel name without breaking evaluation or other channels':
          'helper still uses wry IPC, which owns window.ipc; follow-up: desktop helper transport lane',
      'a redirect replacement is refused and the request fails':
          'helper protocol 1.1 cannot fail a held request, so a refused replacement proceeds; '
          'follow-up: desktop helper transport lane',
    },
  );
}
