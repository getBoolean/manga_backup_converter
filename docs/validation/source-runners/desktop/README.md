# Desktop Tachi worker benchmark (KTD25, U3 step 6)

Harness: `tools/tachi-source-runner/benchmark/src/Benchmark.kt`
(`./gradlew benchmark` from `tools/tachi-source-runner`; `-PbenchmarkArgs=--quick` is the CI smoke mode,
which prints results and writes nothing).

Raw results: [`benchmark-windows-11.json`](benchmark-windows-11.json). The derived rule is committed as
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

## Results (Windows 11, Intel Family 6 Model 165, 16 logical cores; 2026-11-21)

**Machine load:** this run (2026-11-21T04:27Z, after the protocol 1.2 and deterministic-conversion
changes) ran while unrelated processes held the CPU at 100% (other agents' Dart and JVM processes, WSL,
a long-running Python job). Every time below is therefore inflated against the previous idle-machine run
(2026-11-20: restart 4.76 s, shutdown max 55 ms, cancel max 5.9 ms, MangaDex prepare p50 38 ms). Inflated
times only lengthen the derived deadlines and graces, so the rule errs on the safe side, but it should be
regenerated on an idle machine.

| Operation | MangaDex p50 / p99 | Weeb Central p50 / p99 | MangaFire p50 / p99 |
|---|---|---|---|
| artifact.prepare (JAR verify + stage) | 610 / 2407 ms | 260 / 384 ms | 574 / 826 ms |
| package.load | 666 / 2436 ms | 203 / 221 ms | 362 / 429 ms |
| search | 51 / 941 ms | 1920 / 1984 ms | 430 / 643 ms |
| details (manga + chapters) | 1009 / 1079 ms | 4086 / 4603 ms | 1020 / 1074 ms |

| Measurement | Result |
|---|---|
| Cancel settle, fixture (n=20) | p50 1.0 ms, max 223.5 ms |
| Cancel settle, real sources in flight (n=15) | p50 1.8 ms, max 194.5 ms |
| Restart and rehydrate, 3 packages (n=8) | p50 13.98 s, max 15.47 s |
| Graceful shutdown (n=8) | p50 114 ms, max 312 ms |
| Worker CPU per wall second while running one operation | 0.042 |
| Heap: worker baseline / per loaded package | 2.7 MiB measured + 64 MiB fixed floor = 67 MiB / 1.3 MiB measured |
| Throughput, pools 1 / 2 / 3 | 0.8 / 0.8 / 0.8 details/s |

Start-up (launch → handshake reply, then package loads in the same process):

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
| coresFactor | 24.1 | 1 / measured CPU utilisation per running operation (0.042) |
| maxPoolSize | 3 | largest concurrency measured (three distinct packages) |
| baseHeapMiB | 67 | 2.7 MiB measured on-heap delta plus a 64 MiB floor constant (`JVM_BASELINE_MIB`, not measured) |
| perPackageHeapMiB | 3 | measured 1.3 MiB per package, doubled |
| p99OperationMs | 4603 | slowest p99 over search and details |
| deadlineFactor | 50 | policy multiplier (see limits below) |
| maxCancelSettleMs / maxShutdownMs | 223.5 / 312 | measured maxima |
| graceFactor | 3 | policy multiplier |
| interactionTimeoutMs | 300000 | user-facing bound, not a machine capability |
| maxStartupToHandshakeMs | 3112.5 | worst launch → handshake sample (cold, `-Xshare:off`) |
| handshakeFactor | 10 | chosen headroom constant (`HANDSHAKE_FACTOR`), pending macOS and Linux runs |

Derived on the benchmark machine (16 cores, 30 GiB benchmark heap): pool 3, operation deadline 230 s,
cancel grace 936 ms, shutdown grace 936 ms, interaction timeout 300 s, handshake deadline 31.1 s.

The handshake deadline does not depend on device inputs, so it is fixed when the worker is packaged:
the `runtimeManifest` task writes it into `tachi-runtime.json` at the install root, where
`TachiWorkerLocation` reads `handshakeDeadlineMs` before starting the worker. The handshake repeats it in
`limits` and `sizing.derived` for receipts. `handshakeFactor` is a chosen constant: 10× the worst sample
covers first launches after install, a loaded machine (as in this run) and slower disks. A tighter value
risks failing every Tachi conversion on a slower machine; a looser one only delays reporting a worker
that never starts. Revisit it with the macOS and Linux results.

## Limits of this evidence

Step 6 is **partial**:

- The pool size is effectively `min(3, heap bound)` on every machine: `floor(cores × 36.2)` always exceeds
  the measured-concurrency cap, and throughput did not discriminate pool sizes because the sources' rate
  limiters bound it.
- `deadlineFactor` (50), `graceFactor` (3), the heap doubling and the 64 MiB floor are chosen constants,
  not benchmark-derived.
- The cancel grace comes from cancels sent during rate-limiter sleeps. On the idle machine it was 165 ms,
  not fit for the supervisor to adopt as is (a premature kill costs a restart); this loaded run gives
  936 ms. Neither is a considered value yet.
- This run was taken on a loaded machine (see Results); regenerate it on an idle one.

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
