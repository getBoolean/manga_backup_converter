import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/conversion_plan.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_chapter.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_history.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_library_manga.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_manga.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';

sealed class TargetBackupBuilder {
  const TargetBackupBuilder();

  /// Builds the target backup from reconciliation [plans] (one per source
  /// manga). When [report] is given, the builder accounts for every input
  /// record (KTD8). Builders consume the plans' correspondence and never
  /// guess chapter matches themselves.
  ConvertableBackup build(List<MangaConversionPlan> plans, {String? sourceFormatAlias, ConversionReport? report});
}

class AidokuBackupBuilder extends TargetBackupBuilder {
  const AidokuBackupBuilder();

  @override
  ConvertableBackup build(List<MangaConversionPlan> plans, {String? sourceFormatAlias, ConversionReport? report}) {
    final mangaSet = <AidokuBackupManga>{};
    final librarySet = <AidokuBackupLibraryManga>{};
    final chapterSet = <AidokuBackupChapter>{};
    final historySet = <AidokuBackupHistory>{};
    final sources = <String>{};
    final allCategories = <String>{};
    var joinedScanlators = 0;

    for (final plan in plans) {
      final MangaMatchConfirmation confirmation = plan.confirmation;
      final PluginSearchResult? match = confirmation.confirmedMatch;
      final SourceMangaData sourceManga = confirmation.sourceManga;
      if (!plan.isBuildable || match == null) {
        if (report != null) accountUnbuilt(plan, report);
        continue;
      }
      final PluginMangaDetails? details = confirmation.targetMangaDetails;
      final List<PluginChapter> targetChapters = confirmation.targetChapters;
      final String title = sourceManga.details.title;
      report?.add(RecordKind.manga, RecordDisposition.transferred, title, title);

      mangaSet.add(
        AidokuBackupManga(
          sourceId: match.pluginSourceId,
          id: match.mangaKey,
          title: details?.title ?? match.title,
          cover: details?.coverUrl ?? match.coverUrl,
          author: details?.authors.firstOrNull ?? match.authors.firstOrNull,
          artist: details?.artists.firstOrNull ?? sourceManga.details.artists.firstOrNull,
          desc: details?.description ?? sourceManga.details.description,
          tags: details != null && details.tags.isNotEmpty
              ? details.tags
              : sourceManga.details.tagNames.isEmpty
              ? null
              : sourceManga.details.tagNames,
        ),
      );

      librarySet.add(
        AidokuBackupLibraryManga(
          mangaId: match.mangaKey,
          sourceId: match.pluginSourceId,
          dateAdded: sourceManga.dateAdded ?? DateTime.now(),
          lastOpened: sourceManga.lastOpened ?? sourceManga.lastRead ?? DateTime.now(),
          lastUpdated: sourceManga.lastUpdated ?? sourceManga.dateAdded ?? DateTime.now(),
          lastRead: sourceManga.lastRead,
          categories: sourceManga.categories,
        ),
      );

      allCategories.addAll(sourceManga.categories);

      for (final (int i, PluginChapter ch) in targetChapters.indexed) {
        if (ch.scanlators.length > 1) joinedScanlators++;
        chapterSet.add(
          AidokuBackupChapter(
            sourceId: match.pluginSourceId,
            mangaId: match.mangaKey,
            id: ch.chapterId,
            title: ch.title,
            // Aidoku backups hold one scanlator string: every group is kept,
            // joined (see the report note).
            scanlator: ch.scanlator,
            lang: ch.language ?? 'en',
            chapter: ch.chapterNumber,
            volume: ch.volumeNumber,
            dateUploaded: ch.dateUploaded,
            sourceOrder: i,
          ),
        );
      }

      _addChapterState(plan, match, historySet, report);
      sources.add(match.pluginSourceId);
    }

    if (joinedScanlators > 0) {
      report?.notes.add(
        '$joinedScanlators destination chapter(s) list several scanlators; Aidoku backups store one scanlator '
        'field, so the groups are joined with ", "',
      );
    }

    return AidokuBackup(
      library: librarySet,
      history: historySet.isEmpty ? null : historySet,
      manga: mangaSet,
      chapters: chapterSet.isEmpty ? null : chapterSet,
      trackItems: null,
      categories: allCategories.isEmpty ? null : allCategories,
      sources: sources,
      date: DateTime.now(),
      name: sourceFormatAlias != null ? 'Migrated from $sourceFormatAlias' : null,
      version: '0.6.10',
    );
  }

