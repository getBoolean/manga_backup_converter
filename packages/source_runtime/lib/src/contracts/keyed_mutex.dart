import 'dart:async';

/// Runs bodies one at a time per key, in call order; different keys run
/// concurrently. An entry is dropped once its last body finishes.
final class KeyedMutex {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  /// Runs [body] after every earlier body for [key] has finished (whether it
  /// completed or threw).
  Future<T> run<T>(String key, Future<T> Function() body) async {
    final Future<void> previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    final Future<void> mine = done.future;
    _tails[key] = mine;
    try {
      await previous;
      return await body();
    } finally {
      done.complete();
      if (identical(_tails[key], mine)) unawaited(_tails.remove(key));
    }
  }
}
