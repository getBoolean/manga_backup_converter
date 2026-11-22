@TestOn('vm')
library;

import 'package:checks/checks.dart';
import 'package:desktop_webview/desktop_webview.dart';
import 'package:test/scaffolding.dart';

/// L5: the helper is launched with a scrubbed environment, like the workers.
void main() {
  test('the helper keeps profile and display variables and drops overrides', () {
    final Map<String, String> env = helperEnvironment(
      parent: const <String, String>{
        'LOCALAPPDATA': 'local',
        'DISPLAY': ':0',
        'TEMP': 'tmp',
        'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS': '--proxy-server=evil:1',
        'WEBVIEW2_BROWSER_EXECUTABLE_FOLDER': 'evil',
        'HTTP_PROXY': 'http://evil:1',
        'https_proxy': 'http://evil:1',
        'LD_PRELOAD': 'evil.so',
        'SECRET_TOKEN': 'x',
      },
    );
    check(env).deepEquals(<String, String>{'TEMP': 'tmp', 'LOCALAPPDATA': 'local', 'DISPLAY': ':0'});
  });
}
