import 'dart:async';
import 'dart:math';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/terminal_ui.dart';

/// Lets the user resolve unresolved chapters and collisions for one manga
/// (KTD7). For each unresolved source chapter the user types the number of a
/// destination chapter and presses Enter to assign it, `x` to exclude the
/// chapter, Enter alone to leave it unresolved, or Escape to stop.
///
/// Only explicit choices become [ChapterDecision]s; the pipeline re-enforces
/// destination uniqueness after applying them.
class ChapterResolveScreen {
  Future<List<ChapterDecision>> run({
    required TerminalContext context,
    required ChapterAmbiguityRequest request,
  }) async {
    final items = <(SourceChapter, List<PluginChapter>, String)>[
      for (final UnresolvedChapter u in request.unresolved)
        for (final SourceChapter s in sourcesOf(u))
          (s, _candidatesFor(u, request.destinationChapters), unresolvedReason(u)),
    ];
    if (items.isEmpty) return const <ChapterDecision>[];

    final screen = ScreenRegion(context);
    final decisions = <ChapterDecision>[];
    var index = 0;
    var typed = '';
    final done = Completer<void>();

    void render() {
      final (SourceChapter source, List<PluginChapter> candidates, String reason) = items[index];
      final lines = <String>[
        '${bold('Resolve chapters')} ${dim('${request.mangaTitle} (${index + 1}/${items.length})')}',
        '',
        truncate('  ${chapterLabel(source)}', context.width),
        truncate('  ${dim(reason)}', context.width),
        '',
      ];
      final int room = max(1, context.height - lines.length - 4);
      for (final (int i, PluginChapter c) in candidates.take(room).indexed) {
        final number = c.chapterNumber == null ? '?' : '${c.chapterNumber}';
        final vol = c.volumeNumber == null ? '' : 'Vol.${c.volumeNumber} ';
        final group = c.scanlator == null ? '' : ' [${c.scanlator}]';
        lines.add(truncate('  ${i + 1}) $vol${'Ch.$number'} ${c.title ?? ''}$group', context.width));
      }
      if (candidates.length > room) lines.add(dim('  … ${candidates.length - room} more (type its number)'));
      lines
        ..add('')
        ..add('  Choice: $typed${_cursor()}')
        ..add(dim('number + Enter assigns · x excludes · Enter skips · Esc stops'));
      screen.render(lines);
    }

    void advance() {
      typed = '';
      index++;
      if (index >= items.length) {
        if (!done.isCompleted) done.complete();
      } else {
        render();
      }
    }

    context.hideCursor();
    render();
    final StreamSubscription<KeyEvent> keySub = context.keyInput.stream.listen((KeyEvent key) {
      if (done.isCompleted) return;
      final (SourceChapter source, List<PluginChapter> candidates, _) = items[index];
      switch (key) {
        case CharKey(:final String char) when RegExp(r'^[0-9]$').hasMatch(char):
          typed += char;
          render();
        case CharKey(char: 'x' || 'X'):
          decisions.add(ChapterDecision.exclude(stableChapterKey(source)));
          advance();
        case Backspace():
          if (typed.isNotEmpty) typed = typed.substring(0, typed.length - 1);
          render();
        case Enter():
          final int? choice = int.tryParse(typed);
          if (choice != null && choice >= 1 && choice <= candidates.length) {
            decisions.add(
              ChapterDecision(
                sourceChapterKey: stableChapterKey(source),
                destinationChapterId: candidates[choice - 1].chapterId,
              ),
            );
          }
          advance();
        case Escape():
          done.complete();
        default:
          break;
      }
    });
    await done.future;
    await keySub.cancel();
    screen.clear();
    return decisions;
  }

  static List<PluginChapter> _candidatesFor(UnresolvedChapter u, List<PluginChapter> all) => switch (u) {
    AmbiguousChapter(:final candidates) => candidates,
    ChapterCollision(:final destination) => <PluginChapter>[destination, ...all.where((c) => c != destination)],
    UnmatchedChapter() => all,
  };
}

/// An inverse-video block cursor.
String _cursor() => '\x1b[7m \x1b[27m';
