/// CLI library. Re-exports the portable conversion core for existing
/// consumers and adds the CLI-only adapters: the native-dependent Tachimanga
/// and Mangayomi codecs, concrete plugin loaders, and the migration pipeline.
library;

export 'package:manga_backup_core/manga_backup_core.dart';

export 'src/exceptions/mangayomi_exception.dart';
export 'src/exceptions/tachimanga_exception.dart';
export 'src/formats/mangayomi/mangayomi_backup.dart';
export 'src/formats/mangayomi/mangayomi_backup_db.dart';
export 'src/formats/mangayomi/mangayomi_backup_settings.dart';
export 'src/formats/tachimanga/tachi_to_tachimanga.dart';
export 'src/formats/tachimanga/tachimanga_backup.dart';
export 'src/formats/tachimanga/tachimanga_backup_db.dart';
export 'src/formats/tachimanga/tachimanga_backup_db_models.dart';
export 'src/formats/tachimanga/tachimanga_backup_meta.dart';
export 'src/pipeline/plugin_loader.dart';
export 'src/pipeline/plugin_source_tachi.dart';
