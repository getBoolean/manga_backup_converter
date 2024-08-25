import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/mangabackupconverter_lib.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';

part 'tachibk_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class TachibkBackup with TachibkBackupMappable {
  final TachiFork fork;
  final Map<String, Object> data;

  const TachibkBackup({required this.data, this.fork = TachiFork.mihon});

  static TachibkBackup? fromBackup(
    ByteData bytes, {
    TachiFork fork = TachiFork.mihon,
  }) {
    // TODO: Read from file
    return TachibkBackup(data: {}, fork: fork);
  }

  ByteData? toBackup() {
    // TODO: Write json to file
    return null;
  }

  static const fromMap = TachibkBackupMapper.fromMap;
  static const fromJson = TachibkBackupMapper.fromJson;
}
