/// The QuickJS limit sizing rule (KTD25). **Provisional:** the workload
/// profile comes from synthetic benchmarks (`benchmark/`) until U6 measures
/// real Paperback bundles; the policy factors are the rule's tunables and are
/// re-derived from those results.
///
/// Inputs are all measurable at worker startup ([DeviceCapability.measure]),
/// so each device sizes its own limits. The rule, its inputs and the derived
/// values are reported together ([QuickJsSizing.toJson]) for the handshake
/// and qualification receipts.
library;

import 'dart:math' as math;

import 'package:paperback_plugin_loader/src/runtime/runtime_limits.dart';
import 'package:quickjs/quickjs.dart';

/// Capability of the device the worker runs on, measured at startup.
final class DeviceCapability {
  const DeviceCapability({
    required this.physicalMemoryBytes,
    required this.threadStackBytes,
    required this.processors,
    required this.calibration,
  });

  /// Measures this device. [calibrationRuns] repetitions of the fixed
  /// calibration workload are timed and the median kept.
  factory DeviceCapability.measure({required int processors, required int calibrationRuns}) {
    return DeviceCapability(
      physicalMemoryBytes: QuickJs.physicalMemory(),
      threadStackBytes: QuickJs.threadStackAvailable(),
      processors: processors,
      calibration: measureCalibration(runs: calibrationRuns),
    );
  }

  factory DeviceCapability.fromJson(Map<String, Object?> json) => DeviceCapability(
    physicalMemoryBytes: json['physicalMemoryBytes'] as int?,
    threadStackBytes: json['threadStackBytes'] as int?,
    processors: json['processors']! as int,
    calibration: Duration(microseconds: json['calibrationMicros']! as int),
  );

  final int? physicalMemoryBytes;

  /// Native stack left on the worker's isolate thread.
  final int? threadStackBytes;
  final int processors;

  /// Median time of [calibrationScript] on this device; the speed factor
  /// relative to the reference device that produced the profile.
  final Duration calibration;

  Map<String, Object?> toJson() => <String, Object?>{
    'physicalMemoryBytes': physicalMemoryBytes,
    'threadStackBytes': threadStackBytes,
    'processors': processors,
    'calibrationMicros': calibration.inMicroseconds,
  };
}

/// A fixed CPU-bound script (string building, regex, objects, sorting) whose
/// run time measures interpreter speed. Changing it invalidates every
/// committed profile.
const String calibrationScript = r'''
(function () {
  let acc = 0;
  const items = [];
  for (let i = 0; i < 20000; i++) {
    const s = '<div class="item-' + i + '">' + (i * 7919 % 1000) + '</div>';
    const m = /item-(\d+)">(\d+)/.exec(s);
    items.push({ id: +m[1], score: +m[2] });
  }
  items.sort((a, b) => a.score - b.score || a.id - b.id);
  for (const it of items) acc = (acc + it.id * it.score) % 1000003;
  return acc;
})()
''';

/// Times [calibrationScript] [runs] times in a scratch runtime; returns the
/// median.
Duration measureCalibration({required int runs}) {
  if (runs <= 0) throw ArgumentError.value(runs, 'runs', 'must be positive');
  final runtime = JsRuntime();
  try {
    final int? stack = QuickJs.threadStackAvailable();
    if (stack != null) runtime.maxStackSize = stack ~/ 2;
    final JsContext context = runtime.newContext();
    final samples = <int>[];
    for (var i = 0; i < runs; i++) {
      final int start = QuickJs.nowNanoseconds();
      context.eval(calibrationScript).dispose();
      samples.add(QuickJs.nowNanoseconds() - start);
    }
    samples.sort();
    return Duration(microseconds: samples[samples.length ~/ 2] ~/ 1000);
  } finally {
    runtime.dispose();
  }
}

/// What the heaviest measured workload needed on the reference device.
final class QuickJsWorkloadProfile {
  const QuickJsWorkloadProfile({
    required this.source,
    required this.peakHeapBytes,
    required this.peakStackBytes,
    required this.slowestOperation,
    required this.referenceCalibration,
  });

