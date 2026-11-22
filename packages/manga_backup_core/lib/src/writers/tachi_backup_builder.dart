import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fixnum/fixnum.dart';
import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/conversion_plan.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/conversion/target_backup_builder.dart';
import 'package:manga_backup_core/src/formats/tachi/proto/schema_mihon.proto/proto/schema_mihon.pb.dart' as mihon;
import 'package:manga_backup_core/src/formats/tachi/tachi_backup.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_category.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_chapter.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_history.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_manga.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_source.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_tracking.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';

/// Writes a Tachi backup for the selected fork, starting with Mihon (R5).
///
/// Identities come from the destination runtime only: `BackupManga.source`
/// is the loaded source's exact int64 ID, `BackupManga.url` the source's own
/// `SManga.url`, and `BackupChapter.url` the source's own `SChapter.url` (the
/// Tachi runtime's `chapterId`), never a supervisor handle or a web URL.
/// The backup carries its fork identity in [format].
class TachiBackupBuilder extends TargetBackupBuilder {
  const TachiBackupBuilder({this.fork = const Mihon(), this.clock = _now});

  /// The destination fork. Only Mihon has a verified schema and is
  /// registered; SY, J2K, Yokai and Neko need their own restore receipts.
  final Tachiyomi fork;
  final DateTime Function() clock;

  static DateTime _now() => DateTime.now();

  @override
  BackupFormat get format => fork;

  @override
  Set<UnrepresentableField> get unrepresentableFields => const <UnrepresentableField>{};

  /// Tracker IDs are only meaningful inside the same app's tracker registry.
  bool _sameTrackers(String? sourceFormatAlias) => sourceFormatAlias == fork.alias;

  @override
  TrackingDisposition trackingFor(String? sourceFormatAlias) => _sameTrackers(sourceFormatAlias)
      ? (disposition: RecordDisposition.transferred, reason: 'same tracker registry (${fork.alias})')
      : (disposition: RecordDisposition.unrepresentable, reason: unverifiedTrackingReason);

  /// A destination source ID that is not a Tachi int64 runtime identity is
  /// never guessed or hashed into one.
  @override
  String? skipReason(MangaConversionPlan plan) {
    final String? sourceId = plan.confirmation.confirmedMatch?.pluginSourceId;
    if (sourceId == null || _int64(sourceId) != null) return null;
    return 'destination source ID "$sourceId" is not a Tachi int64 source ID';
  }

  @override
  BackupAssembly startBuild({String? sourceFormatAlias}) =>
      _TachiAssembly(this, sameTrackers: _sameTrackers(sourceFormatAlias), now: clock());

  static int _orderOf(List<String> names, String name) {
    final int i = names.indexOf(name);
    if (i >= 0) return i;
    names.add(name);
    return names.length - 1;
  }

  static Int64? _int64(String decimal) {
    try {
      final Int64 v = Int64.parseInt(decimal);
      return v.toString() == decimal ? v : null;
    } on FormatException {
      return null;
    }
  }

  /// The source's own unsplit scanlator string when the runtime kept it.
  static String _rawScanlator(PluginChapter c) => switch (c.context['scanlator']) {
    final String raw => raw,
    _ => c.scanlator ?? '',
  };

  /// The source's own chapter number (Tachi uses -1 for unknown).
  static double _rawChapterNumber(PluginChapter c) => switch (c.context['chapter_number']) {
    final num raw => raw.toDouble(),
    _ => c.chapterNumber ?? -1,
  };

  /// `SManga` status codes.
  static int _status(MangaPublishingStatus? status) => switch (status) {
    MangaPublishingStatus.ongoing => 1,
    MangaPublishingStatus.completed => 2,
    MangaPublishingStatus.cancelled => 5,
    MangaPublishingStatus.hiatus => 6,
    MangaPublishingStatus.unknown || null => 0,
  };

  static TachiBackupTracking _tracking(SourceTrackingEntry t) => TachiBackupTracking(
    syncId: t.syncId,
    libraryId: t.libraryId ?? 0,
    mediaIdInt: 0,
    trackingUrl: t.trackingUrl ?? '',
    title: t.title ?? '',
    lastChapterRead: t.lastChapterRead ?? 0,
    totalChapters: t.totalChapters ?? 0,
    score: t.score ?? 0,
    status: t.status ?? 0,
    startedReadingDate: t.startedReadingDate?.millisecondsSinceEpoch ?? 0,
    finishedReadingDate: t.finishedReadingDate?.millisecondsSinceEpoch ?? 0,
    mediaId: t.mediaId ?? 0,
  );

