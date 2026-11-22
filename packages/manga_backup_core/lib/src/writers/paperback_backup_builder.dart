import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/conversion_plan.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/conversion/target_backup_builder.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_chapter.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_chapter_progress_marker.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_item_reference.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_item_type.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_library_manga.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_library_tab.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_manga_info.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_source_manga.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';

/// The "unknown date" Paperback stores for a non-nullable timestamp with no
/// value: the Unix epoch, which `PaperbackDateCodec.classify` reads back as
/// `PaperbackDateKind.unixEpoch`. Unverified against a restore (U8).
final DateTime paperbackUnknownDate = DateTime.utc(1970);

/// A backup-local Paperback record ID derived from [parts]: a name-based
/// UUID (version 5 layout, SHA-1, upper case like Swift's `uuidString`).
///
/// Deterministic, so the same destination graph always gets the same IDs,
/// and kept separate from the runtime-native IDs (`sourceId`, `mangaId`,
/// `chapterId`). Whether Paperback requires any particular ID convention is
/// not established; U8 must verify a restore.
String paperbackLocalId(String kind, List<String> parts) {
  final List<int> bytes = sha1
      .convert(utf8.encode(<String>['manga-backup-converter', kind, ...parts].join('\u0000')))
      .bytes
      .sublist(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final String hex = bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Writes a Paperback `.pas4` V4 archive (KTD10: the V4 envelope is a
/// separate claim from the 0.9 runtime API, and restore is verified in U8).
///
/// The reference graph is library → source manga → manga info, chapters →
/// source manga, and progress markers → chapters. Every record gets a
/// generated backup-local `id`; the destination runtime's identities go in
/// their own fields: `sourceManga.sourceId` is the runtime source ID (the
/// bare catalog ID such as `WeebCentral`, never the `repository#id` package
/// ID), `sourceManga.mangaId` the source's manga ID, `chapter.chapterId` the
/// source's chapter ID.
class PaperbackBackupBuilder extends TargetBackupBuilder {
  const PaperbackBackupBuilder({this.clock = _now});

  final DateTime Function() clock;

  static DateTime _now() => DateTime.now().toUtc();

  @override
  BackupFormat get format => const Paperback();

  @override
  Set<UnrepresentableField> get unrepresentableFields => const <UnrepresentableField>{
    UnrepresentableField.chapterBookmark,
    UnrepresentableField.scanlatorGroups,
  };

  @override
  TrackingDisposition trackingFor(String? sourceFormatAlias) =>
      (disposition: RecordDisposition.unrepresentable, reason: unverifiedTrackingReason);

  @override
  BackupAssembly startBuild({String? sourceFormatAlias}) => _PaperbackAssembly(sourceFormatAlias, clock());

  /// Status strings as the repo's existing Paperback mapping writes them
  /// (`PaperbackBackupMangaInfo.statusFromAidoku`); unverified against a
  /// restore (U8).
  static String _status(MangaPublishingStatus? status) => switch (status) {
    MangaPublishingStatus.completed => 'Completed',
    MangaPublishingStatus.cancelled => 'Finished',
    MangaPublishingStatus.ongoing || MangaPublishingStatus.hiatus || MangaPublishingStatus.unknown || null => 'Ongoing',
  };

  @override
  WrittenBackup project(Uint8List bytes) {
    final backup = PaperbackBackup.fromData(bytes);
    final problems = <String>[
      // The V4 envelope always carries all five entries.
      if (backup.mangaInfo == null) 'the archive has no __MANGA_INFO_V4 entry',
      if (backup.sourceManga == null) 'the archive has no __SOURCE_MANGA_V4 entry',
      if (backup.chapters == null) 'the archive has no __CHAPTER_V4 entry',
      if (backup.chapterProgressMarker == null) 'the archive has no __CHAPTER_PROGRESS_MARKER_V4-1 entry',
      if (backup.libraryManga == null) 'the archive has no __LIBRARY_MANGA_V4 entry',
    ];
    final infoIds = <String>{for (final PaperbackBackupMangaInfo i in backup.mangaInfo ?? const []) i.id};
    final sourcesById = <String, PaperbackBackupSourceManga>{
      for (final PaperbackBackupSourceManga s in backup.sourceManga ?? const []) s.id: s,
    };
    final chaptersById = <String, PaperbackBackupChapter>{
      for (final PaperbackBackupChapter c in backup.chapters ?? const []) c.id: c,
    };

    String? check(PaperbackBackupItemReference ref, PaperbackBackupItemType type, Set<String> ids) =>
        ref.type != type ? 'has type ${ref.type}, expected $type' : (ids.contains(ref.id) ? null : 'is dangling');

    final chapterIds = <String, List<String>>{for (final String id in sourcesById.keys) id: <String>[]};
    final stateIds = <String, List<String>>{for (final String id in sourcesById.keys) id: <String>[]};
    for (final PaperbackBackupSourceManga s in sourcesById.values) {
      final String? bad = check(s.mangaInfo, PaperbackBackupItemType.mangaInfoV4, infoIds);
      if (bad != null) problems.add('source manga ${s.id}: manga info reference $bad');
    }
    for (final PaperbackBackupChapter c in chaptersById.values) {
      if (c.sourceManga.type != PaperbackBackupItemType.sourceMangaV4 || !sourcesById.containsKey(c.sourceManga.id)) {
        problems.add('chapter ${c.id}: source manga reference is dangling');
        continue;
      }
      chapterIds[c.sourceManga.id]!.add(c.chapterId);
    }
    for (final PaperbackBackupChapterProgressMarker m in backup.chapterProgressMarker ?? const []) {
      final String? bad = check(m.chapter, PaperbackBackupItemType.chapterV4, chaptersById.keys.toSet());
      if (bad != null) {
        problems.add('progress marker for ${m.chapter.id}: chapter reference $bad');
        continue;
      }
      final PaperbackBackupChapter c = chaptersById[m.chapter.id]!;
      stateIds[c.sourceManga.id]?.add(c.chapterId);
    }
    final tabNames = <String, String>{};
    for (final PaperbackBackupLibraryManga l in backup.libraryManga ?? const []) {
      final String? bad = check(l.primarySource, PaperbackBackupItemType.sourceMangaV4, sourcesById.keys.toSet());
      if (bad != null) problems.add('library manga ${l.id}: primary source reference $bad');
      for (final PaperbackBackupItemReference r in l.secondarySources) {
        final String? badSecondary = check(r, PaperbackBackupItemType.sourceMangaV4, sourcesById.keys.toSet());
        if (badSecondary != null) problems.add('library manga ${l.id}: secondary source reference $badSecondary');
      }
      for (final PaperbackBackupLibraryTab t in l.libraryTabs) {
        final String known = tabNames.putIfAbsent(t.id, () => t.name);
        if (known != t.name) problems.add('library tab ${t.id} has two names ("$known", "${t.name}")');
      }
    }
    // Records are archive keys: a duplicate generated ID has already
    // collapsed into one record here, which the chapter count then reveals.
    return WrittenBackup(
      manga: <WrittenManga>[
        for (final PaperbackBackupSourceManga s in sourcesById.values)
          WrittenManga(
            sourceId: s.sourceId,
            mangaId: s.mangaId,
            chapterIds: chapterIds[s.id]!,
            stateChapterIds: stateIds[s.id]!,
          ),
      ],
      stateName: 'progress marker for',
      problems: problems,
    );
  }
}

final class _PaperbackAssembly implements BackupAssembly {
  _PaperbackAssembly(this.sourceFormatAlias, this.now);

  final String? sourceFormatAlias;
  final DateTime now;
  final infos = <PaperbackBackupMangaInfo>[];
  final sources = <PaperbackBackupSourceManga>[];
  final chapters = <PaperbackBackupChapter>[];
  final markers = <PaperbackBackupChapterProgressMarker>[];
  final library = <PaperbackBackupLibraryManga>[];
  int unknownNumbers = 0;

  @override
  void writeManga(MangaConversionPlan plan, PluginSearchResult match) {
    final SourceMangaData sourceManga = plan.sourceManga;
    final String sourceId = match.pluginSourceId;
    final String mangaId = match.mangaKey;
    final String infoId = paperbackLocalId('manga-info', <String>[sourceId, mangaId]);
    final String sourceMangaId = paperbackLocalId('source-manga', <String>[sourceId, mangaId]);
    final PluginMangaDetails? details = plan.confirmation.targetMangaDetails;

    infos.add(
      PaperbackBackupMangaInfo(
        id: infoId,
        titles: <String>[details?.title ?? match.title],
        covers: const <String>[],
        image: details?.coverUrl ?? match.coverUrl ?? '',
        desc: details?.description ?? '',
        author: (details?.authors ?? match.authors).join(', '),
        artist: (details?.artists ?? const <String>[]).join(', '),
        hentai: details?.contentRating == MangaContentRating.nsfw,
        status: PaperbackBackupBuilder._status(details?.status),
        tags: <PaperbackBackupMangaTag>[
          if (details != null && details.tags.isNotEmpty)
            PaperbackBackupMangaTag(
              id: 'tags',
              label: 'Tags',
              tags: <PaperbackBackupMangaTag>[
                for (final String t in details.tags) PaperbackBackupMangaTag(id: t, label: t),
              ],
            ),
        ],
        additionalInfo: PaperbackBackupMangaAdditionalInfo(),
      ),
    );
    sources.add(
      PaperbackBackupSourceManga(
        id: sourceMangaId,
        sourceId: sourceId,
        mangaId: mangaId,
        mangaInfo: PaperbackBackupItemReference(type: PaperbackBackupItemType.mangaInfoV4, id: infoId),
      ),
    );

    final chapterIds = <String, String>{};
    for (final PluginChapter c in plan.confirmation.targetChapters) {
      final String id = paperbackLocalId('chapter', <String>[sourceId, mangaId, c.chapterId]);
      chapterIds[c.chapterId] = id;
      if (c.chapterNumber == null) unknownNumbers++;
      chapters.add(
        PaperbackBackupChapter(
          id: id,
          chapterId: c.chapterId,
          sourceManga: PaperbackBackupItemReference(type: PaperbackBackupItemType.sourceMangaV4, id: sourceMangaId),
          chapNum: c.chapterNumber ?? 0,
          volume: c.volumeNumber ?? 0,
          langCode: c.language ?? '',
          // One group field: every group is kept, joined.
          group: c.scanlator ?? '',
          name: c.title ?? '',
          time: c.dateUploaded?.toUtc() ?? paperbackUnknownDate,
          sortingIndex: c.sourceOrder,
          isNew: false,
        ),
      );
    }

    for (final ChapterMatch m in plan.reconciliation.matches) {
      final SourceChapter s = m.source;
      if (!s.isRead && s.lastPageRead <= 0 && s.dateRead == null) continue;
      markers.add(
        PaperbackBackupChapterProgressMarker(
          chapter: PaperbackBackupItemReference(
            type: PaperbackBackupItemType.chapterV4,
            id: chapterIds[m.destination.chapterId]!,
          ),
          completed: s.isRead,
          lastPage: s.lastPageRead,
          totalPages: s.totalPages ?? 0,
          time: (s.dateRead ?? sourceManga.lastRead)?.toUtc() ?? paperbackUnknownDate,
          hidden: false,
        ),
      );
    }

    library.add(
      PaperbackBackupLibraryManga(
        id: paperbackLocalId('library-manga', <String>[sourceId, mangaId]),
        primarySource: PaperbackBackupItemReference(type: PaperbackBackupItemType.sourceMangaV4, id: sourceMangaId),
        secondarySources: const <PaperbackBackupItemReference>[],
        trackedSources: const <PaperbackBackupItemReference>[],
        libraryTabs: <PaperbackBackupLibraryTab>[
          for (final (int i, String name) in sourceManga.categories.indexed)
            PaperbackBackupLibraryTab(id: paperbackLocalId('library-tab', <String>[name]), name: name, sortOrder: i),
        ],
        lastRead: sourceManga.lastRead?.toUtc(),
        dateBookmarked: (sourceManga.dateAdded ?? now).toUtc(),
      ),
    );
  }

  @override
  ConvertableBackup finish(ConversionReport report) {
    if (unknownNumbers > 0) {
      report.notes.add(
        '$unknownNumbers destination chapter(s) have no chapter number; Paperback requires one, so 0 is written',
      );
    }
    return PaperbackBackup(
      mangaInfo: infos,
      sourceManga: sources,
      chapters: chapters,
      chapterProgressMarker: markers,
      libraryManga: library,
      name: sourceFormatAlias == null ? null : 'Migrated from $sourceFormatAlias',
    );
  }
}
