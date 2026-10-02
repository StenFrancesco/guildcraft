# Local Alt and Guild Profession Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show saved profession recipes for locally owned characters and confirmed current guild members, retain local characters across guild departure, and purge departed non-local guild data only after a complete authoritative roster result.

**Architecture:** Add a GUID-keyed `localCharacterGUIDs` ownership allowlist to SavedVariables and migrate schema 5 to schema 6 without guessing ownership from names. Record the player's GUID synchronously on `PLAYER_LOGIN`, keep profession capture manual, and reuse the existing profession registry/recipe index by changing catalog eligibility from `active == true` to `local GUID OR (confirmed roster AND active)`. Extend the existing roster reconciliation so a complete result removes absent non-local gear/profession records and their recipe-index references, while incomplete or failed roster checks remain non-destructive. The recipe-index format itself remains version 3 because it already stores inactive crafters and its on-disk shape does not change.

**Tech Stack:** World of Warcraft addon Lua 5.1, SavedVariables, WoW guild-roster APIs, existing profession recipe index, existing Lua test harness, GitHub Actions Lua 5.1 syntax/test workflow.

**Spec:** `docs/superpowers/specs/2026-10-01-local-alt-profession-visibility-design.md`

**Base revision reviewed:** `main` at `10e88c719f5e8dedd86ef0a6d0f17db0e3b4ecab` (`feat: browse cached profession recipes`).

**Plan path:** `docs/superpowers/plans/2026-10-01-local-alt-profession-visibility.md`

**Repository note:** `.gitignore` contains `/Docs/`, so on a case-insensitive checkout the plan/spec may require `git add -f` exactly as the prior profession-browser plan did. Do not change unrelated ignore rules as part of this feature.

---

## File Structure

### Production files to modify

- `GuildGearMemory/Constants.lua:3-11`
  - Bump `GGM.SCHEMA_VERSION` from 5 to 6.
  - Keep `GGM.PROFESSION_RECIPE_INDEX_VERSION = 3`; the recipe-index representation does not change.

- `GuildGearMemory/ProfessionIndex.lua:416-509, 779-944, 984-1185`
  - Allow `GGM.EnsureProfessionIndex` to validate a specific schema version during the one-step migration.
  - Add non-destructive local-ownership validation used by roster reconciliation and catalog construction.
  - Remove departed non-local registry/index/profession data after a complete roster result.
  - Expand recipe-catalog eligibility to locally owned GUIDs plus confirmed current guild members.
  - Keep recipe rows deduplicated by `recipeID` and owner rendering metadata unchanged.

- `GuildGearMemory/Storage.lua:181-245`
  - Add `localCharacterGUIDs` on first-run databases.
  - Add deterministic schema-5-to-6 migration seeded only from legacy local keys that resolve to stored identities with matching valid GUIDs; keep unresolved legacy keys as retention-only markers.
  - Add `GGM.MarkLocalCharacterGUID` and `GGM.IsLocalCharacterGUID`.
  - Keep the legacy key-based `localCharacters` set for the existing gear-browser “Mine” behavior.

- `GuildGearMemory/LocalGearMemory.lua:1-18, 74-123`
  - Add a small login ownership helper that reads only `UnitGUID("player")` and writes the GUID ownership marker.
  - Do not capture gear or professions from this helper.
  - Leave the existing key-based marker in `StartLocalPlayerGearTracking` intact.

- `GuildGearMemory/Main.lua:99-126`
  - Call the new GUID ownership helper synchronously on `PLAYER_LOGIN` before the delayed gear-tracker startup.
  - Treat ownership-recording errors as non-fatal to existing gear tracking.

### Test files to modify

- `tests/storage_test.lua`
  - Schema 6 creation/migration tests.
  - GUID ownership helper tests.
  - Verify profession saves do not infer local ownership.

- `tests/local_gear_memory_test.lua`
  - Verify login ownership uses only `UnitGUID`, creates no profession snapshot, and is independent of gear-capture success.

- `tests/main_test.lua`
  - Verify `PLAYER_LOGIN` records ownership synchronously and still defers gear tracking.

- `tests/profession_index_test.lua`
  - Roster purge/retention tests.
  - Local-vs-guild catalog eligibility tests.
  - Failed/incomplete roster non-deletion tests.
  - Update schema-5 assertions/helpers to schema 6 where they represent current state.

- `tests/snapshot_test_ui_test.lua`
  - Regression test that owners remain rendered as `name-realm — saved date`, without local/guild badges.

### Files intentionally unchanged

- `GuildGearMemory/ProfessionLinkSave.lua`
  - Manual Save Snapshot remains the only profession-capture trigger.

- `GuildGearMemory/SyncProtocol.lua`
- `GuildGearMemory/SyncTransport.lua`
- `GuildGearMemory/GuildSync.lua`
  - No automatic profession exchange, new addon messages, protocol fields, or traffic.

- `GuildGearMemory/GuildGearMemory.toc`
  - No new Lua files are introduced, so TOC ordering does not change.

---

## Global Constraints

- `localCharacterGUIDs[guid] == true` means only “this GUID has logged into this local SavedVariables database.” It is local state, never a network claim.
- Never infer local ownership from `snapshot.source`, name/realm equality, a guild trade-skill link, or a profession registry entry.
- Saving the player's profession still requires opening that profession and clicking Save Snapshot.
- Saving another guild member's profession still requires the existing observed guild-link flow and current guild-membership verification.
- A recipe owner is eligible when `db.localCharacterGUIDs[entry.guid] == true` **or** `GGM.professionRosterMembershipCurrent == true and entry.active == true`.
- When roster membership is not current, stale non-local `active` flags must not expose cached guild records.
- A failed, incomplete, ambiguous, or pending roster result must not delete cached data.
- A successful complete roster result may delete only absent non-local records.
- An unresolved schema-5 local key is unknown, not non-local. While its true `db.localCharacters[characterKey]` marker remains, retain matching gear records and profession registry entries. This marker is retention-only and does not grant profession-catalog eligibility.
- Local characters survive guild departure.
- Recipe-index local IDs remain monotonic; purging must not decrement or reuse `nextLocalCharacterID`.
- Catalog construction and UI search remain read-only and send no messages.
- Use only in-game addon APIs and SavedVariables; do not add process-memory, packet, screen-extraction, or external-data paths.
- Preserve cached/last-known labeling and saved dates; do not imply live profession knowledge.

---

### Task 1: Add schema-6 GUID ownership with a safe schema-5 migration

**Files:**
- Modify: `GuildGearMemory/Constants.lua:3-11`
- Modify: `GuildGearMemory/ProfessionIndex.lua:927-944`
- Modify: `GuildGearMemory/Storage.lua:181-245`
- Test: `tests/storage_test.lua:39-220, 580-610`
- Test: `tests/profession_index_test.lua:39-80`

**Interfaces:**

```lua
GGM.SCHEMA_VERSION = 6

GGM.MarkLocalCharacterGUID(db, guid) -> true, nil | false, error
GGM.IsLocalCharacterGUID(db, guid) -> boolean

GGM.EnsureProfessionIndex(db, validateFully, expectedSchemaVersion) -> boolean, error
```

`expectedSchemaVersion` is optional. Normal callers omit it and validate against schema 6; the migration passes `5` so it can validate the old index without temporarily mutating `schemaVersion`.

- [ ] **Step 1: Add failing schema/migration/ownership tests**

In `tests/storage_test.lua`, update current-schema assertions from 5 to 6, keep old schemas 1-4 rejected, and replace the old “schema four/five is rejected” coverage with explicit one-step schema-5 migration coverage. Add these tests:

