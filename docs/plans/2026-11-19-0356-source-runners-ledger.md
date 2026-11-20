# Source runners build ledger

Plan: `docs/plans/2026-11-19-0356-feat-paperback-tachi-source-runners-plan.md`.
Integration branch: `feat/source-runners` (pushed and opened as one PR only at the end).
Parent: coordination and acceptance only. One integration subagent owns merges, conflicts, shared generation, and combined checks.

## Run settings

- Children: Claude Opus 5.5, medium effort, standard speed, `isolation: worktree`, local commits on their own branch, no pushes or PRs.
- Review boundaries: milestone completion (M1, M2, M3), each with a maintainability review and a separate security review.
- Maintainability reviews place a strong focus on where abstraction techniques apply: duplicated logic across the three ecosystems and three platforms that a shared interface, base type, adapter, or data-driven policy could replace (user request).
- Tests never contact a server; captures are recorded once by `tool/capture_source_fixtures.dart` and committed.
- Desktop Java: Amazon Corretto 21.0.13.1 at `C:\Program Files\Amazon Corretto\jdk21.0.13_1`.
- Devices: local Android emulator `Pixel_9_Pro` and `boolean-mac-mini` simulators through T3 device tools; physical devices later.
- Concurrency: no verified active-agent cap is exposed; keep at most 4 children running.

## Units

| Unit | Owner / task | Branch | Owned paths | Depends on | Status | Evidence | Next |
|---|---|---|---|---|---|---|---|
| U19 | delegated (fcc30b22), done | feat/source-runners-u19 @ c87e646 (base a4e3fea) | CLI pipeline, Paperback format, reconciler, dashboard and convert-command fallbacks | — | accepted pending 3.50 re-run | 20 behavioral RED→green; 249 pass/1 skip on fvm Flutter 3.47.5 (3.50 pub resolve blocked by custom_lint ^0.8.0) | integrate; re-run on 3.50 after U1-T; carry unresolved-library-link reporting to U1 step 5 (KTD8); CLAUDE.md dashboard note stale |
| U1-C | delegated (20407c50) | feat/source-runners-u1c | `packages/source_runtime/`, Aidoku adapter, capture contract, Aidoku test replay | — | running | — | await handoff |
| U1-T | delegated (06865e22), done | feat/source-runners-u1t @ eb06faa (base a4e3fea) | CI pins, SDK constraints, lint config, iOS target 15.0, CLAUDE.md | — | accepted (partial: native Android/macOS not migrated) | fmt/analyze clean; tests pass on 3.50 (CLI 198/1 skip, aidoku 295/1 skip minus 2 live files) | custom_lint dropped, solid_lints 2.0 plugins, 18 rules disabled as recorded debt; 55cb274+eb06faa must land together |
| U1-T Android/macOS | delegated (82a02941) | feat/source-runners-u1t-android (from eb06faa) | `android/`, `macos/` | U1-T | running | — | Gradle 9.3.1/AGP 9.1.1/Kotlin 2.4.10, minSdk 24, macOS 12.0 |
| U1 (steps 3-6) | — | — | `packages/manga_backup_core/`, CLI compatibility | U19, U1-C | planned | — | after U19 |
| U2, U3, U5 | — | — | per plan | U1-C | planned | — | after U1-C |
| U16, U17 | — | — | per plan | U1-T | planned | — | after U1-T |
| U4, U6, U7, U8, U11-U15, U9, U10, U18 | — | — | per plan | per plan | planned | — | later waves |

## Worktrees and branches created by this run

| Path / branch | Created for | Status |
|---|---|---|
| `feat/source-runners` | integration branch | active |
| `t3-bbd1df6a` / `feat/source-runners-u19` | U19 | done, awaiting integration |
| `t3-f4af05a3` / `feat/source-runners-u1c` | U1-C | running |
| `t3-e1ce9b79` / `feat/source-runners-u1t` | U1-T | done, awaiting integration |
