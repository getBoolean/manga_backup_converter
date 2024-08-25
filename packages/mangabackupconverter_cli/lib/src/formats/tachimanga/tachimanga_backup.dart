import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';

part 'tachimanga_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class TachimangaBackup with TachimangaBackupMappable {
  final String? name;

  const TachimangaBackup({
    this.name,
  });

  static TachimangaBackup? fromZip(Uint8List bytes, {String? name}) {
    final archive = ZipDecoder().decodeBytes(bytes);
    return TachimangaBackup(
      name: name,
    );
  }

  Uint8List? toZip() {
    final archive = Archive();
    final encodingResult = ZipEncoder().encode(archive);
    return encodingResult == null ? null : Uint8List.fromList(encodingResult);
  }

  static const fromMap = TachimangaBackupMapper.fromMap;
  static const fromJson = TachimangaBackupMapper.fromJson;
}
