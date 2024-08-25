import 'dart:typed_data';

import 'package:mangabackupconverter_cli/src/formats/aib/aidoku_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/pas4/paperback_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/tachibk/tachi_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/tachibk/tachi_fork.dart';

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
