import 'dart:async';

/// Conversion-scoped owner of every asynchronously closed resource: loaded
/// plugin sessions and, on desktop, the runtime scope that owns worker
/// processes (KTD4 ownership).
///
/// The pipeline creates it before any source list is fetched or plugin is
/// loaded and awaits [close] in the `finally` block that covers loading
/// through building, so a failure is returned only after every adopted
/// resource has been released — including plugins a loader opened before a
/// later plugin failed.
final class ConversionOwner {
  final List<Future<void> Function()> _closers = <Future<void> Function()>[];
  Future<void>? _closing;

  /// Whether [close] has been called.
  bool get isClosed => _closing != null;

  /// Registers [close] to run when the owner closes. Resources adopted after
  /// the owner closed are closed immediately; the returned future completes
  /// when that close finishes.
  Future<void> adopt(FutureOr<void> Function() close) {
    Future<void> run() async => close();
    if (_closing != null) return run();
    _closers.add(run);
    return Future<void>.value();
  }

  /// Closes every adopted resource in reverse adoption order, awaiting each.
  /// A failing close does not stop the others; the first error is rethrown
  /// after all have run. Idempotent.
  Future<void> close() => _closing ??= _closeAll();

  Future<void> _closeAll() async {
    Object? firstError;
    StackTrace? firstStack;
    for (final Future<void> Function() closer in _closers.reversed) {
      try {
        await closer();
      } on Object catch (e, s) {
        firstError ??= e;
        firstStack ??= s;
      }
    }
    _closers.clear();
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}