```lua
T.test("database initialization creates schema six with GUID ownership state", function()
    local GGM = loadModules()

    local db, err = GGM.InitializeDatabase(nil)

    T.assertNil(err)
    T.assertEqual(db.schemaVersion, 6)
    T.assertEqual(type(db.characters), "table")
    T.assertEqual(type(db.localCharacters), "table")
    T.assertEqual(type(db.localCharacterGUIDs), "table")
    T.assertNil(next(db.localCharacterGUIDs))
    T.assertEqual(type(db.professions), "table")
    T.assertEqual(db.professionRecipeIndexVersion, 3)
end)

T.test("schema five migrates a resolved legacy local key to its stored GUID", function()
    local GGM = loadModules()
    local existing = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()

    assert(GGM.SaveCompleteCharacterRecord(existing, identity, makeSnapshot(GGM), 0))
    existing.localCharacters[identity.key] = true

    existing.schemaVersion = 5
    existing.localCharacterGUIDs = nil

    local migrated, err = GGM.InitializeDatabase(existing)

    T.assertNil(err)
    T.assertTrue(migrated == existing)
    T.assertEqual(migrated.schemaVersion, 6)
    T.assertTrue(migrated.localCharacterGUIDs[identity.guid])
    T.assertTrue(migrated.localCharacters[identity.key])
end)

T.test("schema five can resolve legacy local ownership from a profession identity", function()
    local GGM = loadModules()
    local existing = assert(GGM.InitializeDatabase(nil))
    local identity = {
        key = "Alt-Silvermoon",
        name = "Alt",
        realm = "Silvermoon",
        guid = "Player-9-ALT",
    }
    local capture = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 1700004000,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }

    assert(GGM.SaveProfessionSnapshot(existing, identity, capture))
    existing.localCharacters[identity.key] = true
    existing.schemaVersion = 5
    existing.localCharacterGUIDs = nil

    local migrated, err = GGM.InitializeDatabase(existing)

    T.assertNil(err)
    T.assertTrue(migrated.localCharacterGUIDs[identity.guid])
    T.assertNotNil(migrated.professions[identity.key])
    T.assertEqual(migrated.professionRecipeIndex[164][100].crafters[1],
        migrated.localCharacterIDByGUID[identity.guid])
end)

T.test("schema five leaves unresolved legacy local keys unclassified", function()
    local GGM = loadModules()
    local existing = assert(GGM.InitializeDatabase(nil))

    existing.localCharacters["Unknown-Silvermoon"] = true
    existing.characters["NameOnly-Silvermoon"] = {
        identity = {
            key = "NameOnly-Silvermoon",
            name = "NameOnly",
            realm = "Silvermoon",
        },
    }
    existing.localCharacters["NameOnly-Silvermoon"] = true
    existing.schemaVersion = 5
    existing.localCharacterGUIDs = nil

    local migrated, err = GGM.InitializeDatabase(existing)

    T.assertNil(err)
    T.assertNil(next(migrated.localCharacterGUIDs))
    T.assertTrue(migrated.localCharacters["Unknown-Silvermoon"])
    T.assertTrue(migrated.localCharacters["NameOnly-Silvermoon"])
end)

T.test("schema five migration is deterministic and safe to retry", function()
    local GGM = loadModules()
    local existing = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()

    assert(GGM.SaveCompleteCharacterRecord(existing, identity, makeSnapshot(GGM), 0))
    existing.localCharacters[identity.key] = true
    existing.schemaVersion = 5
    existing.localCharacterGUIDs = nil

    local first = assert(GGM.InitializeDatabase(existing))
    local second = assert(GGM.InitializeDatabase(first))

    T.assertTrue(second == existing)
    T.assertEqual(second.schemaVersion, 6)
    T.assertTrue(second.localCharacterGUIDs[identity.guid])
end)

T.test("schema six rejects malformed GUID ownership state", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    db.localCharacterGUIDs = { ["Player-1-A"] = false }

    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(initialized)
    T.assertEqual(err, "database-local-character-guids-invalid")
end)

T.test("GUID ownership marks and queries only explicit valid GUIDs", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))

    T.assertFalse(GGM.IsLocalCharacterGUID(db, "Player-1-A"))
    T.assertTrue(GGM.MarkLocalCharacterGUID(db, "Player-1-A"))
    T.assertTrue(GGM.IsLocalCharacterGUID(db, "Player-1-A"))
    T.assertFalse(GGM.IsLocalCharacterGUID(db, "Player-1-B"))

    for _, guid in ipairs({ "", 42, false, {} }) do
        local ok, err = GGM.MarkLocalCharacterGUID(db, guid)
        T.assertFalse(ok)
        T.assertEqual(err, "character-guid-invalid")
    end
end)

T.test("saving a player profession does not infer local GUID ownership", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = {
        key = "Alice-Silvermoon",
        name = "Alice",
        realm = "Silvermoon",
        guid = "Player-1-A",
    }
    local capture = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 1700004000,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }

    assert(GGM.SaveProfessionSnapshot(db, identity, capture))

    T.assertFalse(GGM.IsLocalCharacterGUID(db, identity.guid))
end)
```

Also update the current-state test names/assertions in `tests/storage_test.lua` and `tests/profession_index_test.lua` so “schema five” becomes “schema six” where the test is describing the current schema. Keep explicit schema-5 fixtures only in migration tests.

- [ ] **Step 2: Run the suite and verify the new tests fail**

Run from the repository root:

```bash
lua5.1 tests/run.lua
```

Expected: failures include schema version still being `5`, missing `localCharacterGUIDs`, missing `GGM.MarkLocalCharacterGUID`, and schema 5 still being rejected.

- [ ] **Step 3: Make profession-index validation migration-aware without changing index format**

In `GuildGearMemory/Constants.lua`, change only the schema constant:

```lua
GGM.SCHEMA_VERSION = 6
GGM.DEFAULT_STABILITY_DELAY_SECONDS = 300

GGM.PROFESSION_MAX_RECIPES = 4096
GGM.PROFESSION_MAX_NAME_BYTES = 128
GGM.PROFESSION_SOURCE_GUILD_LINK = "guild-profession-link"
GGM.PROFESSION_SOURCE_PLAYER = "player"
GGM.PROFESSION_CACHE_STATUS = "cached"
GGM.PROFESSION_RECIPE_INDEX_VERSION = 3
```

Replace the schema check at the top of `GGM.EnsureProfessionIndex` in `GuildGearMemory/ProfessionIndex.lua` with this complete function signature/check:

```lua
function GGM.EnsureProfessionIndex(db, validateFully, expectedSchemaVersion)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return false, "database-professions-invalid"
    end

    local requiredSchemaVersion = expectedSchemaVersion or GGM.SCHEMA_VERSION
    if db.schemaVersion ~= nil and db.schemaVersion ~= requiredSchemaVersion then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end

    if type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionIndexRepairCandidates) ~= "table"
        or type(db.professionIndexRepairNeeded) ~= "boolean"
        or not positiveInteger(db.nextLocalCharacterID)
        or db.professionRecipeIndexVersion ~= GGM.PROFESSION_RECIPE_INDEX_VERSION then
        return false, "profession-index-invalid"
    end
    if validateFully == true
        and (not registryConsistent(db)
            or not registryMatchesCanonical(db)
            or not recipeIndexConsistent(db)) then
        return false, "profession-index-invalid"
    end
    return true, nil
end
```

Do not increment `GGM.PROFESSION_RECIPE_INDEX_VERSION`; the index still maps `professionID -> recipeID -> { name, crafters = localIDs }`, and it already retains inactive crafters.

- [ ] **Step 4: Implement schema-5 migration and GUID ownership helpers**

In `GuildGearMemory/Storage.lua`, add these helpers immediately before `GGM.InitializeDatabase`:

