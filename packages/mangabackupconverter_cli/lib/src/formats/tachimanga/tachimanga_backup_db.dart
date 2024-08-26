import 'package:sqlite3/common.dart';

class TachimangaBackupDb {
  final CommonSqlite3 sqlite;
  final CommonDatabase db;

  TachimangaBackupDb({required this.sqlite, required this.db});
}
