import 'package:dart_mappable/dart_mappable.dart';
import 'package:manga_backup_core/src/common/seconds_epoc_date_time_mapper.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_item_reference.dart';

part 'paperback_backup_source_manga.mapper.dart';

@MappableClass(includeCustomMappers: <MapperBase<Object>>[SecondsEpochDateTimeMapper()])
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

  static const PaperbackBackupSourceManga Function(Map<String, dynamic> map) fromMap =
      PaperbackBackupSourceMangaMapper.fromMap;
  static const PaperbackBackupSourceManga Function(String json) fromJson = PaperbackBackupSourceMangaMapper.fromJson;
}
