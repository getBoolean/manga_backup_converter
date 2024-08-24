class PaperbackException implements Exception {
  final Object? message;
  const PaperbackException([this.message]);

  @override
  String toString() {
    Object? message = this.message;
    if (message == null) return "PaperbackException";
    return "PaperbackException: $message";
  }
}
