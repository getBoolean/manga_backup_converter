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
  full GCs), and graceful shutdown time.

## Results (Windows 11, Intel Family 6 Model 165, 16 logical cores; 2026-11-20)

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

Derived on the benchmark machine (16 cores, 30 GiB benchmark heap): pool 3, operation deadline 201 s,
cancel grace 165 ms, shutdown grace 165 ms, interaction timeout 300 s.

## Limits of this evidence

Step 6 is **partial**:

- The pool size is effectively `min(3, heap bound)` on every machine: `floor(cores × 36.2)` always exceeds
  the measured-concurrency cap, and throughput did not discriminate pool sizes because the sources' rate
  limiters bound it.
- `deadlineFactor` (50), `graceFactor` (3), the heap doubling and the 64 MiB floor are chosen constants,
  not benchmark-derived.
- The 165 ms cancel grace comes from cancels sent during rate-limiter sleeps on an idle machine. It is not
  fit for the supervisor to adopt as is; a premature kill costs a ~5 s restart.

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
