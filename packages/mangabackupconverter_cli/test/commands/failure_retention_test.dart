@TestOn('vm')
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/convert_command.dart';
import 'package:mangabackupconverter_cli/src/commands/live_search_select.dart';
import 'package:mangabackupconverter_cli/src/commands/migration_dashboard.dart';
import 'package:mangabackupconverter_cli/src/commands/terminal_ui.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import '../support/test_refs.dart';

/// One source succeeds; another needs a visible interaction.
Stream<PluginSearchEvent> _mixedSearch(String query) {
  final controller = StreamController<PluginSearchEvent>();
  scheduleMicrotask(() {
    controller
      ..add(PluginSearchStarted(pluginId: 'ok'))
      ..add(PluginSearchStarted(pluginId: 'challenge'))
      ..add(
        PluginSearchResults(
          pluginId: 'ok',
          results: <PluginSearchResult>[testResult(pluginSourceId: 'ok', mangaKey: 'k', title: query)],
        ),
      )
      ..add(
        PluginSearchError(
          failure: const PluginSearchFailure(
            pluginId: 'challenge',
            failure: InteractionRequiredFailure('Cloudflare challenge'),
          ),
        ),
      )
      ..close();
  });
  return controller.stream;
}

final FetchDetails _noDetails = legacyFetch((String pluginSourceId, String mangaKey) async => null);

void main() {
  group('search failures reach final accounting', () {
    test("the dashboard keeps a failure beside another source's match, and deselection is an exclusion", () async {
      final output = StringBuffer();
      final input = StreamController<List<int>>.broadcast();
      final context = TerminalContext.test(output: output, inputStream: input.stream, height: 40, width: 120);
      final Future<List<MangaMatchConfirmation>> future = MigrationDashboard().run(
        context: context,
        pluginNames: const <String>['ok', 'challenge'],
        manga: <SourceMangaData>[
          SourceMangaData(details: MangaSearchDetails(title: 'Alpha')),
          SourceMangaData(details: MangaSearchDetails(title: 'Beta')),
        ],
        onSearch: _mixedSearch,
        onFetchDetails: _noDetails,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      input
        ..add(<int>[0x1b, 0x5b, 0x42]) // Arrow down to Beta
        ..add(<int>[0x20]); // Space: deselect
      await Future<void>.delayed(const Duration(milliseconds: 50));
      input.add(<int>[0x79]); // 'y'
      final List<MangaMatchConfirmation> confirmations = await future;
      context.dispose();
      await input.close();

      final MangaMatchConfirmation alpha = confirmations.first;
      check(alpha.confirmedMatch).isNotNull().has((PluginSearchResult r) => r.pluginSourceId, 'source').equals('ok');
      check(alpha.searchFailures.single.failure).isA<InteractionRequiredFailure>();
      check(confirmations.last.excluded).isTrue();
      check(confirmations.last.confirmedMatch).isNull();
    });

    test('live search reports each failure to its caller and shows the failure code', () async {
      final output = StringBuffer();
      final input = StreamController<List<int>>.broadcast();
      final context = TerminalContext.test(output: output, inputStream: input.stream, height: 30);
      final failures = <PluginSearchFailure>[];
      final Future<PluginSearchResult?> future = LiveSearchSelect().run(
        context: context,
        initialQuery: 'Alpha',
        onSearch: _mixedSearch,
        onFetchDetails: _noDetails,
        onFailure: failures.add,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      check(output.toString()).contains('interaction-required');
      input.add(<int>[0x1b]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await future;
      context.dispose();
      await input.close();
      check(failures.single.pluginId).equals('challenge');
    });

    test('the unattended fallback keeps search failures on each confirmation', () async {
      final List<MangaMatchConfirmation> confirmations = await autoAcceptMatches(
        const <String>['ok', 'challenge'],
        <SourceMangaData>[SourceMangaData(details: MangaSearchDetails(title: 'Alpha'))],
        _mixedSearch,
        _noDetails,
      );
      check(confirmations.single.confirmedMatch).isNotNull();
      check(confirmations.single.searchFailures.single.failure.code).equals('interaction-required');
    });
  });
}
