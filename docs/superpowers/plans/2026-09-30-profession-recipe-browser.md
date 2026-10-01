# Profession Recipe Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Populate the existing Professions page with a searchable, deduplicated catalog of cached recipes known by currently confirmed guild members.

**Architecture:** Add a side-effect-free catalog builder beside the existing profession index logic. It will require current roster confirmation, read validated saved snapshots for active registered members, and key profession matching by `professionID`. The existing Professions page will render that model, filter it locally by recipe name, and show explicit empty, unavailable, or incomplete states.

**Tech Stack:** World of Warcraft addon Lua, SavedVariables, existing WoW UI frames, Lua test harness.

**Spec:** `docs/superpowers/specs/2026-09-30-profession-recipe-browser-design.md`

**Handoff:** The plan and spec are currently ignored in the Windows checkout by the `/Docs/` ignore rule. Before implementation, ensure both files travel with the branch; stage these exact files with `git add -f` or correct the ignore rule without discarding existing `.gitignore` edits.

## Global Constraints

- Use only functionality intentionally exposed through the in-game addon/Lua environment.
- Do not bypass Blizzard restrictions or obtain game data outside permitted addon APIs and SavedVariables.
- Current recipe knowledge must not be represented as live; show cached/last-known labels and saved dates.
- Current-member attribution requires confirmed current guild roster membership.
- Do not add UI-triggered or recurring guild traffic, profession inspection, or addon messages.
- Do not change the SavedVariables schema or synchronization protocol.
- Catalog construction, profession selection, tab entry, and search must not mutate SavedVariables or invoke index repair/rebuild helpers.
- If ownership, membership, or data completeness is uncertain, show unavailable/incomplete state instead of guessing.

## Review Focus

- Roster freshness is false when the page opens: the model returns unavailable and attributes no rows to current members; cover in Task 1.
- A character has a valid empty snapshot versus no snapshot versus a malformed-only candidate: the model distinguishes all three; cover in Task 1.
- Multiple current characters share a recipe ID: render one recipe and all owners with their own dates; a zero/invalid capture timestamp displays “Date unavailable”; cover in Task 1.
- Inactive/former guild members, malformed identities/snapshots, or registry repair exist in SavedVariables: exclude or flag them without false current attribution; cover in Task 1.
- Search text varies in case or has no matches: filtering remains case-insensitive and the empty search state is clear; cover in Task 2.

---

### Task 1: Build the current-guild profession recipe catalog

**Files:**
- Modify: `GuildGearMemory/ProfessionIndex.lua`
- Test: `tests/profession_index_test.lua`
- Track with this task's first commit: this plan and `docs/superpowers/specs/2026-09-30-profession-recipe-browser-design.md` (both are ignored locally; use `git add -f` for these exact paths if the ignore rule has not been corrected).

**Interfaces:**
- Produces `GGM.BuildProfessionRecipeCatalog(db, professionID, professionLabel, api) -> model`; `professionID` selects data and `professionLabel` is display-only text for status messages.
- `model` contains `state` (`ready`, `empty`, `incomplete`, or `unavailable`), `hasSnapshot`, `recipes`, and `message`. `hasSnapshot` is `true` when a raw slot for this `professionID` exists (even if malformed), `false` only after a complete trusted scan proves no such slot exists, and `nil` when membership or record shape prevents determining that.
- Each recipe row contains `recipeID`, `name`, and `knownBy`; each owner contains `key`, `name`, `realm`, `capturedAt`, and formatted `savedDate`.
- `api.date("%Y-%m-%d", capturedAt)` formats positive timestamps; zero timestamps or unavailable formatting use `savedDate = "Date unavailable"`.
- Apply this state precedence: (1) `unavailable` with no attributed rows if roster confirmation or canonical member ownership is untrusted; (2) `incomplete` if membership is trusted but a relevant snapshot/container is malformed or recipe names conflict, retaining only safe rows; (3) `empty` with `hasSnapshot=false` only when a complete trusted scan finds no selected-profession snapshot; (4) `empty` with `hasSnapshot=true` when valid selected-profession snapshots contain zero recipes; (5) `ready` when valid rows exist and no relevant uncertainty exists. A malformed-only candidate is `incomplete`, has no rows, and must never use the no-snapshot message.
- Status messages are explicit: roster-unconfirmed is “Current guild membership could not be confirmed.”; no snapshot is “No saved <profession> snapshots for current guild members.”; a valid empty snapshot is “Saved <profession> snapshots contain no learned recipes.”; incomplete data is “Some saved profession data is incomplete.”

- [ ] **Step 1: Add failing catalog tests**

Add tests proving the catalog selects by `professionID` even when saved `professionName` values are localized, combines duplicate recipe IDs across active guild characters, preserves each owner's capture date, uses “Date unavailable” for timestamp zero, sorts recipe and owner rows deterministically, and excludes inactive characters. Cover no snapshot (`empty`, `hasSnapshot=false`), valid zero-recipe snapshot (`empty`, `hasSnapshot=true`), malformed-only selected-profession snapshot (`incomplete`, no rows, `hasSnapshot=true`), and malformed snapshot container (`incomplete`, `hasSnapshot=nil` when presence cannot be established). Also cover unconfirmed roster and registry/canonical identity ambiguity (`unavailable`, no attributed rows), safely attributable rows alongside malformed data (`incomplete`), and conflicting recipe names. Deep-copy the database before catalog construction and assert that neither successful nor failure-path calls mutate it.