```lua
local PREVIOUS_SCHEMA_VERSION = 5

local function validLocalCharacterGUIDs(value)
    if type(value) ~= "table" then return false end
    for guid, owned in pairs(value) do
        if not GGM.IsProfessionGUID(guid) or owned ~= true then
            return false
        end
    end
    return true
end

local function storedIdentityGUID(record, expectedKey)
    local identity = type(record) == "table" and record.identity or nil
    if type(identity) ~= "table"
        or identity.key ~= expectedKey
        or not GGM.IsProfessionGUID(identity.guid) then
        return nil
    end
    return identity.guid
end

local function resolveLegacyLocalGUID(db, characterKey)
    local gearGUID = storedIdentityGUID(db.characters[characterKey], characterKey)
    local professionGUID = storedIdentityGUID(db.professions[characterKey], characterKey)

    if gearGUID and professionGUID and gearGUID ~= professionGUID then
        return nil
    end
    return gearGUID or professionGUID
end

local function migrateSchemaFive(db)
    if type(db.characters) ~= "table" then
        return nil, "database-characters-invalid"
    end
    if type(db.localCharacters) ~= "table" then
        return nil, "database-local-characters-invalid"
    end
    if type(db.professions) ~= "table" then
        return nil, "database-professions-invalid"
    end

    local indexOk, indexErr = GGM.EnsureProfessionIndex(
        db,
        true,
        PREVIOUS_SCHEMA_VERSION
    )
    if not indexOk then return nil, indexErr end

    local migratedLocalGUIDs = {}
    for characterKey, owned in pairs(db.localCharacters) do
        if owned == true and type(characterKey) == "string" and characterKey ~= "" then
            local guid = resolveLegacyLocalGUID(db, characterKey)
            if guid then migratedLocalGUIDs[guid] = true end
        end
    end

    db.localCharacterGUIDs = migratedLocalGUIDs
    db.schemaVersion = GGM.SCHEMA_VERSION
    return db, nil
end
```

Leave `db.localCharacters` unchanged during migration. A true key that cannot be resolved to one matching valid GUID remains a retention-only marker: do not add it to `localCharacterGUIDs`, use it to show profession owners, or discard its matching cached records during roster cleanup.

Replace `GGM.InitializeDatabase` with:

```lua
function GGM.InitializeDatabase(existing)
    if existing == nil then
        return {
            schemaVersion = GGM.SCHEMA_VERSION,
            characters = {},
            localCharacters = {},
            localCharacterGUIDs = {},
            professions = {},
            nextLocalCharacterID = 1,
            professionCharacters = {},
            localCharacterIDByGUID = {},
            professionRecipeIndex = {},
            professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION,
            professionIndexRepairCandidates = {},
            professionIndexRepairNeeded = false,
        }, nil
    end

    if type(existing) ~= "table" then
        return nil, "database-invalid"
    end

    if existing.schemaVersion == PREVIOUS_SCHEMA_VERSION then
        local migrated, migrationErr = migrateSchemaFive(existing)
        if not migrated then return nil, migrationErr end
    elseif existing.schemaVersion ~= GGM.SCHEMA_VERSION then
        return nil, "unsupported-schema-version:" .. tostring(existing.schemaVersion)
    end

    if type(existing.characters) ~= "table" then
        return nil, "database-characters-invalid"
    end
    if type(existing.localCharacters) ~= "table" then
        return nil, "database-local-characters-invalid"
    end
    if not validLocalCharacterGUIDs(existing.localCharacterGUIDs) then
        return nil, "database-local-character-guids-invalid"
    end
    if type(existing.professions) ~= "table" then
        return nil, "database-professions-invalid"
    end

    local indexOk, indexErr = GGM.EnsureProfessionIndex(existing, true)
    if not indexOk then return nil, indexErr end
    return existing, nil
end
```

Add these public helpers directly after the existing key-based `GGM.IsLocalCharacter` helper:

```lua
function GGM.MarkLocalCharacterGUID(db, guid)
    if type(db) ~= "table" then
        return false, "database-invalid"
    end
    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end
    if type(db.localCharacterGUIDs) ~= "table" then
        return false, "database-local-character-guids-invalid"
    end
    if not GGM.IsProfessionGUID(guid) then
        return false, "character-guid-invalid"
    end

    db.localCharacterGUIDs[guid] = true
    return true, nil
end

function GGM.IsLocalCharacterGUID(db, guid)
    return type(db) == "table"
        and type(db.localCharacterGUIDs) == "table"
        and GGM.IsProfessionGUID(guid)
        and db.localCharacterGUIDs[guid] == true
end
```

Do not remove or reinterpret `GGM.MarkLocalCharacter` / `GGM.IsLocalCharacter`; those remain key-based gear-browser ownership markers.

- [ ] **Step 5: Run storage/index tests and the full suite**

Run:

```bash
lua5.1 tests/run.lua
```

Expected: all tests pass, including schema-5 migration and schema-6 current-state tests.

Then verify the schema/index constants explicitly:

```bash
grep -n "SCHEMA_VERSION\|PROFESSION_RECIPE_INDEX_VERSION" GuildGearMemory/Constants.lua
```

Expected:

```text
3:GGM.SCHEMA_VERSION = 6
11:GGM.PROFESSION_RECIPE_INDEX_VERSION = 3
```

- [ ] **Step 6: Commit schema and ownership storage**

```bash
git add GuildGearMemory/Constants.lua GuildGearMemory/ProfessionIndex.lua GuildGearMemory/Storage.lua tests/storage_test.lua tests/profession_index_test.lua
git commit -m "feat: track local character ownership by guid"
```

---

### Task 2: Record local GUID ownership at login without capturing professions

**Files:**
- Modify: `GuildGearMemory/LocalGearMemory.lua:1-18`
- Modify: `GuildGearMemory/Main.lua:99-126`
- Test: `tests/local_gear_memory_test.lua:1-90, 250-335`
- Test: `tests/main_test.lua:477-530`

**Interfaces:**

```lua
GGM.RecordLocalPlayerOwnership(api, db) -> true, nil | false, error
```

The helper reads `api.UnitGUID("player")` only. It does not build a profession snapshot, inspect the profession UI, capture gear, or mark `localCharacters` by name.

- [ ] **Step 1: Add failing ownership-at-login tests**

Add to `tests/local_gear_memory_test.lua`:

```lua
T.test("recording local player ownership reads only the player GUID", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api = {
        UnitGUID = function(unit)
            T.assertEqual(unit, "player")
            return "Player-1234-ABCDEF"
        end,
        UnitFullName = function()
            error("ownership recording must not resolve name or realm")
        end,
        GetInventorySlotInfo = function()
            error("ownership recording must not inspect gear")
        end,
        C_TradeSkillUI = {
            GetProfessionInfoBySkillLineID = function()
                error("ownership recording must not inspect professions")
            end,
        },
    }

    local recorded, err = GGM.RecordLocalPlayerOwnership(api, db)

    T.assertTrue(recorded)
    T.assertNil(err)
    T.assertTrue(GGM.IsLocalCharacterGUID(db, "Player-1234-ABCDEF"))
    T.assertNil(next(db.professions))
    T.assertNil(next(db.localCharacters))
end)

T.test("recording local player ownership fails closed when GUID is unavailable", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))

    local recorded, err = GGM.RecordLocalPlayerOwnership({
        UnitGUID = function() return nil end,
    }, db)

    T.assertFalse(recorded)
    T.assertEqual(err, "player-guid-unavailable")
    T.assertNil(next(db.localCharacterGUIDs))
end)
```

Extend the existing `"player login defers stable gear tracking until equipment is ready"` test in `tests/main_test.lua` with a synchronous ownership stub and assertions:

```lua
local ownershipCount = 0

GGM.RecordLocalPlayerOwnership = function(api, db)
    T.assertTrue(api == _G)
    T.assertTrue(db == GGM.db)
    ownershipCount = ownershipCount + 1
    return true, nil
end
```

Immediately after `onEvent(frame, "PLAYER_LOGIN")`, assert:

```lua
T.assertEqual(ownershipCount, 1)
T.assertEqual(startCount, 0)
T.assertNotNil(deferredStartup)
T.assertNil(GGM.lastLocalOwnershipError)
```

Keep the existing assertion after `deferredStartup()` that gear tracking starts once.

Add a second main test proving ownership failure does not prevent delayed gear tracking:

```lua
T.test("player login ownership failure does not block existing gear tracking", function()
    local onEvent
    local deferredStartup
    local startCount = 0
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }

    withGlobals({
        CreateFrame = function() return frame end,
        C_Timer = {
            After = function(_, callback) deferredStartup = callback end,
        },
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = { DEFAULT_STABILITY_DELAY_SECONDS = 300 }
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 6, characters = {}, localCharacterGUIDs = {} }, nil
        end
        GGM.RecordLocalPlayerOwnership = function()
            return false, "player-guid-unavailable"
        end
        GGM.StartLocalPlayerGearTracking = function()
            startCount = startCount + 1
            return {}, nil
        end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        onEvent(frame, "PLAYER_LOGIN")

        T.assertEqual(GGM.lastLocalOwnershipError, "player-guid-unavailable")
        T.assertEqual(startCount, 0)

        deferredStartup()

        T.assertEqual(startCount, 1)
    end)
end)
```

