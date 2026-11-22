import 'package:manga_backup_core/src/conversion/conversion_plan.dart';
import 'package:manga_backup_core/src/conversion/manga_details.dart';
import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';

/// One plan standing for several source manga confirmed to the same
/// destination manga (the same series from two sources), so a writer writes
/// that destination once.
///
/// Reading state on the same destination chapter is folded as history is
/// folded into chapters (read if any source read it, the furthest page, the
/// latest read date); categories are the ordered union; the earliest date
/// added and the latest read, opened and updated dates win; metadata
/// fallbacks take the first non-empty value; destination chapters are the
/// union by chapter ID. Accounting stays per source plan: this plan is only
/// what gets written.
MangaConversionPlan mergeDestinationPlans(List<MangaConversionPlan> plans) {
  if (plans.length == 1) return plans.single;
  final MangaConversionPlan first = plans.first;
  final sources = <SourceMangaData>[for (final p in plans) p.sourceManga];

  final matchesByChapter = <String, List<ChapterMatch>>{};
  for (final p in plans) {
    for (final ChapterMatch m in p.reconciliation.matches) {
      (matchesByChapter[m.destination.chapterId] ??= <ChapterMatch>[]).add(m);
    }
  }
  final targetChapters = <String, PluginChapter>{
    for (final p in plans)
      for (final PluginChapter c in p.confirmation.targetChapters) c.chapterId: c,
  };

  final confirmation = MangaMatchConfirmation(
    sourceManga: _mergeSourceManga(sources),
    confirmedMatch: first.confirmation.confirmedMatch,
    targetMangaDetails: plans.map((p) => p.confirmation.targetMangaDetails).nonNulls.firstOrNull,
    targetChapters: targetChapters.values.toList(),
    destination: first.confirmation.destination,
  );
  return MangaConversionPlan(
    confirmation: confirmation,
    statefulChapters: <SourceChapter>[for (final p in plans) ...p.statefulChapters],
    reconciliation: ChapterReconciliation(
      matches: <ChapterMatch>[
        for (final List<ChapterMatch> ms in matchesByChapter.values)
          ChapterMatch(_mergeState(<SourceChapter>[for (final m in ms) m.source]), ms.first.destination),
      ],
      unresolved: const <UnresolvedChapter>[],
    ),
    orphanHistory: 0,
  );
}

SourceChapter _mergeState(List<SourceChapter> chapters) {
  if (chapters.length == 1) return chapters.single;
  final SourceChapter c = chapters.first;
  DateTime? dateRead;
  for (final s in chapters) {
    final DateTime? d = s.dateRead;
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
    isRead: chapters.any((SourceChapter s) => s.isRead),
    isBookmarked: chapters.any((SourceChapter s) => s.isBookmarked),
    lastPageRead: chapters.map((SourceChapter s) => s.lastPageRead).reduce((int a, int b) => a > b ? a : b),
    totalPages: chapters.map((SourceChapter s) => s.totalPages).nonNulls.firstOrNull,
    dateRead: dateRead,
    dateUploaded: c.dateUploaded,
    sourceOrder: c.sourceOrder,
  );
}

SourceMangaData _mergeSourceManga(List<SourceMangaData> sources) {
  final SourceMangaData first = sources.first;
  List<String> firstList(List<String> Function(MangaSearchDetails d) field) => sources
      .map((SourceMangaData s) => field(s.details))
      .firstWhere((List<String> l) => l.isNotEmpty, orElse: () => const <String>[]);
  T? firstValue<T extends Object>(T? Function(SourceMangaData s) field) => sources.map(field).nonNulls.firstOrNull;
  DateTime? pick(DateTime? Function(SourceMangaData s) field, {required bool latest}) {
    DateTime? best;
    for (final DateTime d in sources.map(field).nonNulls) {
      if (best == null || (latest ? d.isAfter(best) : d.isBefore(best))) best = d;
    }
    return best;
  }

  return SourceMangaData(
    details: MangaSearchDetails(
      title: first.details.title,
      altTitles: firstList((MangaSearchDetails d) => d.altTitles),
      authors: firstList((MangaSearchDetails d) => d.authors),
      artists: firstList((MangaSearchDetails d) => d.artists),
      tagNames: firstList((MangaSearchDetails d) => d.tagNames),
      description: firstValue((SourceMangaData s) {
        final String? text = s.details.description;
        return text == null || text.isEmpty ? null : text;
      }),
      coverImageUrl: firstValue((SourceMangaData s) => s.details.coverImageUrl),
      languages: firstList((MangaSearchDetails d) => d.languages),
    ),
    sourceId: first.sourceId,
    sourceMangaKey: first.sourceMangaKey,
    categories: <String>{for (final s in sources) ...s.categories}.toList(),
    chapters: <SourceChapter>[for (final s in sources) ...s.chapters],
    tracking: <SourceTrackingEntry>[for (final s in sources) ...s.tracking],
    dateAdded: pick((SourceMangaData s) => s.dateAdded, latest: false),
    lastRead: pick((SourceMangaData s) => s.lastRead, latest: true),
    lastOpened: pick((SourceMangaData s) => s.lastOpened, latest: true),
    lastUpdated: pick((SourceMangaData s) => s.lastUpdated, latest: true),
    status: firstValue((SourceMangaData s) => s.status),
  );
}
