import 'dart:typed_data';

import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/paperback/paperback_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_fork.dart';

class MangaBackupConverter {
  AidokuBackup? importAidokuBackup(ByteData bytes) {
    return AidokuBackup.fromBinaryPropertyList(bytes);
  }

  PaperbackBackup? importPaperbackPas4Backup(Uint8List bytes, {String? name}) {
    return PaperbackBackup.fromZip(bytes, name: name);
  }

  TachiBackup? importTachibkBackup(
    Uint8List bytes, {
    TachiFork fork = TachiFork.mihon,
  }) {
    return TachiBackup.fromBackup(bytes, fork: fork);
  }
}