- [ ] **Step 2: Run the suite and verify ownership tests fail**

Run:

```bash
lua5.1 tests/run.lua
```

Expected: failures because `GGM.RecordLocalPlayerOwnership` does not exist and `Main.lua` does not call it.

- [ ] **Step 3: Implement GUID-only local ownership recording**

Add near the top of `GuildGearMemory/LocalGearMemory.lua`:

```lua
function GGM.RecordLocalPlayerOwnership(api, db)
    if type(api) ~= "table" or type(api.UnitGUID) ~= "function" then
        return false, "player-guid-unavailable"
    end

    local guidOk, guid = pcall(api.UnitGUID, "player")
    if not guidOk or not GGM.IsProfessionGUID(guid) then
        return false, "player-guid-unavailable"
    end

    return GGM.MarkLocalCharacterGUID(db, guid)
end
```

Do not alter `GGM.CaptureAndStoreLocalPlayer`. Keep the existing `GGM.MarkLocalCharacter(db, identity.key)` inside `GGM.StartLocalPlayerGearTracking`; that key-based marker still supports the gear UI.

- [ ] **Step 4: Call ownership recording synchronously from `PLAYER_LOGIN`**

Replace the `PLAYER_LOGIN` branch in `GuildGearMemory/Main.lua` with:

```lua
    if event == "PLAYER_LOGIN" then
        if not GGM.db or GGM.startupError then
            return
        end

        local ownershipRecorded, ownershipErr = GGM.RecordLocalPlayerOwnership(
            _G,
            GGM.db
        )
        if ownershipRecorded then
            GGM.lastLocalOwnershipError = nil
        else
            GGM.lastLocalOwnershipError = ownershipErr
        end

        C_Timer.After(1, function()
            if GGM.gearTracker or GGM.startupError or not GGM.db then
                return
            end

            local tracker, err = GGM.StartLocalPlayerGearTracking(
                _G,
                GGM.db,
                GGM.DEFAULT_STABILITY_DELAY_SECONDS,
                publishConfirmedSlot
            )
            GGM.gearTracker = tracker
            if GGM.guildSync then
                GGM.guildSync.localGearTracker = tracker
            end
            GGM.lastGearTrackingError = err
            GGM.lastCaptureError = err
        end)
        return
    end
```

This records ownership before any profession is opened and before delayed gear capture. A missing GUID is diagnostic only; it does not change existing gear-tracker startup behavior.

- [ ] **Step 5: Run the full suite**

```bash
lua5.1 tests/run.lua
```

Expected: all tests pass. The new tests prove login ownership does not invoke gear or profession APIs.

- [ ] **Step 6: Commit login ownership recording**

```bash
git add GuildGearMemory/LocalGearMemory.lua GuildGearMemory/Main.lua tests/local_gear_memory_test.lua tests/main_test.lua
git commit -m "feat: record local character guid on login"
```

---

### Task 3: Purge departed non-local character data only after a complete roster result

**Files:**
- Modify: `GuildGearMemory/ProfessionIndex.lua:416-460, 820-925`
- Test: `tests/profession_index_test.lua:1200-1550`

**Behavior to preserve:**

- `ReconcileProfessionGuildRoster` sets `GGM.professionRosterMembershipCurrent = false` before it starts.
- Any unavailable API, invalid row, duplicate/ambiguous roster identity, zero-member “in guild” result, failed registry repair, or rename conflict returns before deletion.
- `IsInGuild() == false` is a complete authoritative empty roster and may purge all non-local cached guild characters.
- A true legacy `db.localCharacters[characterKey]` marker with no matching GUID ownership classification protects records at that key from deletion. It does not make them locally owned for catalog visibility.
- `nextLocalCharacterID` never moves backwards after purge.

- [ ] **Step 1: Add failing purge/retention tests**

Add this helper near the roster tests in `tests/profession_index_test.lua`:

```lua
local function guildRosterAPI(rows)
    return {
        IsInGuild = function() return true end,
        GetNumGuildMembers = function(includeOffline)
            T.assertTrue(includeOffline)
            return #rows
        end,
        GetGuildRosterInfo = function(index)
            local row = rows[index]
            return row.name, nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, row.guid
        end,
        GetRealmName = function() return "Silvermoon" end,
    }
end
```

Add the following tests:

```lua
T.test("complete roster purges departed non-local gear profession registry and recipe references", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local localAlt = indexedIdentity(GGM, "LocalAlt-Silvermoon", "Player-1-LOCAL")
    local departed = indexedIdentity(GGM, "Departed-Silvermoon", "Player-1-GONE")

    local localCapture = indexedSnapshot(GGM, 164, 100)
    localCapture.recipes[1].name = "Shared Recipe"
    local departedCapture = indexedSnapshot(GGM, 164, 100)
    departedCapture.recipes[1].name = "Shared Recipe"

    assert(GGM.SaveProfessionSnapshot(db, localAlt, localCapture))
    assert(GGM.SaveProfessionSnapshot(db, departed, departedCapture, {
        guildMembershipVerified = true,
    }))
    assert(GGM.MarkLocalCharacterGUID(db, localAlt.guid))

    db.characters[localAlt.key] = {
        complete = true,
        identity = localAlt,
        gear = { complete = true, capturedAt = 1, slots = {} },
        confirmedSequence = 0,
    }
    db.characters[departed.key] = {
        complete = true,
        identity = departed,
        gear = { complete = true, capturedAt = 1, slots = {} },
        confirmedSequence = 0,
    }

    local localID = db.localCharacterIDByGUID[localAlt.guid]
    local departedID = db.localCharacterIDByGUID[departed.guid]
    local nextIDBefore = db.nextLocalCharacterID

    local ok, err = GGM.ReconcileProfessionGuildRoster(guildRosterAPI({
        { name = "Current-Silvermoon", guid = "Player-1-CURRENT" },
    }), db)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertTrue(GGM.professionRosterMembershipCurrent)

    T.assertNotNil(db.professions[localAlt.key])
    T.assertNotNil(db.characters[localAlt.key])
    T.assertEqual(db.localCharacterIDByGUID[localAlt.guid], localID)
    T.assertFalse(db.professionCharacters[localID].active)

    T.assertNil(db.professions[departed.key])
    T.assertNil(db.characters[departed.key])
    T.assertNil(db.localCharacterIDByGUID[departed.guid])
    T.assertNil(db.professionCharacters[departedID])

    T.assertEqual(#db.professionRecipeIndex[164][100].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], localID)
    T.assertEqual(db.nextLocalCharacterID, nextIDBefore)
end)

T.test("complete roster purges an absent non-local gear-only record", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "GearOnly-Silvermoon", "Player-1-GEAR")
    db.characters[identity.key] = {
        complete = true,
        identity = identity,
        gear = { complete = true, capturedAt = 1, slots = {} },
        confirmedSequence = 0,
    }

    local ok, err = GGM.ReconcileProfessionGuildRoster(guildRosterAPI({
        { name = "Current-Silvermoon", guid = "Player-1-CURRENT" },
    }), db)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertNil(db.characters[identity.key])
end)

T.test("complete roster retains unresolved schema five local records", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local key = "UnresolvedLocal-Silvermoon"
    local gearIdentity = indexedIdentity(GGM, key, "Player-1-LEGACY-GEAR")
    local professionIdentity = indexedIdentity(GGM, key, "Player-1-LEGACY-PROFESSION")

    assert(GGM.SaveProfessionSnapshot(db, professionIdentity,
        indexedSnapshot(GGM, 164, 100), { guildMembershipVerified = true }))
    db.characters[key] = {
        complete = true,
        identity = gearIdentity,
        gear = { complete = true, capturedAt = 1, slots = {} },
        confirmedSequence = 0,
    }
    db.localCharacters[key] = true
    db.schemaVersion = 5
    db.localCharacterGUIDs = nil

    local migrated, migrationErr = GGM.InitializeDatabase(db)

    T.assertNil(migrationErr)
    T.assertTrue(migrated == db)
    T.assertFalse(GGM.IsLocalCharacterGUID(db, gearIdentity.guid))
    T.assertFalse(GGM.IsLocalCharacterGUID(db, professionIdentity.guid))
    local localID = db.localCharacterIDByGUID[professionIdentity.guid]

    local ok, err = GGM.ReconcileProfessionGuildRoster(guildRosterAPI({
        { name = "Current-Silvermoon", guid = "Player-1-CURRENT" },
    }), db)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertNotNil(db.characters[key])
    T.assertNotNil(db.professions[key])
    T.assertNotNil(db.professionCharacters[localID])
    T.assertTrue(db.localCharacters[key])
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], localID)
end)

T.test("complete roster keeps an absent locally owned gear-only record", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "LocalGear-Silvermoon", "Player-1-LOCALGEAR")
    db.characters[identity.key] = {
        complete = true,
        identity = identity,
        gear = { complete = true, capturedAt = 1, slots = {} },
        confirmedSequence = 0,
    }
    assert(GGM.MarkLocalCharacterGUID(db, identity.guid))

    local ok, err = GGM.ReconcileProfessionGuildRoster(guildRosterAPI({
        { name = "Current-Silvermoon", guid = "Player-1-CURRENT" },
    }), db)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertNotNil(db.characters[identity.key])
end)

T.test("incomplete roster does not purge cached non-local data", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Cached-Silvermoon", "Player-1-CACHED")
    local capture = indexedSnapshot(GGM, 164, 100)

    assert(GGM.SaveProfessionSnapshot(db, identity, capture, {
        guildMembershipVerified = true,
    }))
    db.characters[identity.key] = {
        complete = true,
        identity = identity,
        gear = { complete = true, capturedAt = 1, slots = {} },
        confirmedSequence = 0,
    }
    local localID = db.localCharacterIDByGUID[identity.guid]
    local indexBefore = db.professionRecipeIndex

    local ok, err = GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return true end,
        GetNumGuildMembers = function() return 0 end,
        GetGuildRosterInfo = function()
            error("zero-count roster must fail before row reads")
        end,
    }, db)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-roster-incomplete")
    T.assertFalse(GGM.professionRosterMembershipCurrent)
    T.assertNotNil(db.professions[identity.key])
    T.assertNotNil(db.characters[identity.key])
    T.assertEqual(db.localCharacterIDByGUID[identity.guid], localID)
    T.assertTrue(db.professionRecipeIndex == indexBefore)
end)

T.test("not being in a guild purges non-local data but retains local data", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local localAlt = indexedIdentity(GGM, "LocalAlt-Silvermoon", "Player-1-LOCAL")
    local cachedGuild = indexedIdentity(GGM, "Guildie-Silvermoon", "Player-1-GUILD")

    assert(GGM.SaveProfessionSnapshot(db, localAlt, indexedSnapshot(GGM, 171, 200)))
    assert(GGM.SaveProfessionSnapshot(db, cachedGuild, indexedSnapshot(GGM, 171, 201), {
        guildMembershipVerified = true,
    }))
    assert(GGM.MarkLocalCharacterGUID(db, localAlt.guid))

    local ok, err = GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return false end,
    }, db)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertNotNil(db.professions[localAlt.key])
    T.assertNil(db.professions[cachedGuild.key])
end)
```

