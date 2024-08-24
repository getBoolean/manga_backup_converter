import 'dart:typed_data';

import 'package:mangabackupconverter_cli/src/formats/aidoku/aidoku_backup.dart';

class MangaBackupConverter {
  AidokuBackup? importAidokuBackup(ByteData bytes) {
    return AidokuBackup.fromBinaryPropertyList(bytes);
  }
}
