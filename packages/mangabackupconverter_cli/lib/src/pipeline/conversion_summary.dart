import 'package:mangabackupconverter_cli/src/pipeline/plugin_source.dart';
import 'package:mangabackupconverter_cli/src/pipeline/source_manga_data.dart';
import 'package:mangabackupconverter_cli/src/reconciliation/chapter_reconciler.dart';

/// What a migration could not carry over, for display after conversion.
///
/// This is the U19 interim summary: unresolved manga and chapters whose state
/// was withheld. Complete loss accounting (KTD8) replaces it later.
class ConversionSummary {
  /// Source manga without a confirmed destination (not migrated).
  final List<SourceMangaData> unresolvedManga = <SourceMangaData>[];

  /// Per-manga chapter-state issues, only for manga that have any.
  final List<MangaChapterReport> chapterReports = <MangaChapterReport>[];

  bool get isEmpty => unresolvedManga.isEmpty && chapterReports.isEmpty;

  /// Human-readable lines (no trailing newlines, no ANSI).
  List<String> describe() {
    if (isEmpty) return const <String>[];
    final lines = <String>['Conversion summary:'];
    if (unresolvedManga.isNotEmpty) {
      lines.add('  ${unresolvedManga.length} manga not migrated (no confirmed match):');
      for (final SourceMangaData m in unresolvedManga) {
        lines.add('    - ${m.details.title}');
      }
    }
    for (final MangaChapterReport report in chapterReports) {
      lines.add('  ${report.mangaTitle}:');
      for (final UnresolvedChapter u in report.unresolvedChapters) {
        lines.add('    - ${_describeUnresolved(u)}');
      }
      if (report.orphanHistoryEntries > 0) {
        lines.add(
          '    - ${report.orphanHistoryEntries} history entr(ies) not linked to a source chapter; not transferred',
        );
      }
      if (report.secondarySourceChaptersWithState > 0) {
        lines.add(
          '    - ${report.secondarySourceChaptersWithState} chapter(s) with reading state on secondary sources; '
          'not transferred',
        );
      }
      if (report.bookmarksNotRepresentable > 0) {
        lines.add('    - ${report.bookmarksNotRepresentable} bookmark(s) cannot be represented by the target format');
      }
    }
    return lines;
  }

  static String _label(SourceChapter c) {
    final String? title = normalizedChapterTitle(c.title) == null ? null : c.title;
    final String number = c.chapterNumber == null ? '?' : _formatNumber(c.chapterNumber!);
    final volume = knownVolumeNumber(c.volumeNumber) == null ? '' : 'Vol.${_formatNumber(c.volumeNumber!)} ';
    final group = c.scanlator == null ? '' : ' [${c.scanlator}]';
    return '$volume${'Ch.$number'}${title == null ? '' : ' "$title"'}$group';
  }

  static String _formatNumber(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toString();

  static String _describeUnresolved(UnresolvedChapter u) => switch (u) {
    UnmatchedChapter(:final SourceChapter source) =>
      '${_label(source)}: no matching destination chapter; state not transferred',
    AmbiguousChapter(:final SourceChapter source, :final List<PluginChapter> candidates) =>
      '${_label(source)}: ${candidates.length} equally plausible destination chapters; state not transferred',
    ChapterCollision(:final PluginChapter destination, :final List<SourceChapter> sources) =>
      '${sources.length} source chapters (${sources.map(_label).join(', ')}) claim destination chapter '
          '"${destination.title ?? destination.chapterId}"; state not transferred',
  };
}

class MangaChapterReport {
  const MangaChapterReport({
    required this.mangaTitle,
    this.unresolvedChapters = const <UnresolvedChapter>[],
    this.orphanHistoryEntries = 0,
    this.secondarySourceChaptersWithState = 0,
    this.bookmarksNotRepresentable = 0,
  });

  final String mangaTitle;
  final List<UnresolvedChapter> unresolvedChapters;
  final int orphanHistoryEntries;
  final int secondarySourceChaptersWithState;
  final int bookmarksNotRepresentable;

  bool get isEmpty =>
      unresolvedChapters.isEmpty &&
      orphanHistoryEntries == 0 &&
      secondarySourceChaptersWithState == 0 &&
      bookmarksNotRepresentable == 0;
}