Keep the existing rename-conflict tests; they already verify reconciliation failure preserves old records/index state.

- [ ] **Step 2: Run the suite and verify purge tests fail**

```bash
lua5.1 tests/run.lua
```

Expected: the new tests fail because absent non-local records are currently only marked inactive and never deleted.

- [ ] **Step 3: Add safe recipe-index and gear purge helpers**

In `GuildGearMemory/ProfessionIndex.lua`, directly after `removeMembershipFromProfession`, add:

```lua
local function localOwnershipSetIsTrusted(db)
    if type(db) ~= "table" or type(db.localCharacterGUIDs) ~= "table" then
        return false
    end
    for guid, owned in pairs(db.localCharacterGUIDs) do
        if not GGM.IsProfessionGUID(guid) or owned ~= true then
            return false
        end
    end
    return true
end

local function isLocallyOwnedGUID(db, guid)
    return type(db.localCharacterGUIDs) == "table"
        and db.localCharacterGUIDs[guid] == true
end

local function hasUnresolvedLegacyLocalMarker(db, characterKey, guid)
    return type(db.localCharacters) == "table"
        and db.localCharacters[characterKey] == true
        and not isLocallyOwnedGUID(db, guid)
end

local function removeCrafterFromAllProfessions(index, localID)
    local professionIDs = {}
    for professionID in pairs(index) do
        professionIDs[#professionIDs + 1] = professionID
    end
    table.sort(professionIDs)

    for _, professionID in ipairs(professionIDs) do
        removeMembershipFromProfession(index, professionID, localID)
    end
end

local function purgeProfessionCharacter(db, localID)
    local entry = db.professionCharacters[localID]
    if type(entry) ~= "table" then return end
    if hasUnresolvedLegacyLocalMarker(db, entry.key, entry.guid) then return end

    removeCrafterFromAllProfessions(db.professionRecipeIndex, localID)
    db.professions[entry.key] = nil
    db.localCharacterIDByGUID[entry.guid] = nil
    db.professionCharacters[localID] = nil
    db.localCharacters[entry.key] = nil
    if type(db.professionIndexRepairCandidates) == "table" then
        db.professionIndexRepairCandidates[entry.guid] = nil
    end
end

local function purgeDepartedGearRecords(db, currentByGUID)
    local keysToRemove = {}

    for characterKey, record in pairs(db.characters) do
        local identity = type(record) == "table" and record.identity or nil
        local guid = type(identity) == "table" and identity.guid or nil
        if GGM.IsProfessionGUID(guid)
            and currentByGUID[guid] == nil
            and not isLocallyOwnedGUID(db, guid)
            and not hasUnresolvedLegacyLocalMarker(db, characterKey, guid) then
            keysToRemove[#keysToRemove + 1] = characterKey
        end
    end

    table.sort(keysToRemove)
    for _, characterKey in ipairs(keysToRemove) do
        db.characters[characterKey] = nil
        db.localCharacters[characterKey] = nil
    end
end
```

Do not try to rebuild recipe names from `db.professions`: current `Storage.lua` deliberately stores profession snapshot metadata without `recipes`, so the safe reconciliation is to remove departed local IDs from the existing named recipe index.

- [ ] **Step 4: Gate deletion on a fully validated roster/reconciliation result**

At the top of `GGM.ReconcileProfessionGuildRoster`, extend the structural precondition so the data needed for purge is present:

```lua
        or type(db.characters) ~= "table"
        or type(db.localCharacters) ~= "table"
        or type(db.localCharacterGUIDs) ~= "table"
```

After the roster rows have been collected, but before any registry repair/rekey mutation, add:

```lua
    if not localOwnershipSetIsTrusted(db) or not recipeIndexConsistent(db) then
        return false, "profession-index-invalid"
    end
```

Keep the existing two-phase rename validation and registry consistency checks unchanged. Replace the final block that currently sets every `entry.active` value with:

```lua
    local purgeLocalIDs = {}
    for localID, entry in pairs(db.professionCharacters) do
        if currentByGUID[entry.guid] == nil
            and not isLocallyOwnedGUID(db, entry.guid)
            and not hasUnresolvedLegacyLocalMarker(db, entry.key, entry.guid) then
            purgeLocalIDs[#purgeLocalIDs + 1] = localID
        end
    end
    table.sort(purgeLocalIDs)

    for _, entry in pairs(db.professionCharacters) do
        entry.active = currentByGUID[entry.guid] ~= nil
    end

    for _, localID in ipairs(purgeLocalIDs) do
        purgeProfessionCharacter(db, localID)
    end

    purgeDepartedGearRecords(db, currentByGUID)
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION

    GGM.professionRosterMembershipCurrent = true
    return true, nil
```

All returns caused by unavailable/incomplete roster data, registry ambiguity, or rename conflict must remain above this purge block.

