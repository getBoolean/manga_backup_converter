import 'dart:async';
import 'dart:math';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/live_search_select.dart';
import 'package:mangabackupconverter_cli/src/commands/manga_details_screen.dart';
import 'package:mangabackupconverter_cli/src/commands/terminal_ui.dart';
import 'package:source_runtime/source_contracts.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class MigrationEntry {
  MigrationEntry({required this.source}) : selected = true, searching = true, candidates = [], failures = [];

  final SourceMangaData source;
  bool selected;
  bool searching;
  PluginSearchResult? match;
  List<PluginSearchResult> candidates;
  List<PluginSearchFailure> failures;

  /// The match whose details are being fetched in the background; accepting
  /// waits for it so the confirmation carries the snapshot.
  PluginSearchResult? enrichingFor;

  /// Whether this entry still blocks acceptance.
  bool get busy => selected && (searching || enrichingFor != null);
}

// ---------------------------------------------------------------------------
// Internal events
// ---------------------------------------------------------------------------

sealed class _DashboardEvent {}

class _KeyEvent extends _DashboardEvent {
  _KeyEvent(this.key);
  final KeyEvent key;
}

class _SearchResultEvent extends _DashboardEvent {
  _SearchResultEvent(this.entry, this.event);
  final MigrationEntry entry;
  final PluginSearchEvent event;
}

class _SearchDoneEvent extends _DashboardEvent {
  _SearchDoneEvent(this.entry);
  final MigrationEntry entry;
}

class _EnrichmentDoneEvent extends _DashboardEvent {
  _EnrichmentDoneEvent(this.entry, this.original, this.outcome);
  final MigrationEntry entry;

  /// The match that was sent for enrichment.
  final PluginSearchResult original;
  final DetailsOutcome outcome;
}

class _SpinnerTickEvent extends _DashboardEvent {}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

