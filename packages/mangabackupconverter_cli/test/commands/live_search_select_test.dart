@TestOn('vm')
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/live_search_select.dart';
import 'package:mangabackupconverter_cli/src/commands/terminal_ui.dart';
import 'package:test/scaffolding.dart';

import '../support/test_refs.dart';

void main() {
  group('LiveSearchSelect', () {
    test('shows results from multiple plugins with group headers', () async {
      final output = StringBuffer();
      final input = StreamController<List<int>>.broadcast();
      addTearDown(input.close);

      final context = TerminalContext.test(
        output: output,
        inputStream: input.stream,
        height: 30,
      );
      addTearDown(context.dispose);

      final liveSearch = LiveSearchSelect();
      final Future<PluginSearchResult?> future = liveSearch.run(
        context: context,
        initialQuery: 'test',
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin1',
                results: [
                  testResult(
                    pluginSourceId: 'plugin1',
                    mangaKey: 'key1',
                    title: 'Manga From Plugin1',
                  ),
                ],
              ),
            );
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin2',
                results: [
                  testResult(
                    pluginSourceId: 'plugin2',
                    mangaKey: 'key2',
                    title: 'Manga From Plugin2',
                  ),
                ],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: legacyFetch((String pluginSourceId, String mangaKey) async => null),
      );

      // Wait for results to arrive and render.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final rendered = output.toString();
      check(rendered).contains('plugin1');
      check(rendered).contains('plugin2');
      check(rendered).contains('Manga From Plugin1');
      check(rendered).contains('Manga From Plugin2');

      // Press Escape to close.
      input.add([0x1b]);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final PluginSearchResult? result = await future;
      check(result).isNull();
    });

    test('shows no results indicator for plugin with empty results', () async {
      final output = StringBuffer();
      final input = StreamController<List<int>>.broadcast();
      addTearDown(input.close);

      final context = TerminalContext.test(
        output: output,
        inputStream: input.stream,
        height: 30,
      );
      addTearDown(context.dispose);

      final liveSearch = LiveSearchSelect();
      final Future<PluginSearchResult?> future = liveSearch.run(
        context: context,
        initialQuery: 'test',
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(PluginSearchStarted(pluginId: 'plugin1'));
            controller.add(PluginSearchStarted(pluginId: 'plugin2'));
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin1',
                results: [
                  testResult(
                    pluginSourceId: 'plugin1',
                    mangaKey: 'key1',
                    title: 'Manga From Plugin1',
                  ),
                ],
              ),
            );
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin2',
                results: [],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: legacyFetch((String pluginSourceId, String mangaKey) async => null),
      );

      // Wait for results to arrive and render.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final rendered = output.toString();
      check(rendered).contains('Manga From Plugin1');
      check(rendered).contains('[plugin2] no results');

      // Press Escape to close.
      input.add([0x1b]);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final PluginSearchResult? result = await future;
      check(result).isNull();
    });

    test('selecting a result from second plugin returns it', () async {
      final output = StringBuffer();
      final input = StreamController<List<int>>.broadcast();
      addTearDown(input.close);

      final context = TerminalContext.test(
        output: output,
        inputStream: input.stream,
        height: 30,
      );
      addTearDown(context.dispose);

      final liveSearch = LiveSearchSelect();
      final Future<PluginSearchResult?> future = liveSearch.run(
        context: context,
        initialQuery: 'test',
        onSearch: (String query) {
          final controller = StreamController<PluginSearchEvent>();
          scheduleMicrotask(() {
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin1',
                results: [
                  testResult(
                    pluginSourceId: 'plugin1',
                    mangaKey: 'key1',
                    title: 'First Result',
                  ),
                ],
              ),
            );
            controller.add(
              PluginSearchResults(
                pluginId: 'plugin2',
                results: [
                  testResult(
                    pluginSourceId: 'plugin2',
                    mangaKey: 'key2',
                    title: 'Second Result',
                  ),
                ],
              ),
            );
            controller.close();
          });
          return controller.stream;
        },
        onFetchDetails: legacyFetch((String pluginSourceId, String mangaKey) async => null),
      );

      // Wait for results to render.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // ArrowDown from search bar to result 0, then to result 1.
      input.add([0x1b, 0x5b, 0x42]); // ArrowDown
      await Future<void>.delayed(const Duration(milliseconds: 20));
      input.add([0x1b, 0x5b, 0x42]); // ArrowDown
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Press Enter to select.
      input.add([0x0d]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final PluginSearchResult? result = await future;
      check(result).isNotNull().has((r) => r.pluginSourceId, 'pluginSourceId').equals('plugin2');
      check(result).isNotNull().has((r) => r.title, 'title').equals('Second Result');
    });

    test('confirming from Tab details returns the enriched result, fetched once', () async {
      final output = StringBuffer();
      final input = StreamController<List<int>>.broadcast();
      addTearDown(input.close);
      final context = TerminalContext.test(output: output, inputStream: input.stream, height: 30);
      addTearDown(context.dispose);

      var fetches = 0;
      final Future<PluginSearchResult?> future = LiveSearchSelect().run(
        context: context,
        initialQuery: 'test',
        onSearch: (String query) => Stream<PluginSearchEvent>.fromIterable(<PluginSearchEvent>[
          PluginSearchResults(
            pluginId: 'plugin1',
            results: [testResult(pluginSourceId: 'plugin1', mangaKey: 'key1', title: 'First Result')],
          ),
        ]),
        onFetchDetails: legacyFetch((String pluginSourceId, String mangaKey) async {
          fetches++;
          return (
            PluginMangaDetails(key: mangaKey, title: 'First Result'),
            <PluginChapter>[PluginChapter(chapterId: 'c1', chapterNumber: 1)],
          );
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      input.add([0x1b, 0x5b, 0x42]); // ArrowDown to result 0
      await Future<void>.delayed(const Duration(milliseconds: 20));
      input.add([0x09]); // Tab: details
      await Future<void>.delayed(const Duration(milliseconds: 100));
      input.add([0x0d]); // Enter: confirm from the details screen
      final PluginSearchResult? result = await future;

      check(fetches).equals(1);
      check(result).isNotNull().has((PluginSearchResult r) => r.fetched, 'fetched').isNotNull();
      check(result!.chapters).length.equals(1);
    });
  });
}