- [ ] **Step 5: Run roster/index tests and full suite**

```bash
lua5.1 tests/run.lua
```

Expected: all tests pass. Specifically:
- absent non-local profession and gear records disappear after a complete roster;
- recipe rows retain surviving local IDs;
- local GUID-owned records survive;
- zero-count/incomplete roster checks preserve all cached data;
- `nextLocalCharacterID` remains unchanged by deletion.

- [ ] **Step 6: Commit authoritative roster cleanup**

```bash
git add GuildGearMemory/ProfessionIndex.lua tests/profession_index_test.lua
git commit -m "feat: purge departed non-local guild data"
```

---

### Task 4: Show locally owned profession snapshots with or without confirmed guild membership

**Files:**
- Modify: `GuildGearMemory/ProfessionIndex.lua:984-1185`
- Test: `tests/profession_index_test.lua:1550-1945`

**Catalog eligibility:**

```lua
localOwned = db.localCharacterGUIDs[member.guid] == true
confirmedGuildMember = GGM.professionRosterMembershipCurrent == true
    and member.active == true
eligible = localOwned or confirmedGuildMember
```

A stale `active == true` record is not enough when `professionRosterMembershipCurrent` is false.

When roster membership is unconfirmed:
- local snapshots remain visible;
- non-local rows are withheld;
- the catalog warning is `Current guild membership could not be confirmed. Showing saved local characters only.`;
- if there is no safely classifiable local snapshot, return `state = "unavailable"` and `hasSnapshot = nil` rather than claiming no guild snapshot exists.

- [ ] **Step 1: Update the catalog fixture and add failing local-visibility tests**

In the `catalogDB` helper in `tests/profession_index_test.lua`, add the schema-6 ownership fields:

```lua
        characters = {},
        localCharacters = {},
        localCharacterGUIDs = {},
```

Inside the member loop, after `db.localCharacterIDByGUID[member.guid] = localID`, add:

```lua
        if member.localOwned == true then
            db.localCharacterGUIDs[member.guid] = true
        end
```

Add these tests:

```lua
T.test("unconfirmed roster still shows a saved locally owned out-of-guild profession", function()
    local GGM = loadModules()
    local db = catalogDB({
        {
            key = "LocalAlt-Silvermoon",
            name = "LocalAlt",
            realm = "Silvermoon",
            guid = "Player-1-LOCAL",
            active = false,
            localOwned = true,
            snapshots = {
                [171] = catalogSnapshot(GGM, 171, 1700000000, {
                    { recipeID = 100, name = "Local Recipe" },
                }),
            },
        },
        {
            key = "StaleGuildie-Silvermoon",
            name = "StaleGuildie",
            realm = "Silvermoon",
            guid = "Player-1-STALE",
            active = true,
            snapshots = {
                [171] = catalogSnapshot(GGM, 171, 1700000100, {
                    { recipeID = 200, name = "Hidden Stale Recipe" },
                }),
            },
        },
    })
    GGM.professionRosterMembershipCurrent = false

    local model = GGM.BuildProfessionRecipeCatalog(db, 171, "Alchemy", {})

    T.assertEqual(model.state, "ready")
    T.assertTrue(model.hasSnapshot)
    T.assertEqual(#model.recipes, 1)
    T.assertEqual(model.recipes[1].recipeID, 100)
    T.assertEqual(#model.recipes[1].knownBy, 1)
    T.assertEqual(model.recipes[1].knownBy[1].key, "LocalAlt-Silvermoon")
    T.assertEqual(model.message,
        "Current guild membership could not be confirmed. Showing saved local characters only.")
end)

T.test("unconfirmed roster with no local snapshot exposes no non-local owner", function()
    local GGM = loadModules()
    local db = catalogDB({
        {
            key = "CachedGuildie-Silvermoon",
            name = "CachedGuildie",
            realm = "Silvermoon",
            guid = "Player-1-CACHED",
            active = true,
            snapshots = {
                [171] = catalogSnapshot(GGM, 171, 1700000000, {
                    { recipeID = 100, name = "Cached Recipe" },
                }),
            },
        },
    })
    GGM.professionRosterMembershipCurrent = false

    local model = GGM.BuildProfessionRecipeCatalog(db, 171, "Alchemy", {})

    T.assertEqual(model.state, "unavailable")
    T.assertNil(model.hasSnapshot)
    T.assertEqual(#model.recipes, 0)
    T.assertEqual(model.message,
        "Current guild membership could not be confirmed. Showing saved local characters only.")
end)

T.test("confirmed roster combines current guild and local out-of-guild crafters but excludes other former members", function()
    local GGM = loadModules()
    local db = catalogDB({
        {
            key = "LocalAlt-Silvermoon",
            name = "LocalAlt",
            realm = "Silvermoon",
            guid = "Player-1-LOCAL",
            active = false,
            localOwned = true,
            snapshots = {
                [164] = catalogSnapshot(GGM, 164, 1700000000, {
                    { recipeID = 100, name = "Shared Recipe" },
                }),
            },
        },
        {
            key = "CurrentGuildie-Silvermoon",
            name = "CurrentGuildie",
            realm = "Silvermoon",
            guid = "Player-1-CURRENT",
            active = true,
            snapshots = {
                [164] = catalogSnapshot(GGM, 164, 1700000100, {
                    { recipeID = 100, name = "Shared Recipe" },
                }),
            },
        },
        {
            key = "FormerAlt-Silvermoon",
            name = "FormerAlt",
            realm = "Silvermoon",
            guid = "Player-1-FORMER",
            active = false,
            snapshots = {
                [164] = catalogSnapshot(GGM, 164, 1700000200, {
                    { recipeID = 100, name = "Shared Recipe" },
                }),
            },
        },
    })
    GGM.professionRosterMembershipCurrent = true

    local model = GGM.BuildProfessionRecipeCatalog(db, 164, "Blacksmithing", {})

    T.assertEqual(model.state, "ready")
    T.assertEqual(#model.recipes, 1)
    T.assertEqual(#model.recipes[1].knownBy, 2)
    T.assertEqual(model.recipes[1].knownBy[1].key, "CurrentGuildie-Silvermoon")
    T.assertEqual(model.recipes[1].knownBy[2].key, "LocalAlt-Silvermoon")
    T.assertNil(model.message)
end)

T.test("locally owned character with no saved selected profession creates no owner row", function()
    local GGM = loadModules()
    local db = catalogDB({
        {
            key = "LocalNoSnapshot-Silvermoon",
            name = "LocalNoSnapshot",
            realm = "Silvermoon",
            guid = "Player-1-LOCAL",
            active = false,
            localOwned = true,
            snapshots = {},
        },
        {
            key = "CurrentGuildie-Silvermoon",
            name = "CurrentGuildie",
            realm = "Silvermoon",
            guid = "Player-1-CURRENT",
            active = true,
            snapshots = {
                [171] = catalogSnapshot(GGM, 171, 1700000000, {
                    { recipeID = 100, name = "Guild Recipe" },
                }),
            },
        },
    })
    GGM.professionRosterMembershipCurrent = true

    local model = GGM.BuildProfessionRecipeCatalog(db, 171, "Alchemy", {})

    T.assertEqual(#model.recipes, 1)
    T.assertEqual(#model.recipes[1].knownBy, 1)
    T.assertEqual(model.recipes[1].knownBy[1].key, "CurrentGuildie-Silvermoon")
end)
```

Update the existing no-snapshot expected text from:

```text
No saved <profession> snapshots for current guild members.
```

to:

```text
No saved <profession> snapshots for local characters or current guild members.
```

Keep the existing localization, sorting, malformed-data, saved-date, and read-only assertions.

- [ ] **Step 2: Run the suite and verify local-visibility tests fail**

```bash
lua5.1 tests/run.lua
```

Expected: the unconfirmed-local test fails because the current builder exits immediately when roster membership is not current, and the confirmed mixed test excludes inactive local owners.

- [ ] **Step 3: Make catalog trust include the local GUID allowlist**

At the start of `catalogMemberOwnershipIsTrusted`, require the local ownership set to be valid:

