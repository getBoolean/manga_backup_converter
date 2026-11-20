import 'package:dart_mappable/dart_mappable.dart';

part 'paperback_backup_item_type.mapper.dart';

@MappableEnum(defaultValue: PaperbackBackupItemType.unknown)
enum PaperbackBackupItemType {
  @MappableValue('__CHAPTER_PROGRESS_MARKER_V4-1')
  chapterProgressMarkerV4_1,
  @MappableValue('__CHAPTER_V4')
  chapterV4,
  @MappableValue('__LIBRARY_MANGA_V4')
  libraryMangaV4,
  @MappableValue('__MANGA_INFO_V4')
  mangaInfoV4,
  @MappableValue('__SOURCE_MANGA_V4')
  sourceMangaV4,
  unknown,
}
