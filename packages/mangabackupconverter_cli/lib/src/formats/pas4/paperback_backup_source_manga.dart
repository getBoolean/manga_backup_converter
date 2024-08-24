import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/mangabackupconverter_lib.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';

part 'paperback_backup_source_manga.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class PaperbackBackupSourceManga with PaperbackBackupSourceMangaMappable {
  final String sourceId;
  final String mangaId;
  final String id;
  final PaperbackBackupItemReference mangaInfo;

  PaperbackBackupSourceManga({
    required this.sourceId,
    required this.mangaId,
    required this.id,
    required this.mangaInfo,
  });

  static final fromMap = PaperbackBackupSourceMangaMapper.fromMap;
  static final fromJson = PaperbackBackupSourceMangaMapper.fromJson;
}
