import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_decisions.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';

/// Everything a builder needs for one source manga: the decision, and — for
/// a fetched match — the reconciliation plan (KTD7) with user overrides
/// applied. Builders consume plans; they never rematch chapters.
final class MangaConversionPlan {
  const MangaConversionPlan({
    required this.confirmation,
    required this.statefulChapters,
    required this.reconciliation,
    required this.orphanHistory,
    this.decisions = const <ChapterDecision>[],
  });

  final MangaMatchConfirmation confirmation;

  /// Primary-source chapters carrying reading state (history merged in).
  final List<SourceChapter> statefulChapters;

  /// Correspondence for [statefulChapters]; empty unless the manga has a
  /// fetched destination.
  final ChapterReconciliation reconciliation;

  /// History entries referencing no chapter of the manga.
  final int orphanHistory;

  /// User chapter decisions applied to [reconciliation].
  final List<ChapterDecision> decisions;

  SourceMangaData get sourceManga => confirmation.sourceManga;

  /// Whether the manga has a fetched destination a builder can write.
  bool get isBuildable =>
      !confirmation.excluded && confirmation.confirmedMatch != null && confirmation.detailsFailure == null;

  /// Whether exact chapter IDs may be trusted: the destination is the very
  /// same source and manga the backup came from.
  static bool sameSourceIdentity(MangaMatchConfirmation c) {
    final SourceMangaData s = c.sourceManga;
    final String? sourceId = c.confirmedMatch?.pluginSourceId;
    return s.sourceId != null &&
        s.sourceId == sourceId &&
        s.sourceMangaKey != null &&
        s.sourceMangaKey == c.confirmedMatch?.mangaKey;
  }
}

/// Reconciles [confirmation]'s state-bearing chapters against its fetched
/// destination chapters and applies [decisions]. Pure; no source calls.
MangaConversionPlan planConversion(
  MangaMatchConfirmation confirmation, {
  List<ChapterDecision> decisions = const <ChapterDecision>[],
}) {
  final (List<SourceChapter> merged, int orphans) = mergeHistoryIntoChapters(confirmation.sourceManga);
  final List<SourceChapter> stateful = merged.where((SourceChapter c) => c.hasReadingState).toList();
  final bool buildable =
      !confirmation.excluded && confirmation.confirmedMatch != null && confirmation.detailsFailure == null;
  if (!buildable) {
    return MangaConversionPlan(
      confirmation: confirmation,
      statefulChapters: stateful,
      reconciliation: const ChapterReconciliation(matches: <ChapterMatch>[], unresolved: <UnresolvedChapter>[]),
      orphanHistory: orphans,
    );
  }
  final ChapterReconciliation base = reconcileChapters(
    sourceChapters: stateful,
    destinationChapters: confirmation.targetChapters,
    sameSourceIdentity: MangaConversionPlan.sameSourceIdentity(confirmation),
  );
  return MangaConversionPlan(
    confirmation: confirmation,
    statefulChapters: stateful,
    reconciliation: applyChapterDecisions(base, decisions, confirmation.targetChapters),
    orphanHistory: orphans,
    decisions: decisions,
  );
}

/// Folds [SourceMangaData.history] into the chapters it references by
/// [SourceHistoryEntry.chapterKey]: completion, furthest page, total pages and
/// latest read date. Returns the merged chapters and the number of history
/// entries that reference no chapter (those are never transferred — a
/// chapter title is not a destination identifier).
(List<SourceChapter>, int) mergeHistoryIntoChapters(SourceMangaData manga) {
  final byKey = <String, List<SourceHistoryEntry>>{};
  var orphans = 0;
  final chapterKeys = <String>{
    for (final SourceChapter c in manga.chapters) ?c.chapterKey,
  };
  for (final SourceHistoryEntry h in manga.history) {
    final String? key = h.chapterKey;
    if (key == null || !chapterKeys.contains(key)) {
      orphans++;
      continue;
    }
    (byKey[key] ??= <SourceHistoryEntry>[]).add(h);
  }

  final List<SourceChapter> merged = manga.chapters.map((SourceChapter c) {
    final List<SourceHistoryEntry>? entries = c.chapterKey == null ? null : byKey[c.chapterKey];
    if (entries == null || entries.isEmpty) return c;
    bool isRead = c.isRead;
    int lastPage = c.lastPageRead;
    int? total = c.totalPages;
    DateTime? dateRead = c.dateRead;
    for (final SourceHistoryEntry h in entries) {
      isRead = isRead || h.completed;
      if ((h.progress ?? 0) > lastPage) lastPage = h.progress!;
      total ??= h.total;
      final DateTime? d = h.dateRead;
      if (d != null && (dateRead == null || d.isAfter(dateRead))) dateRead = d;
    }
    return SourceChapter(
      title: c.title,
      chapterKey: c.chapterKey,
      sourceId: c.sourceId,
      chapterNumber: c.chapterNumber,
      volumeNumber: c.volumeNumber,
      scanlator: c.scanlator,
      language: c.language,
      isRead: isRead,
      isBookmarked: c.isBookmarked,
      lastPageRead: lastPage,
      totalPages: total,
      dateRead: dateRead,
      dateUploaded: c.dateUploaded,
      sourceOrder: c.sourceOrder,
    );
  }).toList();
  return (merged, orphans);
}

