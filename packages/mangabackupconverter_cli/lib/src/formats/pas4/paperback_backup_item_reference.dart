import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';

part 'paperback_backup_item_reference.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class PaperbackBackupItemReference with PaperbackBackupItemReferenceMappable {
  final String type;
  final String id;

  PaperbackBackupItemReference({
    required this.type,
    required this.id,
  });

  static final fromMap = PaperbackBackupItemReferenceMapper.fromMap;
  static final fromJson = PaperbackBackupItemReferenceMapper.fromJson;
}
