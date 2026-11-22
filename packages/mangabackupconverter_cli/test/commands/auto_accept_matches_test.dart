@TestOn('vm')
library;

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/convert_command.dart';
import 'package:test/scaffolding.dart';

import '../support/test_refs.dart';

PluginSearchResult _result(String pluginId, String title, {String? key}) => testResult(
  pluginSourceId: pluginId,
  mangaKey: key ?? '$pluginId:$title',
  title: title,
);

/// Runs the non-interactive fallback for one manga titled [title] against
/// per-plugin search results.
Future<PluginSearchResult?> _accept(String title, Map<String, List<PluginSearchResult>> resultsByPlugin) async {
  final List<MangaMatchConfirmation> confirmations = await autoAcceptMatches(
    resultsByPlugin.keys.toList(),
    <SourceMangaData>[SourceMangaData(details: MangaSearchDetails(title: title))],
    (String query) => Stream<PluginSearchEvent>.fromIterable(<PluginSearchEvent>[
      for (final MapEntry<String, List<PluginSearchResult>> e in resultsByPlugin.entries)
        PluginSearchResults(pluginId: e.key, results: e.value),
    ]),
    legacyFetch((String pluginSourceId, String mangaKey) async => null),
  );
  check(confirmations).length.equals(1);
  return confirmations.single.confirmedMatch;
}

void main() {
  group('autoAcceptMatches (non-interactive fallback)', () {
    test('leaves the manga unresolved when no result matches the title exactly', () async {
      final PluginSearchResult? match = await _accept('Fixture Title', <String, List<PluginSearchResult>>{
        'p1': <PluginSearchResult>[_result('p1', 'Fixture Title Side Story'), _result('p1', 'Other')],
      });
      check(match).isNull();
    });

    test('leaves the manga unresolved when exact matches exist in two plugins', () async {
      final PluginSearchResult? match = await _accept('Fixture Title', <String, List<PluginSearchResult>>{
        'p1': <PluginSearchResult>[_result('p1', 'Fixture Title')],
        'p2': <PluginSearchResult>[_result('p2', 'Fixture Title')],
      });
      check(match).isNull();
    });

    test('leaves the manga unresolved when one plugin returns two exact matches', () async {
      final PluginSearchResult? match = await _accept('Fixture Title', <String, List<PluginSearchResult>>{
        'p1': <PluginSearchResult>[
          _result('p1', 'Fixture Title', key: 'a'),
          _result('p1', 'Fixture Title', key: 'b'),
        ],
      });
      check(match).isNull();
    });

    test('accepts the single exact-title match across plugins', () async {
      final PluginSearchResult? match = await _accept('Fixture Title', <String, List<PluginSearchResult>>{
        'p1': <PluginSearchResult>[_result('p1', 'Fixture Title: Remastered')],
        'p2': <PluginSearchResult>[_result('p2', 'Other'), _result('p2', 'fixture title')],
      });
      check(match).isNotNull().has((PluginSearchResult r) => r.mangaKey, 'mangaKey').equals('p2:fixture title');
    });

    test('leaves the manga unresolved when there are no results', () async {
      final PluginSearchResult? match = await _accept('Fixture Title', <String, List<PluginSearchResult>>{
        'p1': const <PluginSearchResult>[],
      });
      check(match).isNull();
    });
  });
}
