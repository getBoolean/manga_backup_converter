import 'dart:async';

/// Cooperative cancellation signal passed into runtime operations.
final class CancellationToken {
  CancellationToken._(this._source);

  /// A token that is never cancelled.
  static final CancellationToken none = CancellationSource().token;

  final CancellationSource _source;

  /// Whether cancellation was requested.
  bool get isCancelled => _source._cancelled;

  /// Reason passed to [CancellationSource.cancel], if cancelled.
  String? get reason => _source._reason;

  /// Completes when cancellation is requested.
  Future<void> get whenCancelled => _source._completer.future;
}

/// Owner side of a [CancellationToken].
final class CancellationSource {
  CancellationSource() {
    token = CancellationToken._(this);
  }

  late final CancellationToken token;
  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;
  String? _reason;

  /// Requests cancellation. Later calls are ignored.
  void cancel([String reason = 'cancelled']) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    _completer.complete();
  }
}
