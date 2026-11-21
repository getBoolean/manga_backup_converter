// ignore_for_file: unused_import, avoid_print

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/common/seconds_epoc_date_time_mapper.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/exceptions/tachi_exception.dart';
import 'package:manga_backup_core/src/formats/tachi/proto/schema_j2k.proto/proto/schema_j2k.pb.dart' as j2k;
import 'package:manga_backup_core/src/formats/tachi/proto/schema_mihon.proto/proto/schema_mihon.pb.dart' as mihon;
import 'package:manga_backup_core/src/formats/tachi/proto/schema_neko.proto/proto/schema_neko.pb.dart' as neko;
import 'package:manga_backup_core/src/formats/tachi/proto/schema_sy.proto/proto/schema_sy.pb.dart' as sy;
import 'package:manga_backup_core/src/formats/tachi/proto/schema_yokai.proto/proto/schema_yokai.pb.dart' as yokai;
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_category.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_chapter.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_extension_repo.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_history.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_manga.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_preference.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_source.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_source_preferences.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup_tracking.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_mihon_encoder.dart';
import 'package:meta/meta.dart';
import 'package:protobuf/protobuf.dart';

part 'tachi_backup.mapper.dart';

@MappableClass(includeCustomMappers: <MapperBase<Object>>[SecondsEpochDateTimeMapper()])
class TachiBackup with TachiBackupMappable implements ConvertableBackup {
  final Tachiyomi format;
  final List<TachiBackupSource> backupBrokenSources;
  final List<TachiBackupSource> backupSources;
  final List<TachiBackupCategory> backupCategories;
  final List<TachiBackupExtensionRepo> backupExtensionRepo;
  final List<TachiBackupManga> backupManga;
  final List<TachiBackupPreference> backupPreferences;
  final List<TachiBackupSourcePreferences> backupSourcePreferences;

  const TachiBackup({
    this.backupCategories = const <TachiBackupCategory>[],
    this.backupManga = const <TachiBackupManga>[],
    this.backupBrokenSources = const <TachiBackupSource>[],
    this.backupSources = const <TachiBackupSource>[],
    this.backupExtensionRepo = const <TachiBackupExtensionRepo>[],
    this.backupPreferences = const <TachiBackupPreference>[],
    this.backupSourcePreferences = const <TachiBackupSourcePreferences>[],
    this.format = const Mihon(),
  });

  factory TachiBackup._fromMihon({required mihon.Backup backup}) {
    return TachiBackup(
      backupSources: backup.backupSources.map(TachiBackupSource.fromMihon).toList(),
      backupCategories: backup.backupCategories.map(TachiBackupCategory.fromMihon).toList(),
      backupManga: backup.backupManga.map(TachiBackupManga.fromMihon).toList(),
      backupExtensionRepo: backup.backupExtensionStores.map(TachiBackupExtensionRepo.fromMihon).toList(),
      backupPreferences: backup.backupPreferences.map(TachiBackupPreference.fromMihon).toList(),
      backupSourcePreferences: backup.backupSourcePreferences.map(TachiBackupSourcePreferences.fromMihon).toList(),
    );
  }

  factory TachiBackup._fromSy({required sy.Backup backup}) {
    return TachiBackup(
      format: const TachiSy(),
      backupSources: backup.backupSources.map(TachiBackupSource.fromSy).toList(),
      backupCategories: backup.backupCategories.map(TachiBackupCategory.fromSy).toList(),
      backupManga: backup.backupManga.map(TachiBackupManga.fromSy).toList(),
      backupExtensionRepo: backup.backupExtensionStores.map(TachiBackupExtensionRepo.fromSy).toList(),
      backupPreferences: backup.backupPreferences.map(TachiBackupPreference.fromSy).toList(),
      backupSourcePreferences: backup.backupSourcePreferences.map(TachiBackupSourcePreferences.fromSy).toList(),
    );
  }

  factory TachiBackup._fromNeko({required neko.Backup backup}) {
    return TachiBackup(
      format: const TachiNeko(),
      backupCategories: backup.backupCategories.map(TachiBackupCategory.fromNeko).toList(),
      backupManga: backup.backupManga.map(TachiBackupManga.fromNeko).toList(),
    );
  }

  factory TachiBackup._fromJ2k({required j2k.Backup backup}) {
    return TachiBackup(
      format: const TachiJ2k(),
      backupSources: backup.backupSources.map(TachiBackupSource.fromJ2k).toList(),
      backupCategories: backup.backupCategories.map(TachiBackupCategory.fromJ2k).toList(),
      backupManga: backup.backupManga.map(TachiBackupManga.fromJ2k).toList(),
    );
  }

  factory TachiBackup._fromYokai({required yokai.Backup backup}) {
    return TachiBackup(
      format: const TachiYokai(),
      backupSources: backup.backupSources.map(TachiBackupSource.fromYokai).toList(),
      backupCategories: backup.backupCategories.map(TachiBackupCategory.fromYokai).toList(),
      backupManga: backup.backupManga.map(TachiBackupManga.fromYokai).toList(),
    );
  }

