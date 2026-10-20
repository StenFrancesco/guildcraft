# Inspection Gear Freshness Implementation Plan

> **For agentic workers:** Use test-driven development, independent code review, and verification before completion. Execute the coupled storage/protocol changes together; inspection integration has a separate ownership boundary.

**Goal:** Automatically save inspected guild gear with the same freshness and sharing rules as owner snapshots.
**Architecture:** Keep observation times per slot and a complete observation floor separately from owner sequence tracking. Merge complete snapshots per slot, retain newer local observations, advertise latest observation and complete floor in responder elections, and preserve metadata over the wire.
**Tech Stack:** WoW Lua 5.1, existing Lua test harness, protocol version 6.

## Global Constraints
- Work only in codex/gear-sync-fix; commit after full verification.
- Delegated agents use gpt-6-luna, xhigh; never substitute effort.
- Retain schema 7 compatibility through optional timestamp fields and legacy defaults.
- Inspect uses existing requests, verifies guild identity and GUID, and never clears another add-on's request.

### Task 1: Timestamp storage and synchronization
Files: The Guild Book gear/GearData.lua, Storage.lua, StableGearTracker.lua, SyncProtocol.lua, GuildSync.lua, Constants.lua; relevant tests.
- [x] Add failing regression tests for older high-sequence snapshots, delayed slots, mixed-age merges, timestamp round trips, fresh low-sequence election.
- [x] Run with Lua 5.1 and confirm failures before changing implementation.
- [x] Add validated optional slotObservedAt to runtime/stored gear, defaulting to capturedAt; infer the complete observation floor from its minimum. Preserve metadata when copying/rebuilding snapshots.
- [x] Add SaveObservedCharacterRecord(db, identity, snapshot) returning boolean, error. Preserve known owner sequence; clear resolved gap only when observation covers it.
- [x] Merge received snapshots per slot; keep original times and owner sequence knowledge independent. For sequence gaps, retain repair protections for observations that do not cover the update.
- [x] Record owner slot times when the equipment is actually read at stability confirmation. Never advance unchanged slot times.
- [x] Encode per-slot observation times and complete floor in protocol 6; include latest observation and floor in claims. Elect by latest observation, sequence then responder key; use floor for repair eligibility. Use freshness for cooldown bypass, request acceptance, suppression and response validation.
- [x] Run relevant and full tests; update obsolete expectations to the approved freshness semantics.

### Task 2: Inspect lifecycle
Files: The Guild Book gear/InspectGear.lua, Main.lua, The Guild Book gear.toc; tests/inspect_gear_test.lua and tests/run.lua.
- [x] Add failing inspect lifecycle tests then run them.
- [x] Implement InstallInspectGearCapture(api, db, onChanged), HandleInspectGearReady(state, guid), using SaveObservedCharacterRecord from Task 1.
- [x] Hook NotifyInspect and ClearInspectPlayer, verify public GUID and same guild, capture all tracked slots after INSPECT_READY, reject unloaded items using texture/ID/link consistency, retry a bounded number of times with GUID/token checks.
- [x] Register INSPECT_READY and install the capture after database initialization. Refresh the browser after successful save.
- [x] Cover guild-only capture, wrong GUID, target change, clear/cancel, incomplete items, empty slots, retry bounds, and manifest/event integration.

### Task 3: Review, documentation and commit
Files: README.md and relevant tests.
- [x] Document automatic inspection snapshots and protocol compatibility.
- [x] Run all tests under Lua 5.1, syntax checks, diff checks and independent review.
- [x] Resolve review findings and repeat relevant verification.
- [x] Commit all intended work on codex/gear-sync-fix and confirm clean status.

## Review refinements
- Pin inspection timestamps to the first ready event across retries.
- Elect by latest actual slot observation; advertise the oldest slot time separately for baseline repair eligibility.
- Require the latest timestamp to equal the maximum explicit slot observation time.
- Resolve unique realm spelling aliases without changing saved keys, including subsequent local tracking.
