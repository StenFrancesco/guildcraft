local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionIndex.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    return GGM
end

T.test("first-run database creates profession index state", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))

    T.assertEqual(db.schemaVersion, 4)
    T.assertEqual(db.nextLocalCharacterID, 1)
    T.assertEqual(type(db.professionCharacters), "table")
    T.assertEqual(type(db.localCharacterIDByGUID), "table")
    T.assertEqual(type(db.professionRecipeIndex), "table")
    T.assertEqual(db.professionRecipeIndexVersion, GGM.PROFESSION_RECIPE_INDEX_VERSION)
    T.assertFalse(db.professionIndexDataIncomplete)
    T.assertFalse(db.professionIndexRepairNeeded)
end)

T.test("profession index state never reuses assigned local character IDs", function()
    local GGM = loadModules()
    local counters = { 3, false }

    for _, nextLocalCharacterID in ipairs(counters) do
        local db = {
            professions = {},
            professionCharacters = {
                [4] = { guid = "Player-1-A" },
                [12] = { guid = "Player-2-B" },
            },
            localCharacterIDByGUID = {
                ["Player-1-A"] = 4,
                ["Player-2-B"] = 12,
            },
            nextLocalCharacterID = nextLocalCharacterID,
        }

        local ok, err = GGM.InitializeProfessionIndexState(db)

        T.assertTrue(ok)
        T.assertNil(err)
        T.assertEqual(db.nextLocalCharacterID, 13)
    end

    local db = {
        professions = {},
        professionCharacters = { [12] = { guid = "Player-2-B" } },
        localCharacterIDByGUID = { ["Player-2-B"] = 12 },
        nextLocalCharacterID = 20,
    }

    local ok, err = GGM.InitializeProfessionIndexState(db)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(db.nextLocalCharacterID, 20)
end)

T.test("profession index state fails closed when no monotonic next ID can be represented", function()
    local GGM = loadModules()
    local db = {
        professions = {},
        professionCharacters = { [1e100] = { guid = "Player-Overflow" } },
        localCharacterIDByGUID = { ["Player-Overflow"] = 1e100 },
        nextLocalCharacterID = false,
    }

    local ok, err = GGM.InitializeProfessionIndexState(db)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-character-id-exhausted")
    T.assertFalse(db.professionCharacters[1e100] == nil)
end)

T.test("profession index state rejects a counter that cannot advance even with empty registries", function()
    local GGM = loadModules()
    local db = {
        professions = {},
        professionCharacters = {},
        localCharacterIDByGUID = {},
        nextLocalCharacterID = 1e100,
    }

    local ok, err = GGM.InitializeProfessionIndexState(db)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-character-id-exhausted")
    T.assertEqual(db.nextLocalCharacterID, 1e100)
end)

T.test("local profession IDs are stable and retired IDs are not reused", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }))
    T.assertEqual(aliceID, 1)
    assert(GGM.SetProfessionCharacterActive(db, aliceID, false))
    local bobID = assert(GGM.EnsureProfessionCharacter(db, {
        key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B",
    }))
    T.assertEqual(bobID, 2)
    T.assertEqual(db.nextLocalCharacterID, 3)
    T.assertEqual(db.localCharacterIDByGUID["Player-1-A"], 1)
end)

local function indexedIdentity(GGM, key, guid)
    return { key = key, name = key:match("^([^-]+)"), realm = "Silvermoon", guid = guid }
end

local function indexedSnapshot(GGM, professionID, recipeID)
    return {
        professionID = professionID,
        professionName = professionID == 171 and "Alchemy" or "Blacksmithing",
        capturedAt = 1700000000,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = recipeID, name = "Recipe" } },
    }
end

