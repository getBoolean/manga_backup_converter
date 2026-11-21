// Weeb Central (HTML scraping through the html:: host imports) replaying the
// committed captures in fixtures/source_captures/aidoku/en.weebcentral/.
// No test reaches a server; re-record with tool/capture_source_fixtures.dart.
//
// Run: flutter test packages/aidoku_plugin_loader/test/wasm/aidoku_plugin_weebcentral_test.dart --reporter expanded
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/aidoku_plugin_loader.dart';
import 'package:aidoku_plugin_loader/src/aidoku/aidoku_user_agent.dart';
import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import '../support/replay.dart';

/// Records the User-Agent of every request before replaying it.
final class _UserAgentSpy extends http.BaseClient {
  _UserAgentSpy(this._inner);

  final http.Client _inner;
  final List<String?> userAgents = <String?>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    userAgents.add(request.headers['User-Agent']);
    return _inner.send(request);
  }
}

void main() {
  const fixturePath = 'test/aidoku/fixtures/en.weebcentral-v6.aix';
  final fixture = File(fixturePath).existsSync()
      ? File(fixturePath)
      : File('packages/aidoku_plugin_loader/$fixturePath');

  group(
    'AidokuPlugin weebcentral',
    skip: !fixture.existsSync() ? 'Missing $fixturePath' : null,
    () {
      late AidokuPlugin plugin;
      late ReplayHttpClient replay;
      late _UserAgentSpy spy;

      setUpAll(() async {
        replay = aidokuReplayClient('en.weebcentral');
        spy = _UserAgentSpy(replay);
        plugin = await AidokuPlugin.fromAix(Uint8List.fromList(fixture.readAsBytesSync()), httpClient: spy);
      });

      tearDownAll(() => plugin.dispose());

      tearDown(() {
        final List<String> warnings = plugin.drainWarnings();
        check(because: '[CB] Plugin produced unexpected warnings:\n${warnings.join('\n')}', warnings).isEmpty();
        check(because: 'requests without a committed capture', replay.misses).isEmpty();
      });

      test('search, details and chapters parse from HTML', () async {
        final MangaPageResult result = await plugin.searchManga('Onimai', 1);
        check(result.manga).isNotEmpty();
        final Manga first = result.manga.first;
        check(first.key).isNotEmpty();
        check(first.title).isNotEmpty();

        final Manga? manga = await plugin.getMangaDetails(first.key, includeChapters: true);
        check(manga).isNotNull();
        check(manga!.title).isNotEmpty();
        check(manga.chapters).isNotEmpty();

        // The source sets no User-Agent; the host supplies Aidoku's default.
        check(spy.userAgents).isNotEmpty();
        check(spy.userAgents).every((Subject<String?> ua) => ua.equals(aidokuDefaultUserAgent));
      });
    },
  );
}