```lua
local function catalogMemberOwnershipIsTrusted(db)
    if type(db) ~= "table"
        or type(db.professions) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or not localOwnershipSetIsTrusted(db)
        or db.professionIndexRepairNeeded == true then
        return false
    end
```

Keep the remainder of the existing canonical/registry checks unchanged. A GUID in `localCharacterGUIDs` is allowed to have no profession registry entry; ownership alone does not create a snapshot or crafter row.

Add these helpers below `catalogOwnerLess`:

```lua
local function catalogCharacterEligible(db, member, membershipCurrent)
    if type(member) ~= "table" then return false end
    return isLocallyOwnedGUID(db, member.guid)
        or (membershipCurrent and member.active == true)
end

local function joinCatalogMessages(primary, secondary)
    if primary and secondary then return primary .. " " .. secondary end
    return primary or secondary
end

local function unconfirmedRosterMessage()
    return "Current guild membership could not be confirmed. Showing saved local characters only."
end
```

- [ ] **Step 4: Replace `GGM.BuildProfessionRecipeCatalog` with local-or-confirmed-guild eligibility**

Use this complete function:

```lua
function GGM.BuildProfessionRecipeCatalog(db, professionID, professionLabel, api)
    local emptyModel = {
        state = "unavailable",
        hasSnapshot = nil,
        recipes = {},
        message = nil,
    }

    if not positiveInteger(professionID)
        or not nonEmptyString(professionLabel)
        or not catalogMemberOwnershipIsTrusted(db) then
        emptyModel.message = "Saved profession character identities could not be confirmed."
        return emptyModel
    end

    local indexValid = GGM.EnsureProfessionIndex(db, true)
    if not indexValid then
        emptyModel.message = "Saved profession data could not be verified."
        return emptyModel
    end

    local membershipCurrent = GGM.professionRosterMembershipCurrent == true
    local rosterWarning
    if not membershipCurrent then
        rosterWarning = unconfirmedRosterMessage()
    end
    local hasSnapshot, incomplete = false, false
    local validSnapshotsByLocalID = {}

    for localID, member in pairs(db.professionCharacters) do
        if catalogCharacterEligible(db, member, membershipCurrent) then
            local canonical = db.professions[member.key]
            local snapshots = canonical.snapshots
            if type(snapshots) ~= "table" then
                if hasSnapshot ~= true then hasSnapshot = nil end
                incomplete = true
            else
                for snapshotProfessionID in pairs(snapshots) do
                    if not positiveInteger(snapshotProfessionID) then
                        if hasSnapshot ~= true then hasSnapshot = nil end
                        incomplete = true
                    end
                end

                local snapshot = rawget(snapshots, professionID)
                if snapshot ~= nil then
                    hasSnapshot = true
                    local valid = type(snapshot) == "table"
                        and snapshot.professionID == professionID
                        and GGM.ValidateProfessionSnapshot(snapshot)
                    if not valid then
                        incomplete = true
                    else
                        validSnapshotsByLocalID[localID] = snapshot
                    end
                end
            end
        end
    end

    local recipesByID = {}
    local indexedRecipes = db.professionRecipeIndex[professionID]
    if indexedRecipes ~= nil and type(indexedRecipes) ~= "table" then
        incomplete = true
        indexedRecipes = nil
    end

    for recipeID, indexedRecipe in pairs(indexedRecipes or {}) do
        if not positiveInteger(recipeID)
            or type(indexedRecipe) ~= "table"
            or not nonEmptyString(indexedRecipe.name)
            or type(indexedRecipe.crafters) ~= "table" then
            incomplete = true
        else
            local row = {
                recipeID = recipeID,
                name = indexedRecipe.name,
                knownBy = {},
            }

            for _, localID in ipairs(indexedRecipe.crafters) do
                local member = db.professionCharacters[localID]
                if catalogCharacterEligible(db, member, membershipCurrent) then
                    local snapshot = validSnapshotsByLocalID[localID]
                    if not snapshot then
                        incomplete = true
                    else
                        local canonical = db.professions[member.key]
                        row.knownBy[#row.knownBy + 1] = {
                            key = member.key,
                            name = canonical.identity.name,
                            realm = canonical.identity.realm,
                            capturedAt = snapshot.capturedAt,
                            savedDate = catalogSavedDate(api, snapshot.capturedAt),
                        }
                    end
                end
            end

            if #row.knownBy > 0 then
                table.sort(row.knownBy, catalogOwnerLess)
                recipesByID[recipeID] = row
            end
        end
    end

    local recipes = {}
    for _, recipe in pairs(recipesByID) do
        recipes[#recipes + 1] = recipe
    end
    table.sort(recipes, function(left, right)
        local leftName, rightName = string.lower(left.name), string.lower(right.name)
        if leftName ~= rightName then return leftName < rightName end
        return left.recipeID < right.recipeID
    end)

    if incomplete or hasSnapshot == nil then
        return {
            state = "incomplete",
            hasSnapshot = hasSnapshot,
            recipes = recipes,
            message = joinCatalogMessages(
                "Some saved profession data is incomplete.",
                rosterWarning
            ),
        }
    end

    if not membershipCurrent and hasSnapshot ~= true then
        return {
            state = "unavailable",
            hasSnapshot = nil,
            recipes = {},
            message = rosterWarning,
        }
    end

    if not hasSnapshot then
        return {
            state = "empty",
            hasSnapshot = false,
            recipes = recipes,
            message = "No saved " .. professionLabel
                .. " snapshots for local characters or current guild members.",
        }
    end

    if #recipes == 0 then
        return {
            state = "empty",
            hasSnapshot = true,
            recipes = recipes,
            message = joinCatalogMessages(
                "Saved " .. professionLabel
                    .. " snapshots contain no learned recipes.",
                rosterWarning
            ),
        }
    end

    return {
        state = "ready",
        hasSnapshot = true,
        recipes = recipes,
        message = rosterWarning,
    }
end
```

Do not add `localOwned`, `guildMember`, or badge metadata to `knownBy`; the UI requirement is deliberately neutral name/realm/date presentation.

- [ ] **Step 5: Run catalog tests and full suite**

```bash
lua5.1 tests/run.lua
```

Expected: all tests pass. Confirm these cases specifically:
- local out-of-guild snapshot appears with unconfirmed roster;
- stale non-local active entry does not appear with unconfirmed roster;
- current guild + local out-of-guild owners share one deduplicated recipe row;
- non-local inactive/former entries are excluded;
- malformed/local data keeps existing incomplete safeguards;
- sorting/localization/date behavior remains unchanged;
- catalog calls do not mutate SavedVariables.

- [ ] **Step 6: Commit local-aware catalog eligibility**

```bash
git add GuildGearMemory/ProfessionIndex.lua tests/profession_index_test.lua
git commit -m "feat: show local alt profession recipes"
```

---

### Task 5: Lock the UI presentation and no-new-traffic boundary

**Files:**
- Test: `tests/snapshot_test_ui_test.lua:469-590`
- Verify unchanged: `GuildGearMemory/SnapshotTestUI.lua:783-835`
- Verify unchanged: `GuildGearMemory/ProfessionLinkSave.lua`
- Verify unchanged: `GuildGearMemory/SyncProtocol.lua`
- Verify unchanged: `GuildGearMemory/SyncTransport.lua`
- Verify unchanged: `GuildGearMemory/GuildSync.lua`

No production UI change is expected. The current renderer already displays each owner as `name-realm — savedDate` and does not inspect ownership status.

- [ ] **Step 1: Add a UI regression test for identical local/guild presentation**

Add to `tests/snapshot_test_ui_test.lua`:

