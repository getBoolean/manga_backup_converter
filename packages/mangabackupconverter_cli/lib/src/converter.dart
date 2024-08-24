import 'dart:typed_data';

import 'package:mangabackupconverter_cli/src/formats/aib/aidoku_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/pas4/paperback_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/tachibk/tachibk_backup.dart';

class MangaBackupConverter {
  AidokuBackup? importAidokuBackup(ByteData bytes) {
    return AidokuBackup.fromBinaryPropertyList(bytes);
  }

  PaperbackBackup? importPaperbackPas4Backup(Uint8List bytes) {
    return PaperbackBackup.fromZip(bytes);
  }

  TachibkBackup? importTachibkBackup(ByteData bytes) {
    return TachibkBackup.fromBackup(bytes);
  }
}
