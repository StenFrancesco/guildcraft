# Gear Sync Repair Implementation Plan

> Execute inline with test-driven-development and verification-before-completion; request an independent review before completion.

**Goal:** Recover missing/stale gear and provide an explicit selected-character refresh.
**Architecture:** Reuse GuildSync request/election/storage and add bounded per-request lifecycle feedback. Keep display adaptation in GearBackend and the existing character browser.
**Tech Stack:** Lua 5.1, WoW addon API, existing Lua tests.

## Global constraints
- Work only in the requested gear-sync-fix checkout.
- No schema or protocol-version migration, periodic polling, or network activity on browser selection.
- Any delegated work uses gpt-6-luna at xhigh.

## Task 1: Gear sync correctness
- [x] Add failing regression tests to tests/guild_sync_test.lua and tests/gear_sync_integration_test.lua for sender variants, missing baseline recovery, sequence-gap repair, and newest snapshot selection.
- [x] Run the targeted tests and confirm failures describe the missing behaviors.
- [x] Modify The Guild Book gear/GuildSync.lua to normalize sender identities, request repair only for trusted owner updates, coalesce requests, and report bounded lifecycle states through GetGearSyncStatus(sync, targetKey).
- [x] Add lifecycle tests for send failure, expiry, cooldown, and stale responses; run targeted suites.

## Task 2: Character refresh control and display
- [x] Add failing tests in tests/snapshot_test_ui_test.lua and tests/gear_backend_test.lua for selected-character sync and committed-data refresh.
- [x] Add SyncSelectedGear(frame), RefreshVisibleGearSyncStatus(), a Sync gear button and status label in The Guild Book/SnapshotTestUI.lua. Preserve selection and tab visibility; show cached data while waiting.
- [x] Modify The Guild Book/GearBackend.lua and The Guild Book gear/Main.lua to propagate committed changes and lifecycle updates without refreshing on unrelated frames.
- [x] Run UI/backend suites; verify opening/selecting remains local-only.

## Task 3: Verify and review
- [x] Update README with repair behavior and manual control.
- [x] Run the full suite and Lua syntax checks, inspect the diff and request an independent reviewer.
- [x] Address review findings, rerun affected checks, and report exact results and multiplayer verification limits.

Validation: 633 tests passed on Lua 5.1 using a temporary runtime outside the repository. Independent review used gpt-6-luna at xhigh. Manual cooldown now matches the responder (60 seconds), newer-sequence repair uses a 5-second backoff, and missing-baseline requests retain the sequence floor from owner updates. Final syntax/diff checks are run before delivery. In-game multiplayer verification remains pending.
