# Profession Recipe Browser Design

**Status:** Draft for written review  
**Date:** 2026-09-30

## Goal

When a user selects a profession on the existing Professions page, show the recipes recorded for that profession in SavedVariables. The list combines duplicate recipe IDs and shows which currently confirmed guild members have a saved snapshot containing each recipe.

## Current project context

- `SnapshotTestUI.lua` already provides six profession buttons: Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, and Tailoring. Selecting one currently changes the heading and icon while leaving a placeholder in the detail panel.
- Profession snapshots are stored at `db.professions[characterKey].snapshots[professionID]`. Each validated snapshot contains `professionID`, localized `professionName`, `capturedAt`, cached status, and learned recipes with `recipeID` and `name`. `professionID` is the data key; `professionName` is display metadata and must not be used to select snapshots.
- The SavedVariables database also has a profession character registry and recipe membership index. The registry's active membership is reconciled from the current guild roster, and recipe lookups require `GGM.professionRosterMembershipCurrent` to be true.

The existing sidebar's profession IDs are Alchemy `171`, Blacksmithing `164`, Enchanting `333`, Engineering `202`, Leatherworking `165`, and Tailoring `197`.

## User-facing behavior

1. Selecting any profession already shown in the sidebar refreshes the detail panel for that profession.
2. The panel shows one row per recipe ID, sorted alphabetically by recipe name. Each row identifies the saved guild characters whose snapshots contain the recipe and the date of each character's snapshot.
3. A profession-name search filters the selected profession's recipes using a case-insensitive substring match. Selecting another profession clears the search.
4. The panel labels recipe knowledge as cached/last-known. A saved date describes when the snapshot was captured; it does not claim the recipe is still known now.
5. If the current guild roster has not been confirmed, the panel shows an unavailable message and does not list characters as current guild members.
6. If a selected-profession snapshot is malformed or duplicate recipe IDs have conflicting names, show valid rows that remain safely attributable and mark the list incomplete. A malformed-only candidate is incomplete with no rows; never describe it as no snapshot. If registry repair or canonical identity conflicts make member attribution uncertain, show unavailable with no attributed rows.
7. Distinguish no snapshot from a valid snapshot containing zero learned recipes. Both states receive clear empty messages. No snapshot may be reported only after a complete, trusted scan proves there is no selected-profession snapshot.
8. Opening the window, selecting a profession, entering the Professions tab, and searching read local SavedVariables only. These actions do not repair or rebuild the index, mutate SavedVariables, query the guild roster, inspect a profession, or send addon messages.

When a snapshot has `capturedAt == 0` or its date cannot be formatted, display “Date unavailable” rather than formatting the sentinel as a real date.

## Data flow and boundaries

The display reads validated profession snapshots and the existing roster-confirmed character registry. It derives recipe rows from the snapshots rather than invoking an index repair/rebuild path. Recipe identity comes from `recipeID`; profession matching uses `professionID`; recipe names and capture times come from the matching saved snapshots. `professionName` is display metadata only because snapshots may have been captured on clients using different languages. Duplicate recipe IDs appear once, with one `known by` entry per current guild character. When duplicate snapshots contain different names for one recipe ID, use the most recently captured name and mark the list incomplete; ties are resolved by character key for deterministic output. Sort recipe names case-insensitively, then by recipe ID; sort owners case-insensitively by name, then realm, then key.

Catalog construction is read-only. Do not call `GGM.EnsureProfessionIndex` or `GGM.ValidateProfessionIndexCache`: the former may initialize/rebuild SavedVariables, and the latter's current validation path writes `professionIndexDataIncomplete`. Use side-effect-free structural and canonical-identity checks and validate snapshots individually. The catalog builder must leave the database unchanged on success and failure paths.

The roster freshness gate is mandatory. The profession page must not request a new guild roster, inspect professions, query live recipe knowledge, or send addon messages. Existing roster refresh behavior in `Main.lua` remains the only source of current-membership confirmation. No SavedVariables schema or synchronization protocol changes are required.

## Empty and error states

- **Unavailable, roster unconfirmed:** show “Current guild membership could not be confirmed.”, no member-attributed rows, and `hasSnapshot = nil` (unknown).
- **Unavailable, member attribution ambiguous:** if registry repair or canonical identity conflicts prevent trusting current-member ownership, show no rows and `hasSnapshot = nil`.
- **Incomplete, malformed or conflicting data:** when membership is trusted but selected-profession snapshot data is malformed or recipe names conflict, show safely attributable valid rows plus “Some saved profession data is incomplete.” A malformed-only selected-profession candidate is still incomplete with zero rows and `hasSnapshot = true`. If a malformed snapshots container prevents determining whether a candidate exists, use `hasSnapshot = nil` and do not claim no snapshot.
- **Empty, no saved snapshot:** only after a complete trusted scan finds no candidate at the selected `professionID`, set `hasSnapshot = false` and show “No saved <profession> snapshots for current guild members.”
- **Empty, snapshot with no learned recipes:** if one or more validated selected-profession snapshots exist and all contain zero learned recipes, set `hasSnapshot = true` and show “Saved <profession> snapshots contain no learned recipes.”
- **Ready:** show valid non-empty recipe rows when there is no relevant uncertainty.
- **Search with no matches:** show “No recipes match this search.” only when the underlying catalog has recipes and the local filter returns none. Preserve any incomplete-data notice; unavailable and base empty states take precedence over a search message. Retain the current profession and search query.

`hasSnapshot` is tri-state: `true` means a raw candidate at the selected profession slot exists, including a malformed candidate; `false` means a complete trusted scan proved no candidate exists; `nil` means membership or record structure prevents determining presence.

## Global constraints

- Use only functionality intentionally exposed through the in-game addon/Lua environment.
- Do not bypass Blizzard restrictions or obtain game data outside permitted addon APIs and SavedVariables.
- Current recipe knowledge must not be represented as live; show cached/last-known labels and saved dates.
- Current-member attribution requires confirmed current guild roster membership.
- Do not add UI-triggered or recurring guild traffic, profession inspection, or addon messages.
- Do not change the SavedVariables schema or synchronization protocol.
- If ownership, membership, or data completeness is uncertain, show unavailable/incomplete state instead of guessing.

## Acceptance criteria

- Clicking each existing profession button displays only recipes belonging to that profession.
- Profession matching uses each sidebar entry's `professionID`, including when the saved `professionName` is localized differently.
- The same recipe ID saved by multiple current guild characters appears once and lists each character with that character's snapshot date.
- Inactive/former-guild entries are excluded, and no character is attributed while roster membership is unconfirmed.
- Search filters only the selected profession's recipe names and is case-insensitive.
- Recipe rows are alphabetically sorted with deterministic tie-breaking.
- Empty, unavailable, and incomplete states are explicit and do not imply live/current recipe knowledge.
- Malformed-only selected-profession data produces an incomplete state with no rows, never a no-snapshot state.
- Catalog and UI refresh/search paths do not mutate SavedVariables; search does not rebuild the catalog.
- Returning to the Professions tab refreshes the local catalog without querying the guild or sending addon messages.
- The change adds no periodic or UI-triggered guild traffic, no live profession query, and no schema migration.

## Scope exclusions

- Adding professions beyond the six currently shown in the sidebar.
- Capturing, refreshing, or synchronizing profession snapshots.
- Recipe tooltips, crafting actions, shopping lists, or other recipe workflows.
- Changes to guild roster refresh timing, SavedVariables schema, or addon-message behavior.
