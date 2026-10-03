# Recipe Details Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Open a Blizzard-style recipe window with materials and saved known crafters when a recipe row is clicked.

**Architecture:** A read-only RecipeDetails module normalizes exposed material data. RecipeDetailsUI owns a reusable window; SnapshotTestUI wires clicks and invalidates selections on catalog and navigation changes.

**Tech Stack:** WoW Lua 5.1, Blizzard UI templates, injected addon APIs, existing Lua tests.

## Global Constraints

Follow AGENTS.MD. No network calls, inspection, crafting, gameplay actions, context switching, background polling, or SavedVariables changes. Respect secret values and combat restrictions; show unavailable states. Use existing catalog knownBy eligibility, cached labels, and saved dates. Preserve unrelated working changes. Work in UI-window.

### Task 1: Material normalization

Files: create GuildGearMemory/RecipeDetails.lua and tests/recipe_details_test.lua; modify tests/run.lua.

Interface: `GGM.BuildRecipeMaterialDetails(api, recipeID)` returns `{state="ready"|"unavailable", message=string|nil, materials={...}}`. Each material group has `quantity`, `optional`, `name`, and `choices={{itemID=number|nil, currencyID=number|nil, name=string, icon=number|string|nil}}`. Groups preserve schematic order; choices are alternatives, not cumulative requirements.

- [x] Write failing tests calling `GGM.BuildRecipeMaterialDetails(api, 123)` and assert required quantity, optional groups, alternatives, nil/throwing/malformed API results, missing item metadata, and secret or combat rejection. Assert no context-changing or network API is called.
- [x] Run `tools/lua/lua.exe tests/run.lua`; confirm new tests fail because the reader is absent.
- [x] Implement bounded reads of `C_TradeSkillUI.GetRecipeSchematic(recipeID, false)` and exposed item metadata. Check `issecretvalue` before processing any API-provided value. Fail closed during combat and when APIs are unavailable or inconsistent. Do not persist material data. Avoid extra metadata fetching; use item-ID placeholders when names are not loaded.
- [x] Run the Lua suite and self-review data normalization against Blizzard-authored exposed API documentation.

### Task 2: Window and browser integration

Files: create GuildGearMemory/RecipeDetailsUI.lua; modify GuildGearMemory/GuildGearMemory.toc, GuildGearMemory/SnapshotTestUI.lua, tests/snapshot_test_ui_test.lua.

Interfaces: `GGM.ShowRecipeDetailsWindow(browser, recipe)` creates/updates `browser.recipeDetailsFrame`; `GGM.HideRecipeDetailsWindow(browser)` hides it; `GGM.RefreshRecipeDetailsWindow(browser)` resolves the selected recipe ID from the latest complete catalog, preserves an eligible selected crafter, or closes obsolete attribution. The reader from Task 1 supplies material groups.

- [x] Add failing UI tests to existing injectable browser fixture for clickable pooled rows, reuse on another recipe, material quantities/choices, crafter selection/saved date, refresh removal, close/Escape registration, main-window hide, tab/profession change, and zero network/database side effects.
- [x] Run the suite and confirm failures correspond to missing window behavior.
- [x] Build a named movable Blizzard-style frame with a close button, gold headings, recipe icon/name, profession label, scrollable materials, and a Blizzard dropdown populated from recipe.knownBy. If modern dropdown APIs are absent, use a familiar button and a bounded scrollable choice popup. Keep callbacks pointed at current row/window data. Selecting a crafter is display-only.
- [x] Integrate button rows and lifecycle hooks. Refresh attribution from the latest catalog without requerying materials on search/roster refresh. Close on tab/profession/main-window hide. Load both modules before SnapshotTestUI in toc and tests.
- [x] Run all Lua tests; inspect the actual template contracts and anchors for supported clients.

### Task 3: Independent review and completion

- [x] Review the combined diff against the approved design and AGENTS.MD; correct actionable findings with covering regression tests.
- [x] Run `tools/lua/lua.exe tests/run.lua`, compile each touched Lua file using `loadfile`, and run `git diff --check`.
- [x] Update this checklist and specification status, then commit only task files on UI-window. Report tests and explicitly identify in-game visual validation as pending when WoW is unavailable.
