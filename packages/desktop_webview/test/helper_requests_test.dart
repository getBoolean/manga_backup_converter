// The real helper's answers to malformed requests (helper/src/main.rs
// `refuse_malformed`): what a request that does not decode as a Command is
// answered with, through the raw helper protocol.
@TestOn('vm')
@Timeout.factor(4)
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:desktop_webview/desktop_webview.dart';
import 'package:test/scaffolding.dart';

import 'support/helper_fixture.dart';

void main() {
  HelperProcess? started;
  Directory? dataRoot;

  setUpAll(() async {
    final File? built = await builtHelper();
    if (built == null) {
      markTestSkipped('desktop WebView helper not built: $helperUnavailableReason');
      return;
    }
    dataRoot = Directory.systemTemp.createTempSync('dwv-requests');
    final HelperStart start = await HelperProcess.start(
      executable: built.path,
      arguments: <String>['--data-root', dataRoot!.path, '--offline', '--test-hooks'],
      startupTimeout: const Duration(seconds: 60),
    );
    switch (start) {
      case HelperStarted(:final HelperProcess process):
        started = process;
      case HelperFatal(:final String code, :final String message):
        markTestSkipped('the helper cannot run here ($code): $message');
      case HelperLaunchFailed(:final String message):
        throw StateError('helper did not start: $message');
    }
  });

  tearDownAll(() async {
    await started?.shutdown(grace: const Duration(seconds: 10));
    try {
      dataRoot?.deleteSync(recursive: true);
    } on Object {
      // The next start-up wipe removes it.
    }
  });

  Future<HelperError> refused(String op, Map<String, Object?> params) async {
    final HelperReply reply = await started!.request(op, params);
    return reply as HelperError;
  }

  test('a malformed request for a session that is gone is session-closed', () async {
    check(await refused('load', <String, Object?>{'session': 'gone'}))
        .has((e) => e.code, 'code')
        .equals('session-closed');
    check(await refused('eval', <String, Object?>{'session': 'gone', 'script': 7}))
        .has((e) => e.code, 'code')
        .equals(
          'session-closed',
        );
  });

  test('a missing or mistyped field of an open session is invalid, naming the field', () async {
    final HelperReply opened = await started!.request('open', <String, Object?>{'session': 's1'});
    check(opened).isA<HelperOk>();
    check(await refused('load', <String, Object?>{'session': 's1'}))
      ..has((e) => e.code, 'code').equals('invalid')
      ..has((e) => e.message, 'message').contains('url');
    check(await refused('channel', <String, Object?>{'session': 's1', 'name': 'ipc', 'enabled': 'yes'}))
      ..has((e) => e.code, 'code').equals('invalid')
      ..has((e) => e.message, 'message').contains('bool');
    check(await started!.request('close', <String, Object?>{'session': 's1'})).isA<HelperOk>();
  });

  test('an open without a session, an unknown operation and a malformed respond are invalid', () async {
    check(await refused('open', <String, Object?>{})).has((e) => e.code, 'code').equals('invalid');
    check(await refused('frobnicate', <String, Object?>{'session': 'gone'}))
        .has((e) => e.code, 'code')
        .equals(
          'session-closed',
        );
    check(await refused('frobnicate', <String, Object?>{}))
      ..has((e) => e.code, 'code').equals('invalid')
      ..has((e) => e.message, 'message').contains('frobnicate');
    // A held request is failed rather than left waiting; with no such request only the reply shows.
    check(await refused('respond', <String, Object?>{'rid': 99, 'fail': 5}))
        .has((e) => e.code, 'code')
        .equals('invalid');
  });
}
