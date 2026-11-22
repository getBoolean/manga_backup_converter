import 'dart:typed_data';

import 'package:manga_backup_core/src/conversion/manga_details.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';

abstract interface class ConvertableType<ReturnType, ArgumentType> {
  ReturnType toType(ArgumentType arg);
}

abstract interface class ConvertableBackup {
  Future<Uint8List> toData();

  /// Structured summary lines for diagnostics; hosts decide how to render them.
  List<String> get diagnostics;
  List<MangaSearchEntry> get mangaSearchEntries;
  List<SourceMangaData> get sourceMangaDataEntries;

  /// Library records that could not be extracted into [sourceMangaDataEntries].
  List<ExtractionLoss> get extractionLosses;
}
