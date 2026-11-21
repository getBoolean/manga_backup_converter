# Desktop Tachi worker benchmark (KTD25, U3 step 6)

Harness: `tools/tachi-source-runner/benchmark/src/Benchmark.kt`
(`./gradlew benchmark` from `tools/tachi-source-runner`; `-PbenchmarkArgs=--quick` is the CI smoke mode,
which prints results and writes nothing).

Raw results: [`benchmark-windows-11-2026-11-20-idle.json`](benchmark-windows-11-2026-11-20-idle.json)
(idle machine; every limit except the handshake deadline) and
[`benchmark-windows-11.json`](benchmark-windows-11.json) (loaded machine; start-up only, see Results).
The derived rule is committed as
`tools/tachi-source-runner/src/main/resources/tachi-worker-sizing.json`; the worker reads it at startup,
measures its inputs, and reports rule, inputs and derived limits in the handshake (`sizing`, `limits`).

## Method

- The worker runs as a child process on Amazon Corretto 21.0.13.1 with `-Xmx1g`, in replay mode against
  the committed captures (`fixtures/source_captures/tachi/`). No network is used, so latency here is host
  and source-code time plus the sources' own rate limiters; it excludes site latency.
- Operations: the three qualification extensions' repository JARs (MangaDex 1.6.4, Weeb Central 1.6.27,
  MangaFire 1.6.38), query `Onimai`, first matching hit, details with chapters.
- Measurements: per-operation latency (20 iterations after 2 warm-ups), cooperative-cancel settle time
  (a fixture source sleeping in a loop, and real details operations cancelled in flight), restart and
  rehydrate (new process, handshake, reload the three packages, details from durable references only,
  8 runs), concurrent-package throughput at pool sizes 1-3, heap per loaded package (in-process, after
  full GCs), graceful shutdown time, and start-up (below).
- Start-up is measured on the installed distribution (`installDist`), launched the way
  `TachiWorkerLocation.spec` launches it: `java -cp "<install>/lib/*" mangabackup.tachi.MainKt
  --state-dir <tmp> --replay …`, with no `-Xmx` and no `--limit`. The clock starts before the process is
  created and stops at the handshake reply; loading the first package, and all three, is timed after.
  Cold samples launch from a fresh copy of the install directory (new files, first seen by the OS cache
  and the virus scanner), with and without the JDK's CDS archive (`-Xshare:off`); warm samples repeat
  launches of one install. This is the coldest start the harness can provoke, not a cold OS boot.

## Results (Windows 11, Intel Family 6 Model 165, 16 logical cores)

The rule combines two runs:

- **2026-11-20T17:39Z, idle machine** (before protocol 1.2): every table except start-up, and every
  coefficient except `maxStartupToHandshakeMs`.
- **2026-11-21T04:27Z, loaded machine** (after the protocol 1.2 and deterministic-conversion changes):
  start-up only. Unrelated processes held the CPU at 100% (other agents' Dart and JVM processes, WSL, a
  long-running Python job), which inflated its times: restart and rehydrate p50 13.98 s (idle 4.76 s),
  shutdown max 312 ms (idle 55 ms), cancel settle max 223.5 ms (idle 5.9 ms), details p99 4603 ms (idle
  4021 ms). Those inflated values are not used. Its start-up samples are kept: an inflated handshake time
  only lengthens the handshake deadline, the safe direction for a bound that otherwise fails every Tachi
  conversion.

**Pending:** a full rerun on an idle machine (to measure start-up idle and confirm the other values after
the protocol 1.2 changes), and runs on macOS and Linux.

| Operation | MangaDex p50 / p99 | Weeb Central p50 / p99 | MangaFire p50 / p99 |
|---|---|---|---|
| artifact.prepare (JAR verify + stage) | 38 / 180 ms | 19 / 19 ms | 27 / 31 ms |
| package.load | 59 / 148 ms | 11 / 13 ms | 17 / 19 ms |
| search | 137 / 858 ms | 1994 / 1998 ms | 18 / 986 ms |
| details (manga + chapters) | 1001 / 1003 ms | 4007 / 4021 ms | 1001 / 1003 ms |

| Measurement | Result |
|---|---|
| Cancel settle, fixture (n=20) | p50 0.7 ms, max 5.9 ms |
| Cancel settle, real sources in flight (n=15) | p50 1.2 ms, max 5.5 ms |
| Restart and rehydrate, 3 packages (n=8) | p50 4.76 s, max 5.74 s |
| Graceful shutdown (n=8) | p50 48 ms, max 55 ms |
| Worker CPU per wall second while running one operation | 0.028 |
| Heap: worker baseline / per loaded package | 2.7 MiB measured + 64 MiB fixed floor = 67 MiB / 1.4 MiB measured |
| Throughput, pools 1 / 2 / 3 | 0.8 / 0.8 / 0.8 details/s |

Start-up (2026-11-21 loaded run; launch → handshake reply, then package loads in the same process):

