import 'package:dart_mappable/dart_mappable.dart';

part 'tachimanga_backup_categories.mapper.dart';

@MappableClass(caseStyle: CaseStyle.snakeCase)
class TachimangaBackupCategories with TachimangaBackupCategoriesMappable {
  final int id;
  final String name;
  final int order;
  final bool isDefault;

  const TachimangaBackupCategories({
    required this.id,
    required this.name,
    required this.order,
    required this.isDefault,
  });

  static const fromMap = TachimangaBackupCategoriesMapper.fromMap;
  static const fromJson = TachimangaBackupCategoriesMapper.fromJson;
}
