import 'package:fixnum/fixnum.dart';
import 'package:manga_backup_core/src/formats/tachi/proto/schema_mihon.proto/proto/schema_mihon.pb.dart' as mihon;
import 'package:manga_backup_core/src/formats/tachi/tachi_backup.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_category.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_chapter.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_extension_repo.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_history.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_manga.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_preference.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_source.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_source_preferences.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_tracking.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_update_strategy.dart';

/// Encodes a [TachiBackup] as Mihon's `Backup` protobuf message, field by
/// field (the inverse of `TachiBackup.fromData` for Mihon).
///
/// Every 64-bit field is written as an [Int64], so source IDs keep their
/// exact value. Fields Mihon removed from its schema (`lastModifiedAt`,
/// `version`) are not written; Mihon ignores them on restore.
mihon.Backup encodeMihonBackup(TachiBackup backup) => mihon.Backup(
  backupManga: backup.backupManga.map(_manga),
  backupCategories: backup.backupCategories.map(_category),
  backupSources: backup.backupSources.map(_source),
  backupPreferences: backup.backupPreferences.map(_preference),
  backupSourcePreferences: backup.backupSourcePreferences.map(
    (TachiBackupSourcePreferences p) =>
        mihon.BackupSourcePreferences(sourceKey: p.sourceKey, prefs: p.prefs.map(_preference)),
  ),
  backupExtensionStores: backup.backupExtensionRepo.map(_extensionStore),
);

mihon.BackupManga _manga(TachiBackupManga m) => mihon.BackupManga(
  source: Int64(m.source),
  url: m.url,
  title: m.title,
  artist: m.artist,
  author: m.author,
  description: m.description,
  genre: m.genre,
  status: m.status,
  thumbnailUrl: m.thumbnailUrl,
  dateAdded: Int64(m.dateAdded),
  viewer: m.viewer,
  chapters: m.chapters.map(_chapter),
  categories: m.categories.map(Int64.new),
  tracking: m.tracking.map(_tracking),
  favorite: m.favorite,
  chapterFlags: m.chapterFlags,
  viewerFlags: m.viewerFlags,
  history: m.history.map(_history),
  updateStrategy: switch (m.updateStrategy) {
    TachiUpdateStrategy.alwaysUpdate => mihon.UpdateStrategy.ALWAYS_UPDATE,
    TachiUpdateStrategy.onlyFetchOnce => mihon.UpdateStrategy.ONLY_FETCH_ONCE,
  },
  favoriteModifiedAt: m.favoriteModifiedAt == null ? null : Int64(m.favoriteModifiedAt!),
  excludedScanlators: m.excludedScanlators,
);

mihon.BackupChapter _chapter(TachiBackupChapter c) => mihon.BackupChapter(
  url: c.url,
  name: c.name,
  scanlator: c.scanlator.isEmpty ? null : c.scanlator,
  read: c.read,
  bookmark: c.bookmark,
  lastPageRead: Int64(c.lastPageRead),
  dateFetch: Int64(c.dateFetch),
  dateUpload: Int64(c.dateUpload),
  chapterNumber: c.chapterNumber,
  sourceOrder: Int64(c.sourceOrder),
);

mihon.BackupHistory _history(TachiBackupHistory h) =>
    mihon.BackupHistory(url: h.url, lastRead: Int64(h.lastRead), readDuration: Int64(h.readDuration));

mihon.BackupTracking _tracking(TachiBackupTracking t) => mihon.BackupTracking(
  syncId: t.syncId,
  libraryId: Int64(t.libraryId),
  mediaIdInt: t.mediaIdInt,
  trackingUrl: t.trackingUrl,
  title: t.title,
  lastChapterRead: t.lastChapterRead,
  totalChapters: t.totalChapters,
  score: t.score,
  status: t.status,
  startedReadingDate: Int64(t.startedReadingDate),
  finishedReadingDate: Int64(t.finishedReadingDate),
  mediaId: Int64(t.mediaId),
);

mihon.BackupCategory _category(TachiBackupCategory c) =>
    mihon.BackupCategory(name: c.name, order: Int64(c.order), flags: Int64(c.flags));

mihon.BackupSource _source(TachiBackupSource s) => mihon.BackupSource(name: s.name, sourceId: Int64(s.sourceId));

mihon.BackupPreference _preference(TachiBackupPreference p) => mihon.BackupPreference(
  key: p.key,
  value: mihon.PreferenceValue(type: p.value.type, truevalue: p.value.truevalue),
);

mihon.BackupExtensionStore _extensionStore(TachiBackupExtensionRepo r) => mihon.BackupExtensionStore(
  indexUrl: r.baseUrl,
  name: r.name,
  badgeLabel: r.shortName,
  contactWebsite: r.website,
  signingKey: r.signingKeyFingerprint,
);
