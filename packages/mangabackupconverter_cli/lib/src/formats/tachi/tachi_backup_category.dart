import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/proto/schema_j2k.proto/proto/schema_j2k.pb.dart'
    as j2k;
import 'package:mangabackupconverter_cli/src/proto/schema_mihon.proto/proto/schema_mihon.pb.dart'
    as mihon;
import 'package:mangabackupconverter_cli/src/proto/schema_neko.proto/proto/schema_neko.pb.dart'
    as neko;
import 'package:mangabackupconverter_cli/src/proto/schema_sy.proto/proto/schema_sy.pb.dart'
    as sy;
import 'package:mangabackupconverter_cli/src/proto/schema_yokai.proto/proto/schema_yokai.pb.dart'
    as yokai;

part 'tachi_backup_category.mapper.dart';

@MappableClass()
class TachiBackupCategory with TachiBackupCategoryMappable {
  final String name;
  final int order;
  final int flags;

  const TachiBackupCategory({
    required this.name,
    required this.order,
    required this.flags,
  });

  factory TachiBackupCategory.fromMihon(
    mihon.BackupCategory backupCategory,
  ) {
    return TachiBackupCategory(
      name: backupCategory.name,
      order: backupCategory.order.toInt(),
      flags: backupCategory.flags.toInt(),
    );
  }

  factory TachiBackupCategory.fromSy(
    sy.BackupCategory backupCategory,
  ) {
    return TachiBackupCategory(
      name: backupCategory.name,
      order: backupCategory.order.toInt(),
      flags: backupCategory.flags.toInt(),
    );
  }

  factory TachiBackupCategory.fromJ2k(
    j2k.BackupCategory backupCategory,
  ) {
    return TachiBackupCategory(
      name: backupCategory.name,
      order: backupCategory.order,
      flags: backupCategory.flags,
    );
  }

  factory TachiBackupCategory.fromNeko(
    neko.BackupCategory backupCategory,
  ) {
    return TachiBackupCategory(
      name: backupCategory.name,
      order: backupCategory.order,
      flags: backupCategory.flags,
    );
  }

  factory TachiBackupCategory.fromYokai(
    yokai.BackupCategory backupCategory,
  ) {
    return TachiBackupCategory(
      name: backupCategory.name,
      order: backupCategory.order,
      flags: backupCategory.flags,
    );
  }

  static const fromMap = TachiBackupCategoryMapper.fromMap;
  static const fromJson = TachiBackupCategoryMapper.fromJson;
}
