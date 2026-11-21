/// Desktop worker supervision (KTD1, KTD4, KTD9).
///
/// One [WorkerSupervisor] owns one worker process at a time (the shared JVM
/// worker, or the Paperback Dart worker) and speaks protocol v1 to it.
/// [ConversionRuntimeScope] owns at most one supervisor per [WorkerKind] for
/// the lifetime of a conversion.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/src/backends/artifact_cache.dart';
import 'package:source_runtime/src/backends/browser_reverse_bridge.dart';
import 'package:source_runtime/src/backends/protocol.dart';
import 'package:source_runtime/src/backends/redaction.dart';
import 'package:source_runtime/src/backends/worker_process.dart';
import 'package:source_runtime/src/contracts/browser_port.dart';
import 'package:source_runtime/src/contracts/cancellation.dart';
import 'package:source_runtime/src/contracts/identity.dart';
import 'package:source_runtime/src/contracts/outcome.dart';

/// Where a supervisor's runtime limits come from (KTD25).
///
/// - [SupervisorLimits]: the caller supplies every limit; worker-reported
///   limits are recorded in the handshake but not used.
/// - [AdoptWorkerLimits]: the caller opts in to the limits the worker reports
///   in its handshake (derived from its benchmarked sizing rule on this
///   device). Any limit the caller supplies takes precedence. A limit neither
///   side supplies fails the start: nothing is invented.
sealed class SupervisorLimitsPolicy {
  const SupervisorLimitsPolicy();

  /// The KTD4 frame limit; a protocol rule, not a worker-reported value.
  int get maxFrameBytes;
}

/// Runtime limits for a supervised worker (KTD25).
///
/// Every value is required: no default ships without benchmark evidence.
/// Contract tests pass small overrides. [maxFrameBytes] is the KTD4 protocol
/// rule and is overridable only so tests can exercise the limit cheaply.
@immutable
final class SupervisorLimits extends SupervisorLimitsPolicy {
  const SupervisorLimits({
    required this.maxConcurrentPackages,
    required this.operationDeadline,
    required this.cancelGrace,
    required this.interactionTimeout,
    required this.shutdownGrace,
    this.maxFrameBytes = protocolMaxFrameBytes,
  }) : assert(maxConcurrentPackages > 0, 'maxConcurrentPackages must be positive');

  /// Packages that may execute concurrently in the worker's thread pool.
  final int maxConcurrentPackages;

  /// Deadline per operation, measured from dispatch (queue wait excluded).
  final Duration operationDeadline;

  /// Time allowed after a cooperative cancel before the worker is restarted.
  final Duration cancelGrace;

  /// Bound on a visible user browser interaction; that time is excluded from
  /// [operationDeadline].
  final Duration interactionTimeout;

  /// Bound on graceful shutdown before the process is killed.
  final Duration shutdownGrace;

  @override
  final int maxFrameBytes;
}

/// Adopts the limits a worker reports in its handshake (`limits`, KTD25),
/// with every caller-supplied limit taking precedence.
///
/// [handshakeDeadline] bounds the handshake itself, before the worker has
/// reported anything; the caller must choose it. After each handshake
/// (including restarts) the supervisor resolves its [SupervisorLimits] from
/// the caller's values and the worker's `poolSize`, `operationDeadlineMs`,
/// `cancelGraceMs`, `interactionTimeoutMs` and `shutdownGraceMs`. A limit
/// missing from both fails the start with [RuntimeUnavailableFailure].
@immutable
final class AdoptWorkerLimits extends SupervisorLimitsPolicy {
  const AdoptWorkerLimits({
    required this.handshakeDeadline,
    this.maxConcurrentPackages,
    this.operationDeadline,
    this.cancelGrace,
    this.interactionTimeout,
    this.shutdownGrace,
    this.maxFrameBytes = protocolMaxFrameBytes,
  });

  /// Deadline for the handshake reply.
  final Duration handshakeDeadline;
  final int? maxConcurrentPackages;
  final Duration? operationDeadline;
  final Duration? cancelGrace;
  final Duration? interactionTimeout;
  final Duration? shutdownGrace;

  @override
  final int maxFrameBytes;

  /// Names of the limits neither the caller nor [reported] supplies, using
  /// the handshake's wire names.
  List<String> missing(WorkerReportedLimits? reported) => <String>[
    if ((maxConcurrentPackages ?? reported?.poolSize) == null) 'poolSize',
    if ((operationDeadline ?? reported?.operationDeadline) == null) 'operationDeadlineMs',
    if ((cancelGrace ?? reported?.cancelGrace) == null) 'cancelGraceMs',
    if ((interactionTimeout ?? reported?.interactionTimeout) == null) 'interactionTimeoutMs',
    if ((shutdownGrace ?? reported?.shutdownGrace) == null) 'shutdownGraceMs',
  ];

  /// The effective limits: each caller value, else the worker's. Throws
  /// [ArgumentError] when [missing] is not empty.
  SupervisorLimits resolve(WorkerReportedLimits? reported) {
    final List<String> absent = missing(reported);
    if (absent.isNotEmpty) throw ArgumentError('No value for ${absent.join(', ')}');
    return SupervisorLimits(
      maxConcurrentPackages: maxConcurrentPackages ?? reported!.poolSize!,
      operationDeadline: operationDeadline ?? reported!.operationDeadline!,
      cancelGrace: cancelGrace ?? reported!.cancelGrace!,
      interactionTimeout: interactionTimeout ?? reported!.interactionTimeout!,
      shutdownGrace: shutdownGrace ?? reported!.shutdownGrace!,
      maxFrameBytes: maxFrameBytes,
    );
  }
}

/// A package hosted by the worker, retained so a restart can reload it from
/// its verified artifact with its current settings.
final class WorkerPackage {
  WorkerPackage({required this.packageId, required this.artifact, required this.settings});

  final String packageId;

  /// Lease on the verified, privately staged artifact.
  final ArtifactLease artifact;

  /// Settings snapshot; secrets are sent to the worker but never logged.
  final SettingsSnapshot settings;

  /// The same package with [settings] replaced.
  WorkerPackage withSettings(SettingsSnapshot settings) =>
      WorkerPackage(packageId: packageId, artifact: artifact, settings: settings);
}

/// A worker-initiated `host.browser.*` request (KTD4 reverse request).
final class ReverseRequest {
  const ReverseRequest({
    required this.op,
    required this.payload,
    required this.packageId,
    required this.generation,
    required this.cancel,
    this.interactionTimeout,
    this.protocolMinor = 0,
  });

  final String op;
  final Map<String, Object?> payload;

  /// Package whose operation issued the request.
  final String? packageId;
  final int generation;

  /// Cancelled when the originating operation's deadline expires or the
  /// worker generation changes.
  final CancellationToken cancel;

