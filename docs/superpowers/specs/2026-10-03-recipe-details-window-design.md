# Recipe details window

Date: 2026-10-03
Branch: UI-window
Status: Approved design implemented; in-game visual validation pending.

## Goal

Clicking a recipe in the Professions browser opens a separate, reusable Blizzard-style window showing recipe details, crafting materials, and a dropdown of characters whose saved profession records contain the recipe.

## Window and interaction

- Use Blizzard frame styling, gold headings, familiar fonts, an item icon, and a close button. The window is movable and closes with Escape.
- Show the recipe name and selected profession above the materials section.
- Clicking another recipe updates the same window. Clicking a pooled browser row always opens its currently assigned recipe.
- Use a scrollable materials list so long recipes remain usable. Each material displays its icon, name, and required quantity. Identify optional materials and alternative quality choices without implying all alternatives are required.
- The crafter dropdown lists the existing catalog's eligible knownBy characters, using name and realm. Selecting a character displays that character's saved date and a last-known recipe knowledge label. Selection is informational and does not initiate crafting or contact the character.
- Preserve a selected crafter across refresh when still eligible; otherwise select the first eligible entry. Show an explicit empty state when none are safely attributable.
- Refresh the selected recipe from the current catalog when profession data changes. Close the details window when switching professions, leaving the Professions tab, or closing the main browser. Invalidate obsolete recipe/crafter attribution rather than continuing to display it.

## Data and safety

Recipe identity, name, icon, and crafters come from the existing read-only profession catalog. Its current guild and local-character eligibility rules remain authoritative; do not add a second ownership lookup or bypass roster uncertainty. Crafter knowledge remains explicitly cached.

Materials may be read only through normal Blizzard-exposed profession and item APIs. Before introducing these calls, verify their exposed contract against Blizzard-provided API documentation and assess them against AGENTS.MD and current official policy sources. Use only safely processable values. Respect combat, secret-value, API availability, and profession-context restrictions; report materials unavailable when the permitted context cannot supply them. Do not open another player's profession, change trade-skill context, send addon messages, or request guild information to populate this window.

Material access runs only for a user-selected recipe in an allowed context. No periodic polling, retries, background database enrichment, new communication, SavedVariables schema changes, or profession synchronization are introduced. If item metadata is loading, show a clear placeholder and use a bounded event-driven update for the visible selection if needed; never retain data from a previously selected recipe.

## Implementation boundaries

Keep recipe-detail data normalization and window creation in a dedicated addon module loaded before SnapshotTestUI.lua. Integrate browser-row click handlers and window lifecycle into the existing UI. Reuse current injected API conventions for testability and existing catalog refresh hooks for attribution changes.

## Verification

Add focused tests for row selection, updating an existing window, sorted/eligible crafter choices, saved-date labels, empty or unavailable material states, required quantities and optional/alternative materials, invalid or restricted API results, selection changes, and close/refresh behavior. Confirm opening/selecting details causes no addon communication or database writes. Run the existing Lua suite and syntax checks. Verify in-game rendering when an actual WoW session is available; otherwise state that visual verification remains manual.

Automated result: 351 tests pass; all six changed Lua files parse with Lua 5.1; diff whitespace checks pass. Native dropdown selection/refresh and long material rows have focused regression coverage. Large crafter lists use a scrollable choice popup so every eligible owner remains reachable. See `Docs/Recipe-Details-Validation.md` for the policy sources and in-game checklist.

## Scope

No craft button, whisper workflow, shopping list, gameplay automation, live crafter availability claim, additional data acquisition path, or unrelated UI refactor.
