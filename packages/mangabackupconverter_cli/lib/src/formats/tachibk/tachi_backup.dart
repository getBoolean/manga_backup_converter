// ignore_for_file: unused_import

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';
import 'package:mangabackupconverter_cli/src/formats/tachibk/tachi_backup_category.dart';
import 'package:mangabackupconverter_cli/src/formats/tachibk/tachi_backup_manga.dart';
import 'package:mangabackupconverter_cli/src/formats/tachibk/tachi_fork.dart';
import 'package:mangabackupconverter_cli/src/formats/tachibk/tachi_source.dart';
import 'package:mangabackupconverter_cli/src/proto/schema_j2k.proto/proto/schema_j2k.pb.dart'
    as j2k;
import 'package:mangabackupconverter_cli/src/proto/schema_mihon.proto/proto/schema_mihon.pb.dart'
    as mihon;
import 'package:mangabackupconverter_cli/src/proto/schema_neko.proto/proto/schema_neko.pb.dart'
    as neko;
import 'package:mangabackupconverter_cli/src/proto/schema_sy.proto/proto/schema_sy.pb.dart'
    as sy;
import 'package:mangabackupconverter_cli/src/proto/schema_yokai.proto/proto/schema_yokai.pb.dart'
    as yokai;
import 'package:meta/meta.dart';
import 'package:protobuf/protobuf.dart';

part 'tachi_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class TachiBackup with TachiBackupMappable {
  final TachiFork fork;
  final List<TachiSource> backupBrokenSources;
  final List<TachiSource> backupSources;
  final List<TachiBackupCategory> backupCategories;
  // final List<BackupExtensionRepos> backupExtensionRepo;
  final List<TachiBackupManga> backupManga;
  // final List<BackupPreference> backupPreferences;
  // final List<BackupSourcePreferences> backupSourcePreferences;

  const TachiBackup({
    required this.backupBrokenSources,
    required this.backupSources,
    required this.backupCategories,
    required this.backupManga,
    this.fork = TachiFork.mihon,
  });

  factory TachiBackup._fromMihon({required mihon.Backup backup}) {
    backup.backupExtensionRepo;
    backup.backupPreferences;
    backup.backupSourcePreferences;
    return TachiBackup(
      backupBrokenSources:
          backup.backupBrokenSources.map(TachiSource.fromMihon).toList(),
      backupSources:
          backup.backupBrokenSources.map(TachiSource.fromMihon).toList(),
      backupCategories:
          backup.backupCategories.map(TachiBackupCategory.fromMihon).toList(),
      backupManga: backup.backupManga.map(TachiBackupManga.fromMihon).toList(),
    );
  }

  static TachiBackup? fromBackup(
    Uint8List bytes, {
    TachiFork fork = TachiFork.mihon,
  }) {
    // TODO: Read from file
    final backupArchive = GZipDecoder().decodeBytes(bytes);
    return switch (fork) {
      TachiFork.mihon => TachiBackup._fromMihon(
          backup: mihon.Backup.fromBuffer(backupArchive),
        ),
      TachiFork.sy => throw UnimplementedError(),
      TachiFork.j2k => throw UnimplementedError(),
      TachiFork.yokai => throw UnimplementedError(),
      TachiFork.neko => throw UnimplementedError(),
    };
  }

  Uint8List? toBackup() {
    // TODO: Write json to file
    return null;
  }

  static const fromMap = TachiBackupMapper.fromMap;
  static const fromJson = TachiBackupMapper.fromJson;
}