  /// The supervisor's bound on a visible interaction, from its effective
  /// limits; a handler uses it for `host.browser.show`.
  final Duration? interactionTimeout;

  /// The minor protocol version the worker negotiated. A handler refuses
  /// operations introduced in a later minor (for example the 1.2
  /// `host.browser.*` additions from a 1.1 worker). Defaults to 1.0.
  final int protocolMinor;

  /// Whether the request is a visible interaction, whose time is excluded
  /// from the operation deadline.
  bool get isInteraction => op == 'host.browser.show';
}

/// Handles reverse requests, typically by forwarding to a `BrowserPort`.
typedef ReverseRequestHandler = Future<SourceOutcome<Map<String, Object?>>> Function(ReverseRequest request);

/// Supervisor lifecycle states.
enum WorkerState { idle, starting, ready, restarting, failed, closed }

/// Something the conversion report must record.
sealed class SupervisorEvent {
  const SupervisorEvent(this.generation);

  final int generation;
}

/// A worker process completed its handshake.
final class WorkerStartedEvent extends SupervisorEvent {
  const WorkerStartedEvent(super.generation, this.pid);

  final int pid;
}

/// An in-flight operation of another package was re-queued after a restart
/// and reported as `worker-restarted` (KTD4: once only).
final class OperationRequeuedEvent extends SupervisorEvent {
  const OperationRequeuedEvent(super.generation, this.packageId, this.op);

  final String packageId;
  final String op;
}

/// The worker was restarted.
final class WorkerRestartedEvent extends SupervisorEvent {
  const WorkerRestartedEvent(
    super.generation, {
    required this.reason,
    required this.requeued,
    required this.failed,
    required this.reloadFailures,
  });

  final String reason;

  /// Packages whose interrupted operations were re-queued.
  final List<String> requeued;

  /// Packages whose operations failed because they were interrupted twice.
  final List<String> failed;

  /// Packages that could not be reloaded from their verified artifacts.
  final List<String> reloadFailures;
}

/// The session failed visibly (protocol violation or failed restart).
final class WorkerFailedEvent extends SupervisorEvent {
  const WorkerFailedEvent(super.generation, this.failure);

  final SourceFailure failure;
}

class _Call {
  _Call({
    required this.packageId,
    required this.op,
    required this.payload,
    required this.cancel,
    this.deadline,
    this.coalesceKey,
    this.control = false,
  });

  final String? packageId;
  final String op;
  final Map<String, Object?> payload;

  /// `null` means the supervisor's operation deadline, resolved at dispatch.
  final Duration? deadline;
  final CancellationToken cancel;
  final String? coalesceKey;

  /// Handshake, shutdown and restart reloads bypass the package queue.
  final bool control;
  final Completer<SourceOutcome<Map<String, Object?>>> completer = Completer<SourceOutcome<Map<String, Object?>>>();
  final List<CancellationSource> reverseCancels = <CancellationSource>[];

  String? requestId;
  int requeues = 0;

  /// The caller has been answered (cancelled or superseded); the reply is
  /// discarded when it arrives, but the package slot stays held until then.
  bool abandoned = false;
  bool timedOut = false;
  Timer? graceTimer;
  Timer? interactionTimer;
  int interactions = 0;

  Timer? _deadlineTimer;
  Duration _remaining = Duration.zero;
  final Stopwatch _clock = Stopwatch();
  void Function()? _onExpire;

  bool get isAnswered => completer.isCompleted;

  void answer(SourceOutcome<Map<String, Object?>> outcome) {
    if (!completer.isCompleted) completer.complete(outcome);
  }

  void startDeadline(Duration deadline, void Function() onExpire) {
    _onExpire = onExpire;
    _remaining = deadline;
    _resumeDeadline();
  }

  void pauseDeadline() {
    final Timer? timer = _deadlineTimer;
    if (timer == null) return;
    timer.cancel();
    _deadlineTimer = null;
    _remaining -= _clock.elapsed;
    _clock
      ..stop()
      ..reset();
  }

  void resumeDeadline() {
    if (_deadlineTimer != null || _onExpire == null || timedOut) return;
    _resumeDeadline();
  }

  void _resumeDeadline() {
    _clock
      ..reset()
      ..start();
    _deadlineTimer = Timer(_remaining.isNegative ? Duration.zero : _remaining, () {
      _deadlineTimer = null;
      _onExpire?.call();
    });
  }

  void stopTimers() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    graceTimer?.cancel();
    interactionTimer?.cancel();
    for (final CancellationSource c in reverseCancels) {
      c.cancel('operation settled');
    }
    reverseCancels.clear();
  }

  void resetForRequeue() {
    stopTimers();
    requestId = null;
    timedOut = false;
    interactions = 0;
    _onExpire = null;
  }
}

/// Supervises one worker process speaking protocol v1.
///
/// - One call runs at a time per package; different packages run
///   concurrently up to [SupervisorLimits.maxConcurrentPackages].
/// - A deadline (from dispatch) first sends a cooperative `cancel`; if the
///   operation has not settled after [SupervisorLimits.cancelGrace], the
///   worker is killed and restarted. That operation fails with
///   [TimeoutFailure] and is never retried. Other packages' in-flight
///   operations are re-queued once (recorded as [OperationRequeuedEvent]); a
///   second interruption fails them with [WorkerRestartedFailure].
/// - A restart fences the generation, re-verifies and reloads every package
///   before draining the queue.
/// - Protocol violations fail the session visibly: the worker is killed and
///   every pending call fails with [ProtocolViolationFailure].
/// - Worker stderr is redacted line by line before reaching the log sink.
class WorkerSupervisor {
  WorkerSupervisor({
    required this.spec,
    required SupervisorLimitsPolicy limits,
    WorkerLauncher? launcher,
    this.onReverseRequest,
    void Function(String line)? onLog,
    Redactor? redactor,
    this.onGenerationFenced,
  }) : limitsPolicy = limits,
       _limits = limits is SupervisorLimits ? limits : null,
       _launcher = launcher ?? launchWorkerProcess,
       _onLog = onLog ?? _discardLog,
       redactor = redactor ?? Redactor();

  final WorkerSpec spec;

  /// Where the limits come from: fixed by the caller, or adopted from the
  /// worker's handshake with caller precedence.
  final SupervisorLimitsPolicy limitsPolicy;
  SupervisorLimits? _limits;

  /// The effective limits. Fixed limits are available at once; adopted
  /// limits once a handshake has completed (re-resolved on every restart).
  SupervisorLimits? get limits => _limits;
  final WorkerLauncher _launcher;
  final ReverseRequestHandler? onReverseRequest;
  final void Function(String line) _onLog;

  /// Redacts stderr; session secrets are registered on package load.
  final Redactor redactor;

  /// Called whenever a generation ends, with the first generation that is
  /// still valid: after a restart that is the new generation; after a failed
  /// session or [close] it is one past the last, so every generation is
  /// fenced. Browser sessions of fenced generations close in response.
  final FutureOr<void> Function(int generation)? onGenerationFenced;

