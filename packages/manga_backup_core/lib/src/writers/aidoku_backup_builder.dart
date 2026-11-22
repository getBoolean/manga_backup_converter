import 'dart:typed_data';

import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/conversion_plan.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/conversion/target_backup_builder.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_chapter.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_history.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_library_manga.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_manga.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';

/// Writes an Aidoku backup. Records are collected in sets, so identical
/// records written for two plans collapse into one.
class AidokuBackupBuilder extends TargetBackupBuilder {
  const AidokuBackupBuilder();

  @override
  BackupFormat get format => const Aidoku();

  @override
  Set<UnrepresentableField> get unrepresentableFields => const <UnrepresentableField>{
    UnrepresentableField.chapterBookmark,
    UnrepresentableField.scanlatorGroups,
  };

  @override
  TrackingDisposition trackingFor(String? sourceFormatAlias) => (
    disposition: RecordDisposition.unrepresentable,
    reason: 'destination tracker identities are unknown, so Aidoku track items are not written',
  );

  @override
  BackupAssembly startBuild({String? sourceFormatAlias}) => _AidokuAssembly(sourceFormatAlias);

  @override
  WrittenBackup project(Uint8List bytes) {
    final AidokuBackup backup = AidokuBackup.fromData(bytes);
    final problems = <String>[];
    final Set<String> sources = backup.sources ?? const <String>{};
    final Set<String> categories = backup.categories ?? const <String>{};
    final manga = <String, _Collected>{};
    final written = <WrittenManga>[];
    for (final AidokuBackupManga m in backup.manga ?? const <AidokuBackupManga>{}) {
      if (!sources.contains(m.sourceId)) problems.add('manga ${m.sourceId}/${m.id}: source is not listed');
      manga.putIfAbsent('${m.sourceId}|${m.id}', () => (record: m, chapters: <String>[], state: <String>[]));
    }
    for (final AidokuBackupLibraryManga l in backup.library ?? const <AidokuBackupLibraryManga>{}) {
      if (!manga.containsKey('${l.sourceId}|${l.mangaId}')) {
        problems.add('library entry ${l.sourceId}/${l.mangaId}: no such manga');
      }
      for (final String c in l.categories) {
        if (!categories.contains(c)) problems.add('library entry ${l.sourceId}/${l.mangaId}: unknown category "$c"');
      }
    }
    for (final AidokuBackupChapter c in backup.chapters ?? const <AidokuBackupChapter>{}) {
      final List<String>? chapters = manga['${c.sourceId}|${c.mangaId}']?.chapters;
      if (chapters == null) {
        problems.add('chapter ${c.sourceId}/${c.mangaId}/${c.id}: no such manga');
      } else {
        chapters.add(c.id);
      }
    }
    for (final AidokuBackupHistory h in backup.history ?? const <AidokuBackupHistory>{}) {
      final List<String>? state = manga['${h.sourceId}|${h.mangaId}']?.state;
      if (state == null) {
        problems.add('history ${h.sourceId}/${h.mangaId}/${h.chapterId}: no such manga');
      } else {
        state.add(h.chapterId);
      }
    }
    for (final AidokuBackupManga m in backup.manga ?? const <AidokuBackupManga>{}) {
      final _Collected entry = manga['${m.sourceId}|${m.id}']!;
      // A second record for the same manga carries no chapters of its own.
      final bool first = identical(entry.record, m);
      written.add(
        WrittenManga(
          sourceId: m.sourceId,
          mangaId: m.id,
          chapterIds: first ? entry.chapters : const <String>[],
          stateChapterIds: first ? entry.state : const <String>[],
        ),
      );
    }
    return WrittenBackup(manga: written, stateName: 'history', problems: problems);
  }
}

/// One manga's first record and the chapters and history pointing at it.
typedef _Collected = ({AidokuBackupManga record, List<String> chapters, List<String> state});

final class _AidokuAssembly implements BackupAssembly {
  _AidokuAssembly(this.sourceFormatAlias);

  final String? sourceFormatAlias;
  final manga = <AidokuBackupManga>{};
  final library = <AidokuBackupLibraryManga>{};
  final chapters = <AidokuBackupChapter>{};
  final history = <AidokuBackupHistory>{};
  final sources = <String>{};
  final categories = <String>{};

  @override
  void writeManga(MangaConversionPlan plan, PluginSearchResult match) {
    final PluginMangaDetails? details = plan.confirmation.targetMangaDetails;
    final SourceMangaData sourceManga = plan.sourceManga;
    manga.add(
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
    library.add(
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
    categories.addAll(sourceManga.categories);

    for (final (int i, PluginChapter ch) in plan.confirmation.targetChapters.indexed) {
      chapters.add(
        AidokuBackupChapter(
          sourceId: match.pluginSourceId,
          mangaId: match.mangaKey,
          id: ch.chapterId,
          title: ch.title,
          // One scanlator string: every group is kept, joined.
          scanlator: ch.scanlator,
          lang: ch.language ?? 'en',
          chapter: ch.chapterNumber,
          volume: ch.volumeNumber,
          dateUploaded: ch.dateUploaded,
          sourceOrder: i,
        ),
      );
    }

    // Reading state for accepted matches only: every history record
    // references a fetched destination chapter.
    for (final ChapterMatch m in plan.reconciliation.matches) {
      final SourceChapter s = m.source;
      if (!s.isRead && s.lastPageRead <= 0 && s.dateRead == null) continue;
      history.add(
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
    sources.add(match.pluginSourceId);
  }

  @override
  ConvertableBackup finish(ConversionReport report) => AidokuBackup(
    library: library,
    history: history.isEmpty ? null : history,
    manga: manga,
    chapters: chapters.isEmpty ? null : chapters,
    trackItems: null,
    categories: categories.isEmpty ? null : categories,
    sources: sources,
    date: DateTime.now(),
    name: sourceFormatAlias != null ? 'Migrated from $sourceFormatAlias' : null,
    version: '0.6.10',
  );
}
