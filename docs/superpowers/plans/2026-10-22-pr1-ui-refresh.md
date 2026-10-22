# PR1 UI Refresh Implementation Plan

> **For agentic workers:** Execute the approved plan in this session and request an independent review before committing.

**Goal:** Eliminate hidden, duplicate and unrelated catalog rendering.

**Architecture:** Keep dirty state on the browser frame. Queue one visible refresh per event burst, and let opening/tab selection consume dirty state synchronously. Keep opening separate from targeted character refresh.

**Tech Stack:** WoW Lua 5.1, existing mock UI regression suite.

## Global constraints

Preserve SavedVariables and selected baseline protocols/codecs. Keep all changes local. Preserve search, stable selection and scroll; Own remains the reopening default. Opening/selecting Characters sends no gear request.

## Tasks

- [x] Add failing operation-count tests in tests/snapshot_test_ui_test.lua for hidden/inactive events, single opening builds, queued refresh bursts, hide-before-flush, and isolated gear refreshes. Use actual browser functions and count catalog construction and bank refreshes. Record latest saved values and assert preserved search/selection/scroll.
- [x] In The Guild Book/SnapshotTestUI.lua, centralize visible profession flushing, retain dirty state, queue repeated invalidations via the existing timer API, and consume dirty state when opening/entering Professions. Remove duplicate catalog builders and unrelated profession-library work from character list rendering. Update older profession fixtures to explicitly select the visible profession page.
- [x] Replace the general opening call in RefreshVisibleGuildGearBrowser with a targeted character-data invalidation/flush. Rebind selected entries by key to new saved records, and preserve viewport positions. Gear events remain routed through the existing GearBackend adapter.
- [x] Update README.md with deferred/coalesced rendering behavior. Run lua tests/run.lua, compile all TOC Lua files, and run git diff --check. Record before/after operation counts.
- [x] Request gpt-6-luna independent review, address actionable findings, and make one local commit containing implementation, tests and documentation. Verify the commit while preserving unrelated concurrent bank edits.

Validation: eight PR1 regressions fail on the original implementation; 823 tests pass in the isolated PR1 snapshot; 42 TOC Lua sources compile. Independent review finding addressed. See ../../pr1-ui-refresh-validation.md for operation counts and the shared-worktree bank-test caveat.