```lua
T.test("profession owner rows show name realm and date without ownership badges", function()
    local GGM = loadUI()
    local calls = {}

    installProfessionCatalogStub(GGM, function()
        return professionCatalog("ready", {
            {
                recipeID = 100,
                name = "Copper Bracers",
                knownBy = {
                    {
                        key = "Alice-Silvermoon",
                        name = "Alice",
                        realm = "Silvermoon",
                        savedDate = "2026-10-01",
                    },
                    {
                        key = "Bob-ArgentDawn",
                        name = "Bob",
                        realm = "ArgentDawn",
                        savedDate = "2026-09-30",
                    },
                },
            },
        })
    end, calls)

    local frame = showBrowser(
        GGM,
        makeBrowserAPI(),
        { schemaVersion = GGM.SCHEMA_VERSION, characters = {} }
    )
    GGM.SelectGuildGearBrowserTab(frame, "Professions")

    local text = frame.professionRecipeRows[1].knownBy.text
    T.assertTrue(string.find(
        text,
        "Alice-Silvermoon — 2026-10-01",
        1,
        true
    ) ~= nil)
    T.assertTrue(string.find(
        text,
        "Bob-ArgentDawn — 2026-09-30",
        1,
        true
    ) ~= nil)
    T.assertNil(string.find(text, "[Local]", 1, true))
    T.assertNil(string.find(text, "[Guild]", 1, true))
    T.assertNil(string.find(text, "Mine:", 1, true))
end)
```

This is a regression test and is expected to pass after Task 4 without production UI changes.

- [ ] **Step 2: Run the full test suite**

```bash
lua5.1 tests/run.lua
```

Expected: all tests pass.

- [ ] **Step 3: Run the same Lua 5.1 syntax validation as CI**

```bash
set -euo pipefail
while IFS= read -r -d '' file; do
    luac5.1 -p "$file"
done < <(find . -type f -name '*.lua' -not -path './.git/*' -print0)
```

Expected: no output from `luac5.1` and exit status 0.

- [ ] **Step 4: Verify no profession synchronization/protocol files changed**

Run:

```bash
git diff -- GuildGearMemory/ProfessionLinkSave.lua GuildGearMemory/SyncProtocol.lua GuildGearMemory/SyncTransport.lua GuildGearMemory/GuildSync.lua
```

Expected: no diff.

Then verify the login/catalog work did not add profession capture calls to `Main.lua` or `LocalGearMemory.lua`:

```bash
grep -n "CaptureLinkedProfessionSnapshot\|SaveProfessionSnapshot\|SendAddonMessage" GuildGearMemory/Main.lua GuildGearMemory/LocalGearMemory.lua
```

Expected: no matches.

- [ ] **Step 5: Commit the presentation/boundary regression test**

```bash
git add tests/snapshot_test_ui_test.lua
git commit -m "test: lock profession owner presentation"
```

---

### Task 6: Final acceptance pass and documentation handoff

**Files:**
- Create: `docs/superpowers/plans/2026-10-01-local-alt-profession-visibility.md`
- Track: `docs/superpowers/specs/2026-10-01-local-alt-profession-visibility-design.md`
- Verify all files changed by Tasks 1-5.

- [ ] **Step 1: Run the complete automated suite one final time**

```bash
lua5.1 tests/run.lua
```

Expected: all tests pass.

- [ ] **Step 2: Review the final diff against the intended file set**

```bash
git status --short
git diff --stat
git diff -- GuildGearMemory/Constants.lua GuildGearMemory/Storage.lua GuildGearMemory/LocalGearMemory.lua GuildGearMemory/Main.lua GuildGearMemory/ProfessionIndex.lua tests/storage_test.lua tests/local_gear_memory_test.lua tests/main_test.lua tests/profession_index_test.lua tests/snapshot_test_ui_test.lua
```

Expected production changes are limited to:
- schema/ownership storage;
- login GUID recording;
- roster purge;
- recipe-catalog eligibility.

No new production file, addon-message type, profession capture trigger, or UI ownership badge should appear.

- [ ] **Step 3: Perform an in-game smoke test using only supported addon APIs**

Use a test SavedVariables copy and verify this exact sequence:

1. Log into character A.
2. Confirm `GuildGearMemoryDB.localCharacterGUIDs[UnitGUID("player")] == true`.
3. Without opening/saving a profession, open the recipe browser and confirm character A is not fabricated as a recipe owner.
4. Open A's profession and click Save Snapshot.
5. Confirm A's saved recipe appears.
6. Log into character B on the same account, outside the guild.
7. Save B's profession manually.
8. With guild-roster membership unavailable/unconfirmed, confirm B's saved recipes remain visible and non-local cached guild rows are withheld.
9. After a successful guild roster refresh, confirm current guild-member snapshots appear alongside A/B local snapshots.
10. Use a test copy where a non-local cached member is absent from a complete roster; confirm that character's gear, profession record, registry mapping, and recipe-index references are removed.
11. Confirm a locally owned character absent from that roster remains stored and visible if it has a saved profession snapshot.
12. Confirm opening/searching/changing profession tabs sends no addon messages and does not create a profession snapshot.

- [ ] **Step 4: Stage the plan/spec explicitly if the checkout ignores `Docs` case-insensitively**

```bash
git add -f docs/superpowers/plans/2026-10-01-local-alt-profession-visibility.md docs/superpowers/specs/2026-10-01-local-alt-profession-visibility-design.md
git status --short
```

Expected: both documentation files are staged/tracked along with the implementation commits. Do not stage unrelated ignored documentation.

- [ ] **Step 5: Commit documentation if it was not included earlier**

```bash
git commit -m "docs: add local alt profession visibility plan"
```

If the plan/spec were already included in a prior feature commit, skip this commit rather than creating an empty commit.

---

## Self-Review Against the Specification

### Spec coverage

- **Login records stable local GUID ownership:** Task 2.
- **Login ownership alone creates no profession snapshot:** Task 2 tests and smoke steps 1-4.
- **Manual Save Snapshot remains the capture trigger:** no `ProfessionLinkSave.lua` production change; Task 5 boundary check.
- **Guild-link capture still requires current membership:** existing `profession_link_save_test.lua` suite remains unchanged and runs in every full-suite step.
- **Browser eligibility is local GUID OR confirmed current guild member:** Task 4.
- **Local out-of-guild saved snapshot visible while roster unconfirmed:** Task 4 explicit test.
- **Non-local data withheld while roster unconfirmed:** Task 4 explicit test.
- **Other guild members' former/out-of-guild alts excluded:** Tasks 3 and 4.
- **Name/realm only, no ownership/guild badge:** Task 5.
- **Cached date behavior preserved:** existing catalog/UI tests plus Task 5.
- **Recipe rows remain deduplicated and resolve valid local IDs:** Task 4 reuses the existing index and adds a mixed-owner dedupe test.
- **Failed/incomplete roster does not delete:** Task 3 explicit zero-count test plus existing failure/rename-conflict tests.
- **Unresolved legacy local records survive a complete roster without being classified as local:** Task 3 migration-plus-roster regression test.
- **Complete roster deletes absent non-local gear + profession + derived references:** Task 3 explicit test.
- **Local data survives guild departure:** Task 3 tests for profession and gear-only records.
- **No automatic profession addon-message exchange:** Task 5 diff check.
- **No UI-triggered roster/profession/network activity:** existing UI tests remain in the full suite; Task 5 grep/diff checks.
- **Migration is bounded, deterministic, retry-safe, and does not transmit:** Task 1.
- **Unresolved legacy local keys are not guessed from name/realm:** Task 1 explicit migration test.
- **Existing search/sorting/localization/malformed-data safeguards remain:** Task 4 keeps and reruns the existing catalog tests; Task 5 reruns UI tests.
- **Confirmed roster results do not show an unconfirmed-membership warning:** Task 4 confirmed-catalog regression assertion.

### Placeholder scan

The implementation steps above name the exact functions, fields, error strings, tests, commands, and expected outcomes. There are no deferred implementation placeholders.

### Type/name consistency

Use these exact names throughout implementation:

```text
db.localCharacterGUIDs
GGM.MarkLocalCharacterGUID
GGM.IsLocalCharacterGUID
GGM.RecordLocalPlayerOwnership
GGM.EnsureProfessionIndex(db, validateFully, expectedSchemaVersion)
GGM.ReconcileProfessionGuildRoster
GGM.BuildProfessionRecipeCatalog
```

Do not introduce a second ownership field or infer ownership into `professionCharacters.active`; `active` continues to mean current guild membership only.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-10-01-local-alt-profession-visibility.md`. Two execution options:

**1. Subagent-Driven (recommended)** - Dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
