# QuickJS limit benchmark (KTD25)

`quickjs_limits_benchmark.dart` measures what Paperback-like workloads need from a QuickJS runtime on the device it runs on, then applies the sizing rule in `lib/src/runtime/limit_sizing.dart`.

**Status: superseded by the real-bundle benchmark** (`bundle_benchmark.dart`, below). This synthetic harness is kept for comparison. The sizing rule's profile now comes from real Paperback 0.8/0.9 bundles (`paperbackBundleProfile` in `lib/src/worker_plan.dart`). Reference devices of different capability, including Android and iOS hardware, still have to be measured.

## Real-bundle benchmark (U6)

`bundle_benchmark.dart` runs the pinned Paperback bundles (`fixtures/source_captures/paperback`) on the committed captures: each bundle's load, and search and details where the capture completes them. It measures median/p95 time (rate-limiter sleeps made instant), peak and minimal heap, minimal stack, the JS frame size, how far each operation runs past an engine deadline placed inside it, and the reply conversion and frame-encoding tail.

```bash
# JIT (flutter_tester), from the repository root:
QJS_BENCH_OUT=packages/paperback_plugin_loader/benchmark/results/<date>-<os>-bundles-jit.json   flutter test packages/paperback_plugin_loader/benchmark/paperback_bundles_benchmark_test.dart
# AOT, as the worker ships (from packages/paperback_plugin_loader):
dart build cli -t benchmark/bundle_benchmark_main.dart -o <dir>
<dir>/bundle/bin/bundle_benchmark_main <repo>/fixtures/source_captures/paperback results/<date>-<os>-bundles-aot.json
```

iOS (U10): `integration_test/source_runners_ios_paperback_browser_test.dart` runs `runBundleBenchmark` in a worker isolate on the device with `--dart-define=SRT_BENCH=true`. 2026-11-21, iOS 26.5 Simulator (arm64, debug/JIT Dart, native QuickJS): `results/2026-11-21-ios-simulator-arm64-bundles-jit.json`, **provisional** (a simulator on an Apple-silicon Mac; physical iPhones still to be measured; `docs/validation/source-runners/ios/README.md`, U10).

Android (U12): `integration_test/android_u12_cases.dart` runs the same benchmark in a worker isolate with `--dart-define=SRT_BENCH=true`. 2026-11-21, Android 16 emulator (x86_64, debug/JIT Dart, native QuickJS): `results/2026-11-21-android-emulator-x64-bundles-jit.json`, **provisional** (an emulator; physical ARM64 devices still to be measured). It measured a 924 ms deadline overshoot; see `docs/validation/source-runners/android/README.md`, U12.

Results and the derived limits are in `docs/source-runners.md` (Paperback host, Limits). 2026-11-21, Windows 11 x64 (MSVC): `results/2026-11-21-windows-x64-bundles-aot.json` (sizes the shipped worker) and `...-bundles-jit.json`.

2026-11-21, macOS 27.0 arm64 (Apple M1, 8 cores, 16 GiB; Apple clang 21.0.0; QuickJS-ng `dce8c0bb3b5d`, `libquickjs.dylib` SHA-256 `aa30ddb329d66e1011bcd14cbff1dc45815bfe72f557d869d786be71f1f471e1`, the same binary the macOS package ships; host commit b519a8d, U8 macOS lane): `results/2026-11-21-macos-arm64-bundles-aot.json`, `...-bundles-jit.json`, and the synthetic `results/2026-11-21-macos-arm64.json`. **Loaded machine** (Spotlight indexing, 31-50% CPU idle during the runs), so timings are upper bounds. Findings:

- **The clang build uses about 1 KB of native stack per JS call** (1011 B AOT, 1008 B JIT) against 4.8 KB for the MSVC build. The AOT worker's thread has about 1 MiB of stack on macOS too, so the half-stack ceiling allows about **523 JS frames** (Windows: 108). Under `flutter_tester` the thread stack is 8 MiB (4143 frames). This confirms the Windows recursion limit is an MSVC code-generation cost, not a QuickJS one.
- Heap needs are identical to Windows to within 0.5% (same bundles, same 64-bit JSValue layout): peak 9.6 MB for MangaDex details, minimal stack limits 28-49 KB.
- AOT is 2.6-5× faster than the Windows AOT run (calibration 27.7 ms against 122.2 ms; Weeb Central details median 232-237 ms against 1.14-1.21 s). Slowest operation: numby-0.8 Weeb Central details (p95 244 ms). Worst deadline overshoot 36.3 ms (numby load), Windows 214 ms.
- Synthetic interrupt overshoot past a 50 ms deadline: median 0.20 ms, max 0.44 ms.

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
- Clang targets: macOS arm64 measured on 2026-11-21 (about 1 KB per JS frame, above); Android and Linux are still unmeasured. Frame size and thread stacks differ per target, which is exactly why the rule measures them at startup.
