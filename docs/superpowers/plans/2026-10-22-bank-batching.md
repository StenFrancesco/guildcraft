# Bank batching implementation plan

**Goal:** One local capture and notification per event burst.
**Architecture:** Controller owns dirty sets and cancellation. Main arms one OnUpdate only while dirty. Existing capture validation remains responsible for complete snapshots.
**Tech stack:** Lua 5.1, existing mocked WoW API regression harness.

- [x] Add failing burst-count and cancellation regressions in tests/bank_memory_test.lua and integration wiring in tests/bank_integration_test.lua; use explicit FlushPending boundaries for burst tests.
- [x] Extend capturePersonal(controller, dirtyIDs) to read only validated affected containers; nil means full scan.
- [x] Add controller FlushPending and CancelPending, deduplicate queues and coalesce notifications; preserve combat and guild readiness guards.
- [x] Wire Main.lua one-shot OnUpdate scheduling and controller replacement cancellation.
- [x] Update README bank behavior; run full regressions and compile all TOC-listed Lua sources.
- [x] Review requirements and diff, resolve findings, then commit only bank changes and their documentation/tests locally.

Verification: 838 full-suite tests passed, 0 failed; 37 focused bank tests passed; 42 TOC-listed Lua files compiled; git diff --check clean. Full six-tab probe: 588 reads, 1 metadata fetch, 1 notification. Known-tab probe: 98 reads, 1 notification; untouched tab freshness preserved. Closed/cancelled/stale callbacks: 0 delayed item reads. No in-game frame-time measurement performed. Independent review found no verified defects; added combat-recovery/database-replacement regressions exposed and verified fixes.
