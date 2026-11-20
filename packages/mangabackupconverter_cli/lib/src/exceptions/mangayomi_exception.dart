import 'package:manga_backup_core/manga_backup_core.dart';

class MangayomiException extends MangaConverterException {
  const MangayomiException([super.message, super.cause, super.stackTrace]);

  @override
  String toString() {
    final Object? message = this.message;
    if (message == null) return 'MangayomiException';
    return 'MangayomiException: $message';
  }
}