  @override
  WrittenBackup project(Uint8List bytes) {
    final backup = mihon.Backup.fromBuffer(const GZipDecoder().decodeBytes(bytes));
    final problems = <String>[];
    final sourceIds = <Int64>{for (final mihon.BackupSource s in backup.backupSources) s.sourceId};
    final orders = <Int64>{for (final mihon.BackupCategory c in backup.backupCategories) c.order};
    final manga = <WrittenManga>[];
    for (final mihon.BackupManga m in backup.backupManga) {
      final source = m.source.toString();
      if (!sourceIds.contains(m.source)) problems.add('manga $source/${m.url}: source is not listed');
      for (final Int64 c in m.categories) {
        if (!orders.contains(c)) problems.add('manga $source/${m.url}: unknown category order $c');
      }
      manga.add(
        WrittenManga(
          sourceId: source,
          mangaId: m.url,
          chapterIds: <String>[for (final mihon.BackupChapter c in m.chapters) c.url],
          stateChapterIds: <String>[for (final mihon.BackupHistory h in m.history) h.url],
        ),
      );
    }
    return WrittenBackup(manga: manga, stateName: 'history', problems: problems);
  }
}

final class _TachiAssembly implements BackupAssembly {
  _TachiAssembly(this.builder, {required this.sameTrackers, required DateTime now})
    : now = now,
      nowMs = now.millisecondsSinceEpoch;

  final TachiBackupBuilder builder;
  final bool sameTrackers;
  final DateTime now;
  final int nowMs;

  // Category order is the list position; Mihon restores a manga's
  // categories by matching `order` (unverified against a restore: U8).
  final categoryNames = <String>[];
  final sources = <String, TachiBackupSource>{};
  final manga = <TachiBackupManga>[];

  @override
  void writeManga(MangaConversionPlan plan, PluginSearchResult match) {
    final SourceMangaData sourceManga = plan.sourceManga;
    final int sourceId = TachiBackupBuilder._int64(match.pluginSourceId)!.toInt();
    sources[match.pluginSourceId] = TachiBackupSource(
      name: match.pluginSourceName ?? match.pluginSourceId,
      sourceId: sourceId,
    );

    final stateByDestination = <String, SourceChapter>{
      for (final ChapterMatch m in plan.reconciliation.matches) m.destination.chapterId: m.source,
    };
    final chapters = <TachiBackupChapter>[];
    final history = <TachiBackupHistory>[];
    for (final PluginChapter c in plan.confirmation.targetChapters) {
      final SourceChapter? s = stateByDestination[c.chapterId];
      chapters.add(
        TachiBackupChapter(
          url: c.chapterId,
          name: c.title ?? '',
          scanlator: TachiBackupBuilder._rawScanlator(c),
          read: s?.isRead ?? false,
          bookmark: s?.isBookmarked ?? false,
          lastPageRead: s?.lastPageRead ?? 0,
          dateFetch: nowMs,
          dateUpload: c.dateUploaded?.millisecondsSinceEpoch ?? 0,
          chapterNumber: TachiBackupBuilder._rawChapterNumber(c),
          sourceOrder: c.sourceOrder,
        ),
      );
      final DateTime? read = s?.dateRead;
      if (s != null && read != null) {
        history.add(TachiBackupHistory(url: c.chapterId, lastRead: read.millisecondsSinceEpoch, readDuration: 0));
      }
    }

    final PluginMangaDetails? details = plan.confirmation.targetMangaDetails;
    manga.add(
      TachiBackupManga(
        source: sourceId,
        url: match.mangaKey,
        title: details?.title ?? match.title,
        artist: (details?.artists ?? const <String>[]).join(', '),
        author: (details?.authors ?? match.authors).join(', '),
        description: details?.description ?? '',
        genre: details?.tags ?? const <String>[],
        status: TachiBackupBuilder._status(details?.status),
        thumbnailUrl: details?.coverUrl ?? match.coverUrl ?? '',
        dateAdded: (sourceManga.dateAdded ?? now).millisecondsSinceEpoch,
        viewer: 0,
        chapters: chapters,
        categories: <int>[
          for (final String name in sourceManga.categories) TachiBackupBuilder._orderOf(categoryNames, name),
        ],
        tracking: sameTrackers
            ? sourceManga.tracking.map(TachiBackupBuilder._tracking).toList()
            : const <TachiBackupTracking>[],
        favorite: true,
        chapterFlags: 0,
        viewerFlags: 0,
        history: history,
      ),
    );
  }

  @override
  ConvertableBackup finish(ConversionReport report) => TachiBackup(
    format: builder.fork,
    backupManga: manga,
    backupCategories: <TachiBackupCategory>[
      for (final (int i, String name) in categoryNames.indexed) TachiBackupCategory(name: name, order: i, flags: 0),
    ],
    backupSources: sources.values.toList(),
  );
}
