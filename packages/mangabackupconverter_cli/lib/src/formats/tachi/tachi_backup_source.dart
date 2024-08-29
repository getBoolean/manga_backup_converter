import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/proto/schema_j2k.proto/proto/schema_j2k.pb.dart'
    as j2k;
import 'package:mangabackupconverter_cli/src/proto/schema_mihon.proto/proto/schema_mihon.pb.dart'
    as mihon;
import 'package:mangabackupconverter_cli/src/proto/schema_sy.proto/proto/schema_sy.pb.dart'
    as sy;
import 'package:mangabackupconverter_cli/src/proto/schema_yokai.proto/proto/schema_yokai.pb.dart'
    as yokai;

part 'tachi_backup_source.mapper.dart';

@MappableClass()
class TachiBackupSource with TachiBackupSourceMappable {
  final String name;
  final int sourceId;

  const TachiBackupSource({required this.name, required this.sourceId});

  factory TachiBackupSource.fromMihon(
    mihon.BrokenBackupSource brokenBackupSource,
  ) {
    return TachiBackupSource(
      name: brokenBackupSource.name,
      sourceId: brokenBackupSource.sourceId.toInt(),
    );
  }

  factory TachiBackupSource.fromSy(
    sy.BrokenBackupSource brokenBackupSource,
  ) {
    return TachiBackupSource(
      name: brokenBackupSource.name,
      sourceId: brokenBackupSource.sourceId.toInt(),
    );
  }

  factory TachiBackupSource.fromJ2k(
    j2k.BrokenBackupSource brokenBackupSource,
  ) {
    return TachiBackupSource(
      name: brokenBackupSource.name,
      sourceId: brokenBackupSource.sourceId.toInt(),
    );
  }

  factory TachiBackupSource.fromYokai(
    yokai.BrokenBackupSource brokenBackupSource,
  ) {
    return TachiBackupSource(
      name: brokenBackupSource.name,
      sourceId: brokenBackupSource.sourceId.toInt(),
    );
  }

  static const fromMap = TachiBackupSourceMapper.fromMap;
  static const fromJson = TachiBackupSourceMapper.fromJson;
}
