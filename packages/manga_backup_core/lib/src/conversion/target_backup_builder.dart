import 'dart:typed_data';

import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/conversion_plan.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';
import 'package:meta/meta.dart';

/// A source field a destination format cannot store as the source holds it.
/// The shared build accounts for each one a writer declares.
enum UnrepresentableField {
  /// Chapter bookmarks: each bookmark on a matched chapter is reported
  /// unrepresentable.
  chapterBookmark,

  /// Several scanlator groups: the format stores one scanlator field, so the
  /// groups are joined with `, ` and the report says so.
  scanlatorGroups,
}

/// How a writer disposes of the source's tracking records.
typedef TrackingDisposition = ({RecordDisposition disposition, String reason});

/// Reason recorded for tracking records a writer cannot map: no tracker
/// mapping between these apps has been verified.
const String unverifiedTrackingReason =
    'no verified tracker-service mapping exists for this destination, so tracking records are not written';

/// A destination backup writer (KTD15: registered in `FormatRegistry`, never
/// selected by a `BackupFormat` model).
///
/// Writers consume reconciliation [MangaConversionPlan]s and never guess
/// chapter matches themselves (KTD7). [build] is shared: it walks the plans,
/// accounts for every input record (KTD8) and asks the writer only to write
/// each manga ([startBuild]). [validate] is shared too: the writer projects
/// the exact bytes about to be published into a [WrittenBackup] ([project])
/// and one set of rules checks it (KTD8 pre-publish validation).
abstract class TargetBackupBuilder {
  const TargetBackupBuilder();

  /// The format this writer produces.
  BackupFormat get format;

  /// Source fields this format cannot store; [build] accounts for them.
  Set<UnrepresentableField> get unrepresentableFields;

  /// What happens to the source's tracking records when converting from
  /// [sourceFormatAlias].
  TrackingDisposition trackingFor(String? sourceFormatAlias);

  /// Why this writer cannot write the buildable [plan], or `null` when it
  /// can. Pure: [build] skips such a plan (accounting it unresolved with this
  /// reason) and [validate] expects none of its chapters.
  String? skipReason(MangaConversionPlan plan) => null;

  /// Starts one build; the returned assembly collects the written manga.
  BackupAssembly startBuild({String? sourceFormatAlias});

  /// Reads the published [bytes] back into the neutral shape [validate]
  /// checks, with any format-specific structural problems. Throws when the
  /// bytes do not decode.
  WrittenBackup project(Uint8List bytes);

  /// Builds the target backup from reconciliation [plans] (one per source
  /// manga). When [report] is given, every input record is accounted for
  /// (KTD8).
  @nonVirtual
  ConvertableBackup build(List<MangaConversionPlan> plans, {String? sourceFormatAlias, ConversionReport? report}) {
    final ConversionReport accounting = report ?? ConversionReport();
    final BackupAssembly assembly = startBuild(sourceFormatAlias: sourceFormatAlias);
    final TrackingDisposition tracking = trackingFor(sourceFormatAlias);
    final Set<UnrepresentableField> limits = unrepresentableFields;
    var joinedScanlators = 0;

    for (final plan in plans) {
      final PluginSearchResult? match = plan.confirmation.confirmedMatch;
      if (!plan.isBuildable || match == null) {
        accountUnbuilt(plan, accounting);
        continue;
      }
      final String? skipped = skipReason(plan);
      if (skipped != null) {
        accountUnbuilt(plan, accounting, reason: skipped);
        continue;
      }
      final String title = plan.sourceManga.details.title;
      accounting.add(RecordKind.manga, RecordDisposition.transferred, title, title);
      assembly.writeManga(plan, match);

      if (limits.contains(UnrepresentableField.scanlatorGroups)) {
        joinedScanlators += plan.confirmation.targetChapters.where((PluginChapter c) => c.scanlators.length > 1).length;
      }
      if (limits.contains(UnrepresentableField.chapterBookmark)) {
        for (final ChapterMatch m in plan.reconciliation.matches.where((ChapterMatch m) => m.source.isBookmarked)) {
          accounting.add(
            RecordKind.field,
            RecordDisposition.unrepresentable,
            title,
            'bookmark on ${chapterLabel(m.source)}',
            reason: '$format backups cannot represent chapter bookmarks',
          );
        }
      }
      _accountChapterState(plan, accounting, tracking);
    }

    if (joinedScanlators > 0) {
      accounting.notes.add(
        '$joinedScanlators destination chapter(s) list several scanlators; $format backups store one scanlator '
        'field, so the groups are joined with ", "',
      );
    }
    return assembly.finish(accounting);
  }

