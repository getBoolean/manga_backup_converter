import 'dart:typed_data';

import 'package:manga_backup_core/src/conversion/manga_details.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';

abstract interface class ConvertableType<ReturnType, ArgumentType> {
  ReturnType toType(ArgumentType arg);
}

abstract interface class ConvertableBackup {
  Future<Uint8List> toData();
  // ignore: avoid_positional_boolean_parameters
  void verbosePrint(bool verbose);
  List<MangaSearchEntry> get mangaSearchEntries;
  List<SourceMangaData> get sourceMangaDataEntries;
}
