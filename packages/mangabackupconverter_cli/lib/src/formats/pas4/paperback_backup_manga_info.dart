import 'package:dart_mappable/dart_mappable.dart';

part 'paperback_backup_manga_info.mapper.dart';

@MappableClass()
class PaperbackBackupMangaInfo with PaperbackBackupMangaInfoMappable {
  final List<PaperbackBackupMangaTag> tags;
  final String desc;
  final String? rating;
  final List<String> titles;
  final List<String> covers;
  final String? banner;
  final String author;
  final String image;
  final bool hentai;
  final PaperbackBackupMangaAdditionalInfo additionalInfo;
  final String artist;
  final String id;
  final String status;

  PaperbackBackupMangaInfo({
    required this.tags,
    required this.desc,
    this.rating,
    required this.titles,
    required this.covers,
    this.banner,
    required this.author,
    required this.image,
    required this.hentai,
    required this.additionalInfo,
    required this.artist,
    required this.id,
    required this.status,
  });

  static final fromMap = PaperbackBackupMangaInfoMapper.fromMap;
  static final fromJson = PaperbackBackupMangaInfoMapper.fromJson;
}

@MappableClass()
class PaperbackBackupMangaAdditionalInfo
    with PaperbackBackupMangaAdditionalInfoMappable {
  final String? langFlag;
  final String? avgRating;
  final String? views;
  final String? follows;
  final String? users;
  final String? langName;

  PaperbackBackupMangaAdditionalInfo({
    this.langFlag,
    this.avgRating,
    this.views,
    this.follows,
    this.users,
    this.langName,
  });

  static final fromMap = PaperbackBackupMangaAdditionalInfoMapper.fromMap;
  static final fromJson = PaperbackBackupMangaAdditionalInfoMapper.fromJson;
}

@MappableClass()
class PaperbackBackupMangaTag with PaperbackBackupMangaTagMappable {
  final String id;
  final String label;
  final List<PaperbackBackupMangaTag> tags;

  PaperbackBackupMangaTag({
    required this.id,
    required this.label,
    this.tags = const [],
  });

  static final fromMap = PaperbackBackupMangaTagMapper.fromMap;
  static final fromJson = PaperbackBackupMangaTagMapper.fromJson;
}
