import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart' show test;
import 'package:mangabackupconverter/src/features/conversion/application/conversion_composition.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';

AndroidConversionConfig _config({
  required bool interactive,
  List<String> tachiWorkerArguments = const <String>[],
}) => AndroidConversionConfig(
  storageRoot: Directory.systemTemp,
  interactionTimeout: const Duration(seconds: 30),
  interactive: interactive,
  tachiWorkerArguments: tachiWorkerArguments,
);

void main() {
  test('an interactive configuration bounds Cloudflare challenges by the '
      'interaction timeout and lets the browser port show interactions', () {
    final AndroidConversionConfig config = _config(interactive: true);
    check(config.tachiArguments).deepEquals(<String>[
      '--interactive-challenges',
      '30000',
    ]);
    check(config.browser.allowInteraction).isTrue();
    check(config.browser.offline).isFalse();
  });

  test('an unattended configuration shows nothing', () {
    final AndroidConversionConfig config = _config(interactive: false);
    check(config.tachiArguments).isEmpty();
    check(config.browser.allowInteraction).isFalse();
  });

  test('test-only worker arguments come first and only from the caller', () {
    final AndroidConversionConfig config = _config(
      interactive: true,
      tachiWorkerArguments: const <String>[
        '--replay',
        'x',
        '--offline-browser',
      ],
    );
    check(config.tachiArguments).deepEquals(<String>[
      '--replay',
      'x',
      '--offline-browser',
      '--interactive-challenges',
      '30000',
    ]);
  });

  test('Tachi artifacts are APKs only by default (KTD17)', () {
    check(
      _config(interactive: false).tachiPolicy.all,
    ).equals(TachiArtifactKind.apk);
  });

  test('the runtimes start on Android only', () async {
    final SourceOutcome<AndroidSourceRuntimes> result =
        await AndroidSourceRuntimes.start(
          _config(interactive: false),
        );
    check(result.failureOrNull?.code).equals('runtime-unavailable');
  });
}