- [ ] **Step 2: Run the suite and confirm the new tests fail for the missing catalog behavior**

Run: `lua tests/run.lua` from `guildcraft`.  
Expected: existing tests pass and the new catalog tests fail because `GGM.BuildProfessionRecipeCatalog` is not implemented.

- [ ] **Step 3: Implement `GGM.BuildProfessionRecipeCatalog` in `GuildGearMemory/ProfessionIndex.lua`**

Require `GGM.professionRosterMembershipCurrent == true`. Walk the existing registry and canonical records using side-effect-free checks, then derive rows from individually validated snapshots on active members; match the selected profession by `professionID` and use `professionLabel` only in display messages. Do not call `GGM.EnsureProfessionIndex` (it can initialize or rebuild SavedVariables) or `GGM.ValidateProfessionIndexCache` (its validation path writes `professionIndexDataIncomplete`). If registry repair or canonical identity conflicts make member attribution uncertain, return `unavailable`, `hasSnapshot=nil`, and no rows. A malformed selected-profession snapshot with trustworthy ownership sets `incomplete`; retain unrelated safe rows, and return an empty recipe list rather than claiming no snapshot when the malformed candidate is the only one. Group by `recipeID`, choose the display name from the newest snapshot (mark conflicting names incomplete; use character key for ties), sort recipe and owner rows deterministically, and attach each owner's capture date. Treat timestamp zero or unavailable date formatting as “Date unavailable.”

- [ ] **Step 4: Run `lua tests/run.lua` and confirm the catalog tests pass**

Expected: all existing and new tests pass.

- [ ] **Step 5: Commit the catalog model and tests**

```bash
git add GuildGearMemory/ProfessionIndex.lua tests/profession_index_test.lua
git add -f docs/superpowers/plans/2026-09-30-profession-recipe-browser.md docs/superpowers/specs/2026-09-30-profession-recipe-browser-design.md
git commit -m "feat: build cached profession recipe catalog"
```

### Task 2: Render and search recipes on the Professions page

**Files:**
- Modify: `GuildGearMemory/SnapshotTestUI.lua`
- Test: `tests/snapshot_test_ui_test.lua`

**Interfaces:**
- Consumes `GGM.BuildProfessionRecipeCatalog(db, professionID, professionLabel, api)` from Task 1.
- Produces `GGM.FilterProfessionRecipeBrowserEntries(entries, query) -> filteredEntries`, preserving the input's deterministic order and matching recipe names case-insensitively.
- Each sidebar entry contains `key`, `professionID`, and `icon`: Alchemy `171`, Blacksmithing `164`, Enchanting `333`, Engineering `202`, Leatherworking `165`, and Tailoring `197`. The key/label is presentation metadata; catalog matching uses the ID.
- `GGM.SelectProfession(frame, selectedKey)` updates selection and, when `frame.db` exists, refreshes the local model using `frame.db` and `frame.api`; changing professions clears the search field. Initial visual selection during frame construction must defer catalog work until `frame.db` is assigned.

- [ ] **Step 1: Add failing UI/model-filter tests**

Load `Constants.lua`, `CharacterIdentity.lua`, `GearSnapshot.lua`, `ProfessionSnapshot.lua`, `ProfessionIndex.lua`, `Storage.lua`, `SavedCharacterModel.lua`, and `SnapshotTestUI.lua` in TOC order (or explicitly stub the builder in tests that do not exercise it). Test that construction before `frame.db` assignment does not call the builder or error; showing the window after assigning a database and selecting each profession builds the matching ID catalog. Test that search keystrokes only filter the existing model, changing profession clears the query, and returning to the Professions tab locally refreshes from SavedVariables. Verify the database remains unchanged across open/select/search/tab-entry, and that no roster, profession, or addon-message API is called. Cover all catalog messages plus no-match behavior: unavailable/empty/incomplete base states take precedence when there are no safe recipes, while a no-match message appears only when a non-empty catalog is filtered to zero rows. Verify each displayed owner line includes that owner's saved date.

- [ ] **Step 2: Run the suite and confirm the new tests fail for the missing UI behavior**

Run: `lua tests/run.lua` from `guildcraft`.  
Expected: existing tests pass and the new profession-page tests fail because the page still contains its placeholder and has no recipe search.

- [ ] **Step 3: Replace the profession placeholder with the searchable recipe view**

In `createProfessionsPage`, add a profession recipe search box, status/count text, and a scrollable results area styled with existing UI helpers. Render one recipe entry and its `known by` character names/dates per catalog row. Update `GGM.SelectProfession` to refresh the model and filtered display; reset the query when another profession is selected. Keep construction-time selection visual-only while `frame.db` is nil. In `GGM.ShowGuildGearBrowserWindow`, assign `frame.db` before refreshing the selected profession. When `GGM.SelectGuildGearBrowserTab` makes Professions visible, rebuild the local model and reapply the existing query. Search keystrokes only filter the already-built model. Do not add profession API calls or network behavior.

- [ ] **Step 4: Run `lua tests/run.lua` and confirm the profession page tests pass**

Expected: all existing and new tests pass with no errors.

- [ ] **Step 5: Commit the Professions page and tests**

```bash
git add GuildGearMemory/SnapshotTestUI.lua tests/snapshot_test_ui_test.lua
git commit -m "feat: display cached profession recipes"
```
