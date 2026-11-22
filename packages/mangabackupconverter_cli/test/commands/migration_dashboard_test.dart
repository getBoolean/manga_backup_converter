@TestOn('vm')
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/migration_dashboard.dart';
import 'package:mangabackupconverter_cli/src/commands/terminal_ui.dart';
import 'package:test/scaffolding.dart';

import '../support/test_refs.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

SourceMangaData _source(String title, {int chapters = 0}) => SourceMangaData(
  details: MangaSearchDetails(title: title),
  chapters: List<SourceChapter>.generate(
    chapters,
    (int i) => SourceChapter(title: 'Ch ${i + 1}', chapterNumber: i + 1.0),
  ),
);

PluginSearchResult _result(
  String pluginId,
  String title, {
  String? mangaKey,
  List<PluginChapter> chapters = const [],
  PluginMangaDetails? details,
}) => testResult(
  pluginSourceId: pluginId,
  mangaKey: mangaKey ?? title.toLowerCase().replaceAll(' ', '-'),
  title: title,
  chapters: chapters,
  details: details,
);

List<PluginChapter> _chapters(int count) => List<PluginChapter>.generate(
  count,
  (int i) => PluginChapter(chapterId: 'ch-$i', chapterNumber: i + 1.0),
);

/// Runs the dashboard with the given manga and fake search/enrichment callbacks,
/// then presses 'y' to accept after all searches complete.
Future<List<MangaMatchConfirmation>> _runDashboard({
  required List<SourceMangaData> manga,
  required Stream<PluginSearchEvent> Function(String query) onSearch,
  required Future<(PluginMangaDetails, List<PluginChapter>)?> Function(
    String pluginSourceId,
    String mangaKey,
  )
  onFetchDetails,
  List<String> pluginNames = const ['testPlugin'],
  void Function(StreamController<List<int>> input)? beforeAccept,
}) async {
  final output = StringBuffer();
  final input = StreamController<List<int>>.broadcast();

  final context = TerminalContext.test(
    output: output,
    inputStream: input.stream,
    height: 40,
    width: 120,
  );

  final dashboard = MigrationDashboard();
  final Future<List<MangaMatchConfirmation>> future = dashboard.run(
    context: context,
    pluginNames: pluginNames,
    manga: manga,
    onSearch: onSearch,
    onFetchDetails: legacyFetch(onFetchDetails),
  );

  // Wait for searches + enrichment to settle.
  await Future<void>.delayed(const Duration(milliseconds: 300));

  beforeAccept?.call(input);
  await Future<void>.delayed(const Duration(milliseconds: 50));

  // Press 'y' to accept.
  input.add([0x79]); // 'y'
  await Future<void>.delayed(const Duration(milliseconds: 50));

  try {
    return await future;
  } finally {
    context.dispose();
    await input.close();
  }
}

