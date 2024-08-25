import 'package:mangabackupconverter_cli/src/exceptions/base_exeption.dart';

class TachiException extends MangaConverterException {
  const TachiException([super.message]);

  @override
  String toString() {
    final Object? message = this.message;
    if (message == null) return 'TachiException';
    return 'TachiException: $message';
  }
}
