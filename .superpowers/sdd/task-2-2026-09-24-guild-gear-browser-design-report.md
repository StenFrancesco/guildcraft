# Task 2: Searchable Guild Gear Browser

## Status

Implemented and committed as Task 2 on branch `Gear-ui`.

## Changes

- Replaced the prior saved-snapshot tab window with a reusable two-panel browser frame.
- Added a searchable alphabetized character list and a saved-gear detail panel with tracked gear icons arranged around an open center.
- Preserved search text and the selected matching character when refreshing the local entry model; the first match is selected when the previous selection is no longer available.
- Added distinct `No saved guild gear` and `No characters found` states. Empty equipment slots remain explicit and visually dimmed.
- Displayed selected character identity and the stored capture time with the label `Saved capture`, without presenting cached data as live/current.
- Updated `/ggm` to open the browser. The existing explicit `/ggm request <name-realm>` command remains as a separate feature.
- Kept Task 1's pure view-model APIs and tests. Replaced the old snapshot-renderer/show-window tests with browser interaction coverage for empty states, search retention, name/realm rows, selection and detail updates, empty slots, and absence of inspect/request/capture/write/send operations during browsing.

## Safety and scope review

Browser entries are constructed from validated local SavedVariables records. Search and selection operate on the in-memory entry list. Neither path inspects characters, requests snapshots, captures equipment, writes records, or sends addon messages. No new network behavior or data-acquisition path was added. The UI only displays values from stored records and the existing item/slot icon APIs. Missing or invalid records are excluded by the Task 1 view-model validation; saved empty slots are kept explicit.

## Checks

- `git diff --check`: passed.
- Static review: checked the browser flow against the Task 2 brief and project guardrails; confirmed old snapshot window/tab APIs were removed from the UI and slash command opens the browser.
- Lua focused and full suites: not run because no Lua runtime is available, as instructed. The user plans to test the addon at the end.

## Files

- `GuildGearMemory/SnapshotTestUI.lua`
- `tests/snapshot_test_ui_test.lua`
## Follow-up review fix

- Bound each row click handler to an iteration-local row reference, preventing WoW Lua 5.1 loop-variable closure behavior from redirecting clicks to the final row.
- Expanded interaction coverage to click both the first row and a later row and verify each selected identity.
- Lua tests remain unavailable and were not run, per instruction. `git diff --check` is the static whitespace check for this follow-up.