  /// Structural validation of the exact [bytes] that will be published,
  /// decoded again, against the [plans] they were built from (see
  /// [validateWritten]). Returns the problems found; empty means valid.
  List<String> validate(Uint8List bytes, List<MangaConversionPlan> plans) {
    final WrittenBackup written;
    try {
      written = project(bytes);
    } on Object catch (e) {
      return <String>['the written backup does not decode: $e'];
    }
    return validateWritten(
      written,
      FetchedChapterIndex(plans.where((MangaConversionPlan p) => skipReason(p) == null)),
    );
  }

  /// Accounts for the reading state of a written plan (KTD8): matched
  /// chapters are transferred; unresolved, excluded and secondary-source
  /// chapters and unlinked history keep their disposition; tracking records
  /// get [tracking].
  static void _accountChapterState(MangaConversionPlan plan, ConversionReport report, TrackingDisposition tracking) {
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
      report.add(RecordKind.tracking, tracking.disposition, title, trackingLabel(t), reason: tracking.reason);
    }
  }
}

/// One build in progress: [TargetBackupBuilder.build] hands it each written
/// plan, then asks for the finished backup.
abstract interface class BackupAssembly {
  /// Writes the buildable, not skipped [plan] confirmed as [match]: the
  /// manga, all of its fetched destination chapters, and reading state for
  /// the plan's accepted matches only.
  void writeManga(MangaConversionPlan plan, PluginSearchResult match);

  /// The finished backup; [report] takes format-specific notes.
  ConvertableBackup finish(ConversionReport report);
}

/// A written backup read back in a format-neutral shape: what
/// [validateWritten] checks for every writer.
final class WrittenBackup {
  const WrittenBackup({required this.manga, this.stateName = 'reading state', this.problems = const <String>[]});

  /// Every manga record, in written order; a duplicate appears twice.
  final List<WrittenManga> manga;

  /// What the format calls a reading-state record (`history`, `progress
  /// marker`), for messages.
  final String stateName;

  /// Format-specific structural problems found while projecting (missing
  /// envelope entries, dangling or mistyped references, unlisted sources).
  final List<String> problems;
}

/// One written manga: its runtime identity, every written chapter record
/// and the chapters its reading-state records point at.
final class WrittenManga {
  const WrittenManga({
    required this.sourceId,
    required this.mangaId,
    this.chapterIds = const <String>[],
    this.stateChapterIds = const <String>[],
  });

  /// Runtime source ID and native manga ID.
  final String sourceId;
  final String mangaId;

  /// The runtime chapter ID of every written chapter record; a duplicate
  /// appears twice.
  final List<String> chapterIds;

  /// The runtime chapter ID each reading-state record points at.
  final List<String> stateChapterIds;

  String get label => '$sourceId/$mangaId';
}

/// The shared pre-publish rules (KTD8), for every writer: each manga is
/// written once and is a confirmed destination; each fetched destination
/// chapter is written exactly once and nothing else is; every reading-state
/// record points at a written chapter.
List<String> validateWritten(WrittenBackup written, FetchedChapterIndex index) {
  final problems = <String>[...written.problems];
  final writtenChapters = <String, Set<String>>{};
  for (final WrittenManga m in written.manga) {
    final String label = m.label;
    final String key = FetchedChapterIndex._key(m.sourceId, m.mangaId);
    if (writtenChapters.containsKey(key)) problems.add('manga $label is written twice');
    (writtenChapters[key] ??= <String>{}).addAll(m.chapterIds);
    if (!index.hasManga(m.sourceId, m.mangaId)) problems.add('manga $label: not a confirmed destination');
    final chapters = <String>{};
    for (final String c in m.chapterIds) {
      if (!chapters.add(c)) problems.add('manga $label: chapter $c is written twice');
      if (!index.fetched(m.sourceId, m.mangaId, c)) {
        problems.add('manga $label: chapter $c was not returned by the destination runtime');
      }
    }
    for (final String c in m.stateChapterIds) {
      if (!chapters.contains(c)) problems.add('manga $label: ${written.stateName} $c has no chapter');
    }
  }
  for (final MapEntry<String, Set<String>> expected in index._chapters.entries) {
    final int count = writtenChapters[expected.key]?.intersection(expected.value).length ?? 0;
    if (count != expected.value.length) {
      problems.add(
        '${expected.key.replaceFirst('\u0000', '/')}: $count of ${expected.value.length} destination chapters written',
      );
    }
  }
  return problems;
}

/// The destination chapters each buildable plan fetched, keyed by runtime
/// source ID and native manga ID. The shared validator checks written state
/// against it, so no state lands on a chapter the runtime did not return.
final class FetchedChapterIndex {
  FetchedChapterIndex(Iterable<MangaConversionPlan> plans) {
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