  /// Writes per-chapter reading state for the plan's accepted matches only.
  /// Every emitted history record references a fetched destination chapter;
  /// unresolved and excluded chapters get no state.
  void _addChapterState(
    MangaConversionPlan plan,
    PluginSearchResult match,
    Set<AidokuBackupHistory> historySet,
    ConversionReport? report,
  ) {
    final SourceMangaData sourceManga = plan.sourceManga;
    final String title = sourceManga.details.title;
    for (final ChapterMatch m in plan.reconciliation.matches) {
      final SourceChapter s = m.source;
      report?.add(RecordKind.chapterState, RecordDisposition.transferred, title, chapterLabel(s));
      if (s.isBookmarked) {
        report?.add(
          RecordKind.field,
          RecordDisposition.unrepresentable,
          title,
          'bookmark on ${chapterLabel(s)}',
          reason: 'Aidoku backups cannot represent chapter bookmarks',
        );
      }
      if (!s.isRead && s.lastPageRead <= 0 && s.dateRead == null) continue;
      historySet.add(
        AidokuBackupHistory(
          dateRead: s.dateRead ?? sourceManga.lastRead ?? DateTime.now(),
          sourceId: match.pluginSourceId,
          chapterId: m.destination.chapterId,
          mangaId: match.mangaKey,
          progress: s.lastPageRead > 0 ? s.lastPageRead : null,
          total: s.totalPages,
          completed: s.isRead,
        ),
      );
    }
    if (report == null) return;
    for (final UnresolvedChapter u in plan.reconciliation.unresolved) {
      final String reason = unresolvedReason(u);
      for (final SourceChapter s in switch (u) {
        UnmatchedChapter(:final source) || AmbiguousChapter(:final source) => <SourceChapter>[source],
        ChapterCollision(:final sources) => sources,
      }) {
        report.add(RecordKind.chapterState, RecordDisposition.unresolved, title, chapterLabel(s), reason: reason);
      }
    }
    for (final SourceChapter s in plan.reconciliation.excluded) {
      report.add(
        RecordKind.chapterState,
        RecordDisposition.excluded,
        title,
        chapterLabel(s),
        reason: 'excluded by the user',
      );
    }
    for (final SourceChapter s in sourceManga.secondarySourceChapters.where((SourceChapter c) => c.hasReadingState)) {
      report.add(
        RecordKind.chapterState,
        RecordDisposition.unresolved,
        title,
        '${s.sourceId ?? '?'} ${chapterLabel(s)}',
        reason: 'reading state on a secondary source is not reconciled; not transferred',
      );
    }
    for (var i = 0; i < plan.orphanHistory; i++) {
      report.add(
        RecordKind.history,
        RecordDisposition.unresolved,
        title,
        'history entry ${i + 1}',
        reason: 'not linked to a source chapter; not transferred',
      );
    }
    for (final SourceTrackingEntry t in sourceManga.tracking) {
      report.add(
        RecordKind.tracking,
        RecordDisposition.unrepresentable,
        title,
        trackingLabel(t),
        reason: 'destination tracker identities are unknown, so Aidoku track items are not written',
      );
    }
  }
}

class UnimplementedBackupBuilder extends TargetBackupBuilder {
  const UnimplementedBackupBuilder();

  @override
  ConvertableBackup build(List<MangaConversionPlan> plans, {String? sourceFormatAlias, ConversionReport? report}) {
    // TODO: Implement backup builders for other formats
    throw UnimplementedError('Target backup construction not yet implemented for this format');
  }
}