T.test("unsupported or malformed recipe index rebuilds from canonical snapshots", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local id = assert(GGM.EnsureProfessionCharacter(db, identity))
    assert(GGM.SetProfessionCharacterActive(db, id, true))
    db.professions[identity.key] = { identity = identity, snapshots = { [171] = indexedSnapshot(GGM, 171, 200) } }
    db.professionRecipeIndexVersion = 999
    db.professionRecipeIndex = { broken = true }

    local ok, err = GGM.EnsureProfessionIndex(db)
    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(db.professionRecipeIndexVersion, GGM.PROFESSION_RECIPE_INDEX_VERSION)
    T.assertTrue(db.professionRecipeIndex[171][200][id])

    db.professionRecipeIndex = { [171] = { [200] = { ["not-a-local-id"] = true } } }
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    assert(GGM.EnsureProfessionIndex(db, true))
    T.assertTrue(db.professionRecipeIndex[171][200][id])
    T.assertNil(db.professionRecipeIndex[171][200]["not-a-local-id"])
end)

T.test("stale registry key rebuilds from canonical GUID and preserves inactive state", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local localID = assert(GGM.EnsureProfessionCharacter(db, identity))
    db.professionCharacters[localID].key = "OldName-Silvermoon"
    db.professionCharacters[localID].active = false
    db.professions[identity.key] = { identity = identity, snapshots = { [171] = indexedSnapshot(GGM, 171, 200) } }
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION

    assert(GGM.EnsureProfessionIndex(db, true))
    T.assertEqual(db.localCharacterIDByGUID[identity.guid], localID)
    T.assertEqual(db.professionCharacters[localID].key, identity.key)
    T.assertFalse(db.professionCharacters[localID].active)
    T.assertNil(db.professionRecipeIndex[171])
end)

