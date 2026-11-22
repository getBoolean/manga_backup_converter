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
the protocol 1.2 changes), an idle macOS run (the 2026-11-21 macOS run below was loaded), and Linux.

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

## macOS run (2026-11-21, `benchmark-macos-27.json`; loaded machine, not used by the rule)

Identity: host commit b519a8d (clean), macOS 27.0 build 26A428, Apple M1, 8 logical cores, 16 GiB, Amazon Corretto
21.0.13.1+2 from the pinned archive (worker `-Xmx1g`), replayed captures, harness recording CPU model and commit since
5b41b70. The machine was **not idle**: Spotlight was indexing the new build outputs (mds_stores up to 230% CPU),
WindowServer animated the wallpaper and Syncthing synced; `top` showed 49% CPU idle before and 65% after. Waiting
15 minutes did not change that, and stopping those services was not done without the owner. The run is a
lower-capability, loaded-device comparison, so the committed rule (`tachi-worker-sizing.json`, from the Windows runs)
was kept; the benchmark's rewrite of it was reverted.

| Operation | MangaDex p50 / p99 | Weeb Central p50 / p99 | MangaFire p50 / p99 |
|---|---|---|---|
| artifact.prepare | 15.5 / 84.4 ms | 7.5 / 23.7 ms | 11.3 / 28.3 ms |
| package.load | 18.3 / 90.8 ms | 5.1 / 8.1 ms | 6.8 / 11.8 ms |
| search | 59.2 / 968.9 ms | 1997.3 / 2006.9 ms | 7.0 / 1011.3 ms |
| details | 1009.1 / 1014.7 ms | 4024.8 / 4048.4 ms | 1009.0 / 1013.6 ms |

