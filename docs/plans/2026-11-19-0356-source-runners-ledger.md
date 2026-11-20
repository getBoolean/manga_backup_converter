# Source runners build ledger

Plan: `docs/plans/2026-11-19-0356-feat-paperback-tachi-source-runners-plan.md`.
Integration branch: `feat/source-runners` (pushed and opened as one PR only at the end).
Parent: coordination and acceptance only. One integration subagent owns merges, conflicts, shared generation, and combined checks.

## Run settings

- Children: Claude Opus 5.5, medium effort, standard speed, `isolation: worktree`, local commits on their own branch, no pushes or PRs.
- Review boundaries: milestone completion (M1, M2, M3), each with a maintainability review and a separate security review.
- Tests never contact a server; captures are recorded once by `tool/capture_source_fixtures.dart` and committed.
- Desktop Java: Amazon Corretto 21.0.13.1 at `C:\Program Files\Amazon Corretto\jdk21.0.13_1`.
- Devices: local Android emulator `Pixel_9_Pro` and `boolean-mac-mini` simulators through T3 device tools; physical devices later.
- Concurrency: no verified active-agent cap is exposed; keep at most 4 children running.

## Units

| Unit | Owner / task | Branch | Owned paths | Depends on | Status | Evidence | Next |
|---|---|---|---|---|---|---|---|
| U19 | — | — | CLI pipeline, Paperback format, reconciler, dashboard and convert-command fallbacks | — | planned | — | dispatch |
| U1-C | — | — | `packages/source_runtime/`, Aidoku adapter, capture contract, Aidoku test replay | — | planned | — | dispatch |
| U1-T | — | — | CI Flutter pin, SDK constraints, `CLAUDE.md`, iOS deployment target | — | planned | — | dispatch |
| U1 (steps 3-6) | — | — | `packages/manga_backup_core/`, CLI compatibility | U19, U1-C | planned | — | after U19 |
| U2, U3, U5 | — | — | per plan | U1-C | planned | — | after U1-C |
| U16, U17 | — | — | per plan | U1-T | planned | — | after U1-T |
| U4, U6, U7, U8, U11-U15, U9, U10, U18 | — | — | per plan | per plan | planned | — | later waves |

## Worktrees and branches created by this run

| Path / branch | Created for | Status |
|---|---|---|
| `feat/source-runners` | integration branch | active |
