# tachi-source-runner

The desktop Tachi worker (plan unit U3, KTD1/KTD4/KTD5/KTD20/KTD25): one JVM process that hosts every
selected Tachi extension package in its own class loader and speaks worker protocol v1 on stdio
(`packages/source_runtime/doc/protocol-v1.md`). Compatibility inventory: `docs/source-runners.md`.

## Build and test

Needs Amazon Corretto 21.0.13.1 or later (`JAVA_HOME`). The wrapper downloads Gradle 9.8.1.

```bash
export JAVA_HOME="/c/Program Files/Amazon Corretto/jdk21.0.13_1"
./gradlew test          # JVM tests; replay committed captures, never contact a server
./gradlew installDist   # build/install/tachi-source-runner/{bin,lib,tachi-runtime.json}
```

After changing dependencies: `./gradlew resolveAll --write-locks` (updates `gradle.lockfile`), and
update `THIRD_PARTY.md`.

## Run

```text
tachi-source-runner [--replay CAPTURE_DIR]... [--state-dir DIR] [--limit NAME=VALUE]... [--no-browser]
```

- The worker speaks protocol 1.2 (`protocolMinor` = the lower of the supervisor's offer and 2). 1.2
  browser features (page-start scripts, request interception) are used only when negotiated and only as
  far as the session's reported capabilities allow; see `docs/source-runners.md` › Browser translation.
- Trusted signers come only from each `artifact.prepare` request's `trustedSigners` (KTD5): an absent or
  empty list is refused as `artifact-incompatible`. There is no command-line trust list.
- Settings: package-wide `values`/`secrets` seed every `SharedPreferences` store; `sources.<id>` overrides
  them in that source's `source_<id>` store. Array values are string sets (`getStringSet`). Keys are plain;
  the former `storeName/key` convention is gone.

- Limits come from `src/main/resources/tachi-worker-sizing.json` (the KTD25 rule); `--limit` overrides
  `poolSize`, `operationDeadlineMs`, `cancelGraceMs`, `interactionTimeoutMs`, `shutdownGraceMs`.
- Handshake deadline: `installDist` writes `tachi-runtime.json` (`format`, `worker`, `classpath: "lib"`,
  `mainClass`, `handshakeDeadlineMs`) at the install root from the committed rule
  (`ceil(maxStartupToHandshakeMs × handshakeFactor)`; the `runtimeManifest` task). Point the CLI at it
  with `--tachi-runtime build/install/tachi-source-runner/tachi-runtime.json`. The handshake repeats the
  value in `limits`/`sizing` for receipts; the supervisor cannot take it from there.
- APK preparation is byte-deterministic: the same APK gives the same prepared SHA-256 in one JVM and
  across restarts (`DeterministicConversionTest`).
- `--replay` serves only committed captures through a loopback transport; an uncaptured request gets a
  599. The handshake reports `networkMode`.

## Layout

| Path | Contents |
|---|---|
| `src/main/java/android*/` | Android API shims (only the surface the hosted extensions use) |
| `src/main/kotlin/host/tachiyomi/` | Mihon source API and network extraction (Apache-2.0, see `THIRD_PARTY.md`) |
| `src/main/kotlin/protocol/` | protocol v1 framing, the worker, a test/benchmark client |
| `src/main/kotlin/extensions/` | artifact verification, dex2jar conversion and fixes, class loading, source operations |
| `src/main/kotlin/host/` | per-package environment, preferences, cookies, DI, main looper dispatcher, sizing, replay |
| `src/main/kotlin/webkit/` | KTD20 `android.webkit` translation over `host.browser.*` |
| `src/fixtureExt*`, `src/fixtureCommon` | small fixture extensions for tests |
| `src/capture/` | manual one-time capture tool (`./gradlew capture`), never run by tests |
| `benchmark/` | KTD25 benchmark (`./gradlew benchmark`, runs `installDist` first to time start-up of the install); results in `docs/validation/source-runners/desktop/` |

## Captures

`./gradlew capture -PcaptureArgs="record <mangadex|weebcentral|mangafire> <rawDir>"` records once (≥1.5 s
between requests, no retries, JAR path, APK path replayed against the recording), then
`-PcaptureArgs="finalize <source> <rawDir> <repo>/fixtures/source_captures/tachi/<dir>"` applies the
documented body edits, recomputes digests and writes the committed capture.
