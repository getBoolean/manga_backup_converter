// Records source network captures for replay tests (record mode).
//
// MANUAL TOOL. No test runs it, and CI must never run it: it is the only code
// path allowed to reach a live source server. Tests replay the committed
// captures through `ReplayHttpClient`, which fails any request without one.
//
// Usage (from the repository root):
//   dart run tool/capture_source_fixtures.dart <ecosystem> <source> --min-interval-ms=<n> [--out=<dir>]
//   dart run tool/capture_source_fixtures.dart --list
//
// Output: fixtures/source_captures/<ecosystem>/<source>/
//   capture.json            manifest (format, provenance, exchanges)
//   bodies/<sha256>.bin     response bodies, one artifact each
//
// Each exchange records the request method, canonical URL and body digest,
// the response status and headers (cookie/auth headers dropped;
// `cf-mitigated` kept so header-based Cloudflare challenges replay), and an
// artifact entry with the source URL, SHA-256, size and licence/terms.
// Request headers are never recorded. A URL carrying credentials aborts the
// recording. Re-run a scenario whenever the test that replays it changes the
// requests it makes; a replay miss names the missing request.
//
// Cookies: a scenario's `setCookies` names the only cookies whose
// `Set-Cookie` is recorded, sanitised to name, value, Path and Domain. Use
// `CapturedCookieValue.redact` for anything that is a credential (a
// site-issued token such as Mangahub's `mhub_access`): the replay sees the
// cookie's name with the value `redacted`, and a later URL that carries the
// real value aborts the recording. Leave it empty (the default for every
// scenario) unless a replay test needs to see a site-issued cookie.
//
// Adding a scenario: add an entry to `_scenarios` that drives the source
// through exactly the calls its replay test makes, with the same arguments.
import 'dart:io';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/aidoku_plugin_loader.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';

typedef _Scenario = ({
  String description,
  String licence,
  Set<String> volatileQueryParameters,
  Map<String, CapturedCookieValue> setCookies,
  Future<void> Function(http.Client client) run,
});

/// No cookie is recorded unless a scenario names it.
const Map<String, CapturedCookieValue> _noCookies =
    <String, CapturedCookieValue>{};

const String _mangadexTerms =
    'Third-party MangaDex API response; not openly licensed; retained only as an '
    'interoperability test fixture.';

const String _mangafireTerms =
    'Third-party MangaFire page content; not openly licensed; retained only as an '
    'interoperability test fixture.';

const String _weebcentralTerms =
    'Third-party Weeb Central page content; not openly licensed; retained only as an '
    'interoperability test fixture.';

