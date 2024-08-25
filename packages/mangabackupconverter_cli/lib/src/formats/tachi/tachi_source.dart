import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/proto/schema_j2k.proto/proto/schema_j2k.pb.dart'
    as j2k;
import 'package:mangabackupconverter_cli/src/proto/schema_mihon.proto/proto/schema_mihon.pb.dart'
    as mihon;
import 'package:mangabackupconverter_cli/src/proto/schema_sy.proto/proto/schema_sy.pb.dart'
    as sy;
import 'package:mangabackupconverter_cli/src/proto/schema_yokai.proto/proto/schema_yokai.pb.dart'
    as yokai;

part 'tachi_source.mapper.dart';

@MappableClass()
class TachiSource with TachiSourceMappable {
  final String name;
  final int sourceId;

  const TachiSource({required this.name, required this.sourceId});

  factory TachiSource.fromMihon(
    mihon.BrokenBackupSource brokenBackupSource,
  ) {
    return TachiSource(
      name: brokenBackupSource.name,
      sourceId: brokenBackupSource.sourceId.toInt(),
    );
  }

  factory TachiSource.fromSy(
    sy.BrokenBackupSource brokenBackupSource,
  ) {
    return TachiSource(
      name: brokenBackupSource.name,
      sourceId: brokenBackupSource.sourceId.toInt(),
    );
  }

  factory TachiSource.fromJ2k(
    j2k.BrokenBackupSource brokenBackupSource,
  ) {
    return TachiSource(
      name: brokenBackupSource.name,
      sourceId: brokenBackupSource.sourceId.toInt(),
    );
  }

  factory TachiSource.fromYokai(
    yokai.BrokenBackupSource brokenBackupSource,
  ) {
    return TachiSource(
      name: brokenBackupSource.name,
      sourceId: brokenBackupSource.sourceId.toInt(),
    );
  }

  static const fromMap = TachiSourceMapper.fromMap;
  static const fromJson = TachiSourceMapper.fromJson;
}
