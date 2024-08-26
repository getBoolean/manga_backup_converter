import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/seconds_epoc_date_time_mapper.dart';
import 'package:mangabackupconverter_cli/src/exceptions/tachimanga_exception.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup_meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcode_parser/xcode_parser.dart';

part 'tachimanga_backup.mapper.dart';

@MappableClass(includeCustomMappers: [SecondsEpochDateTimeMapper()])
class TachimangaBackup with TachimangaBackupMappable {
  final String? name;
  final TachimangaBackupMeta meta;
  final Map<String, Object?>? pref;
  final Pbxproj? prefAll;
  final Map<String, Map<String, Object?>>? prefs;
  final Map<String, Uint8List>? extensions;
  final Uint8List db;

  const TachimangaBackup({
    required this.meta,
    required this.db,
    this.pref,
    this.prefAll,
    this.prefs,
    this.extensions,
    this.name,
  });

  static TachimangaBackup? fromZip(Uint8List bytes, {String? overrideName}) {
    final backupArchive = ZipDecoder().decodeBytes(bytes);
    final metaFile = backupArchive.findFile('meta.json');
    if (metaFile == null || metaFile.content == null) {
      throw const TachimangaException(
        'Could not decode Tachimanga backup',
      );
    }

    final meta = TachimangaBackupMeta.fromJson(
      String.fromCharCodes(metaFile.content as Uint8List),
    );
    final archiveName = overrideName ?? meta.name;

    final contentZipFile = backupArchive.findFile('contents.zip');
    if (contentZipFile == null || contentZipFile.content == null) {
      throw TachimangaException(
        'Could not decode Tachimanga backup "$archiveName", contents.zip not found',
      );
    }
    final contentArchive =
        ZipDecoder().decodeBytes(contentZipFile.content as Uint8List);
    final prefFile = contentArchive.findFile('pref.json');
    if (prefFile == null || prefFile.content == null) {
      throw TachimangaException(
        'Could not decode Tachimanga backup "$archiveName", pref.json not found',
      );
    }
    final pref = jsonDecode(String.fromCharCodes(prefFile.content as Uint8List))
        as Map<String, Object?>;

    // This json file is actually a pbxproj file
    final prefAllFile = contentArchive.findFile('pref-all.json');
    if (prefAllFile == null || prefAllFile.content == null) {
      throw TachimangaException(
        'Could not decode Tachimanga backup "$archiveName", pref-all.json not found',
      );
    }
    final prefAllContent =
        String.fromCharCodes(prefAllFile.content as Uint8List);
    final prefAll = Pbxproj.parse(prefAllContent, path: 'pref-all.json');

    final prefsFiles = contentArchive.files.where(
      (file) {
        return file.name.startsWith('prefs/') && file.name.endsWith('.plist');
      },
    ).toList();
    final prefs =
        prefsFiles.fold(<String, Map<String, Object?>>{}, (map, file) {
      final content = file.content as Uint8List;
      map[file.name] = PropertyListSerialization.propertyListWithData(
        ByteData.sublistView(content),
      ) as Map<String, Object?>;
      return map;
    });
    final extensionFiles = contentArchive.files.where(
      (file) {
        return file.name.startsWith('extensions/') &&
            file.name.endsWith('.jar');
      },
    ).toList();
    final extensions = extensionFiles.fold(
      <String, Uint8List>{},
      (map, file) => map..addAll({file.name: file.content as Uint8List}),
    );

    final dbFile = contentArchive.findFile('tachimanga.db');
    if (dbFile == null) {
      throw TachimangaException(
        'Could not decode Tachimanga backup "$archiveName", tachimanga.db not found',
      );
    }
    // TODO: Extra data from db file
    return TachimangaBackup(
      name: archiveName,
      meta: meta,
      pref: pref,
      prefs: prefs,
      prefAll: prefAll,
      db: dbFile.content as Uint8List,
      extensions: extensions,
    );
  }

  Uint8List? toZip() {
    final contentsArchive = Archive();
    if (pref case final Map<String, Object?> pref) {
      contentsArchive
          .addFile(ArchiveFile.string('pref.json', jsonEncode(pref)));
    }
    if (prefAll case final Pbxproj prefAll) {
      contentsArchive.addFile(
        ArchiveFile.string(
          'pref-all.json',
          prefAll.toString(),
        ),
      );
    }
    if (extensions case final Map<String, Uint8List> extensions) {
      extensions.forEach((filename, content) {
        contentsArchive.addFile(
          ArchiveFile(filename, content.elementSizeInBytes, content),
        );
      });
    }
    if (prefs case final Map<String, Map<String, Object?>> prefs) {
      prefs.forEach((filename, content) {
        final ByteData binaryPlist =
            PropertyListSerialization.dataWithPropertyList(content);
        contentsArchive.addFile(
          ArchiveFile.noCompress(
            filename,
            binaryPlist.lengthInBytes,
            binaryPlist.buffer.asUint8List(),
          ),
        );
      });
    }

    contentsArchive.addFile(
      ArchiveFile.noCompress('tachimanga.db', db.elementSizeInBytes, db),
    );
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