T.test("profession recipe lookup resolves active local IDs through the registry", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    db.professions[identity.key] = { identity = identity, snapshots = { [164] = indexedSnapshot(GGM, 164, 100) } }
    assert(GGM.EnsureProfessionIndex(db, true))
    local id = db.localCharacterIDByGUID[identity.guid]
    assert(GGM.SetProfessionCharacterActive(db, id, true))
    assert(GGM.RebuildProfessionRecipeIndex(db))
    GGM.professionRosterMembershipCurrent = true

    local characters = assert(GGM.GetProfessionRecipeCharacters(db, 164, 100))
    T.assertEqual(#characters, 1)
    T.assertEqual(characters[1].localCharacterID, id)
    T.assertEqual(characters[1].guid, identity.guid)
    T.assertEqual(characters[1].key, identity.key)
end)

T.test("malformed active snapshots produce an unavailable index without repeated rebuilds", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local localID = assert(GGM.EnsureProfessionCharacter(db, identity))
    assert(GGM.SetProfessionCharacterActive(db, localID, true))
    db.professions[identity.key] = { identity = identity, snapshots = { [171] = { professionID = 171, recipes = "malformed" } } }
    db.professionRecipeIndexVersion = 0

    assert(GGM.EnsureProfessionIndex(db))
    T.assertTrue(db.professionIndexDataIncomplete)
    T.assertEqual(db.professionRecipeIndexVersion, GGM.PROFESSION_RECIPE_INDEX_VERSION)
    local rebuildCount = 0
    local rebuild = GGM.RebuildProfessionRecipeIndex
    GGM.RebuildProfessionRecipeIndex = function(...) rebuildCount = rebuildCount + 1; return rebuild(...) end
    GGM.professionRosterMembershipCurrent = true
    local first, firstErr = GGM.GetProfessionRecipeCharacters(db, 171, 200)
    local second, secondErr = GGM.GetProfessionRecipeCharacters(db, 171, 200)
    T.assertNil(first)
    T.assertEqual(firstErr, "profession-index-incomplete")
    T.assertNil(second)
    T.assertEqual(secondErr, "profession-index-incomplete")
    T.assertEqual(rebuildCount, 0)
end)

T.test("active canonical record without snapshots makes the recipe index unavailable", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local localID = assert(GGM.EnsureProfessionCharacter(db, identity))
    assert(GGM.SetProfessionCharacterActive(db, localID, true))
    db.professions[identity.key] = { identity = identity, snapshots = false }
    db.professionRecipeIndexVersion = 0
    assert(GGM.EnsureProfessionIndex(db))
    GGM.professionRosterMembershipCurrent = true

    local results, err = GGM.GetProfessionRecipeCharacters(db, 171, 200)

    T.assertNil(results)
    T.assertEqual(err, "profession-index-incomplete")
    T.assertTrue(db.professionIndexDataIncomplete)
end)

T.test("normal recipe lookups skip full canonical consistency scans", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local fullValidationCount = 0
    local validate = GGM.ValidateProfessionIndexCache
    GGM.ValidateProfessionIndexCache = function(...) fullValidationCount = fullValidationCount + 1; return validate(...) end
    GGM.professionRosterMembershipCurrent = true
    assert(GGM.GetProfessionRecipeCharacters(db, 164, 100))
    T.assertEqual(fullValidationCount, 0)
end)

T.test("duplicate canonical GUIDs are preserved and omitted from the index", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local guid = "Player-1-A"
    local first = indexedIdentity(GGM, "Alice-Silvermoon", guid)
    local second = indexedIdentity(GGM, "Alice-ArgentDawn", guid)
    db.professions[first.key] = { identity = first, snapshots = { [171] = indexedSnapshot(GGM, 171, 200) } }
    db.professions[second.key] = { identity = second, snapshots = { [164] = indexedSnapshot(GGM, 164, 100) } }
    assert(GGM.EnsureProfessionIndex(db, true))
    T.assertNotNil(db.professions[first.key])
    T.assertNotNil(db.professions[second.key])
    T.assertNil(db.localCharacterIDByGUID[guid])
    T.assertTrue(db.professionIndexRepairNeeded)
    T.assertNil(next(db.professionCharacters))
    T.assertNil(next(db.professionRecipeIndex))
end)

T.test("recipe queries stay unavailable until guild membership is current", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    GGM.professionRosterMembershipCurrent = false
    local results, err = GGM.GetProfessionRecipeCharacters(db, 164, 100)
    T.assertNil(results)
    T.assertEqual(err, "profession-roster-incomplete")
end)

T.test("registry rebuild preserves numeric IDs reserved only by the reverse map", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local reservedID = 37
    local canonical = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    db.localCharacterIDByGUID["Player-1-Retired"] = reservedID
    db.nextLocalCharacterID = 2
    db.professions[canonical.key] = {
        identity = canonical,
        snapshots = { [171] = indexedSnapshot(GGM, 171, 200) },
    }

    assert(GGM.RebuildProfessionRecipeIndex(db))

    local allocatedID = db.localCharacterIDByGUID[canonical.guid]
    T.assertTrue(allocatedID > reservedID)
    T.assertEqual(db.nextLocalCharacterID, allocatedID + 1)
    T.assertNil(db.localCharacterIDByGUID["Player-1-Retired"])
    T.assertNil(db.professionCharacters[reservedID])
    T.assertEqual(db.professions[canonical.key].identity.guid, canonical.guid)
end)

T.test("incremental profession reconciliation removes only one character from one profession", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local bob = { key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B" }
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, alice))
    local bobID = assert(GGM.EnsureProfessionCharacter(db, bob))
    assert(GGM.SetProfessionCharacterActive(db, aliceID, true))
    assert(GGM.SetProfessionCharacterActive(db, bobID, true))
    db.professionRecipeIndex = {
        [164] = { [100] = { [aliceID] = true }, [200] = { [aliceID] = true } },
        [171] = { [300] = { [aliceID] = true, [bobID] = true } },
    }
    local replacement = {
        professionID = 164, professionName = "Blacksmithing", capturedAt = 2,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 400, name = "Steel Belt" } },
    }

    assert(GGM.ReconcileProfessionRecipeMembership(db, aliceID, replacement))

    T.assertNil(db.professionRecipeIndex[164][100])
    T.assertNil(db.professionRecipeIndex[164][200])
    T.assertTrue(db.professionRecipeIndex[164][400][aliceID])
    T.assertTrue(db.professionRecipeIndex[171][300][aliceID])
    T.assertTrue(db.professionRecipeIndex[171][300][bobID])
end)