  static void _discardLog(String _) {}

  WorkerState _state = WorkerState.idle;
  int _generation = 0;
  int _counter = 0;
  WorkerProcess? _process;
  StreamSubscription<ProtocolFrame>? _frames;
  Future<WorkerProcess>? _launching;
  Future<SourceOutcome<HandshakeResponse>>? _startFuture;
  HandshakeResponse? _handshake;
  int _fencedThrough = 0;
  Future<void>? _closeFuture;
  Future<void>? _restartFuture;
  bool _closing = false;
  SourceFailure? _failure;

  final Set<WorkerProcess> _live = <WorkerProcess>{};
  final List<Future<void>> _drains = <Future<void>>[];
  final Map<String, _Call> _inFlight = <String, _Call>{};
  final Set<String> _busy = <String>{};
  final Map<String, Queue<_Call>> _queues = <String, Queue<_Call>>{};
  final List<String> _queueOrder = <String>[];
  int _roundRobin = 0;
  final Map<String, WorkerPackage> _packages = <String, WorkerPackage>{};
  final List<SupervisorEvent> _events = <SupervisorEvent>[];

  WorkerState get state => _state;

  /// Current session generation; increments on every (re)start.
  int get generation => _generation;

  /// PID of the current worker process, if any.
  int? get pid => _process?.pid;

  /// Report events, in order.
  List<SupervisorEvent> get events => List<SupervisorEvent>.unmodifiable(_events);

  /// Packages currently hosted.
  Iterable<String> get packageIds => _packages.keys;

  /// Current settings of a hosted package, or `null` if it is not loaded.
  /// Restarts reload the package with these settings.
  SettingsSnapshot? settingsOf(String packageId) => _packages[packageId]?.settings;

  /// The current worker's handshake reply, once started.
  HandshakeResponse? get handshake => _handshake;

  /// Starts the worker and performs the handshake. Idempotent.
  Future<SourceOutcome<HandshakeResponse>> start() => _startFuture ??= _startInternal();

  Future<SourceOutcome<HandshakeResponse>> _startInternal() async {
    if (_closing) return const SourceFailed<HandshakeResponse>(RuntimeUnavailableFailure('Runtime closed'));
    _state = WorkerState.starting;
    _generation++;
    final SourceOutcome<HandshakeResponse> result = await _spawn();
    if (result is SourceFailed<HandshakeResponse>) {
      await _fail(result.failure);
      return result;
    }
    _state = WorkerState.ready;
    _pump();
    return result;
  }

  /// Loads [package] into the worker, serialised with that package's other
  /// calls. On success the package is reloaded after every restart.
  Future<SourceOutcome<PackageLoadResponse>> loadPackage(WorkerPackage package, {CancellationToken? cancel}) async {
    final SourceOutcome<HandshakeResponse> started = await start();
    if (started case SourceFailed<HandshakeResponse>(:final SourceFailure failure)) {
      return SourceFailed<PackageLoadResponse>(failure);
    }
    final SourceFailure? unsupported = _settingsUnsupported(package.settings);
    if (unsupported != null) return SourceFailed<PackageLoadResponse>(unsupported);
    final PackageLoadRequest request;
    try {
      request = await _loadRequest(package);
    } on ArtifactIntegrityException catch (e) {
      return SourceFailed<PackageLoadResponse>(ArtifactIncompatibleFailure(e.message));
    }
    final SourceOutcome<PackageLoadResponse> outcome = await send(package.packageId, request, cancel: cancel);
    if (outcome is SourceSuccess<PackageLoadResponse>) _packages[package.packageId] = package;
    return outcome;
  }

  /// Unloads a hosted package. On success it is no longer reloaded after a
  /// restart. Calls of the package queued behind the unload still run; the
  /// worker answers them with an error once the package is gone.
  Future<SourceOutcome<EmptyPayload>> unloadPackage(String packageId, {CancellationToken? cancel}) async {
    if (!_packages.containsKey(packageId)) {
      return SourceFailed<EmptyPayload>(StaleReferenceFailure('Package $packageId is not loaded'));
    }
    final SourceOutcome<EmptyPayload> outcome = await send(packageId, const PackageUnloadRequest(), cancel: cancel);
    if (outcome is SourceSuccess<EmptyPayload>) _packages.remove(packageId);
    return outcome;
  }