  factory TachiBackup.fromData(Uint8List bytes, {Tachiyomi format = const Mihon()}) {
    final Uint8List backupArchive = const GZipDecoder().decodeBytes(bytes);
    return switch (format) {
      Mihon() => TachiBackup._fromMihon(backup: mihon.Backup.fromBuffer(backupArchive)),
      TachiSy() => TachiBackup._fromSy(backup: sy.Backup.fromBuffer(backupArchive)),
      TachiJ2k() => TachiBackup._fromJ2k(backup: j2k.Backup.fromBuffer(backupArchive)),
      TachiYokai() => TachiBackup._fromYokai(backup: yokai.Backup.fromBuffer(backupArchive)),
      TachiNeko() => TachiBackup._fromNeko(backup: neko.Backup.fromBuffer(backupArchive)),
    };
  }

  @override
  Future<Uint8List> toData() async {
    // Mihon is encoded field by field (exact int64s). The other forks still
    // go through the generated JSON path, which is not round-trip tested and
    // no writer is registered for them (U7: Mihon is the first destination).
    final Uint8List backupBytes = switch (format) {
      Mihon() => encodeMihonBackup(this).writeToBuffer(),
      TachiSy() => sy.Backup.fromJson(toJson()).writeToBuffer(),
      TachiJ2k() => j2k.Backup.fromJson(toJson()).writeToBuffer(),
      TachiYokai() => yokai.Backup.fromJson(toJson()).writeToBuffer(),
      TachiNeko() => neko.Backup.fromJson(toJson()).writeToBuffer(),
    };
    return const GZipEncoder().encodeBytes(backupBytes);
  }

  @override
  List<TachiBackupManga> get mangaSearchEntries => backupManga;

  @override
  List<SourceMangaData> get sourceMangaDataEntries {
    return backupManga.map((TachiBackupManga manga) {
      final List<String> categoryNames = manga.categories.map((int idx) {
        if (idx >= 0 && idx < backupCategories.length) {
          return backupCategories[idx].name;
        }
        return 'Category $idx';
      }).toList();

      final String? sourceName = <TachiBackupSource>[
        ...backupSources,
        ...backupBrokenSources,
      ].where((TachiBackupSource s) => s.sourceId == manga.source).map((TachiBackupSource s) => s.name).firstOrNull;

      return SourceMangaData(
        details: manga.toMangaSearchDetails(),
        sourceId: sourceName ?? 'Source ${manga.source}',
        sourceMangaKey: manga.url,
        categories: categoryNames,
        chapters: manga.chapters.map((TachiBackupChapter c) {
          return SourceChapter(
            title: c.name,
            chapterKey: c.url,
            chapterNumber: c.chapterNumber,
            scanlator: c.scanlator.isEmpty ? null : c.scanlator,
            isRead: c.read,
            isBookmarked: c.bookmark,
            lastPageRead: c.lastPageRead,
            dateUploaded: c.dateUpload > 0 ? DateTime.fromMillisecondsSinceEpoch(c.dateUpload) : null,
            sourceOrder: c.sourceOrder,
          );
        }).toList(),
        history: manga.history.map((TachiBackupHistory h) {
          final TachiBackupChapter? ch = manga.chapters
              .where(
                (TachiBackupChapter c) => c.url == h.url,
              )
              .firstOrNull;
          return SourceHistoryEntry(
            chapterTitle: ch?.name ?? h.url,
            chapterKey: h.url,
            chapterNumber: ch?.chapterNumber,
            dateRead: h.lastRead > 0 ? DateTime.fromMillisecondsSinceEpoch(h.lastRead) : null,
            completed: ch?.read ?? false,
          );
        }).toList(),
        tracking: manga.tracking.map((TachiBackupTracking t) {
          return SourceTrackingEntry(
            syncId: t.syncId,
            libraryId: t.libraryId,
            mediaId: t.mediaId,
            trackingUrl: t.trackingUrl,
            title: t.title,
            lastChapterRead: t.lastChapterRead,
            totalChapters: t.totalChapters,
            score: t.score,
            status: t.status,
            startedReadingDate: t.startedReadingDate > 0
                ? DateTime.fromMillisecondsSinceEpoch(t.startedReadingDate)
                : null,
            finishedReadingDate: t.finishedReadingDate > 0
                ? DateTime.fromMillisecondsSinceEpoch(t.finishedReadingDate)
                : null,
          );
        }).toList(),
        dateAdded: manga.dateAdded > 0 ? DateTime.fromMillisecondsSinceEpoch(manga.dateAdded) : null,
        lastUpdated: (manga.lastModifiedAt ?? 0) > 0
            ? DateTime.fromMillisecondsSinceEpoch(manga.lastModifiedAt!)
            : null,
        status: manga.status,
      );
    }).toList();
  }

  static const TachiBackup Function(Map<String, dynamic> map) fromMap = TachiBackupMapper.fromMap;
  static const TachiBackup Function(String json) fromJson = TachiBackupMapper.fromJson;

  @override
  List<ExtractionLoss> get extractionLosses => const <ExtractionLoss>[];

  @override
  List<String> get diagnostics {
    final lines = <String>[];
    lines.add('Categories: ${backupCategories.length}');
    lines.add('Manga: ${backupManga.length}');
    lines.add('Sources: ${backupSources.length}');
    lines.add('Extension Repos: ${backupExtensionRepo.length}');
    return lines;
  }
}
