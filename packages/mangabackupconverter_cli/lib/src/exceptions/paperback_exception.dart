class PaperbackException implements Exception {
  final Object? message;
  const PaperbackException([this.message]);

  @override
  String toString() {
    final Object? message = this.message;
    if (message == null) return 'PaperbackException';
    return 'PaperbackException: $message';
  }
}