/// Short human-readable label for a source chapter.
String chapterLabel(SourceChapter c) {
  final String? title = normalizedChapterTitle(c.title) == null ? null : c.title;
  final String number = c.chapterNumber == null ? '?' : _formatNumber(c.chapterNumber!);
  final volume = knownVolumeNumber(c.volumeNumber) == null ? '' : 'Vol.${_formatNumber(c.volumeNumber!)} ';
  final group = c.scanlator == null ? '' : ' [${c.scanlator}]';
  return '$volume${'Ch.$number'}${title == null ? '' : ' "$title"'}$group';
}

String _formatNumber(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toString();

/// Why [u] stays unresolved, for the report.
String unresolvedReason(UnresolvedChapter u) => switch (u) {
  UnmatchedChapter() => 'no matching destination chapter; state not transferred',
  AmbiguousChapter(:final candidates) =>
    '${candidates.length} equally plausible destination chapters; state not transferred',
  ChapterCollision(:final destination, :final sources) =>
    '${sources.length} source chapters (${sources.map(chapterLabel).join(', ')}) claim destination chapter '
        '"${destination.title ?? destination.chapterId}"; state not transferred',
};

/// Records every input record of a manga that is not built — excluded by the
/// user or without a usable destination — with one shared disposition.
void accountUnbuilt(MangaConversionPlan plan, ConversionReport report) {
  final MangaMatchConfirmation c = plan.confirmation;
  final String title = c.sourceManga.details.title;
  final RecordDisposition d = c.excluded ? RecordDisposition.excluded : RecordDisposition.unresolved;
  final String reason = switch (c) {
    MangaMatchConfirmation(excluded: true) => 'skipped by the user',
    MangaMatchConfirmation(:final detailsFailure?) =>
      'details for the confirmed match could not be fetched (${detailsFailure.code}: ${detailsFailure.message})',
    MangaMatchConfirmation(:final searchFailures) when searchFailures.isNotEmpty =>
      'no confirmed match; ${searchFailures.length} source search failure(s): '
          '${searchFailures.map((PluginSearchFailure f) => '${f.pluginName ?? f.pluginId} ${f.failure.code}').join(', ')}',
    _ => 'no confirmed match',
  };
  report.add(RecordKind.manga, d, title, title, reason: reason);
  final childReason = c.excluded ? 'manga skipped by the user' : 'manga not migrated';
  for (final SourceChapter ch in plan.statefulChapters) {
    report.add(RecordKind.chapterState, d, title, chapterLabel(ch), reason: childReason);
  }
  for (final SourceChapter ch in c.sourceManga.secondarySourceChapters.where((SourceChapter s) => s.hasReadingState)) {
    report.add(RecordKind.chapterState, d, title, '${ch.sourceId ?? '?'} ${chapterLabel(ch)}', reason: childReason);
  }
  for (var i = 0; i < plan.orphanHistory; i++) {
    report.add(RecordKind.history, d, title, 'history entry ${i + 1}', reason: childReason);
  }
  for (final SourceTrackingEntry t in c.sourceManga.tracking) {
    report.add(RecordKind.tracking, d, title, trackingLabel(t), reason: childReason);
  }
}

/// Short label for a tracking record.
String trackingLabel(SourceTrackingEntry t) => 'tracker ${t.syncId}${t.title == null ? '' : ' "${t.title}"'}';
