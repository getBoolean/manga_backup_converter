import 'dart:typed_data';

import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
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

/// A destination backup writer (KTD15: registered in `FormatRegistry`, never
/// selected by a `BackupFormat` model).
///
/// Writers consume reconciliation [MangaConversionPlan]s and never guess
/// chapter matches themselves (KTD7). Every writer also checks the exact
/// bytes about to be published (KTD8 pre-publish validation).
abstract class TargetBackupBuilder {
  const TargetBackupBuilder();

  /// The format this writer produces.
  BackupFormat get format;

  /// Builds the target backup from reconciliation [plans] (one per source
  /// manga). When [report] is given, the builder accounts for every input
  /// record (KTD8).
  ConvertableBackup build(List<MangaConversionPlan> plans, {String? sourceFormatAlias, ConversionReport? report});

  /// Structural validation of the exact [bytes] that will be published,
  /// decoded again, against the [plans] they were built from: every
  /// reference resolves, and no reading state points at a chapter the
  /// destination runtime did not return. Returns the problems found; empty
  /// means valid.
  List<String> validate(Uint8List bytes, List<MangaConversionPlan> plans);
}

/// The destination chapters each buildable plan fetched, keyed by runtime
/// source ID and native manga ID. Validators check written state against it,
/// so no state lands on a chapter the runtime did not return.
final class FetchedChapterIndex {
  FetchedChapterIndex(List<MangaConversionPlan> plans) {
    for (final plan in plans) {
      final PluginSearchResult? match = plan.confirmation.confirmedMatch;
      if (!plan.isBuildable || match == null) continue;
      (_chapters[_key(match.pluginSourceId, match.mangaKey)] ??= <String>{}).addAll(
        plan.confirmation.targetChapters.map((PluginChapter c) => c.chapterId),
      );
    }
  }

  final Map<String, Set<String>> _chapters = <String, Set<String>>{};

  static String _key(String sourceId, String mangaId) => '$sourceId\u0000$mangaId';

  /// Whether the plans built the manga `(sourceId, mangaId)`.
  bool hasManga(String sourceId, String mangaId) => _chapters.containsKey(_key(sourceId, mangaId));

  /// Whether the runtime returned [chapterId] for that manga.
  bool fetched(String sourceId, String mangaId, String chapterId) =>
      _chapters[_key(sourceId, mangaId)]?.contains(chapterId) ?? false;

  int get mangaCount => _chapters.length;
}

/// Accounts for the reading state of a built plan (KTD8): matched chapters
/// are transferred; unresolved, excluded and secondary-source chapters and
/// unlinked history keep their disposition; tracking records get
/// [trackingDisposition]. Writers add their own unrepresentable fields.
void accountChapterState(
  MangaConversionPlan plan,
  ConversionReport report, {
  required RecordDisposition trackingDisposition,
  required String trackingReason,
}) {
  final SourceMangaData sourceManga = plan.sourceManga;
  final String title = sourceManga.details.title;
  for (final ChapterMatch m in plan.reconciliation.matches) {
    report.add(RecordKind.chapterState, RecordDisposition.transferred, title, chapterLabel(m.source));
  }
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
    report.add(RecordKind.tracking, trackingDisposition, title, trackingLabel(t), reason: trackingReason);
  }
}

/// Reason recorded for tracking records a writer cannot map: no tracker
/// mapping between these apps has been verified.
const String unverifiedTrackingReason =
    'no verified tracker-service mapping exists for this destination, so tracking records are not written';

/// Decodes [bytes] with [decode], turning a decode error into a problem.
(T?, List<String>) decodeForValidation<T>(Uint8List bytes, T Function(Uint8List bytes) decode) {
  try {
    return (decode(bytes), const <String>[]);
  } on Object catch (e) {
    return (null, <String>['the written backup does not decode: $e']);
  }
}

class AidokuBackupBuilder extends TargetBackupBuilder {
  const AidokuBackupBuilder();

  @override
  BackupFormat get format => const Aidoku();

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
    accountChapterState(
      plan,
      report,
      trackingDisposition: RecordDisposition.unrepresentable,
      trackingReason: 'destination tracker identities are unknown, so Aidoku track items are not written',
    );
  }

  @override
  List<String> validate(Uint8List bytes, List<MangaConversionPlan> plans) {
    final (AidokuBackup? backup, List<String> decodeProblems) = decodeForValidation(bytes, AidokuBackup.fromData);
    if (backup == null) return decodeProblems;
    final problems = <String>[];
    final index = FetchedChapterIndex(plans);
    final mangaKeys = <String>{
      for (final AidokuBackupManga m in backup.manga ?? const <AidokuBackupManga>{}) '${m.sourceId}|${m.id}',
    };
    final chapterKeys = <String>{
      for (final AidokuBackupChapter c in backup.chapters ?? const <AidokuBackupChapter>{})
        '${c.sourceId}|${c.mangaId}|${c.id}',
    };
    final Set<String> sources = backup.sources ?? const <String>{};
    final Set<String> categories = backup.categories ?? const <String>{};
    for (final AidokuBackupManga m in backup.manga ?? const <AidokuBackupManga>{}) {
      if (!sources.contains(m.sourceId)) problems.add('manga ${m.sourceId}/${m.id}: source is not listed');
      if (!index.hasManga(m.sourceId, m.id)) problems.add('manga ${m.sourceId}/${m.id}: not a confirmed destination');
    }
    for (final AidokuBackupLibraryManga l in backup.library ?? const <AidokuBackupLibraryManga>{}) {
      if (!mangaKeys.contains('${l.sourceId}|${l.mangaId}')) {
        problems.add('library entry ${l.sourceId}/${l.mangaId}: no such manga');
      }
      for (final String c in l.categories) {
        if (!categories.contains(c)) problems.add('library entry ${l.sourceId}/${l.mangaId}: unknown category "$c"');
      }
    }
    for (final AidokuBackupChapter c in backup.chapters ?? const <AidokuBackupChapter>{}) {
      if (!mangaKeys.contains('${c.sourceId}|${c.mangaId}')) {
        problems.add('chapter ${c.sourceId}/${c.mangaId}/${c.id}: no such manga');
      } else if (!index.fetched(c.sourceId, c.mangaId, c.id)) {
        problems.add('chapter ${c.sourceId}/${c.mangaId}/${c.id}: not returned by the destination runtime');
      }
    }
    for (final AidokuBackupHistory h in backup.history ?? const <AidokuBackupHistory>{}) {
      if (!chapterKeys.contains('${h.sourceId}|${h.mangaId}|${h.chapterId}')) {
        problems.add('history ${h.sourceId}/${h.mangaId}/${h.chapterId}: no such chapter');
      } else if (!index.fetched(h.sourceId, h.mangaId, h.chapterId)) {
        problems.add('history ${h.sourceId}/${h.mangaId}/${h.chapterId}: points at a non-fetched chapter');
      }
    }
    return problems;
  }
}
