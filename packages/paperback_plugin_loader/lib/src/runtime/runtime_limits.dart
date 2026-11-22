/// QuickJS resource limits for one Paperback source runtime (KTD25).
///
/// Every field is required: no limit has a built-in default. Production
/// values come from the sizing rule (`limit_sizing.dart`) applied to the
/// device's measured capability; tests pass small explicit values.
final class PaperbackRuntimeLimits {
  PaperbackRuntimeLimits({
    required this.memoryLimitBytes,
    required this.maxStackBytes,
    required this.operationDeadline,
    required this.jobSlice,
  }) {
    if (memoryLimitBytes <= 0) throw ArgumentError.value(memoryLimitBytes, 'memoryLimitBytes', 'must be positive');
    if (maxStackBytes <= 0) throw ArgumentError.value(maxStackBytes, 'maxStackBytes', 'must be positive');
    if (operationDeadline <= Duration.zero) {
      throw ArgumentError.value(operationDeadline, 'operationDeadline', 'must be positive');
    }
    if (jobSlice <= Duration.zero) throw ArgumentError.value(jobSlice, 'jobSlice', 'must be positive');
  }

  factory PaperbackRuntimeLimits.fromJson(Map<String, Object?> json) => PaperbackRuntimeLimits(
    memoryLimitBytes: json['memoryLimitBytes']! as int,
    maxStackBytes: json['maxStackBytes']! as int,
    operationDeadline: Duration(microseconds: json['operationDeadlineMicros']! as int),
    jobSlice: Duration(microseconds: json['jobSliceMicros']! as int),
  );

  /// QuickJS heap limit for the source's runtime.
  final int memoryLimitBytes;

  /// JS stack limit, measured from the outermost engine entry. Must be below
  /// the worker thread's real stack (see `QuickJs.threadStackAvailable`).
  final int maxStackBytes;

  /// Deadline for one operation, measured from its start. Enforced inside JS
  /// by the interrupt handler and around host waits by a Dart timer.
  final Duration operationDeadline;

  /// Longest run of pending jobs before the runtime yields one event-loop
  /// turn, so a microtask loop cannot starve cancellation or I/O.
  final Duration jobSlice;

  Map<String, Object?> toJson() => <String, Object?>{
    'memoryLimitBytes': memoryLimitBytes,
    'maxStackBytes': maxStackBytes,
    'operationDeadlineMicros': operationDeadline.inMicroseconds,
    'jobSliceMicros': jobSlice.inMicroseconds,
  };

  @override
  String toString() =>
      'PaperbackRuntimeLimits(memory: $memoryLimitBytes, stack: $maxStackBytes, '
      'deadline: $operationDeadline, slice: $jobSlice)';
}