  factory QuickJsWorkloadProfile.fromJson(Map<String, Object?> json) => QuickJsWorkloadProfile(
    source: json['source']! as String,
    peakHeapBytes: json['peakHeapBytes']! as int,
    peakStackBytes: json['peakStackBytes']! as int,
    slowestOperation: Duration(microseconds: json['slowestOperationMicros']! as int),
    referenceCalibration: Duration(microseconds: json['referenceCalibrationMicros']! as int),
  );

  /// Where the numbers came from, e.g. a benchmark results file.
  final String source;

  /// Smallest heap limit under which every workload succeeded.
  final int peakHeapBytes;

  /// Smallest stack limit under which every workload succeeded.
  final int peakStackBytes;

  /// Slowest single operation on the reference device.
  final Duration slowestOperation;

  /// The reference device's calibration time.
  final Duration referenceCalibration;

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source,
    'peakHeapBytes': peakHeapBytes,
    'peakStackBytes': peakStackBytes,
    'slowestOperationMicros': slowestOperation.inMicroseconds,
    'referenceCalibrationMicros': referenceCalibration.inMicroseconds,
  };
}

/// Tunable factors of the rule, re-derived with each benchmark run.
final class QuickJsSizingPolicy {
  const QuickJsSizingPolicy({
    required this.heapHeadroom,
    required this.stackHeadroom,
    required this.deadlineHeadroom,
    required this.maxMemoryShare,
    required this.maxThreadStackShare,
    required this.slicesPerDeadline,
  });

  factory QuickJsSizingPolicy.fromJson(Map<String, Object?> json) => QuickJsSizingPolicy(
    heapHeadroom: (json['heapHeadroom']! as num).toDouble(),
    stackHeadroom: (json['stackHeadroom']! as num).toDouble(),
    deadlineHeadroom: (json['deadlineHeadroom']! as num).toDouble(),
    maxMemoryShare: (json['maxMemoryShare']! as num).toDouble(),
    maxThreadStackShare: (json['maxThreadStackShare']! as num).toDouble(),
    slicesPerDeadline: json['slicesPerDeadline']! as int,
  );

  /// Multiplier on the measured peak heap.
  final double heapHeadroom;

  /// Multiplier on the measured peak stack.
  final double stackHeadroom;

  /// Multiplier on the speed-scaled slowest operation.
  final double deadlineHeadroom;

  /// Largest share of physical memory all runtimes together may claim.
  final double maxMemoryShare;

  /// Largest share of the thread's native stack the JS stack may claim; the
  /// rest is for host frames (Dart, FFI, host callbacks).
  final double maxThreadStackShare;

  /// How many times per deadline the worker must get an event-loop turn
  /// (bounds cancellation and I/O latency under a microtask flood).
  final int slicesPerDeadline;

  Map<String, Object?> toJson() => <String, Object?>{
    'heapHeadroom': heapHeadroom,
    'stackHeadroom': stackHeadroom,
    'deadlineHeadroom': deadlineHeadroom,
    'maxMemoryShare': maxMemoryShare,
    'maxThreadStackShare': maxThreadStackShare,
    'slicesPerDeadline': slicesPerDeadline,
  };
}

/// The current policy factors. **Provisional** until U6 measures real
/// bundles; rationale in `benchmark/README.md`.
const QuickJsSizingPolicy provisionalSizingPolicy = QuickJsSizingPolicy(
  heapHeadroom: 2,
  stackHeadroom: 2,
  deadlineHeadroom: 4,
  maxMemoryShare: 0.25,
  maxThreadStackShare: 0.5,
  slicesPerDeadline: 50,
);

/// The rule's output: limits plus everything needed to audit them.
final class QuickJsSizing {
  const QuickJsSizing({
    required this.limits,
    required this.device,
    required this.profile,
    required this.policy,
    required this.concurrentRuntimes,
    required this.hostWaitAllowance,
    required this.warnings,
  });

