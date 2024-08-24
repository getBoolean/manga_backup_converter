import 'package:dart_mappable/dart_mappable.dart';

part 'aidoku_backup_track_item.mapper.dart';

@MappableClass()
class AidokuBackupTrackItem with AidokuBackupTrackItemMappable {
  final String id;
  final String trackerId;
  final String mangaId;
  final String sourceId;
  final String? title;

  AidokuBackupTrackItem({
    required this.id,
    required this.trackerId,
    required this.mangaId,
    required this.sourceId,
    required this.title,
  });

  static final fromMap = AidokuBackupTrackItemMapper.fromMap;
  static final fromJson = AidokuBackupTrackItemMapper.fromJson;
}
