class TachibkException implements Exception {
  final Object? message;
  const TachibkException([this.message]);

  @override
  String toString() {
    final Object? message = this.message;
    if (message == null) return 'TachibkException';
    return 'TachibkException: $message';
  }
}
