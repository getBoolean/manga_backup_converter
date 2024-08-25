import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';
import 'package:mangabackupconverter_cli/src/exceptions/tachimanga_exception.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup_meta.dart';

part 'tachimanga_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class TachimangaBackup with TachimangaBackupMappable {
  final String? name;
  final TachimangaBackupMeta meta;

  const TachimangaBackup({
    required this.meta,
    this.name,
  });

  static TachimangaBackup? fromZip(Uint8List bytes, {String? name}) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final metaFile = archive.findFile('meta.json');
    if (metaFile == null || metaFile.content == null) {
      throw TachimangaException('Could not decode Tachimanga backup "$name"');
    }

    final meta = TachimangaBackupMeta.fromMap(
      jsonDecode(
        String.fromCharCodes(
          metaFile.content as Uint8List,
        ),
      ) as Map<String, dynamic>,
    );
    return TachimangaBackup(
      name: name,
      meta: meta,
    );
  }

  Uint8List? toZip() {
    final contentsArchive = Archive();
    final contentsEncoded = ZipEncoder().encode(contentsArchive);
    if (contentsEncoded == null) {
      throw const TachimangaException('Could not encode Tachimanga backup');
    }

    final backupArchive = Archive();
    backupArchive.addFile(ArchiveFile.string('meta.json', meta.toJson()));
    backupArchive.addFile(
      ArchiveFile.noCompress(
        'contents.zip',
        contentsEncoded.length,
        contentsEncoded,
      ),
    );
    final backupEncoded = ZipEncoder().encode(backupArchive);
    return backupEncoded == null ? null : Uint8List.fromList(backupEncoded);
  }

  static const fromMap = TachimangaBackupMapper.fromMap;
  static const fromJson = TachimangaBackupMapper.fromJson;
}
