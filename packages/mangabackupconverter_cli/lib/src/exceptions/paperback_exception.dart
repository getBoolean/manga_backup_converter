import 'package:mangabackupconverter_cli/src/exceptions/base_exeption.dart';

class PaperbackException extends MangaConverterException {
  const PaperbackException([super.message]);

  @override
  String toString() {
    final Object? message = this.message;
    if (message == null) return 'PaperbackException';
    return 'PaperbackException: $message';
  }
}
