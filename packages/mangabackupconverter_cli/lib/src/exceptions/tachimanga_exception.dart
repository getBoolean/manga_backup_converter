import 'package:mangabackupconverter_cli/src/exceptions/base_exeption.dart';

class TachimangaException extends MangaConverterException {
  const TachimangaException([super.message]);

  @override
  String toString() {
    final Object? message = this.message;
    if (message == null) return 'TachimangaException';
    return 'TachimangaException: $message';
  }
}
