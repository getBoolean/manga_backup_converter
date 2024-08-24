import 'dart:typed_data';

import 'package:mangabackupconverter_cli/src/formats/aib/aidoku_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/pas4/paperback_backup.dart';

class MangaBackupConverter {
  AidokuBackup? importAidokuBackup(ByteData bytes) {
    return AidokuBackup.fromBinaryPropertyList(bytes);
  }

  PaperbackBackup? importPaperbackPas4Backup(ByteData bytes) {
    return PaperbackBackup.fromZip(bytes);
  }
}