| Measurement | macOS | Windows idle (rule) |
|---|---|---|
| Cancel settle, fixture / real sources | max 3.1 / 7.2 ms | max 5.9 / 5.5 ms |
| Restart and rehydrate, 3 packages (n=8) | p50 2.72 s, max 2.81 s | p50 4.76 s, max 5.74 s |
| Graceful shutdown | max 24.3 ms | max 55 ms |
| Heap baseline / per package | 66.6 / 1.4 MiB | 67 / 1.4 MiB |
| Throughput, pools 1 / 2 / 3 | 0.7 / 0.7 / 0.7 details/s | 0.8 / 0.8 / 0.8 |
| Handshake: cold copy / cold no CDS / warm, max | 354.5 / 469.0 / 473.7 ms | 2696 / 3113 / 3006 ms (loaded run) |
| CPU per wall second, one operation | 0.0 (below the harness's resolution) | 0.028 |

What it changes: nothing in the rule. The worst macOS handshake (474 ms) is 15% of `maxStartupToHandshakeMs`
(3112.5 ms), so the 31.1 s packaged handshake deadline holds with a wide margin; the slowest p99 (4048 ms) is within
1% of the rule's 4021 ms, again the Weeb Central rate limiter; cancel and shutdown maxima stay inside the 165 ms
grace. The CPU-utilisation reading of 0.0 makes the macOS-only rule's `coresFactor` hit its floor (100), which does
not change the pool (always the measured cap of 3). An idle-machine macOS rerun, and Linux, remain to do before the
rule is regenerated from combined results.

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

# U8 qualification (desktop packaging and the browser join)

- [`qualification-manifest.json`](qualification-manifest.json): one cell per runner, qualification source and
  desktop OS, with replayed, live and restore evidence kept apart. Windows cells ran in U8, macOS cells in the U8 macOS lane;
  Linux is a separate lane and is listed as not run. U8b (Windows): Paperback 0.9 MangaFire passes live and in replay
  (browser capture of the page's site scripts, replayed through the real helper); Tachi MangaFire passes search,
  details and chapters live and in replay, but its browser path was not exercised live (no WAF challenge fired);
  Aidoku MangaFire has no browser path. The macOS MangaFire cells stay open (no WebKit recorder, no replace tier to
  replay a browser capture), Linux is not run and no restore was made, so M1 stays open.
- `receipts/` (generated by runs, never written by hand; each passes `dart run tool/check_evidence_receipts.dart`):
  - `windows-package-smoke.json`: `scripts/smoke_packaged_cli.dart` on the package built by
    `scripts/package_cli.dart` (path with spaces, no system toolchains, manifest hashes and licences, JRE floor,
    runtime start and close, killed CLI leaves no process).
  - `windows-tachi-two-repositories-one-worker.json` and `windows-paperback-executeinwebview-helper.json`:
    `packages/mangabackupconverter_cli/test/integration/source_runner_conversion_test.dart` run with
    `SRT_RECEIPT_DIR` set (replayed captures; the helper offline). Regenerated in U8b at the U8b head: the Paperback
    receipt now records MangaFire search, details and 86 chapters through the helper replaying the browser capture,
    and the Tachi receipt's `java` is the runtime's `java.runtime.version` and vendor (the macOS receipts keep the
    older directory-name string).
- Windows suites in U8b (2026-11-21/22, Windows 11 Pro build 26300, WebView2 157.0.4341.60, Corretto 21.0.13.1,
  Flutter 3.50.0 / Dart 3.14.0), pass / skip / fail:

  | Suite | Result |
  |---|---|
  | Gradle `--offline test installDist fixtureJar_prefs fixtureJar_cloudflare` | 108 / 0 / 0 |
  | `source_runtime` | 211 / 0 / 0 |
  | `source_runtime_testing` | 219 / 7 / 0 |
  | `desktop_webview` (`--concurrency 1`, visible windows) | 88 / 3 / 0. Two full runs each failed one test once, on a loaded machine, and passed on rerun: the record test's live cross-origin fetch (now recorded offline over loopback; see `browser_capture_test.dart`), and the U8a test `mainFrame marks the top-level document` (its `/same-framed` load ended with WebView2 web error status 0). Causes not identified |
  | `tachi_plugin_loader` | 35 / 0 / 0 |
  | `paperback_plugin_loader` (incl. e2e workers) | 147 / 0 / 0 |
  | `manga_backup_core` | 206 / 1 / 0 |
  | `mangabackupconverter_cli` (incl. `test/integration/`) | 178 / 1 / 0 |
  | `source_loaders` | no tests |
  | `scripts/smoke_packaged_cli.dart` | all checks pass (`windows-package-smoke.json`) |

  `tool/check_benchmark_results.dart` (also in CI's non-gating benchmarks job) confirms the committed benchmark
  results still derive the committed sizing rules; the Tachi results predate the recorded worker identity, so their
  worker version is reported, not checked.
- macOS (2026-11-21, U8 macOS lane, Apple M1 / macOS 27.0 build 26A428 / arm64, WebKit 22625.1.29.11.27,
  Amazon Corretto 21.0.13.1 from the pinned archive, Flutter 3.50.0 / Dart 3.14.0):
  - `macos-package-smoke.json`: the same smoke test on the macOS package (also: every Mach-O signature valid,
    nothing quarantined; `/usr/bin/java` recorded as the OS launcher stub).
  - `macos-tachi-two-repositories-one-worker.json` and `macos-paperback-executeinwebview-helper.json`: the CLI
    integration test with `SRT_RECEIPT_DIR` set (replayed captures; WKWebView helper offline through the content
    rules). The MangaFire outcome matches Windows (VRF capture timed out in the page).
  - Suites run on that Mac (replay only, `TACHI_JAVA_HOME` = the pinned Corretto JDK), pass / skip / fail:

    | Suite | Result |
    |---|---|
    | Gradle `--offline test installDist fixtureJar_prefs` (`tools/tachi-source-runner`) | 97 / 1 / 0 (the skip needs `node` on PATH; it passes with node: 13 / 0 / 0 for that class) |
    | `source_runtime` | 211 / 0 / 0 |
    | `source_runtime_testing` | 219 / 7 / 0 (the fake port's display / no-display interaction variants) |
    | `manga_backup_core` | 206 / 1 / 0 (presubmit-only build check) |
    | `tachi_plugin_loader` | 34 / 1 / 0 (`jre_floor_test` needs an older JRE; rerun with `TACHI_BELOW_FLOOR_JAVA_HOME` = Temurin 21.0.2: 1 / 0 / 0, the installed worker refuses 21.0.2 and starts on 21.0.13.1) |
    | `paperback_plugin_loader` (incl. e2e workers) | 145 / 0 / 0 |
    | `mangabackupconverter_cli` (incl. `test/integration/source_runner_conversion_test.dart`) | 169 / 1 / 0 (presubmit-only build check) |
    | `desktop_webview` (`--concurrency 1`, visible windows) | 80 / 8 / 0; the contract suite 54 / 1 / 0 (the no-display case). The other skips are WebView2-only cases (observe and replace tiers, request bodies, Windows file-locking wipe), each skipped after checking the engine names its reason |

    The CLI suite failed once on the way: Paperback MangaFire's `executeInWebView` hit the operation deadline on
    WKWebView instead of the page's VRF timeout. Two helper fixes followed (pending evaluations end only when a new
    document commits; hidden pages' timers are no longer throttled), and the reported counts are from the reruns
    after them.
- The evidence-publication check's failing fixtures (password, token, cookie, private title, credential URL, raw
  diagnostics, settings key, seeded marker) live under `packages/source_runtime/test/fixtures/receipts/`, never here.
