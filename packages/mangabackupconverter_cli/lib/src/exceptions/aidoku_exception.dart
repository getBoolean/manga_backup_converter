import 'package:mangabackupconverter_cli/src/exceptions/base_exeption.dart';

class AidokuException extends MangaConverterException {
  const AidokuException([super.message]);

  @override
  String toString() {
    final Object? message = this.message;
    if (message == null) return 'AidokuException';
    return 'AidokuException: $message';
  }
}