void main() {
  group('MigrationDashboard', () {
    test('does not auto-confirm by chapter count when several plugins match exactly (R8)', () async {
      final fetched = <String>[];
      final List<MangaMatchConfirmation> results = await _runDashboard(
        manga: [_source('Naruto', chapters: 100)],
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'pluginA',
                results: [_result('pluginA', 'Naruto')],
              ),
            );
            controller.add(
              PluginSearchResults(
                pluginId: 'pluginB',
                results: [_result('pluginB', 'Naruto')],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: (String pluginSourceId, String mangaKey) async {
          fetched.add(pluginSourceId);
          final chapterCount = pluginSourceId == 'pluginA' ? 50 : 200;
          return (
            PluginMangaDetails(
              key: mangaKey,
              title: 'Naruto',
              authors: ['Kishimoto'],
            ),
            _chapters(chapterCount),
          );
        },
        pluginNames: ['pluginA', 'pluginB'],
      );

      // Two equally exact candidates require the user to choose; titles are
      // all matching needs, so no candidate's details are fetched.
      check(fetched).isEmpty();
      check(results).length.equals(1);
      check(results.first.confirmedMatch).isNull();
    });

    test('does not auto-confirm a single candidate whose title is not an exact match', () async {
      final List<MangaMatchConfirmation> results = await _runDashboard(
        manga: [_source('Naruto')],
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'pluginA',
                results: [_result('pluginA', 'Naruto Gaiden')],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: (String pluginSourceId, String mangaKey) async => (
          PluginMangaDetails(key: mangaKey, title: 'Naruto Gaiden'),
          _chapters(500),
        ),
      );

      check(results).length.equals(1);
      check(results.first.confirmedMatch).isNull();
    });

    test('auto-confirms the single exact-title candidate among plugins', () async {
      final List<MangaMatchConfirmation> results = await _runDashboard(
        manga: [_source('Naruto')],
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'pluginA',
                results: [_result('pluginA', 'Naruto Gaiden')],
              ),
            );
            controller.add(
              PluginSearchResults(
                pluginId: 'pluginB',
                results: [_result('pluginB', 'naruto')],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: (String pluginSourceId, String mangaKey) async => (
          PluginMangaDetails(key: mangaKey, title: mangaKey),
          _chapters(pluginSourceId == 'pluginA' ? 900 : 1),
        ),
        pluginNames: ['pluginA', 'pluginB'],
      );

      check(results.first.confirmedMatch)
          .isNotNull()
          .has((PluginSearchResult r) => r.pluginSourceId, 'plugin')
          .equals(
            'pluginB',
          );
    });

    test('takes only first result per plugin', () async {
      final List<MangaMatchConfirmation> results = await _runDashboard(
        manga: [_source('One Piece')],
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin1',
                results: [
                  _result('plugin1', 'One Piece'),
                  _result('plugin1', 'One Piece: Wanted!'),
                ],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: (String pluginSourceId, String mangaKey) async => (
          PluginMangaDetails(key: mangaKey, title: 'One Piece'),
          _chapters(10),
        ),
      );

      check(results).length.equals(1);
      // Should have only 1 candidate (first result), not 2.
      final PluginSearchResult match = results.first.confirmedMatch!;
      check(match.title).equals('One Piece');
    });

    test('handles enrichment failure gracefully', () async {
      final List<MangaMatchConfirmation> results = await _runDashboard(
        manga: [_source('Bleach')],
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin1',
                results: [_result('plugin1', 'Bleach')],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: (String pluginSourceId, String mangaKey) async {
          throw Exception('Network error');
        },
      );

      check(results).length.equals(1);
      // Match should still be set (unenriched candidate kept).
      final PluginSearchResult match = results.first.confirmedMatch!;
      check(match.title).equals('Bleach');
    });

    test('no candidates yields no match', () async {
      final List<MangaMatchConfirmation> results = await _runDashboard(
        manga: [_source('Obscure Manga')],
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin1',
                results: [],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: (String pluginSourceId, String mangaKey) async => null,
      );

      check(results).length.equals(1);
      check(results.first.confirmedMatch).isNull();
    });

    test('toggling entry off skips it in results', () async {
      final List<MangaMatchConfirmation> results = await _runDashboard(
        manga: [_source('Manga A'), _source('Manga B')],
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin1',
                results: [_result('plugin1', query)],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: (String pluginSourceId, String mangaKey) async => (
          PluginMangaDetails(key: mangaKey, title: mangaKey),
          _chapters(5),
        ),
        beforeAccept: (StreamController<List<int>> input) {
          // Press Space on first entry to deselect it.
          input.add([0x20]); // Space
        },
      );

      check(results).length.equals(2);
      // First entry deselected -> confirmedMatch is null.
      check(results.first.confirmedMatch).isNull();
      // Second entry should still have a match.
      check(results[1].confirmedMatch).isNotNull();
    });

    test('enriched details populate authors and chapters', () async {
      final List<MangaMatchConfirmation> results = await _runDashboard(
        manga: [_source('Test Manga')],
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin1',
                results: [
                  _result('plugin1', 'Test Manga', mangaKey: 'test-key'),
                ],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: (String pluginSourceId, String mangaKey) async => (
          PluginMangaDetails(
            key: mangaKey,
            title: 'Test Manga',
            authors: ['Author A'],
            artists: ['Artist B'],
            url: 'https://example.com/test',
          ),
          _chapters(42),
        ),
      );

      check(results).length.equals(1);
      final PluginSearchResult match = results.first.confirmedMatch!;
      // The confirmation carries the snapshot, so the pipeline reuses it.
      check(match.fetched).isNotNull();
      check(match.authors).deepEquals(['Author A']);
      check(match.chapters).length.equals(42);
      check(match.details)
          .isNotNull()
          .has(
            (PluginMangaDetails d) => d.url,
            'url',
          )
          .equals('https://example.com/test');
    });

    test('the next search does not wait for enrichment, but accepting does', () async {
      final release = Completer<void>();
      final searched = <String>[];
      var fetches = 0;
      final output = StringBuffer();
      final input = StreamController<List<int>>.broadcast();
      final context = TerminalContext.test(output: output, inputStream: input.stream, height: 40, width: 120);
      final Future<List<MangaMatchConfirmation>> future = MigrationDashboard().run(
        context: context,
        pluginNames: const ['plugin1'],
        manga: [_source('Manga 1'), _source('Manga 2')],
        onSearch: (String query) {
          searched.add(query);
          return Stream<PluginSearchEvent>.fromIterable(<PluginSearchEvent>[
            PluginSearchResults(pluginId: 'plugin1', results: [_result('plugin1', query)]),
          ]);
        },
        onFetchDetails: legacyFetch((String pluginSourceId, String mangaKey) async {
          fetches++;
          await release.future;
          return (PluginMangaDetails(key: mangaKey, title: mangaKey), _chapters(2));
        }),
      );
      var done = false;
      unawaited(future.then((_) => done = true));
      try {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        check(searched).deepEquals(['Manga 1', 'Manga 2']);
        input.add([0x79]); // 'y' while details are still being fetched: ignored.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        check(done).isFalse();

        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        input.add([0x79]);
        final List<MangaMatchConfirmation> results = await future;
        check(fetches).equals(2);
        for (final r in results) {
          check(r.confirmedMatch).isNotNull().has((PluginSearchResult m) => m.fetched, 'fetched').isNotNull();
        }
      } finally {
        context.dispose();
        await input.close();
      }
    });

    test('multiple manga entries searched sequentially', () async {
      var searchCount = 0;

      final List<MangaMatchConfirmation> results = await _runDashboard(
        manga: [_source('Manga 1'), _source('Manga 2'), _source('Manga 3')],
        onSearch: (String query) {
          searchCount++;
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin1',
                results: [_result('plugin1', query)],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: (String pluginSourceId, String mangaKey) async => (
          PluginMangaDetails(key: mangaKey, title: mangaKey),
          _chapters(3),
        ),
      );

      check(searchCount).equals(3);
      check(results).length.equals(3);
      for (final r in results) {
        check(r.confirmedMatch).isNotNull();
      }
    });
  });
}
