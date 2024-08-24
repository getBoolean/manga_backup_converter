import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';

part 'paperback_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class PaperbackBackup with PaperbackBackupMappable {
  final Map<String, Object> data;

  const PaperbackBackup({required this.data});

  static PaperbackBackup? fromZip(ByteData bytes) {
    // TODO: Read json files from zip file
    return PaperbackBackup(data: {});
  }

  ByteData? toZip() {
    // TODO: Write json to zip file
    return null;
  }

  static final fromMap = PaperbackBackupMapper.fromMap;
  static final fromJson = PaperbackBackupMapper.fromJson;
}
