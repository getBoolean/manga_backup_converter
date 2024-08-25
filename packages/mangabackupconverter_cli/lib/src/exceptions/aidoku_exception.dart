class AidokuException implements Exception {
  final Object? message;
  const AidokuException([this.message]);

  @override
  String toString() {
    final Object? message = this.message;
    if (message == null) return 'AidokuException';
    return 'AidokuException: $message';
  }
}
