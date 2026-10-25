# Guild Recipe Crafting Implementation Plan

> **For agentic workers:** Implement each task with a failing test first, then run the full Lua 5.1 suite before calling the change complete.

**Goal:** Let the logged-in character use Create and Create All from a Guild recipe detail when the live profession API confirms that character knows the recipe, while retaining Whisper crafter above those controls.

**Architecture:** Reuse the existing profession context and craft-request paths. The Guild details view checks the active profession and live recipe information before showing crafting controls; every click rechecks eligibility and quantity. Cached guild recipe ownership remains display information only.

**Tech Stack:** World of Warcraft addon Lua, existing UI helpers, Lua 5.1 tests.

**Spec:** [Issue #99](https://github.com/StenFrancesco/guildcraft/issues/99).

## Global constraints

- Preserve SavedVariables and addon communication formats.
- Craft only after a player's explicit button click, using supported game APIs.
- Fail closed when profession context, combat state, or protected API values cannot be checked.
- Keep the Own view's existing Create and Create All behavior.

## Task 1: Live self-crafting eligibility

**Files:** `The Guild Book/SnapshotTestUI.lua`, `The Guild Book/RecipeDetailsUI.lua`, `tests/snapshot_test_ui_test.lua`.

- [ ] Add a failing test: an All-view recipe known only to another character does not show crafting controls, even when its cached `knownBy` list names the player.
- [ ] Add a failing test: an All-view recipe with live `learned = true` shows Create and Create All after opening the selected profession, even when the cached list omits the player.
- [ ] Share the selected-profession context opener with the recipe detail view; validate that the open context belongs to the selected profession.
- [ ] Read the live recipe's `learned` and `craftable` flags with protected-value checks; use `learned` for visibility and `craftable` for enablement.
- [ ] Run the focused tests under Lua 5.1 and commit.

## Task 2: Combined Guild action layout and safe craft requests

**Files:** `The Guild Book/RecipeDetailsUI.lua`, `tests/snapshot_test_ui_test.lua`, `README.md` if user-facing behavior needs documentation.

- [ ] Add a failing test: Whisper crafter remains visible above Create and Create All in the All view, while the Own layout stays unchanged.
- [ ] Add failing tests for invalid amount, no materials, combat, wrong or closed profession context, stale recipe selection, protected or missing API values, and failed craft calls.
- [ ] Arrange the three buttons and their status text without overlap. Recheck context, recipe, craftability, and quantity immediately before each craft call.
- [ ] Refresh visibility and enabled state on recipe and profession changes, trade-skill updates and close, amount edits, and combat events.
- [ ] Run the focused tests and complete Lua 5.1 suite; inspect the final diff and commit.

## Verification and handoff

- [ ] Verify the PR diff and checks, and report any missing in-game verification separately.
- [ ] In game, confirm the button layout, the intended recipe and quantity, and unchanged Whisper and Own-view behavior.