final Map<String, _Scenario> _scenarios = <String, _Scenario>{
  'aidoku/multi.mangadex': (
    description: 'packages/aidoku_plugin_loader/test/wasm/aidoku_plugin_native_test.dart',
    licence: _mangadexTerms,
    // getHome sends `createdAtSince=<now - 30 days>`.
    volatileQueryParameters: <String>{'createdAtSince'},
    setCookies: _noCookies,
    run: (http.Client client) async {
      const mangaId = 'ed996855-70de-449f-bba2-e8e24224c14d';
      const chapterId = '6eb2f8ea-3b6c-4bce-a0d0-d9224fad5b64';
      final AidokuPlugin plugin = await AidokuPlugin.fromAix(
        _aix('multi.mangadex-v12.aix'),
        defaults: <String, dynamic>{'login': _postcardString('{}')},
        httpClient: client,
      );
      try {
        await plugin.searchManga('', 1);
        await plugin.searchManga('Onimai', 1);
        final Manga? manga = await plugin.getMangaDetails(mangaId);
        await plugin.getMangaDetails(mangaId, includeChapters: true);
        if (manga != null) {
          await plugin.getPageList(manga, const Chapter(key: chapterId));
        }
        await plugin.getMangaList(1, listing: plugin.sourceInfo.listings[1]);
        await plugin.getListings();
        await plugin.getHome();
      } finally {
        plugin.dispose();
      }
    },
  ),
  'aidoku/multi.mangafire': (
    description: 'packages/aidoku_plugin_loader/test/wasm/aidoku_plugin_mangafire_test.dart',
    licence: _mangafireTerms,
    volatileQueryParameters: <String>{},
    setCookies: _noCookies,
    run: (http.Client client) async {
      final AidokuPlugin plugin = await AidokuPlugin.fromAix(
        _aix('multi.mangafire-v8.aix'),
        httpClient: client,
      );
      try {
        final MangaPageResult result = await plugin.searchManga('Onimai', 1);
        final String? key = result.manga.firstOrNull?.key;
        if (key == null) {
          throw StateError(
            'MangaFire search returned no results; nothing to capture',
          );
        }
        await plugin.getMangaDetails(key);
        await plugin.getMangaDetails(key, includeChapters: true);
      } finally {
        plugin.dispose();
      }
    },
  ),
  'aidoku/en.weebcentral': (
    description: 'integration_test/source_runners_android_test.dart (U13)',
    licence: _weebcentralTerms,
    volatileQueryParameters: <String>{},
    setCookies: _noCookies,
    run: (http.Client client) async {
      final AidokuPlugin plugin = await AidokuPlugin.fromAix(
        _aix('en.weebcentral-v6.aix'),
        httpClient: client,
      );
      try {
        final MangaPageResult result = await plugin.searchManga('Onimai', 1);
        final String? key = result.manga.firstOrNull?.key;
        if (key == null) {
          throw StateError(
            'Weeb Central search returned no results; nothing to capture',
          );
        }
        await plugin.getMangaDetails(key, includeChapters: true);
        final List<String> warnings = plugin.drainWarnings();
        if (warnings.isNotEmpty) {
          throw StateError('Weeb Central produced host warnings: $warnings');
        }
      } finally {
        plugin.dispose();
      }
    },
  ),
};

Uint8List _aix(String name) => File(
  p.join(
    'packages',
    'aidoku_plugin_loader',
    'test',
    'aidoku',
    'fixtures',
    name,
  ),
).readAsBytesSync();

Uint8List _postcardString(String value) {
  final List<int> bytes = value.codeUnits;
  return Uint8List.fromList(<int>[bytes.length, ...bytes]);
}

Future<void> main(List<String> args) async {
  if (args.contains('--list')) {
    for (final MapEntry<String, _Scenario> e in _scenarios.entries) {
      stdout.writeln('${e.key}\t${e.value.description}');
    }
    return;
  }
  final List<String> positional = args
      .where((String a) => !a.startsWith('--'))
      .toList();
  if (positional.length != 2) {
    stderr.writeln(
      'usage: dart run tool/capture_source_fixtures.dart <ecosystem> <source> [--min-interval-ms=<n>]',
    );
    exitCode = 64;
    return;
  }
  final id = '${positional[0]}/${positional[1]}';
  final _Scenario? scenario = _scenarios[id];
  if (scenario == null) {
    stderr.writeln('Unknown scenario $id. Use --list.');
    exitCode = 64;
    return;
  }
  final String? intervalArg = args
      .where((String a) => a.startsWith('--min-interval-ms='))
      .map((String a) => a.split('=').last)
      .firstOrNull;
  if (intervalArg == null) {
    stderr.writeln(
      '--min-interval-ms=<n> is required: choose a polite spacing for the source.',
    );
    exitCode = 64;
    return;
  }
  final inner = http.Client();
  final recorder = RecordingHttpClient(
    inner,
    minInterval: Duration(milliseconds: int.parse(intervalArg)),
    licence: scenario.licence,
    volatileQueryParameters: scenario.volatileQueryParameters,
    setCookieAllowList: scenario.setCookies,
  );
  try {
    await scenario.run(recorder);
  } finally {
    inner.close();
  }
  final String? outArg = args
      .where((String a) => a.startsWith('--out='))
      .map((String a) => a.substring(6))
      .firstOrNull;
  final dir = Directory(
    outArg ??
        p.join('fixtures', 'source_captures', positional[0], positional[1]),
  )..createSync(recursive: true);
  recorder.writeTo(
    dir,
    ecosystem: positional[0],
    source: positional[1],
    notes: 'Replayed by ${scenario.description}',
  );
  stdout.writeln('Recorded ${recorder.length} exchanges into ${dir.path}');
  // Plugin isolates may keep the VM alive; exit explicitly.
  exit(0);
}
