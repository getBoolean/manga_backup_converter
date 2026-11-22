/// The plugin's WASM isolate exited before it answered [operation].
///
/// Raised instead of waiting forever on a reply that can no longer arrive:
/// after `dispose`, after an uncaught error in the isolate (for example a
/// trap in the source's `start` export), or after the isolate was killed.
/// The plugin cannot be used again; load it afresh.
class AidokuIsolateExitedException implements Exception {
  const AidokuIsolateExitedException(this.operation, {this.error});

  /// The plugin call that was waiting, or `start` during loading.
  final String operation;

  /// The isolate's uncaught error, when it reported one before exiting.
  final String? error;

  @override
  String toString() =>
      'AidokuIsolateExitedException: WASM isolate exited during $operation'
      '${error == null ? '' : ': $error'}';
}