| Samples | Handshake p50 / max | Load 1 package p50 / max | Load 3 packages p50 / max |
|---|---|---|---|
| Cold, fresh install copy (n=3) | 2263 / 2696 ms | 250 / 1272 ms | 652 / 1405 ms |
| Cold, fresh install copy, `-Xshare:off` (n=3) | 2341 / 3113 ms | 997 / 2454 ms | 1102 / 2948 ms |
| Warm, same install (n=10) | 1365 / 3006 ms | 249 / 806 ms | 319 / 1316 ms |

The worst handshake sample, 3112.5 ms, is `maxStartupToHandshakeMs`. Package loads are not part of the
handshake deadline: each `package.load` runs under the operation deadline.

Search and details times step in whole seconds because the extensions' own rate limiters (Weeb Central
about one request per 2 s, MangaDex and MangaFire about one per second) dominate; the host's own work is
tens of milliseconds. Throughput is flat across pool sizes for the same reason: the slowest source's rate
limiter bounds each round. A throughput knee therefore cannot size the pool, so the rule uses CPU
utilisation instead and caps the pool at the largest concurrency measured.

## Sizing rule

```
poolSize             = clamp(floor(cores × coresFactor), 1, min(maxPoolSize, floor((maxHeapMiB − baseHeapMiB) / perPackageHeapMiB)))
operationDeadlineMs  = ceil(p99OperationMs × deadlineFactor)
cancelGraceMs        = ceil(max(maxCancelSettleMs, maxShutdownMs) × graceFactor)
shutdownGraceMs      = ceil(maxShutdownMs × graceFactor)
interactionTimeoutMs = interactionTimeoutMs
handshakeDeadlineMs  = ceil(maxStartupToHandshakeMs × handshakeFactor)
```

| Coefficient | Value | From |
|---|---|---|
| coresFactor | 36.2 | 1 / measured CPU utilisation per running operation (0.028) |
| maxPoolSize | 3 | largest concurrency measured (three distinct packages) |
| baseHeapMiB | 67 | 2.7 MiB measured on-heap delta plus a 64 MiB floor constant (`JVM_BASELINE_MIB`, not measured) |
| perPackageHeapMiB | 3 | measured 1.4 MiB per package, doubled |
| p99OperationMs | 4021 | slowest p99 over search and details |
| deadlineFactor | 50 | policy multiplier (see limits below) |
| maxCancelSettleMs / maxShutdownMs | 5.9 / 55 | measured maxima |
| graceFactor | 3 | policy multiplier |
| interactionTimeoutMs | 300000 | user-facing bound, not a machine capability |
| maxStartupToHandshakeMs | 3112.5 | worst launch → handshake sample (cold, `-Xshare:off`; loaded run) |
| handshakeFactor | 10 | chosen headroom constant (`HANDSHAKE_FACTOR`), pending macOS and Linux runs |

Derived on the benchmark machine (16 cores, 30 GiB benchmark heap): pool 3, operation deadline 201 s,
cancel grace 165 ms, shutdown grace 165 ms, interaction timeout 300 s, handshake deadline 31.1 s.

The handshake deadline does not depend on device inputs, so it is fixed when the worker is packaged:
the `runtimeManifest` task writes it into `tachi-runtime.json` at the install root, where
`TachiWorkerLocation` reads `handshakeDeadlineMs` before starting the worker. The handshake repeats it in
`limits` and `sizing.derived` for receipts. `handshakeFactor` is a chosen constant: 10× the worst sample
covers first launches after install, a loaded machine (as in the start-up run) and slower disks. A tighter value
risks failing every Tachi conversion on a slower machine; a looser one only delays reporting a worker
that never starts. Revisit it with the macOS and Linux results.

## Limits of this evidence

Step 6 is **partial**:

- The pool size is effectively `min(3, heap bound)` on every machine: `floor(cores × 36.2)` always exceeds
  the measured-concurrency cap, and throughput did not discriminate pool sizes because the sources' rate
  limiters bound it.
- `deadlineFactor` (50), `graceFactor` (3), the heap doubling and the 64 MiB floor are chosen constants,
  not benchmark-derived.
- The 165 ms cancel grace comes from cancels sent during rate-limiter sleeps on an idle machine. It is not
  fit for the supervisor to adopt as is; a premature kill costs a ~5 s restart. (The loaded 2026-11-21 run
  gave 936 ms; neither is a considered value yet.)
- The start-up measurement comes from a loaded machine and the other values predate protocol 1.2 (see
  Results); regenerate the whole rule from one idle run.

- One device. KTD25 asks for each desktop OS and devices of different capability; macOS and Linux runs
  are still to do (rerun `./gradlew benchmark` there and commit `benchmark-<os>.json`; the rule should be
  regenerated from the combined results).
- Replay removes site latency, so `p99OperationMs` understates live operations. The deadline multiplier
  (50) is a policy value until U8's live gates recalibrate it from live receipts.
- Concurrency beyond three packages is unmeasured, hence `maxPoolSize = 3`. A benchmark with more
  qualification packages would lift it.
- The interaction timeout is a product decision, recorded with the rule but not benchmarked.
- CI should run `./gradlew benchmark -PbenchmarkArgs=--quick` as a non-gating report that fails only on
  crashes or missing output; no CI job was added in this change.
