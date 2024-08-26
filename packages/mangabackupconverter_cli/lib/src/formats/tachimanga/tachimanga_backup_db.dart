import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/common/constants.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup_db_manager.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup_db_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

part 'tachimanga_backup_db.mapper.dart';

@MappableClass(
  generateMethods:
      GenerateMethods.equals | GenerateMethods.copy | GenerateMethods.stringify,
)
class TachimangaBackupDb with TachimangaBackupDbMappable {
  final List<TachimangaBackupCategories> categories;
  // TODO: Add variables for each table

  const TachimangaBackupDb({
    required this.categories,
  });

  static Future<TachimangaBackupDb> fromDatabase(Uint8List dbContent) async {
    final Database db;
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      await databaseFactory.writeDatabaseBytes(
        'tachimanga.db',
        dbContent,
      );
      db = await databaseFactory.openDatabase('tachimanga.db');
    } else {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await databaseFactory.writeDatabaseBytes(
        'tachimanga.db',
        dbContent,
      );
      db = await databaseFactory.openDatabase('tachimanga.db');
    }
    final backupDbManager =
        TachimangaBackupDbManager(db: db, databaseFactory: databaseFactory);
    final categories = await backupDbManager.queryCategories();

    await db.close();

    return TachimangaBackupDb(
      categories: categories,
    );
  }

  Future<Uint8List> exportDatabase() async {
    final Database db;
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      db = await databaseFactory.openDatabase('tachimanga.db');
    } else {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      db = await databaseFactory.openDatabase('tachimanga.db');
    }
    final backupDbManager =
        TachimangaBackupDbManager(db: db, databaseFactory: databaseFactory);
    await backupDbManager.initDb();
    await backupDbManager.insertCategories(categories);
    // TODO: Insert each added variable into DB

    final dbContent = await databaseFactory.readDatabaseBytes('tachimanga.db');
    await db.close();

    return dbContent;
  }
}
