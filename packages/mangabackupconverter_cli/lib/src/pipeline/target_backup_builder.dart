import 'package:mangabackupconverter_cli/src/common/convertable.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_chapter.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_history.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_library_manga.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_manga.dart';
import 'package:mangabackupconverter_cli/src/pipeline/conversion_summary.dart';
import 'package:mangabackupconverter_cli/src/pipeline/migration_pipeline.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source.dart';
import 'package:mangabackupconverter_cli/src/pipeline/source_manga_data.dart';
import 'package:mangabackupconverter_cli/src/reconciliation/chapter_reconciler.dart';

sealed class TargetBackupBuilder {
  const TargetBackupBuilder();

  /// Builds the target backup. When [summary] is given, the builder records
  /// unresolved manga and withheld chapter state in it.
  ConvertableBackup build(
    List<MangaMatchConfirmation> confirmations, {
    String? sourceFormatAlias,
    ConversionSummary? summary,
  });
}

class AidokuBackupBuilder extends TargetBackupBuilder {
  const AidokuBackupBuilder();

  @override
  ConvertableBackup build(
    List<MangaMatchConfirmation> confirmations, {
    String? sourceFormatAlias,
    ConversionSummary? summary,
  }) {
    final mangaSet = <AidokuBackupManga>{};
    final librarySet = <AidokuBackupLibraryManga>{};
    final chapterSet = <AidokuBackupChapter>{};
    final historySet = <AidokuBackupHistory>{};
    final sources = <String>{};
    final allCategories = <String>{};

    for (final confirmation in confirmations) {
      final PluginSearchResult? match = confirmation.confirmedMatch;
      final SourceMangaData sourceManga = confirmation.sourceManga;
      if (match == null) {
        summary?.unresolvedManga.add(sourceManga);
        continue;
      }
      final PluginMangaDetails? details = confirmation.targetMangaDetails;
      final List<PluginChapter> targetChapters = confirmation.targetChapters;

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
        chapterSet.add(
          AidokuBackupChapter(
            sourceId: match.pluginSourceId,
            mangaId: match.mangaKey,
            id: ch.chapterId,
            title: ch.title,
            scanlator: ch.scanlator,
            lang: ch.language ?? 'en',
            chapter: ch.chapterNumber,
            volume: ch.volumeNumber,
            dateUploaded: ch.dateUploaded,
            sourceOrder: i,
          ),
        );
      }

      final MangaChapterReport report = _addChapterState(sourceManga, match, targetChapters, historySet);
      if (!report.isEmpty) summary?.chapterReports.add(report);

      sources.add(match.pluginSourceId);
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

  /// Transfers per-chapter reading state onto the fetched destination
  /// chapters through [reconcileChapters]. Every emitted history record
  /// references a destination chapter; unresolved chapters get no state.
  MangaChapterReport _addChapterState(
    SourceMangaData sourceManga,
    PluginSearchResult match,
    List<PluginChapter> targetChapters,
    Set<AidokuBackupHistory> historySet,
  ) {
    final (List<SourceChapter> chapters, int orphanHistory) = mergeHistoryIntoChapters(sourceManga);
    final List<SourceChapter> stateful = chapters.where((SourceChapter c) => c.hasReadingState).toList();

    // Exact chapter IDs are only trusted when the destination is the very
    // same source and manga the backup came from.
    final bool sameSourceIdentity =
        sourceManga.sourceId != null &&
        sourceManga.sourceId == match.pluginSourceId &&
        sourceManga.sourceMangaKey != null &&
        sourceManga.sourceMangaKey == match.mangaKey;

    final ChapterReconciliation reconciliation = reconcileChapters(
      sourceChapters: stateful,
      destinationChapters: targetChapters,
      sameSourceIdentity: sameSourceIdentity,
    );

    var bookmarks = 0;
    for (final ChapterMatch m in reconciliation.matches) {
      final SourceChapter s = m.source;
      if (s.isBookmarked) bookmarks++;
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

    return MangaChapterReport(
      mangaTitle: sourceManga.details.title,
      unresolvedChapters: reconciliation.unresolved,
      orphanHistoryEntries: orphanHistory,
      secondarySourceChaptersWithState: sourceManga.secondarySourceChapters
          .where((SourceChapter c) => c.hasReadingState)
          .length,
      bookmarksNotRepresentable: bookmarks,
    );
  }
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

class UnimplementedBackupBuilder extends TargetBackupBuilder {
  const UnimplementedBackupBuilder();

  @override
  ConvertableBackup build(
    List<MangaMatchConfirmation> confirmations, {
    String? sourceFormatAlias,
    ConversionSummary? summary,
  }) {
    // TODO: Implement backup builders for other formats
    throw UnimplementedError('Target backup construction not yet implemented for this format');
  }
}
