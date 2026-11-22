import 'package:manga_backup_core/src/conversion/backup_format.dart';

sealed class ConversionStrategy {
  const ConversionStrategy();
}

class DirectConversion extends ConversionStrategy {
  const DirectConversion();
}

class Migration extends ConversionStrategy {
  const Migration();
}

ConversionStrategy determineStrategy(BackupFormat source, BackupFormat target) {
  if (source is Tachimanga && target is Tachiyomi) return const DirectConversion();
  if (source is Tachiyomi && target is Tachimanga) return const DirectConversion();
  return const Migration();
}
