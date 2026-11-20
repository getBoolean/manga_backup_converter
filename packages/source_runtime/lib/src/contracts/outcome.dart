/// Typed outcomes and failures shared by every source runtime (KTD3, KTD15).
///
/// A successful empty result is a [SourceSuccess] with empty data; it is never
/// conflated with a [SourceFailed] outcome.
library;

/// Result of a source runtime operation.
sealed class SourceOutcome<T> {
  const SourceOutcome();

  /// Whether this outcome is a success.
  bool get isSuccess => this is SourceSuccess<T>;

  /// The value of a success, or `null` for a failure.
  T? get valueOrNull => switch (this) {
    SourceSuccess<T>(:final T value) => value,
    SourceFailed<T>() => null,
  };

  /// The failure, or `null` for a success.
  SourceFailure? get failureOrNull => switch (this) {
    SourceSuccess<T>() => null,
    SourceFailed<T>(:final SourceFailure failure) => failure,
  };

  /// Maps a success value; failures pass through unchanged.
  SourceOutcome<R> map<R>(R Function(T value) transform) => switch (this) {
    SourceSuccess<T>(:final T value) => SourceSuccess<R>(transform(value)),
    SourceFailed<T>(:final SourceFailure failure) => SourceFailed<R>(failure),
  };
}

/// A completed operation and its (possibly empty) data.
final class SourceSuccess<T> extends SourceOutcome<T> {
  const SourceSuccess(this.value);

  final T value;

  @override
  String toString() => 'SourceSuccess($value)';
}

/// A failed operation and its typed reason.
final class SourceFailed<T> extends SourceOutcome<T> {
  const SourceFailed(this.failure);

  final SourceFailure failure;

  @override
  String toString() => 'SourceFailed($failure)';
}

/// Why a source operation did not complete.
///
/// [code] is the stable wire identifier used by the worker protocol.
sealed class SourceFailure {
  const SourceFailure(this.message);

  /// Reconstructs a failure from its wire form.
  factory SourceFailure.fromWire(String code, String message, {String? operation}) => switch (code) {
    TimeoutFailure.wireCode => TimeoutFailure(message),
    CancelledFailure.wireCode => CancelledFailure(message),
    UnsupportedApiFailure.wireCode => UnsupportedApiFailure(message),
    InteractionRequiredFailure.wireCode => InteractionRequiredFailure(message),
    StaleReferenceFailure.wireCode => StaleReferenceFailure(message),
    ArtifactIncompatibleFailure.wireCode => ArtifactIncompatibleFailure(message),
    WorkerRestartedFailure.wireCode => WorkerRestartedFailure(message),
    CapabilityUnavailableFailure.wireCode => CapabilityUnavailableFailure(operation ?? 'unknown', message),
    ProtocolViolationFailure.wireCode => ProtocolViolationFailure(message),
    RuntimeUnavailableFailure.wireCode => RuntimeUnavailableFailure(message),
    _ => SourceErrorFailure(message),
  };

  final String message;

  /// Stable wire identifier.
  String get code;

  Map<String, Object?> toWire() => <String, Object?>{'code': code, 'message': message};

  @override
  String toString() => '$code: $message';
}

/// The operation exceeded its deadline (measured from dispatch).
final class TimeoutFailure extends SourceFailure {
  const TimeoutFailure(super.message);
  static const String wireCode = 'timeout';
  @override
  String get code => wireCode;
}

/// The caller cancelled, a newer request superseded this one, or its
/// generation was fenced.
final class CancelledFailure extends SourceFailure {
  const CancelledFailure(super.message);
  static const String wireCode = 'cancelled';
  @override
  String get code => wireCode;
}

/// The source's API version or family is not supported by this host.
final class UnsupportedApiFailure extends SourceFailure {
  const UnsupportedApiFailure(super.message);
  static const String wireCode = 'unsupported-api';
  @override
  String get code => wireCode;
}

/// The source needs a visible user interaction (for example a challenge).
final class InteractionRequiredFailure extends SourceFailure {
  const InteractionRequiredFailure(super.message);
  static const String wireCode = 'interaction-required';
  @override
  String get code => wireCode;
}

/// A native reference no longer matches the running source (different
/// artifact, settings revision or source identity), or its state could not
/// be reconstructed. Never answered by guessing a replacement (KTD3).
final class StaleReferenceFailure extends SourceFailure {
  const StaleReferenceFailure(super.message);
  static const String wireCode = 'stale-reference';
  @override
  String get code => wireCode;
}

/// The artifact failed integrity, trust, or host-compatibility checks.
final class ArtifactIncompatibleFailure extends SourceFailure {
  const ArtifactIncompatibleFailure(super.message);
  static const String wireCode = 'artifact-incompatible';
  @override
  String get code => wireCode;
}

/// The worker restarted while the operation was in flight, and its single
/// re-queue was already used (KTD4).
final class WorkerRestartedFailure extends SourceFailure {
  const WorkerRestartedFailure(super.message);
  static const String wireCode = 'worker-restarted';
  @override
  String get code => wireCode;
}

/// The source code itself failed.
final class SourceErrorFailure extends SourceFailure {
  const SourceErrorFailure(super.message);
  static const String wireCode = 'source-error';
  @override
  String get code => wireCode;
}

/// A runtime capability is missing on this platform. Names the operation;
/// never answered with an empty result or a different machine (KTD15).
final class CapabilityUnavailableFailure extends SourceFailure {
  const CapabilityUnavailableFailure(this.operation, String message) : super(message);
  static const String wireCode = 'capability-unavailable';

  /// The operation that could not be performed.
  final String operation;

  @override
  String get code => wireCode;

  @override
  Map<String, Object?> toWire() => <String, Object?>{...super.toWire(), 'operation': operation};

  @override
  String toString() => '$code($operation): $message';
}

/// The worker broke the protocol; its session failed visibly (KTD4).
final class ProtocolViolationFailure extends SourceFailure {
  const ProtocolViolationFailure(super.message);
  static const String wireCode = 'protocol-violation';
  @override
  String get code => wireCode;
}

/// The runtime could not start, or was closed.
final class RuntimeUnavailableFailure extends SourceFailure {
  const RuntimeUnavailableFailure(super.message);
  static const String wireCode = 'runtime-unavailable';
  @override
  String get code => wireCode;
}