  /// Replaces a hosted package's settings, serialised with its other calls.
  /// On success later restarts reload the package with [settings]; on
  /// failure the previous settings stay in effect.
  Future<SourceOutcome<EmptyPayload>> updateSettings(
    String packageId,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async {
    if (!_packages.containsKey(packageId)) {
      return SourceFailed<EmptyPayload>(StaleReferenceFailure('Package $packageId is not loaded'));
    }
    final SourceFailure? unsupported = _settingsUnsupported(settings);
    if (unsupported != null) return SourceFailed<EmptyPayload>(unsupported);
    settings.allSecretValues.forEach(redactor.addSecret);
    final SourceOutcome<EmptyPayload> outcome = await send(
      packageId,
      SettingsUpdateRequest(settings: SettingsPayload.fromSnapshot(settings)),
      cancel: cancel,
    );
    final WorkerPackage? current = _packages[packageId];
    if (outcome is SourceSuccess<EmptyPayload> && current != null) {
      _packages[packageId] = current.withSettings(settings);
    }
    return outcome;
  }

  /// Negotiated minor version of the current worker; `0` before a handshake.
  int get protocolMinor => _handshake?.protocolMinor ?? 0;

  /// String sets and source-scoped settings need protocol 1.1: a 1.0 worker
  /// would reject the payload or misread it.
  SourceFailure? _settingsUnsupported(SettingsSnapshot settings) => settings.needsProtocol11 && protocolMinor < 1
      ? UnsupportedApiFailure(
          '${spec.label} worker speaks protocol $protocolVersion.$protocolMinor; '
          'string-set or source-scoped settings need $protocolVersion.1',
        )
      : null;

  /// Prepares [input] for loading (`artifact.prepare`, KTD5) and admits the
  /// result to [cache].
  ///
  /// The worker verifies the artifact's signature against [trust], the
  /// stored trust anchor, and writes the converted or verified bytes to a
  /// private staging path this method chooses. The package need not be
  /// loaded. The output is then re-hashed here: a digest that differs from
  /// the worker's report fails as [ArtifactIncompatibleFailure], and the
  /// bytes are admitted under an [ArtifactProfile] built from the reply's
  /// producer and converter version plus [hostCompatibility]. [verifier]
  /// runs on the admitted bytes like any other cache admission.
  ///
  /// Fails without contacting the worker when [trust] holds no signer, and
  /// before sending when the worker speaks protocol 1.0 (it would ignore
  /// `trustedSigners`).
  Future<SourceOutcome<ArtifactLease>> prepareArtifact({
    required String packageId,
    required ArtifactLease input,
    required ArtifactTrustAnchor trust,
    required ArtifactCache cache,
    required String hostCompatibility,
    ArtifactVerifier? verifier,
    CancellationToken? cancel,
  }) async {
    if (trust.signerFingerprints.isEmpty) {
      return SourceFailed<ArtifactLease>(
        ArtifactIncompatibleFailure('No trusted signer is stored for $packageId; approve its repository first'),
      );
    }
    final SourceOutcome<HandshakeResponse> started = await start();
    if (started case SourceFailed<HandshakeResponse>(:final SourceFailure failure)) {
      return SourceFailed<ArtifactLease>(failure);
    }
    if (protocolMinor < 1) {
      return SourceFailed<ArtifactLease>(
        UnsupportedApiFailure(
          '${spec.label} worker speaks protocol $protocolVersion.$protocolMinor; '
          'artifact.prepare with trustedSigners needs $protocolVersion.1',
        ),
      );
    }
    final String inputPath;
    try {
      inputPath = await input.verifiedPath();
    } on ArtifactIntegrityException catch (e) {
      return SourceFailed<ArtifactLease>(ArtifactIncompatibleFailure(e.message));
    }
    final Directory staging = await cache.createScratchDirectory();
    try {
      final String outputPath = p.join(staging.path, 'prepared.bin');
      final SourceOutcome<ArtifactPrepareResponse> prepared = await send(
        packageId,
        ArtifactPrepareRequest(
          artifact: input.binding,
          inputPath: inputPath,
          outputPath: outputPath,
          trustedSigners: trust.signerFingerprints,
        ),
        cancel: cancel,
      );
      switch (prepared) {
        case SourceFailed<ArtifactPrepareResponse>(:final SourceFailure failure):
          return SourceFailed<ArtifactLease>(failure);
        case SourceSuccess<ArtifactPrepareResponse>(:final ArtifactPrepareResponse value):
          return await _admitPrepared(File(outputPath), value, cache, hostCompatibility, verifier);
      }
    } finally {
      try {
        await staging.delete(recursive: true);
      } on Object catch (e) {
        _log('[${spec.label}] could not delete prepare staging ${staging.path}: $e');
      }
    }
  }

  Future<SourceOutcome<ArtifactLease>> _admitPrepared(
    File output,
    ArtifactPrepareResponse reply,
    ArtifactCache cache,
    String hostCompatibility,
    ArtifactVerifier? verifier,
  ) async {
    if (!output.existsSync()) {
      return SourceFailed<ArtifactLease>(
        ArtifactIncompatibleFailure('${spec.label} worker reported success but wrote no prepared artifact'),
      );
    }
    final Uint8List bytes = await output.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    if (digest != reply.artifact.sha256) {
      return SourceFailed<ArtifactLease>(
        ArtifactIncompatibleFailure(
          'Prepared artifact digest $digest does not match the reported ${reply.artifact.sha256}',
        ),
      );
    }
    try {
      return SourceSuccess<ArtifactLease>(
        await cache.admit(
          bytes,
          binding: ArtifactBinding(sha256: digest, kind: reply.artifact.kind, version: reply.artifact.version),
          profile: ArtifactProfile(
            producer: reply.producer,
            converterVersion: reply.converterVersion,
            hostCompatibility: hostCompatibility,
          ),
          verifier: verifier ?? _acceptVerified,
        ),
      );
    } on ArtifactIntegrityException catch (e) {
      return SourceFailed<ArtifactLease>(ArtifactIncompatibleFailure(e.message));
    }
  }

  /// The worker already verified the signature against the trust anchor.
  static void _acceptVerified(Uint8List bytes, ArtifactBinding binding) {}

  Future<PackageLoadRequest> _loadRequest(WorkerPackage package) async {
    package.settings.allSecretValues.forEach(redactor.addSecret);
    final String path = await package.artifact.verifiedPath();
    return PackageLoadRequest(
      artifact: package.artifact.binding,
      path: path,
      settings: SettingsPayload.fromSnapshot(package.settings),
    );
  }

  /// Sends a typed [request] for [packageId] (see [call]) and decodes its
  /// reply. A reply that does not match the operation's payload type is a
  /// protocol violation: like a malformed frame, it fails the whole session
  /// (KTD4), because the worker's state can no longer be trusted — for
  /// example it may hold a package the supervisor does not track.
  Future<SourceOutcome<R>> send<R extends ProtocolPayload>(
    String packageId,
    WorkerRequest<R> request, {
    CancellationToken? cancel,
    String? coalesceKey,
    Duration? deadline,
  }) async => _decode(
    request.operation.wire,
    await call(
      packageId,
      request.operation.wire,
      request.toJson(),
      cancel: cancel,
      coalesceKey: coalesceKey,
      deadline: deadline,
    ),
    request.decodeResponse,
  );

  SourceOutcome<R> _decode<R>(
    String op,
    SourceOutcome<Map<String, Object?>> outcome,
    R Function(Map<String, Object?> ok) decode,
  ) {
    switch (outcome) {
      case SourceFailed<Map<String, Object?>>(:final SourceFailure failure):
        return SourceFailed<R>(failure);
      case SourceSuccess<Map<String, Object?>>(:final Map<String, Object?> value):
        try {
          return SourceSuccess<R>(decode(value));
        } on Object catch (e) {
          final SourceFailure failure = _redacted(ProtocolViolationFailure('Malformed $op reply: $e'));
          unawaited(_fail(failure));
          return SourceFailed<R>(failure);
        }
    }
  }

  /// Sends [op] for [packageId] and returns its typed outcome.
  ///
  /// [cancel] abandons the call: queued, it is removed; in flight, a
  /// cooperative cancel is sent and the reply discarded. [coalesceKey]
  /// supersedes queued and in-flight calls of the same package with the same
  /// key (newest query wins) without disturbing the worker. [deadline]
  /// overrides [SupervisorLimits.operationDeadline] (qualification only).
  Future<SourceOutcome<Map<String, Object?>>> call(
    String packageId,
    String op,
    Map<String, Object?> payload, {
    CancellationToken? cancel,
    String? coalesceKey,
    Duration? deadline,
  }) {
    final SourceFailure? failure = _unavailable();
    if (failure != null) return Future<SourceOutcome<Map<String, Object?>>>.value(SourceFailed(failure));
    final c = _Call(
      packageId: packageId,
      op: op,
      payload: payload,
      deadline: deadline,
      cancel: cancel ?? CancellationToken.none,
      coalesceKey: coalesceKey,
    );
    if (coalesceKey != null) _supersede(packageId, coalesceKey);
    final Queue<_Call> queue = _queues.putIfAbsent(packageId, () {
      _queueOrder.add(packageId);
      return Queue<_Call>();
    });
    queue.add(c);
    if (c.cancel.isCancelled) {
      _onCancel(c);
    } else {
      unawaited(c.cancel.whenCancelled.then((_) => _onCancel(c)));
    }
    if (_state == WorkerState.idle) unawaited(start());
    _pump();
    return c.completer.future;
  }

  /// Sends a supervisor-to-worker event (for example `host.browser.message`)
  /// in [generation]. Dropped if that generation has been fenced.
  void sendEvent(String op, Map<String, Object?> payload, {required int generation}) {
    if (generation != _generation || _state != WorkerState.ready) return;
    _send(
      ProtocolFrame(
        type: FrameType.event,
        id: 'e$generation-${++_counter}',
        generation: generation,
        op: op,
        payload: payload,
      ),
    );
  }

  SourceFailure? _unavailable() {
    if (_closing || _state == WorkerState.closed) return const RuntimeUnavailableFailure('Runtime closed');
    if (_state == WorkerState.failed) return _failure ?? const RuntimeUnavailableFailure('Runtime failed');
    return null;
  }

  void _supersede(String packageId, String key) {
    final Queue<_Call>? queue = _queues[packageId];
    if (queue != null) {
      queue.removeWhere((_Call c) {
        if (c.coalesceKey != key) return false;
        c.answer(const SourceFailed<Map<String, Object?>>(CancelledFailure('Superseded by a newer request')));
        return true;
      });
    }
    for (final _Call c in _inFlight.values) {
      if (c.packageId == packageId && c.coalesceKey == key && !c.abandoned) {
        c
          ..abandoned = true
          ..answer(const SourceFailed<Map<String, Object?>>(CancelledFailure('Superseded by a newer request')));
      }
    }
  }

  void _onCancel(_Call c) {
    if (c.isAnswered) return;
    final String reason = c.cancel.reason ?? 'cancelled';
    if (c.requestId == null) {
      _queues[c.packageId]?.remove(c);
      c.answer(SourceFailed<Map<String, Object?>>(CancelledFailure(reason)));
      return;
    }
    c
      ..abandoned = true
      ..answer(SourceFailed<Map<String, Object?>>(CancelledFailure(reason)));
    _sendCancel(c);
  }

  void _pump() {
    if (_state != WorkerState.ready) return;
    while (_busy.length < _limits!.maxConcurrentPackages) {
      final _Call? next = _nextQueued();
      if (next == null) return;
      _dispatch(next);
    }
  }

  _Call? _nextQueued() {
    for (var i = 0; i < _queueOrder.length; i++) {
      final String pkg = _queueOrder[(_roundRobin + i) % _queueOrder.length];
      final Queue<_Call>? queue = _queues[pkg];
      if (queue == null || queue.isEmpty || _busy.contains(pkg)) continue;
      _roundRobin = (_roundRobin + i + 1) % _queueOrder.length;
      return queue.removeFirst();
    }
    return null;
  }

  void _dispatch(_Call c) {
    final id = '$_generation-${++_counter}';
    c.requestId = id;
    _inFlight[id] = c;
    if (!c.control && c.packageId != null) _busy.add(c.packageId!);
    final frame = ProtocolFrame(
      type: FrameType.request,
      id: id,
      generation: _generation,
      op: c.op,
      packageId: c.packageId,
      payload: c.payload,
    );
    try {
      _send(frame);
    } on ProtocolException catch (e) {
      _inFlight.remove(id);
      _busy.remove(c.packageId);
      c.answer(SourceFailed<Map<String, Object?>>(ProtocolViolationFailure('Request not sent: ${e.message}')));
      scheduleMicrotask(_pump);
      return;
    }
    c.startDeadline(c.deadline ?? _limits!.operationDeadline, () => _onDeadline(c));
  }

  void _send(ProtocolFrame frame) {
    final WorkerProcess? process = _process;
    if (process == null) return;
    final Uint8List bytes = encodeFrame(frame, maxFrameBytes: limitsPolicy.maxFrameBytes);
    try {
      process.stdin.add(bytes);
    } on Object catch (e) {
      // The worker is gone; its exit restarts it and re-queues this call.
      _log('[${spec.label}] write to worker failed: $e');
    }
  }

  void _sendCancel(_Call c) {
    final String? id = c.requestId;
    if (id == null) return;
    try {
      _send(ProtocolFrame(type: FrameType.cancel, id: id, generation: _generation));
    } on Object {
      // Best effort; the deadline still escalates.
    }
  }

  void _onDeadline(_Call c) {
    if (c.requestId == null || !_inFlight.containsKey(c.requestId)) return;
    if (c.control) {
      _inFlight.remove(c.requestId);
      c.answer(SourceFailed<Map<String, Object?>>(TimeoutFailure('${c.op} exceeded its deadline')));
      return;
    }
    c.timedOut = true;
    for (final CancellationSource r in c.reverseCancels) {
      r.cancel('operation deadline exceeded');
    }
    _sendCancel(c);
    c.graceTimer = Timer(_limits!.cancelGrace, () {
      if (_inFlight.containsKey(c.requestId)) {
        _scheduleRestart('${c.op} for ${c.packageId} did not settle after cooperative cancel', timedOut: c);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Process lifecycle
  // ---------------------------------------------------------------------------

  Future<SourceOutcome<HandshakeResponse>> _spawn() async {
    final WorkerProcess process;
    try {
      final Future<WorkerProcess> launching = _launching = _launcher(spec);
      process = await launching;
    } on Object catch (e) {
      return SourceFailed<HandshakeResponse>(RuntimeUnavailableFailure('Could not start ${spec.label} worker: $e'));
    } finally {
      _launching = null;
    }
    _live.add(process);
    unawaited(process.exitCode.then((int code) => _onExit(process, code)));
    if (_closing) {
      // The launch completed after cancellation: never leak it.
      await _kill(process);
      return const SourceFailed<HandshakeResponse>(RuntimeUnavailableFailure('Runtime closed during startup'));
    }
    _attach(process);
    final request = HandshakeRequest(
      protocolVersions: const <int>[protocolVersion],
      protocolMinor: protocolMinorVersion,
      maxFrameBytes: limitsPolicy.maxFrameBytes,
    );
    final c = _Call(
      packageId: null,
      op: request.operation.wire,
      payload: request.toJson(),
      deadline: switch (limitsPolicy) {
        final SupervisorLimits l => l.operationDeadline,
        final AdoptWorkerLimits a => a.handshakeDeadline,
      },
      cancel: CancellationToken.none,
      control: true,
    );
    _dispatch(c);
    final SourceOutcome<HandshakeResponse> outcome = _decode(
      request.operation.wire,
      await c.completer.future,
      request.decodeResponse,
    );
    if (outcome case SourceSuccess<HandshakeResponse>(:final HandshakeResponse value)) {
      if (value.protocolVersion != protocolVersion) {
        return SourceFailed<HandshakeResponse>(
          ProtocolViolationFailure('Worker negotiated protocol version ${value.protocolVersion}'),
        );
      }
      if (value.protocolMinor > protocolMinorVersion) {
        return SourceFailed<HandshakeResponse>(
          ProtocolViolationFailure(
            'Worker negotiated protocol $protocolVersion.${value.protocolMinor}; '
            'the supervisor offered at most $protocolVersion.$protocolMinorVersion',
          ),
        );
      }
      if (limitsPolicy case final AdoptWorkerLimits adopt) {
        final List<String> missing = adopt.missing(value.limits);
        if (missing.isNotEmpty) {
          return SourceFailed<HandshakeResponse>(
            RuntimeUnavailableFailure(
              '${spec.label} worker reported no ${missing.join(', ')} and the caller supplied none (KTD25)',
            ),
          );
        }
        _limits = adopt.resolve(value.limits);
      }
      _handshake = value;
      _events.add(WorkerStartedEvent(_generation, process.pid));
    }
    return outcome;
  }

  void _attach(WorkerProcess process) {
    _process = process;
    _frames = process.stdout
        .transform(FrameDecoder(maxFrameBytes: limitsPolicy.maxFrameBytes))
        .listen(
          (ProtocolFrame frame) => _onFrame(process, frame),
          onError: (Object error) {
            if (!identical(_process, process)) return;
            final message = error is ProtocolException ? error.toString() : 'stdout error: $error';
            unawaited(_fail(ProtocolViolationFailure(message)));
          },
        );
    final sink = RedactingLineSink(redactor, (String line) => _onLog('[${spec.label}] $line'));
    _drains.add(sink.addStream(process.stderr).catchError((Object _) {}));
    // Writes to a worker that has died fail on `done`; the exit drives the
    // restart, so only record it.
    unawaited(
      process.stdin.done.then<void>(
        (_) {},
        onError: (Object e) {
          if (identical(_process, process)) _log('[${spec.label}] worker stdin closed: $e');
        },
      ),
    );
  }

  /// Logs a supervisor-written line. Everything reaching the log sink passes
  /// through the redactor (KTD9), including text echoed from the worker.
  void _log(String line) => _onLog(redactor.redact(line));

  /// [failure] with its worker-derived message redacted.
  SourceFailure _redacted(SourceFailure failure) => SourceFailure.fromWire(
    failure.code,
    redactor.redact(failure.message),
    operation: failure is CapabilityUnavailableFailure ? failure.operation : null,
  );

  void _onFrame(WorkerProcess process, ProtocolFrame frame) {
    if (!identical(_process, process)) return;
    if (frame.generation != _generation) {
      unawaited(
        _fail(ProtocolViolationFailure('Frame for generation ${frame.generation}, expected $_generation')),
      );
      return;
    }
    switch (frame.type) {
      case FrameType.response:
        final _Call? c = _inFlight.remove(frame.id);
        if (c == null) {
          unawaited(_fail(ProtocolViolationFailure('Reply for unknown request ${frame.id}')));
          return;
        }
        _settle(c, frame);
      case FrameType.reverseRequest:
        final _Call? origin = _inFlight[frame.originId];
        if (origin == null || frame.op == null || !frame.op!.startsWith('host.')) {
          unawaited(
            _fail(ProtocolViolationFailure('Orphaned reverse request ${frame.id} (originating ${frame.originId})')),
          );
          return;
        }
        unawaited(_handleReverse(frame, origin));
      case FrameType.request || FrameType.cancel || FrameType.reverseResponse || FrameType.event:
        unawaited(_fail(ProtocolViolationFailure('Unexpected ${frame.type.wire} frame from worker')));
    }
  }

  void _settle(_Call c, ProtocolFrame frame) {
    c.stopTimers();
    if (!c.control) _busy.remove(c.packageId);
    final Map<String, Object?>? error = frame.error;
    final SourceOutcome<Map<String, Object?>> outcome = error == null
        ? SourceSuccess<Map<String, Object?>>(frame.ok ?? const <String, Object?>{})
        : SourceFailed<Map<String, Object?>>(
            _redacted(
              SourceFailure.fromWire(
                error['code'] as String? ?? '',
                error['message'] as String? ?? '',
                operation: error['operation'] as String?,
              ),
            ),
          );
    if (c.timedOut) {
      c.answer(SourceFailed<Map<String, Object?>>(TimeoutFailure('${c.op} exceeded its deadline')));
    } else {
      c.answer(outcome);
    }
    _pump();
  }

  Future<void> _handleReverse(ProtocolFrame frame, _Call origin) async {
    final int generation = _generation;
    final WorkerProcess? process = _process;
    final ReverseRequestHandler? handler = onReverseRequest;
    final cancel = CancellationSource();
    origin.reverseCancels.add(cancel);
    final request = ReverseRequest(
      op: frame.op!,
      payload: frame.payload ?? const <String, Object?>{},
      packageId: origin.packageId,
      generation: generation,
      cancel: cancel.token,
      interactionTimeout: _limits?.interactionTimeout,
      protocolMinor: protocolMinor,
    );
    if (request.isInteraction) {
      origin
        ..interactions += 1
        ..pauseDeadline();
      origin.interactionTimer ??= Timer(_limits!.interactionTimeout, () => _onDeadline(origin));
    }
    SourceOutcome<Map<String, Object?>> outcome;
    try {
      outcome = handler == null
          ? SourceFailed<Map<String, Object?>>(CapabilityUnavailableFailure(request.op, 'No browser port configured'))
          : await handler(request);
    } on Object catch (e) {
      outcome = SourceFailed<Map<String, Object?>>(SourceErrorFailure('Reverse request failed: $e'));
    }
    origin.reverseCancels.remove(cancel);
    if (request.isInteraction) {
      origin.interactions -= 1;
      if (origin.interactions == 0) {
        origin.interactionTimer?.cancel();
        origin.interactionTimer = null;
        origin.resumeDeadline();
      }
    }
    // A late reply after a generation change is discarded, never delivered
    // to a newer request.
    if (generation != _generation || !identical(process, _process) || _state != WorkerState.ready) return;
    try {
      _send(
        ProtocolFrame(
          type: FrameType.reverseResponse,
          id: frame.id,
          generation: generation,
          ok: outcome.valueOrNull,
          error: outcome.failureOrNull?.toWire(),
        ),
      );
    } on ProtocolException catch (e) {
      _send(
        ProtocolFrame(
          type: FrameType.reverseResponse,
          id: frame.id,
          generation: generation,
          error: ProtocolViolationFailure(e.message).toWire(),
        ),
      );
    }
  }

  void _onExit(WorkerProcess process, int code) {
    _live.remove(process);
    if (!identical(process, _process) || _closing) return;
    switch (_state) {
      case WorkerState.ready:
        _scheduleRestart('${spec.label} worker exited unexpectedly with code $code');
      case WorkerState.starting || WorkerState.restarting:
        _detach();
        _failInFlight(RuntimeUnavailableFailure('${spec.label} worker exited with code $code during startup'));
      case WorkerState.idle || WorkerState.failed || WorkerState.closed:
        break;
    }
  }

  void _detach() {
    unawaited(_frames?.cancel());
    _frames = null;
    _process = null;
  }

  void _failInFlight(SourceFailure failure) {
    final List<_Call> calls = _inFlight.values.toList();
    _inFlight.clear();
    _busy.clear();
    for (final c in calls) {
      c
        ..stopTimers()
        ..answer(SourceFailed<Map<String, Object?>>(failure));
    }
  }

  Future<void> _kill(WorkerProcess process) async {
    process.kill();
    await process.exitCode;
  }

  void _scheduleRestart(String reason, {_Call? timedOut}) {
    final Future<void> restart = _restart(reason, timedOut: timedOut);
    _restartFuture = restart;
    unawaited(restart);
  }

  Future<void> _restart(String reason, {_Call? timedOut}) async {
    if (_closing || _state != WorkerState.ready) {
      if (timedOut != null && _state == WorkerState.restarting) {
        timedOut.answer(SourceFailed<Map<String, Object?>>(TimeoutFailure('${timedOut.op} exceeded its deadline')));
      }
      return;
    }
    _state = WorkerState.restarting;
    final WorkerProcess? old = _process;
    _detach();
    final List<_Call> interrupted = _inFlight.values.toList();
    _inFlight.clear();
    _busy.clear();
    _generation++;
    if (old != null) await _kill(old);
    if (!_closing) await _fence(_generation);
    if (_closing) {
      // close() began while the old worker was stopping: answer everything
      // that was in flight and never start a new worker.
      for (final c in interrupted) {
        c
          ..stopTimers()
          ..answer(
            identical(c, timedOut)
                ? SourceFailed<Map<String, Object?>>(TimeoutFailure('${c.op} exceeded its deadline'))
                : const SourceFailed<Map<String, Object?>>(CancelledFailure('Runtime closed')),
          );
      }
      return;
    }

    final requeued = <String>[];
    final failed = <String>[];
    for (final _Call c in interrupted.reversed) {
      c.stopTimers();
      if (identical(c, timedOut)) {
        c.answer(SourceFailed<Map<String, Object?>>(TimeoutFailure('${c.op} exceeded its deadline; worker restarted')));
      } else if (c.abandoned || c.isAnswered) {
        continue;
      } else if (c.control) {
        c.answer(const SourceFailed<Map<String, Object?>>(WorkerRestartedFailure('Worker restarted')));
      } else if (c.requeues == 0) {
        c
          ..requeues = 1
          ..resetForRequeue();
        _queues[c.packageId]!.addFirst(c);
        requeued.add(c.packageId!);
        _events.add(OperationRequeuedEvent(_generation, c.packageId!, c.op));
      } else {
        c.answer(
          SourceFailed<Map<String, Object?>>(
            WorkerRestartedFailure('${c.op} for ${c.packageId} was interrupted by a second worker restart'),
          ),
        );
        failed.add(c.packageId!);
      }
    }

    final SourceOutcome<HandshakeResponse> started = await _spawn();
    if (_closing) return;
    if (started is SourceFailed<HandshakeResponse>) {
      await _fail(started.failure);
      return;
    }
    final reloadFailures = <String>[];
    for (final WorkerPackage package in _packages.values.toList()) {
      final SourceOutcome<PackageLoadResponse> loaded = await _reload(package);
      if (loaded is SourceFailed<PackageLoadResponse>) {
        reloadFailures.add(package.packageId);
        _packages.remove(package.packageId);
        final Queue<_Call>? queue = _queues[package.packageId];
        while (queue != null && queue.isNotEmpty) {
          queue.removeFirst().answer(SourceFailed<Map<String, Object?>>(loaded.failure));
        }
      }
      if (_closing || _state != WorkerState.restarting) return;
    }
    _events.add(
      WorkerRestartedEvent(
        _generation,
        reason: reason,
        requeued: requeued,
        failed: failed,
        reloadFailures: reloadFailures,
      ),
    );
    _log('[${spec.label}] worker restarted (generation $_generation): $reason');
    _state = WorkerState.ready;
    _pump();
  }

  /// Reloads [package] from its verified artifact with its current settings.
  Future<SourceOutcome<PackageLoadResponse>> _reload(WorkerPackage package) async {
    final PackageLoadRequest request;
    try {
      request = await _loadRequest(package);
    } on ArtifactIntegrityException catch (e) {
      return SourceFailed<PackageLoadResponse>(ArtifactIncompatibleFailure(e.message));
    }
    final c = _Call(
      packageId: package.packageId,
      op: request.operation.wire,
      payload: request.toJson(),
      cancel: CancellationToken.none,
      control: true,
    );
    _dispatch(c);
    return _decode(request.operation.wire, await c.completer.future, request.decodeResponse);
  }

  /// Fences every generation below [validFrom] once, notifying
  /// [onGenerationFenced]. A failing callback is logged, never fatal.
  Future<void> _fence(int validFrom) async {
    if (validFrom <= _fencedThrough) return;
    _fencedThrough = validFrom;
    try {
      await onGenerationFenced?.call(validFrom);
    } on Object catch (e) {
      _log('[${spec.label}] fencing generations below $validFrom failed: $e');
    }
  }

  Future<void> _fail(SourceFailure unredacted) async {
    if (_state == WorkerState.failed || _state == WorkerState.closed) return;
    final SourceFailure failure = _redacted(unredacted);
    _state = WorkerState.failed;
    _failure = failure;
    _events.add(WorkerFailedEvent(_generation, failure));
    if (!_closing) _log('[${spec.label}] worker session failed: $failure');
    final WorkerProcess? process = _process;
    _detach();
    _failInFlight(failure);
    for (final Queue<_Call> queue in _queues.values) {
      while (queue.isNotEmpty) {
        queue.removeFirst().answer(SourceFailed<Map<String, Object?>>(failure));
      }
    }
    _packages.clear();
    if (process != null) await _kill(process);
    await _fence(_generation + 1);
  }

  /// Shuts the worker down: graceful `shutdown` bounded by
  /// [SupervisorLimits.shutdownGrace], then kill. Pending calls fail with
  /// [CancelledFailure]. Completes only after every process this supervisor
  /// started has exited and its stderr is drained. Idempotent.
  Future<void> close() => _closeFuture ??= _closeInternal();

  Future<void> _closeInternal() async {
    _closing = true;
    const closed = SourceFailed<Map<String, Object?>>(CancelledFailure('Runtime closed'));
    for (final Queue<_Call> queue in _queues.values) {
      while (queue.isNotEmpty) {
        queue.removeFirst().answer(closed);
      }
    }
    final WorkerProcess? process = _process;
    if (process != null && _state == WorkerState.ready) {
      const request = ShutdownRequest();
      final c = _Call(
        packageId: null,
        op: request.operation.wire,
        payload: request.toJson(),
        deadline: _limits!.shutdownGrace,
        cancel: CancellationToken.none,
        control: true,
      );
      _dispatch(c);
      await Future.any(<Future<void>>[c.completer.future, process.exitCode]);
      await process.exitCode.timeout(_limits!.shutdownGrace, onTimeout: () => -1);
    }
    _detach();
    for (final _Call c in _inFlight.values) {
      c
        ..stopTimers()
        ..answer(closed);
    }
    _inFlight.clear();
    _busy.clear();
    final Future<WorkerProcess>? launching = _launching;
    if (launching != null) {
      try {
        await launching;
      } on Object {
        // A failed launch has nothing to clean up.
      }
      // _spawn kills a process whose launch completed after close began.
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait(<Future<void>>[for (final WorkerProcess p in _live.toList()) _kill(p)]);
    // A restart in progress notices _closing, answers its calls, and starts
    // nothing; wait for it, then for anything it launched meanwhile.
    final Future<void>? restart = _restartFuture;
    if (restart != null) await restart;
    await Future.wait(<Future<void>>[for (final WorkerProcess p in _live.toList()) _kill(p)]);
    await Future.wait(_drains);
    // Every generation is over: late reverse replies are discarded and the
    // owner closes their browser sessions.
    await _fence(_generation + 1);
    _state = WorkerState.closed;
  }
}

/// Worker processes a desktop conversion may own.
enum WorkerKind { jvm, paperback }

/// Conversion-scoped owner of the desktop workers (KTD4 ownership): created
/// before loading, registers each worker as soon as it is requested, and is
/// closed in a `finally` covering loading through publication.
///
/// Holds at most one supervisor per [WorkerKind]: one shared JVM worker for
/// every Tachi package and one Paperback Dart worker.
///
/// With a [browserPort], each worker gets its own [BrowserReverseBridge]
/// serving its `host.browser.*` reverse requests. Generations are counted
/// per worker, so each bridge is fenced only by its own worker: a JVM restart
/// closes the JVM worker's browser sessions and leaves Paperback's open.
/// Closing the scope closes every bridge, so no browser session outlives it.
class ConversionRuntimeScope {
  ConversionRuntimeScope({
    required this.workers,
    required this.limits,
    this.launcher,
    this.browserPort,
    this.resolveBrowserSource,
    this.onLog,
    Redactor? redactor,
    this.onGenerationFenced,
  }) : redactor = redactor ?? Redactor();

  /// Worker specs by kind; a kind without a spec is unavailable.
  final Map<WorkerKind, WorkerSpec> workers;

  /// Limits for every worker: fixed, or adopted from each worker's handshake.
  final SupervisorLimitsPolicy limits;
  final WorkerLauncher? launcher;

  /// Browser access for workers; `null` answers every `host.browser.*`
  /// request with [CapabilityUnavailableFailure].
  final BrowserPort? browserPort;

  /// Resolves the identity a worker package may open a browser session for;
  /// `null` (or a `null` result) refuses the request.
  final SourceIdentity? Function(WorkerKind kind, String? packageId, String sourceId)? resolveBrowserSource;
  final void Function(String line)? onLog;
  final Redactor redactor;
  final FutureOr<void> Function(WorkerKind kind, int generation)? onGenerationFenced;

  final Map<WorkerKind, WorkerSupervisor> _supervisors = <WorkerKind, WorkerSupervisor>{};
  final Map<WorkerKind, BrowserReverseBridge> _bridges = <WorkerKind, BrowserReverseBridge>{};
  Future<void>? _closeFuture;

  /// Browser bridges created so far, one per started worker kind.
  Map<WorkerKind, BrowserReverseBridge> get bridges => Map<WorkerKind, BrowserReverseBridge>.unmodifiable(_bridges);

  /// Runs [body] with a new scope and always awaits [close] afterwards, so a
  /// failure is returned only after every worker has exited.
  static Future<T> run<T>(ConversionRuntimeScope scope, Future<T> Function(ConversionRuntimeScope scope) body) async {
    try {
      return await body(scope);
    } finally {
      await scope.close();
    }
  }

  /// Supervisors created so far.
  Map<WorkerKind, WorkerSupervisor> get supervisors => Map<WorkerKind, WorkerSupervisor>.unmodifiable(_supervisors);

  /// Returns the started supervisor for [kind], creating it on first use.
  Future<SourceOutcome<WorkerSupervisor>> worker(WorkerKind kind) async {
    if (_closeFuture != null) {
      return const SourceFailed<WorkerSupervisor>(RuntimeUnavailableFailure('Conversion runtime scope closed'));
    }
    final WorkerSpec? spec = workers[kind];
    if (spec == null) {
      return SourceFailed<WorkerSupervisor>(
        CapabilityUnavailableFailure('worker.${kind.name}', 'No ${kind.name} worker is configured on this host'),
      );
    }
    final WorkerSupervisor supervisor = _supervisors.putIfAbsent(kind, () => _create(kind, spec));
    final SourceOutcome<HandshakeResponse> started = await supervisor.start();
    return started.map((_) => supervisor);
  }

  WorkerSupervisor _create(WorkerKind kind, WorkerSpec spec) {
    final BrowserPort? port = browserPort;
    final BrowserReverseBridge? bridge = port == null
        ? null
        : _bridges[kind] = BrowserReverseBridge(
            port: port,
            interactionTimeout: switch (limits) {
              final SupervisorLimits l => l.interactionTimeout,
              AdoptWorkerLimits(:final Duration? interactionTimeout) => interactionTimeout,
            },
            resolveSource: (String? packageId, String sourceId) =>
                resolveBrowserSource?.call(kind, packageId, sourceId),
            onLog: (String line) => onLog?.call(redactor.redact('[${spec.label}] $line')),
          );
    final supervisor = WorkerSupervisor(
      spec: spec,
      limits: limits,
      launcher: launcher,
      onReverseRequest: bridge?.handle,
      onLog: onLog,
      redactor: redactor,
      onGenerationFenced: (int generation) async {
        await bridge?.fence(generation);
        await onGenerationFenced?.call(kind, generation);
      },
    );
    bridge?.emitEvent = supervisor.sendEvent;
    return supervisor;
  }

  /// Closes every worker concurrently, then every browser bridge, and waits
  /// for all of them. Idempotent.
  Future<void> close() => _closeFuture ??= () async {
    await Future.wait(<Future<void>>[for (final WorkerSupervisor s in _supervisors.values) s.close()]);
    await Future.wait(<Future<void>>[for (final BrowserReverseBridge b in _bridges.values) b.close()]);
  }();
}
