// The KTD25 launch plan: limits and deadline headroom derived from the
// real-bundle profile for a given device, and the arguments the worker gets.
@TestOn('vm')
library;

import 'package:checks/checks.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:test/scaffolding.dart';

void main() {
  const reference = DeviceCapability(
    physicalMemoryBytes: 16 << 30,
    threadStackBytes: 1044208,
    processors: 8,
    calibration: Duration(microseconds: 122176),
  );

  test('the reference device gets the profile times the policy headroom', () {
    final PaperbackWorkerPlan plan = planPaperbackWorker(device: reference, hostWaitAllowance: Duration.zero);
    final PaperbackRuntimeLimits limits = plan.sizing.limits;
    check(limits.memoryLimitBytes).equals(paperbackBundleProfile.peakHeapBytes * 2);
    check(limits.maxStackBytes).equals(paperbackBundleProfile.peakStackBytes * 2);
    check(limits.operationDeadline).equals(paperbackBundleProfile.slowestOperation * 4);
    check(plan.sizing.warnings).isEmpty();
    // Supervisor headroom: the measured tail times four.
    check(plan.deadlineHeadroom).equals(referenceDeadlineTail * 4);
    check(plan.arguments)
        .contains('--deadline-headroom-ms=${((referenceDeadlineTail * 4).inMicroseconds + 999) ~/ 1000}');
    check(parseWorkerArguments(plan.arguments).limits.memoryLimitBytes).equals(limits.memoryLimitBytes);
  });

  test('a slower device scales the deadline and the headroom; its stack cap is reported', () {
    const slow = DeviceCapability(
      physicalMemoryBytes: 4 << 30,
      threadStackBytes: 512 * 1024,
      processors: 4,
      calibration: Duration(microseconds: 122176 * 3),
    );
    final PaperbackWorkerPlan plan = planPaperbackWorker(device: slow, hostWaitAllowance: Duration.zero);
    check(plan.sizing.limits.operationDeadline).equals(paperbackBundleProfile.slowestOperation * 12);
    check(plan.deadlineHeadroom).equals(referenceDeadlineTail * 12);
    // Half of a 512 KiB stack is below twice the measured need, but above
    // the need itself: capped without a warning.
    check(plan.sizing.limits.maxStackBytes).equals(256 * 1024);
    check(plan.sizing.warnings).isEmpty();
  });

  test('the host-wait allowance is added to the engine deadline', () {
    final PaperbackWorkerPlan plan = planPaperbackWorker(device: reference);
    check(plan.sizing.limits.operationDeadline)
        .equals(paperbackBundleProfile.slowestOperation * 4 + paperbackHostWaitAllowance);
  });
}