  final PaperbackRuntimeLimits limits;
  final DeviceCapability device;
  final QuickJsWorkloadProfile profile;
  final QuickJsSizingPolicy policy;
  final int concurrentRuntimes;
  final Duration hostWaitAllowance;

  /// Inputs that capped a limit below what the workload needs.
  final List<String> warnings;

  Map<String, Object?> toJson() => <String, Object?>{
    'rule': 'quickjs-sizing-v1 (provisional: synthetic workloads)',
    'limits': limits.toJson(),
    'device': device.toJson(),
    'profile': profile.toJson(),
    'policy': policy.toJson(),
    'concurrentRuntimes': concurrentRuntimes,
    'hostWaitAllowanceMicros': hostWaitAllowance.inMicroseconds,
    'warnings': warnings,
  };
}

/// Applies the sizing rule:
///
/// - memory = peakHeap × heapHeadroom, capped at
///   physicalMemory × maxMemoryShare ÷ concurrentRuntimes;
/// - stack = peakStack × stackHeadroom, capped at
///   threadStack × maxThreadStackShare;
/// - deadline = slowestOperation × (device calibration ÷ reference
///   calibration) × deadlineHeadroom + hostWaitAllowance;
/// - job slice = the CPU part of the deadline ÷ slicesPerDeadline.
///
/// [hostWaitAllowance] is the time an operation may spend waiting on host
/// I/O (network). It is not a device property of QuickJS; the caller passes
/// the per-operation allowance from its own deadline policy (KTD4).
///
/// A cap that lands below the workload's measured need is reported in
/// [QuickJsSizing.warnings] rather than silently accepted.
QuickJsSizing deriveQuickJsLimits({
  required DeviceCapability device,
  required QuickJsWorkloadProfile profile,
  required QuickJsSizingPolicy policy,
  required int concurrentRuntimes,
  required Duration hostWaitAllowance,
}) {
  if (concurrentRuntimes <= 0) throw ArgumentError.value(concurrentRuntimes, 'concurrentRuntimes');
  if (hostWaitAllowance < Duration.zero) throw ArgumentError.value(hostWaitAllowance, 'hostWaitAllowance');
  final warnings = <String>[];

  int memory = (profile.peakHeapBytes * policy.heapHeadroom).ceil();
  final int? physical = device.physicalMemoryBytes;
  if (physical != null) {
    final int cap = (physical * policy.maxMemoryShare / concurrentRuntimes).floor();
    if (cap < memory) {
      memory = cap;
      if (cap < profile.peakHeapBytes) {
        warnings.add('memory cap $cap is below the measured peak heap ${profile.peakHeapBytes}');
      }
    }
  }

  int stack = (profile.peakStackBytes * policy.stackHeadroom).ceil();
  final int? threadStack = device.threadStackBytes;
  if (threadStack != null) {
    final int cap = (threadStack * policy.maxThreadStackShare).floor();
    if (cap < stack) {
      stack = cap;
      if (cap < profile.peakStackBytes) {
        warnings.add('stack cap $cap is below the measured peak stack ${profile.peakStackBytes}');
      }
    }
  }

  final double speed = device.calibration.inMicroseconds / math.max(1, profile.referenceCalibration.inMicroseconds);
  final int cpuUs = (profile.slowestOperation.inMicroseconds * speed * policy.deadlineHeadroom).ceil();
  final int deadlineUs = cpuUs + hostWaitAllowance.inMicroseconds;
  final int sliceUs = math.max(1, cpuUs ~/ policy.slicesPerDeadline);

  return QuickJsSizing(
    limits: PaperbackRuntimeLimits(
      memoryLimitBytes: math.max(1, memory),
      maxStackBytes: math.max(1, stack),
      operationDeadline: Duration(microseconds: math.max(1, deadlineUs)),
      jobSlice: Duration(microseconds: sliceUs),
    ),
    device: device,
    profile: profile,
    policy: policy,
    concurrentRuntimes: concurrentRuntimes,
    hostWaitAllowance: hostWaitAllowance,
    warnings: warnings,
  );
}
