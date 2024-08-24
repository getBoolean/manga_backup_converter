import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';

part 'tachibk_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class TachibkBackup with TachibkBackupMappable {
  final Map<String, Object> data;

  const TachibkBackup({required this.data});

  static TachibkBackup? fromBackup(ByteData bytes) {
    // TODO: Read from file
    return TachibkBackup(data: {});
  }

  ByteData? toBackup() {
    // TODO: Write json to file
    return null;
  }

  static final fromMap = TachibkBackupMapper.fromMap;
  static final fromJson = TachibkBackupMapper.fromJson;
}
