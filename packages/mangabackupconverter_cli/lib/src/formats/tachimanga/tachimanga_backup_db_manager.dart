import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup_categories.dart';
import 'package:meta/meta.dart';
import 'package:sqflite/sqflite.dart';

@internal
class TachimangaBackupDbManager {
  final Database db;
  final DatabaseFactory databaseFactory;

  TachimangaBackupDbManager({required this.db, required this.databaseFactory});

  Future<List<TachimangaBackupCategories>> queryCategories() async {
    final List<Map<String, Object?>> result = await db.query('Category');
    return result.map(TachimangaBackupCategories.fromMap).toList();
  }
}
