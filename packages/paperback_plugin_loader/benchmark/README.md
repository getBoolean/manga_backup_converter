# QuickJS limit benchmark (KTD25)

`quickjs_limits_benchmark.dart` measures what Paperback-like workloads need from a QuickJS runtime on the device it runs on, then applies the sizing rule in `lib/src/runtime/limit_sizing.dart`.

**Status: provisional.** The workloads are synthetic stand-ins. U6 replaces them with real Paperback 0.8/0.9 bundles (with bundled Cheerio) and re-derives the profile and policy. Results exist for one desktop so far (below). Reference devices of different capability, including Android and iOS hardware, still have to be measured.

## Running

From the repository root (no network is used; host calls are served in-process):

```bash
QJS_BENCH_OUT=packages/paperback_plugin_loader/benchmark/results/<date>-<os>-<arch>.json \
  flutter test packages/paperback_plugin_loader/benchmark/quickjs_limits_benchmark.dart
```

CI may run it as a non-gating report. It fails only if a workload cannot complete under the generous harness limits. Timing is never asserted.

## What it measures

| Measurement | How |
|---|---|
| Device calibration | Median time of `calibrationScript` (string building, regex, objects, sort) over 15 runs. It gives the device's speed relative to the reference device. |
| Per-workload time | Median and p95 over 7 fresh-runtime runs. |
| Peak heap | `JsRuntime.peakAllocatedBytes`: bytes held from the system allocator, which is exactly what the memory limit bounds. |
| Minimal heap limit | Binary search, to 64 KiB, for the smallest memory limit under which the workload still passes. |
| Minimal stack limit | Binary search, to 4 KiB, for the smallest JS stack limit under which it still passes. |
| JS frame size | Native stack per JS call: the stack ceiling divided by the recursion depth reached. |
| Interrupt overshoot | How far past a 50 ms deadline a busy loop actually stops. |

The workloads:

- `bundle-eval`: evaluate a ~1 MiB generated bundle and call into it.
- `html-parse`: tokenize a ~600 KiB results page into a tree and extract 1,000 cards. This stands in for Cheerio.
- `json-response`: fetch ~2 MiB of JSON through the promise bridge and map it.
- `deep-tree`: recursive descent 64 levels deep, the depth of deeply nested DOM.
- `await-loop`: 2,000 sequential awaits on host calls.

## The sizing rule (quickjs-sizing-v1)

Every input can be measured at worker startup (`DeviceCapability.measure`), so each device sizes its own limits:

- **memory** = peakHeap × `heapHeadroom`, capped at physicalMemory × `maxMemoryShare` ÷ concurrentRuntimes
- **stack** = peakStack × `stackHeadroom`, capped at threadStack × `maxThreadStackShare`
- **deadline** = slowestOperation × (device calibration ÷ reference calibration) × `deadlineHeadroom` + hostWaitAllowance
- **job slice** = the CPU part of the deadline ÷ `slicesPerDeadline`

A cap that lands below the measured need is reported in `QuickJsSizing.warnings`, never silently accepted. `QuickJsSizing.toJson()` records the rule, its inputs and the derived values for the handshake and qualification receipts. `hostWaitAllowance` covers network waits. It is not a QuickJS device property, so the supervisor passes it from its own per-operation deadline policy (KTD4).

### Provisional policy (`provisionalSizingPolicy`)

| Factor | Value | Rationale (to be re-derived from U6 bundles) |
|---|---|---|
| `heapHeadroom` | 2 | Real pages and responses vary in size around the synthetic ones. The measured peak already includes GC lag. |
| `stackHeadroom` | 2 | Real bundles recurse more (Cheerio and parse5 traversal) than the synthetic descent. |
| `deadlineHeadroom` | 4 | p95 sits about 1.1–2.6× the median across workloads (JIT-free variance plus GC pauses). 4× leaves margin on loaded machines. |
| `maxMemoryShare` | 0.25 | Keeps all source runtimes together within a quarter of RAM. |
| `maxThreadStackShare` | 0.5 | Leaves half the thread's stack for Dart, FFI and host-callback frames below the JS entry. |
| `slicesPerDeadline` | 50 | Gives the worker at least 50 event-loop turns per deadline, so cancellation and I/O latency stay within 2% of the deadline. |

## Results

### 2026-11-20 — Windows 11 x64, MSVC 19.51 build (`results/2026-11-20-windows-x64.json`)

16 logical processors, 128 GiB RAM, calibration 62.9 ms, about 1 MiB of thread stack.

| Workload | Median | p95 | Minimal heap | Minimal stack |
|---|---|---|---|---|
| bundle-eval | 49.7 ms | 58.1 ms | 5.6 MB | 16 KB |
| html-parse | 41.4 ms | 45.0 ms | 4.4 MB | 52 KB |
| json-response | 30.4 ms | 78.1 ms | 13.7 MB | 24 KB |
| deep-tree | 0.1 ms | 0.2 ms | 0.2 MB | 311 KB |
| await-loop | 189 ms | 303 ms | 0.2 MB | 12 KB |

- Interrupt overshoot past a 50 ms deadline: median 0.24 ms, max 0.25 ms.
- Derived limits (any concurrency on this machine): memory 27.4 MB, stack 518 KB (capped by the thread stack), deadline 1.21 s plus the host-wait allowance, job slice 24 ms.

### Findings that constrain U6 and the mobile units

- **Windows recursion depth is small.** The MSVC `/O2` build uses about **4.8 KB of native stack per JS call**. Dart isolate threads on Windows have about 1 MiB of stack, both the main isolate and spawned isolates (`Isolate.run`). So the ceiling is about 107 JS frames at a 50% stack share, and about 215 at 100%, which would crash. The 64-level descent already needs 311 KB. Compiler experiments on the same machine:
  - `/O1`: 3.8 KB per frame, but calibration 65% slower.
  - `/Os`: 15.4 KB per frame and 3× slower.

  - `/O2 /Ob1`: no change (109 frames), so inlining is not the cause.

  The same ceiling holds under `dart run` (1,042,880 bytes of thread stack, 108 frames at half), not only under `flutter_tester`. AOT executables were not measured. For comparison, the former `BooleanExtra/quickjs-dart` engine (Bellard QuickJS, MinGW build, engine-default stack limit) completed 600-deep recursion in the same probe and threw `InternalError: stack overflow` at 800. So Aidoku JS evaluation, which now runs with half the thread stack as its limit, supports roughly a sixth of the former recursion depth on Windows. The hook keeps `/O2`. On Windows, `native_toolchain_c` 0.17.4 resolves only `cl.exe` unless the launcher supplies a compiler, so a clang-cl build would need the hook to drive the compiler itself. If real bundles need deeper recursion on Windows, U6 should evaluate a clang-cl build, or running QuickJS on a native thread with a larger stack. The second option needs a synchronous host-call channel, because isolate-local FFI callbacks cannot run on a foreign thread.
- **Host awaits cost about 95 µs each,** one event-loop turn per await. The `await-loop` workload is the slowest operation for that reason. It sets the deadline basis until real bundles replace it.
- Clang targets (Android, Apple, Linux) have not been measured. Their frame size and thread stacks differ, which is exactly why the rule measures them at startup.
