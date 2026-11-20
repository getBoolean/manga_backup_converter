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
  );
}
