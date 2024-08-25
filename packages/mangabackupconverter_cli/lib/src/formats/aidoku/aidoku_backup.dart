import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';
import 'package:mangabackupconverter_cli/src/exceptions/aidoku_exception.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_chapter.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_history.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_library_manga.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_manga.dart';
import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup_track_item.dart';
import 'package:propertylistserialization/propertylistserialization.dart';

part 'aidoku_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class AidokuBackup with AidokuBackupMappable {
  final List<AidokuBackupLibraryManga>? library;
  final List<AidokuBackupHistory>? history;
  final List<AidokuBackupManga>? manga;
  final List<AidokuBackupChapter>? chapters;
  final List<AidokuBackupTrackItem>? trackItems;
  final List<String>? categories;
  final List<String>? sources;
  final DateTime date;
  final String? name;
  final String? version;

  const AidokuBackup({
    required this.library,
    required this.history,
    required this.manga,
    required this.chapters,
    required this.trackItems,
    required this.categories,
    required this.sources,
    required this.date,
    required this.name,
    required this.version,
  });

  static AidokuBackup? fromBinaryPropertyList(ByteData bytes) {
    final asMap = PropertyListSerialization.propertyListWithData(bytes)
        as Map<String, Object>;
    return fromMap(asMap);
  }

  ByteData? toBinaryPropertyList() {
    try {
      return PropertyListSerialization.dataWithPropertyList(toMap());
    } on PropertyListWriteStreamException catch (e) {
      throw AidokuException(e);
    }
  }

  static const fromMap = AidokuBackupMapper.fromMap;
  static const fromJson = AidokuBackupMapper.fromJson;
}