class MigrationDashboard {
  Future<List<MangaMatchConfirmation>> run({
    required TerminalContext context,
    required List<String> pluginNames,
    required List<SourceMangaData> manga,
    required Stream<PluginSearchEvent> Function(String query) onSearch,
    required FetchDetails onFetchDetails,
  }) async {
    if (manga.isEmpty) return [];

    final List<MigrationEntry> entries = manga.map((SourceMangaData m) => MigrationEntry(source: m)).toList();
    var cursorIndex = 0;
    var scrollOffset = 0;

    final events = StreamController<_DashboardEvent>();
    final spinner = Spinner();
    final screen = ScreenRegion(context);

    // Listen for key events on shared KeyInput (broadcast stream).
    StreamSubscription<KeyEvent> keySub = context.keyInput.stream.listen((KeyEvent key) => events.add(_KeyEvent(key)));

    // Search entries one at a time. A confirmed match's details are fetched
    // in the background (sessions queue overlapping calls), so the next
    // search never waits for them.
    var nextSearchIndex = 0;
    StreamSubscription<PluginSearchEvent>? activeSub;
    MigrationEntry? activeEntry;
    final pendingRetries = <MigrationEntry>[];

    // One details fetch per result: background enrichment and Tab share it.
    // A failed fetch is forgotten so a later Tab retries it.
    final details = <PluginSearchResult, Future<DetailsOutcome>>{};
    Future<DetailsOutcome> detailsOf(PluginSearchResult r) {
      final DetailsOutcome? known = r.fetchedOutcome;
      if (known != null) return Future<DetailsOutcome>.value(known);
      return details.putIfAbsent(
        r,
        () =>
            Future<DetailsOutcome>(() => onFetchDetails(r.ref))
                .onError<Object>((Object e, _) => DetailsFailed(SourceErrorFailure('$e')))
                .then((DetailsOutcome o) {
                  if (o is DetailsFailed) details.remove(r);
                  return o;
                }),
      );
    }

    /// Replaces [entry]'s match with [original] enriched by [outcome], unless
    /// the match changed meanwhile (a manual pick or a restarted search).
    void applyDetails(MigrationEntry entry, PluginSearchResult original, DetailsOutcome outcome) {
      final FetchedManga? fetched = outcome.fetchedOrNull;
      if (fetched != null && identical(entry.match, original) && original.fetched == null) {
        entry.match = original.enrichedWith(fetched);
      }
    }

    void startSearch(MigrationEntry entry) {
      entry.candidates.clear();
      entry.failures.clear();
      entry.match = null;
      entry.enrichingFor = null;
      entry.searching = true;
      activeEntry = entry;
      final Stream<PluginSearchEvent> stream = onSearch(entry.source.details.title);
      activeSub = stream.listen(
        (PluginSearchEvent event) => events.add(_SearchResultEvent(entry, event)),
        onDone: () => events.add(_SearchDoneEvent(entry)),
      );
    }

    void startNextSearch() {
      // Drain pending retries first.
      while (pendingRetries.isNotEmpty) {
        final MigrationEntry retry = pendingRetries.removeAt(0);
        if (retry.selected && retry.searching) {
          startSearch(retry);
          return;
        }
      }
      // Continue linear scan.
      while (nextSearchIndex < entries.length) {
        final MigrationEntry entry = entries[nextSearchIndex++];
        // Skip deselected entries and entries the user already chose manually
        // (startSearch would discard the manual choice).
        if (!entry.selected || entry.match != null) {
          entry.searching = false;
          continue;
        }
        startSearch(entry);
        return;
      }
    }

    startNextSearch();

    // Spinner tick.
    spinner.start(() => events.add(_SpinnerTickEvent()));

    context.hideCursor();

    void render() {
      final int budget = max(4, context.height - 6);

      // Adjust scroll to keep cursor visible.
      if (cursorIndex < scrollOffset) scrollOffset = cursorIndex;
      while (cursorIndex >= scrollOffset + _visibleCount(entries, scrollOffset, budget)) {
        scrollOffset++;
      }

      final int visibleEnd = min(
        entries.length,
        scrollOffset + _visibleCount(entries, scrollOffset, budget),
      );

      final lines = <String>[];
      lines.add('${bold('Migration')} ${dim(pluginNames.join(', '))}');
      lines.add('');
      if (scrollOffset > 0) {
        lines.add(dim('↑ more above'));
      }

      for (var i = scrollOffset; i < visibleEnd; i++) {
        final MigrationEntry entry = entries[i];
        final isCursor = i == cursorIndex;
        lines.addAll(_renderEntry(entry, isCursor, spinner, context.width));
      }

      if (visibleEnd < entries.length) {
        lines.add(dim('↓ more below'));
      }

      lines.add('');
      final bool allDone = !entries.any((MigrationEntry e) => e.busy);
      final acceptHint = allDone ? 'y to accept selections' : 'searching... ${spinner.frame}';
      lines.add(
        dim(acceptHint) +
            dim(' · ') +
            dim('Space to toggle') +
            dim(' · ') +
            dim('Tab details') +
            dim(' · ') +
            dim('Enter to choose manually'),
      );

      screen.render(lines);
    }

    render();

    var accepted = false;

    try {
      await for (final _DashboardEvent event in events.stream) {
        switch (event) {
          case _KeyEvent(key: ArrowUp() || ScrollUp()):
            cursorIndex = max(0, cursorIndex - 1);
            render();

          case _KeyEvent(key: ArrowDown() || ScrollDown()):
            cursorIndex = min(entries.length - 1, cursorIndex + 1);
            render();

          case _KeyEvent(key: Space()):
            final MigrationEntry toggled = entries[cursorIndex];
            toggled.selected = !toggled.selected;
            if (!toggled.selected && toggled == activeEntry) {
              // Cancel the active search for this entry.
              await activeSub?.cancel();
              activeSub = null;
              activeEntry = null;
              startNextSearch();
            } else if (toggled.selected && toggled.match == null) {
              // Re-selected while search never completed or was skipped.
              toggled.searching = true;
              pendingRetries.add(toggled);
              if (activeEntry == null) startNextSearch();
            }
            render();

          case _KeyEvent(key: Tab()):
            final MigrationEntry tabEntry = entries[cursorIndex];
            if (tabEntry.match == null) break;

            await keySub.cancel();
            screen.clear();

            final PluginSearchResult shown = tabEntry.match!;
            DetailsOutcome? shownDetails;
            final detailsScreen = MangaDetailsScreen();
            await detailsScreen.run(
              context: context,
              result: shown,
              // Reuses enriched or in-flight details; otherwise fetches once.
              fetchDetails: () async => shownDetails = await detailsOf(shown),
            );
            if (shownDetails case final DetailsOutcome o) applyDetails(tabEntry, shown, o);

            keySub = context.keyInput.stream.listen(
              (KeyEvent key) => events.add(_KeyEvent(key)),
            );
            context.hideCursor();
            render();

          case _KeyEvent(key: CharKey(char: 'y')):
            if (entries.any((MigrationEntry e) => e.busy)) break;
            accepted = true;
            unawaited(events.close());

          case _KeyEvent(key: Enter()):
            // Cancel active search to free WASM plugins for the live search.
            await activeSub?.cancel();
            activeSub = null;
            final interrupted = activeEntry;
            activeEntry = null;

            await keySub.cancel();
            screen.clear();

            final MigrationEntry entry = entries[cursorIndex];
            final liveSearch = LiveSearchSelect();
            final PluginSearchResult? result = await liveSearch.run(
              context: context,
              initialQuery: entry.source.details.title,
              onSearch: onSearch,
              onFetchDetails: onFetchDetails,
              onFailure: entry.failures.add,
            );
            if (result != null) {
              entry.match = result;
              entry.enrichingFor = null;
              entry.selected = true;
              entry.searching = false;
            }

            // Re-queue interrupted search if it didn't complete.
            if (interrupted != null && interrupted.selected && interrupted.match == null) {
              pendingRetries.insert(0, interrupted);
            }
            if (activeEntry == null) startNextSearch();

            keySub = context.keyInput.stream.listen(
              (KeyEvent key) => events.add(_KeyEvent(key)),
            );
            context.hideCursor();
            render();

          case _SearchResultEvent(event: PluginSearchStarted()):
            break; // No-op — dashboard doesn't show per-plugin status.

          case _SearchResultEvent(:final entry, event: PluginSearchResults(:final results)):
            if (entry != activeEntry) break; // Stale event from cancelled sub.
            if (results.isNotEmpty) entry.candidates.add(results.first);
            render();

          case _SearchResultEvent(:final entry, event: PluginSearchError(:final failure)):
            if (entry != activeEntry) break; // Stale event from cancelled sub.
            entry.failures.add(failure);
            render();

          case _SearchDoneEvent(:final entry):
            if (entry != activeEntry) break; // Stale event from cancelled sub.
            // R8: auto-confirm only an unambiguous exact-title match; titles
            // are all it needs, so the next search starts right away.
            final PluginSearchResult? match = uniqueExactTitleMatch(entry.source.details.title, entry.candidates);
            entry.match = match;
            entry.searching = false;
            activeEntry = null;
            if (match != null) {
              // Fetch the match's details in the background for display; the
              // enriched match carries the snapshot to the pipeline, which
              // then does not fetch it again. A failed fetch leaves it
              // unenriched; the pipeline retries it and reports the failure.
              entry.enrichingFor = match;
              unawaited(
                detailsOf(match).then((DetailsOutcome o) {
                  if (!events.isClosed) events.add(_EnrichmentDoneEvent(entry, match, o));
                }),
              );
            }
            startNextSearch();
            render();

          case _EnrichmentDoneEvent(:final entry, :final original, :final outcome):
            if (identical(entry.enrichingFor, original)) entry.enrichingFor = null;
            applyDetails(entry, original, outcome);
            render();

          case _SpinnerTickEvent():
            if (entries.any((MigrationEntry e) => e.busy)) render();

          case _KeyEvent():
            break; // Unhandled keys.
        }

        if (events.isClosed) break;
      }
    } finally {
      // Cleanup -- always restore terminal state.
      spinner.stop();
      await activeSub?.cancel();
      await keySub.cancel();
      screen.clear();
      context.showCursor();
    }

    if (!accepted) return [];

    return entries
        .map(
          (MigrationEntry e) => MangaMatchConfirmation(
            sourceManga: e.source,
            confirmedMatch: e.selected ? e.match : null,
            // Deselecting is an explicit exclusion, not a loss.
            excluded: !e.selected,
            searchFailures: List<PluginSearchFailure>.of(e.failures),
          ),
        )
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Rendering helpers
// ---------------------------------------------------------------------------

int _entryLineCount(MigrationEntry entry) => 5;

/// How many entries fit within [budget] lines starting from [scrollOffset].
int _visibleCount(List<MigrationEntry> entries, int scrollOffset, int budget) {
  var used = 0;
  var count = 0;
  for (var i = scrollOffset; i < entries.length; i++) {
    final int h = _entryLineCount(entries[i]);
    if (used + h > budget) break;
    used += h;
    count++;
  }
  return max(1, count);
}

List<String> _renderEntry(MigrationEntry entry, bool isCursor, Spinner spinner, int width) {
  final checkbox = entry.selected ? '◉' : '◯';
  const indent = '  ';

  final String sourceTitle = entry.source.details.title;
  final String sourceAuthors = <String>{
    ...entry.source.details.authors,
    ...entry.source.details.artists,
  }.join(', ');
  final int sourceChapters = entry.source.chapters.length;
  final String? sourceId = entry.source.sourceId;
  final String sourceInfo = [
    if (sourceId != null && sourceId.isNotEmpty) sourceId,
    if (sourceAuthors.isNotEmpty) sourceAuthors,
    '$sourceChapters chapters',
  ].join(' · ');

  final lines = <String>[];
  final cursorMark = isCursor ? '❯ ' : '  ';
  lines.add(truncate('$cursorMark$checkbox ${bold(sourceTitle)}', width));
  lines.add(truncate('$indent  ${dim(sourceInfo)}', width));

  if (!entry.selected) {
    lines.add('$indent  ${dim('⏭ skipped')}');
    lines.add(indent);
    lines.add(indent);
  } else {
    lines.add('$indent  ${dim('↓')}');

    if (entry.searching && entry.match == null) {
      lines.add('$indent  ${spinner.frame}');
      lines.add(indent);
    } else if (entry.match != null) {
      final PluginSearchResult m = entry.match!;
      final PluginMangaDetails? d = m.details;
      final String matchText = green(m.title);
      final String? linkUrl = d?.url;
      final String linkedMatch = linkUrl != null ? hyperlink(matchText, linkUrl) : matchText;
      lines.add(truncate('$indent  $linkedMatch', width));

      final String matchAuthors = <String>{
        ...m.authors,
        if (d != null) ...d.artists,
      }.join(', ');
      final String? chapterCount = d != null ? '${m.chapters.length} chapters' : null;
      final String errorHint = entry.failures.isNotEmpty ? yellow('\u26A0 ${entry.failures.length} error(s)') : '';
      final String infoLine = [
        m.pluginSourceName ?? m.pluginSourceId,
        if (matchAuthors.isNotEmpty) matchAuthors,
        if (chapterCount != null) chapterCount,
        if (errorHint.isNotEmpty) errorHint,
      ].join(' \u00B7 ');
      lines.add(infoLine.isNotEmpty ? truncate('$indent  ${dim(infoLine)}', width) : indent);
    } else if (entry.candidates.isNotEmpty) {
      final int n = entry.candidates.length;
      lines.add('$indent  ${yellow('$n candidate${n == 1 ? '' : 's'}, none confirmed automatically')}');
      lines.add('$indent  ${dim('Enter to choose')}');
    } else if (entry.failures.isNotEmpty) {
      lines.add('$indent  ${yellow('\u26A0 ${entry.failures.length} plugin error(s) (see log)')}');
      lines.add(indent);
    } else {
      lines.add('$indent  ${dim('No match found')}');
      lines.add(indent);
    }
  }

  return lines;
}

/// Returns the single candidate, across all plugins, whose title exactly
/// matches [title] (case-insensitive, whitespace-normalized), or `null` when
/// there is none or more than one.
///
/// This is the only automatic manga confirmation (R8): chapter counts and
/// result order are not evidence of identity, so anything else is left for
/// the user to choose (interactive) or unresolved (non-interactive).
PluginSearchResult? uniqueExactTitleMatch(String title, Iterable<PluginSearchResult> candidates) {
  final String? wanted = normalizedChapterTitle(title);
  if (wanted == null) return null;
  final List<PluginSearchResult> exact = candidates
      .where((PluginSearchResult r) => normalizedChapterTitle(r.title) == wanted)
      .take(2)
      .toList();
  return exact.length == 1 ? exact.single : null;
}
