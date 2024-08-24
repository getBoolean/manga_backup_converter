import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';

part 'aidoku_backup_history.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class AidokuBackupHistory with AidokuBackupHistoryMappable {
  final DateTime dateRead;
  final String sourceId;
  final String chapterId;
  final String mangaId;
  final int? progress;
  final int? total;
  final bool completed;

  AidokuBackupHistory({
    required this.dateRead,
    required this.sourceId,
    required this.chapterId,
    required this.mangaId,
    required this.progress,
    required this.total,
    required this.completed,
  });

  static final fromMap = AidokuBackupHistoryMapper.fromMap;
  static final fromJson = AidokuBackupHistoryMapper.fromJson;
}
