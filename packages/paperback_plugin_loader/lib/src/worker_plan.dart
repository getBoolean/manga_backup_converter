import 'dart:io';
import 'dart:math' as math;

import 'package:paperback_plugin_loader/src/runtime/limit_sizing.dart';

/// The real-bundle workload profile (KTD25, U6): measured by
/// `benchmark/bundle_benchmark.dart` over the pinned Paperback 0.8/0.9
/// bundles replaying the committed captures, as an AOT executable on the
/// reference device (`benchmark/results/2026-11-21-windows-x64-bundles-aot.json`).
/// Replaces U5's synthetic profile.
const QuickJsWorkloadProfile paperbackBundleProfile = QuickJsWorkloadProfile(
  source: _profileSource,
  peakHeapBytes: _peakHeapBytes,
  peakStackBytes: _peakStackBytes,
  slowestOperation: Duration(microseconds: _slowestOperationMicros),
  referenceCalibration: Duration(microseconds: _referenceCalibrationMicros),
);

/// The longest an operation kept running after its engine deadline fired on
/// the reference device, over every real workload (interrupt polling inside
/// JS, the Dart deadline timer during host waits, then reply conversion),
/// plus encoding the largest reply frame. Scaled to the device like the
/// operation time.
const Duration referenceDeadlineTail = Duration(microseconds: _deadlineTailMicros);

/// The sizing policy re-derived from the real-bundle results (see
/// `benchmark/README.md`, "quickjs-sizing-v2").
const QuickJsSizingPolicy paperbackSizingPolicy = QuickJsSizingPolicy(
  heapHeadroom: 2,
  stackHeadroom: 2,
  deadlineHeadroom: 4,
  maxMemoryShare: 0.25,
  maxThreadStackShare: 0.5,
  slicesPerDeadline: 50,
);

/// Multiplier on the device-scaled [referenceDeadlineTail] for the
/// supervisor-side headroom; the same margin the policy gives operation
/// time (p95 variance and loaded machines).
const double deadlineTailHeadroom = 4;

/// Host waits an operation may spend outside QuickJS: the most requests one
/// qualification operation made in the captures (MangaDex 0.9 details: 4
/// requests, plus redirects; WeebCentral details: 2), rounded up to 6, each
/// bounded by the host's per-request timeout (`PaperbackHttp`, 30 s), plus
/// one bundle rate-limiter sleep (about 1 s) per request. Not a QuickJS
/// property; the supervisor's policy (KTD4).
const Duration paperbackHostWaitAllowance = Duration(seconds: 6 * 30 + 6);

// Values from benchmark/results/2026-11-21-windows-x64-bundles-aot.json.
const String _profileSource = 'U6 real Paperback bundles (14 workloads, replayed captures), windows AOT';
const int _peakHeapBytes = 9710473;
const int _peakStackBytes = 216968;
const int _slowestOperationMicros = 2389048;
const int _referenceCalibrationMicros = 122176;
// Largest single-operation deadline overshoot (64,150 us, WeebCentral 0.8
// details) plus the largest reply frame encode (2,478 us).
const int _deadlineTailMicros = 66628;

/// What the supervisor launches the worker with, and why.
final class PaperbackWorkerPlan {
  const PaperbackWorkerPlan({
    required this.sizing,
    required this.deadlineHeadroom,
    required this.cancelGrace,
    required this.handshakeDeadline,
  });

  /// The KTD25 sizing (rule, inputs, derived limits) for the handshake and
  /// receipts.
  final QuickJsSizing sizing;

  /// Supervisor-side headroom over the engine deadline (reported in the
  /// handshake's `operationDeadlineMs`).
  final Duration deadlineHeadroom;

  /// Time to let a cancelled operation settle. The worker reads a `cancel`
  /// frame only between job slices, so this is one job slice plus the
  /// measured deadline tail.
  final Duration cancelGrace;

  /// Bound on worker start-up to handshake (process start, isolate and
  /// QuickJS library load).
  final Duration handshakeDeadline;

  /// The worker's limit arguments (`runPaperbackWorker`).
  List<String> get arguments => <String>[
    '--memory-limit-bytes=${sizing.limits.memoryLimitBytes}',
    '--max-stack-bytes=${sizing.limits.maxStackBytes}',
    '--operation-deadline-ms=${(sizing.limits.operationDeadline.inMicroseconds + 999) ~/ 1000}',
    '--job-slice-ms=${math.max(1, (sizing.limits.jobSlice.inMicroseconds + 999) ~/ 1000)}',
    '--deadline-headroom-ms=${(deadlineHeadroom.inMicroseconds + 999) ~/ 1000}',
  ];
}

/// Applies the sizing rule to this device (KTD25): measures it (or takes
/// [device]), derives the QuickJS limits from [paperbackBundleProfile], and
/// the supervisor-side deadline headroom from [referenceDeadlineTail]
/// scaled by the device's calibration.
PaperbackWorkerPlan planPaperbackWorker({
  DeviceCapability? device,
  int concurrentRuntimes = 1,
  Duration hostWaitAllowance = paperbackHostWaitAllowance,
}) {
  final DeviceCapability d =
      device ?? DeviceCapability.measure(processors: Platform.numberOfProcessors, calibrationRuns: 15);
  final QuickJsSizing sizing = deriveQuickJsLimits(
    device: d,
    profile: paperbackBundleProfile,
    policy: paperbackSizingPolicy,
    concurrentRuntimes: concurrentRuntimes,
    hostWaitAllowance: hostWaitAllowance,
  );
  final double speed = d.calibration.inMicroseconds / paperbackBundleProfile.referenceCalibration.inMicroseconds;
  final headroom = Duration(
    microseconds: (referenceDeadlineTail.inMicroseconds * math.max(1, speed) * deadlineTailHeadroom).ceil(),
  );
  return PaperbackWorkerPlan(
    sizing: sizing,
    deadlineHeadroom: headroom,
    cancelGrace: sizing.limits.jobSlice + headroom,
    handshakeDeadline: const Duration(seconds: 30),
  );
}
