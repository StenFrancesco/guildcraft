local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionIndex.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    return GGM
end

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

T.test("profession index state advances malformed numeric counters above their prior value", function()
    local GGM = loadModules()
    local db = {
        professions = {},
        professionCharacters = {},
        localCharacterIDByGUID = {},
        nextLocalCharacterID = 100.5,
    }

    local ok, err = GGM.InitializeProfessionIndexState(db)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertTrue(db.nextLocalCharacterID >= 101)
end)

T.test("profession index state fails closed when no numeric high-water can be established", function()
    local GGM = loadModules()
    local db = {
        professions = {},
        professionCharacters = {},
        localCharacterIDByGUID = {},
        nextLocalCharacterID = "corrupt-counter",
    }

    local ok, err = GGM.InitializeProfessionIndexState(db)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-character-id-exhausted")
end)

T.test("startup repairs a malformed registry key from canonical profession data", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local canonical = { identity = identity, snapshots = { [164] = indexedSnapshot(GGM, 164, 100) } }
    db.professions[identity.key] = canonical
    db.professionCharacters = {
        ["malformed-id"] = { guid = "Player-1-OLD", key = "Old-Silvermoon", active = true },
    }
    db.localCharacterIDByGUID = {}
    db.nextLocalCharacterID = 8

    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(err)
    T.assertTrue(initialized == db)
    T.assertTrue(db.professions[identity.key] == canonical)
    local repairedID = db.localCharacterIDByGUID[identity.guid]
    T.assertTrue(repairedID >= 9)
    T.assertEqual(db.professionCharacters[repairedID].guid, identity.guid)
end)

T.test("startup repairs a malformed reverse registry value from canonical profession data", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local canonical = { identity = identity, snapshots = { [164] = indexedSnapshot(GGM, 164, 100) } }
    db.professions[identity.key] = canonical
    db.professionCharacters = {}
    db.localCharacterIDByGUID = { [identity.guid] = "malformed-id" }
    db.nextLocalCharacterID = 8

    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(err)
    T.assertTrue(initialized == db)
    T.assertTrue(db.professions[identity.key] == canonical)
    local repairedID = db.localCharacterIDByGUID[identity.guid]
    T.assertTrue(repairedID >= 9)
    T.assertEqual(db.professionCharacters[repairedID].guid, identity.guid)
end)

T.test("unsafe profession ID high-water keeps startup available but marks index incomplete", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local canonical = { identity = identity, snapshots = { [164] = indexedSnapshot(GGM, 164, 100) } }
    db.professions[identity.key] = canonical
    db.professionCharacters = { [1e100] = { guid = "Player-1-OLD", key = "Old-Silvermoon", active = true } }
    db.localCharacterIDByGUID = {}
    db.nextLocalCharacterID = 1e100

    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(err)
    T.assertTrue(initialized == db)
    T.assertTrue(db.professions[identity.key] == canonical)
    T.assertTrue(db.professionIndexDataIncomplete)
    T.assertTrue(db.professionIndexRepairNeeded)
    GGM.professionRosterMembershipCurrent = true
    local results, queryErr = GGM.GetProfessionRecipeCharacters(db, 164, 100)
    T.assertNil(results)
    T.assertEqual(queryErr, "profession-index-incomplete")
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

T.test("snapshots without a canonical GUID keep the recipe index incomplete", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    db.professions["Legacy-Silvermoon"] = {
        identity = { key = "Legacy-Silvermoon", name = "Legacy", realm = "Silvermoon" },
        snapshots = { [164] = indexedSnapshot(GGM, 164, 100) },
    }
    db.professionRecipeIndexVersion = 0

    assert(GGM.RebuildProfessionRecipeIndex(db))
    GGM.professionRosterMembershipCurrent = true
    local results, err = GGM.GetProfessionRecipeCharacters(db, 164, 100)

    T.assertTrue(db.professionIndexDataIncomplete)
    T.assertNil(results)
    T.assertEqual(err, "profession-index-incomplete")
end)

T.test("saving a new GUID does not claim snapshots from an ownerless legacy row", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local oldSnapshot = indexedSnapshot(GGM, 164, 100)
    db.professions[identity.key] = {
        identity = { key = identity.key, name = "Alice", realm = "Silvermoon" },
        snapshots = { [164] = oldSnapshot },
    }

    local localID, err = GGM.PrepareProfessionCharacterForSave(db, identity, true)

    T.assertNil(localID)
    T.assertEqual(err, "profession-key-collision")
    T.assertNil(db.localCharacterIDByGUID[identity.guid])
    T.assertNil(db.professions[identity.key].identity.guid)
    T.assertEqual(db.professions[identity.key].snapshots[164], oldSnapshot)
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

T.test("registry disagreement is repaired from unambiguous canonical GUIDs without reusing old IDs", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    db.professions["Alice-Silvermoon"] = {
        identity = {
            key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
        },
        snapshots = {},
    }
    db.professionCharacters = {
        [7] = { guid = "Player-1-BAD", key = "Bad-Silvermoon", active = true },
    }
    db.localCharacterIDByGUID = { ["Player-1-A"] = 7 }
    db.nextLocalCharacterID = 8
    db.professionRecipeIndexVersion = 0

    local ok, err = GGM.EnsureProfessionIndex(db)

    T.assertTrue(ok)
    T.assertNil(err)
    local repairedID = db.localCharacterIDByGUID["Player-1-A"]
    T.assertTrue(repairedID >= 8)
    T.assertTrue(repairedID >= 9)
    T.assertEqual(db.professionCharacters[repairedID].guid, "Player-1-A")
    T.assertTrue(db.nextLocalCharacterID > repairedID)
end)

T.test("overlapping canonical snapshots for one GUID remain excluded and flagged for repair", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local sharedGUID = "Player-1-A"
    db.professions = {
        ["Alice-Silvermoon"] = {
            identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = sharedGUID },
            snapshots = { [164] = indexedSnapshot(GGM, 164, 100) },
        },
        ["Alicia-Silvermoon"] = {
            identity = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = sharedGUID },
            snapshots = { [164] = indexedSnapshot(GGM, 164, 101) },
        },
    }
    db.professionRecipeIndexVersion = 0

    assert(GGM.EnsureProfessionIndex(db))

    T.assertTrue(db.professionIndexRepairNeeded)
    T.assertNil(db.localCharacterIDByGUID[sharedGUID])
    T.assertNotNil(db.professions["Alice-Silvermoon"])
    T.assertNotNil(db.professions["Alicia-Silvermoon"])
end)

T.test("duplicate canonical records with disjoint professions remain untouched and unavailable", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local sharedGUID = "Player-1-A"
    db.professions = {
        ["Alice-Silvermoon"] = {
            identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = sharedGUID },
            snapshots = { [164] = indexedSnapshot(GGM, 164, 100) },
        },
        ["Alicia-Silvermoon"] = {
            identity = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = sharedGUID },
            snapshots = { [171] = indexedSnapshot(GGM, 171, 300) },
        },
    }
    db.professionRecipeIndexVersion = 0

    assert(GGM.EnsureProfessionIndex(db))

    T.assertNotNil(db.professions["Alicia-Silvermoon"])
    T.assertNotNil(db.professions["Alice-Silvermoon"].snapshots[164])
    T.assertNotNil(db.professions["Alicia-Silvermoon"].snapshots[171])
    T.assertNil(db.localCharacterIDByGUID[sharedGUID])
    T.assertNil(db.professionRecipeIndex[164])
    T.assertNil(db.professionRecipeIndex[171])
    T.assertTrue(db.professionIndexRepairNeeded)
    GGM.professionRosterMembershipCurrent = true
    local results, queryErr = GGM.GetProfessionRecipeCharacters(db, 164, 100)
    T.assertNil(results)
    T.assertEqual(queryErr, "profession-index-repair-needed")
end)

T.test("verified save recovers duplicate GUID records after rebuild when registry provenance is trusted", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local sourceIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local destinationIdentity = indexedIdentity(GGM, "Alicia-Silvermoon", sourceIdentity.guid)
    local sourceSnapshot = indexedSnapshot(GGM, 164, 100)
    local destinationSnapshot = indexedSnapshot(GGM, 171, 300)
    assert(GGM.SaveProfessionSnapshot(db, sourceIdentity, sourceSnapshot, { guildMembershipVerified = true }))
    local trustedID = db.localCharacterIDByGUID[sourceIdentity.guid]
    db.professions[destinationIdentity.key] = {
        identity = destinationIdentity,
        snapshots = { [171] = destinationSnapshot },
    }
    db.professionRecipeIndexVersion = 0

    assert(GGM.EnsureProfessionIndex(db, true))
    T.assertNil(db.localCharacterIDByGUID[sourceIdentity.guid])
    T.assertTrue(db.professionIndexRepairNeeded)
    GGM.professionRosterMembershipCurrent = true
    local beforeRepair, beforeRepairErr = GGM.GetProfessionRecipeCharacters(db, 171, 300)
    T.assertNil(beforeRepair)
    T.assertEqual(beforeRepairErr, "profession-index-repair-needed")

    local repairedSnapshot = indexedSnapshot(GGM, 164, 100)
    repairedSnapshot.capturedAt = sourceSnapshot.capturedAt + 1
    local saved, saveErr = GGM.SaveProfessionSnapshot(
        db,
        destinationIdentity,
        repairedSnapshot,
        { guildMembershipVerified = true }
    )

    T.assertTrue(saved)
    T.assertNil(saveErr)
    T.assertNil(db.professions[sourceIdentity.key])
    T.assertNotNil(db.professions[destinationIdentity.key].snapshots[164])
    T.assertNotNil(db.professions[destinationIdentity.key].snapshots[171])
    T.assertEqual(db.localCharacterIDByGUID[sourceIdentity.guid], trustedID)
    T.assertEqual(db.professionCharacters[trustedID].key, destinationIdentity.key)
    T.assertFalse(db.professionIndexRepairNeeded)
    local recovered = assert(GGM.GetProfessionRecipeCharacters(db, 171, 300))
    T.assertEqual(#recovered, 1)
    T.assertEqual(recovered[1].localCharacterID, trustedID)
    T.assertEqual(recovered[1].key, destinationIdentity.key)
end)

T.test("rebuild keeps persisted repair candidate IDs reserved when counter rolls back", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local seedIdentity = indexedIdentity(GGM, "Charlie-Silvermoon", "Player-1-C")
    assert(GGM.SaveProfessionSnapshot(db, seedIdentity, indexedSnapshot(GGM, 164, 50), {
        guildMembershipVerified = true,
    }))
    local sourceIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local destinationIdentity = indexedIdentity(GGM, "Alicia-Silvermoon", sourceIdentity.guid)
    local sourceSnapshot = indexedSnapshot(GGM, 164, 100)
    assert(GGM.SaveProfessionSnapshot(db, sourceIdentity, sourceSnapshot, {
        guildMembershipVerified = true,
    }))
    local reservedID = db.localCharacterIDByGUID[sourceIdentity.guid]
    local seedID = db.localCharacterIDByGUID[seedIdentity.guid]
    T.assertTrue(reservedID > seedID)
    db.professions[destinationIdentity.key] = {
        identity = destinationIdentity,
        snapshots = { [171] = indexedSnapshot(GGM, 171, 300) },
    }
    db.professionRecipeIndexVersion = 0
    assert(GGM.EnsureProfessionIndex(db, true))
    T.assertEqual(db.professionIndexRepairCandidates[sourceIdentity.guid].localID, reservedID)

    local otherIdentity = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    db.professions[otherIdentity.key] = {
        identity = otherIdentity,
        snapshots = { [164] = indexedSnapshot(GGM, 164, 200) },
    }
    db.nextLocalCharacterID = 1
    db.professionRecipeIndexVersion = 0
    assert(GGM.EnsureProfessionIndex(db, true))

    local otherID = db.localCharacterIDByGUID[otherIdentity.guid]
    T.assertTrue(otherID ~= reservedID)
    T.assertEqual(db.professionIndexRepairCandidates[sourceIdentity.guid].localID, reservedID)
    T.assertTrue(db.professionIndexRepairNeeded)

    local repairedSnapshot = indexedSnapshot(GGM, 164, 101)
    repairedSnapshot.capturedAt = sourceSnapshot.capturedAt + 1
    local saved, saveErr = GGM.SaveProfessionSnapshot(
        db,
        destinationIdentity,
        repairedSnapshot,
        { guildMembershipVerified = true }
    )
    T.assertTrue(saved)
    T.assertNil(saveErr)
    T.assertEqual(db.localCharacterIDByGUID[sourceIdentity.guid], reservedID)
    T.assertEqual(db.localCharacterIDByGUID[otherIdentity.guid], otherID)
    T.assertEqual(db.localCharacterIDByGUID[seedIdentity.guid], seedID)
    T.assertNil(db.professionIndexRepairCandidates[sourceIdentity.guid])
end)

T.test("verified save cannot recover duplicate GUID records without registry provenance", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local sourceIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local destinationIdentity = indexedIdentity(GGM, "Alicia-Silvermoon", sourceIdentity.guid)
    local sourceRecord = { identity = sourceIdentity, snapshots = { [164] = indexedSnapshot(GGM, 164, 100) } }
    local destinationRecord = { identity = destinationIdentity, snapshots = { [171] = indexedSnapshot(GGM, 171, 300) } }
    db.professions[sourceIdentity.key] = sourceRecord
    db.professions[destinationIdentity.key] = destinationRecord
    db.professionCharacters = {}
    db.localCharacterIDByGUID = {}
    db.professionRecipeIndexVersion = 0

    assert(GGM.EnsureProfessionIndex(db, true))
    local saved, err = GGM.SaveProfessionSnapshot(
        db,
        destinationIdentity,
        indexedSnapshot(GGM, 164, 101),
        { guildMembershipVerified = true }
    )

    T.assertFalse(saved)
    T.assertEqual(err, "profession-identity-ambiguous")
    T.assertTrue(db.professions[sourceIdentity.key] == sourceRecord)
    T.assertTrue(db.professions[destinationIdentity.key] == destinationRecord)
    T.assertNil(db.localCharacterIDByGUID[sourceIdentity.guid])
    T.assertTrue(db.professionIndexRepairNeeded)
end)

T.test("verified save keeps duplicate GUID records blocked when a third record appears after rebuild", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local sourceIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local destinationIdentity = indexedIdentity(GGM, "Alicia-Silvermoon", sourceIdentity.guid)
    local thirdIdentity = indexedIdentity(GGM, "Ally-Silvermoon", sourceIdentity.guid)
    assert(GGM.SaveProfessionSnapshot(db, sourceIdentity, indexedSnapshot(GGM, 164, 100), {
        guildMembershipVerified = true,
    }))
    local sourceRecord = db.professions[sourceIdentity.key]
    local destinationRecord = { identity = destinationIdentity, snapshots = { [171] = indexedSnapshot(GGM, 171, 300) } }
    db.professions[destinationIdentity.key] = destinationRecord
    db.professionRecipeIndexVersion = 0
    assert(GGM.EnsureProfessionIndex(db, true))
    local thirdRecord = { identity = thirdIdentity, snapshots = {} }
    db.professions[thirdIdentity.key] = thirdRecord

    local saved, err = GGM.SaveProfessionSnapshot(
        db,
        destinationIdentity,
        indexedSnapshot(GGM, 164, 101),
        { guildMembershipVerified = true }
    )

    T.assertFalse(saved)
    T.assertEqual(err, "profession-identity-ambiguous")
    T.assertTrue(db.professions[sourceIdentity.key] == sourceRecord)
    T.assertTrue(db.professions[destinationIdentity.key] == destinationRecord)
    T.assertTrue(db.professions[thirdIdentity.key] == thirdRecord)
    T.assertNil(db.localCharacterIDByGUID[sourceIdentity.guid])
    T.assertTrue(db.professionIndexRepairNeeded)
end)

T.test("verified save does not recover duplicate GUID records with overlapping professions", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local sourceIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local destinationIdentity = indexedIdentity(GGM, "Alicia-Silvermoon", sourceIdentity.guid)
    assert(GGM.SaveProfessionSnapshot(db, sourceIdentity, indexedSnapshot(GGM, 164, 100), {
        guildMembershipVerified = true,
    }))
    assert(GGM.SaveProfessionSnapshot(db, sourceIdentity, indexedSnapshot(GGM, 171, 200)))
    local sourceRecord = db.professions[sourceIdentity.key]
    local destinationRecord = { identity = destinationIdentity, snapshots = { [171] = indexedSnapshot(GGM, 171, 300) } }
    db.professions[destinationIdentity.key] = destinationRecord
    db.professionRecipeIndexVersion = 0
    assert(GGM.EnsureProfessionIndex(db, true))

    local saved, err = GGM.SaveProfessionSnapshot(
        db,
        destinationIdentity,
        indexedSnapshot(GGM, 164, 101),
        { guildMembershipVerified = true }
    )

    T.assertFalse(saved)
    T.assertEqual(err, "profession-rename-profession-conflict")
    T.assertTrue(db.professions[sourceIdentity.key] == sourceRecord)
    T.assertTrue(db.professions[destinationIdentity.key] == destinationRecord)
    T.assertNil(db.localCharacterIDByGUID[sourceIdentity.guid])
    T.assertTrue(db.professionIndexRepairNeeded)
end)

T.test("near-exhausted profession ID counter keeps startup available and preserves canonical data", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local firstIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local secondIdentity = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    local firstRecord = { identity = firstIdentity, snapshots = { [164] = indexedSnapshot(GGM, 164, 100) } }
    local secondRecord = { identity = secondIdentity, snapshots = { [171] = indexedSnapshot(GGM, 171, 300) } }
    db.professions[firstIdentity.key] = firstRecord
    db.professions[secondIdentity.key] = secondRecord
    local priorCounter = 2 ^ 53 - 2
    db.nextLocalCharacterID = priorCounter
    db.professionRecipeIndexVersion = 0

    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(err)
    T.assertTrue(initialized == db)
    T.assertTrue(db.professions[firstIdentity.key] == firstRecord)
    T.assertTrue(db.professions[secondIdentity.key] == secondRecord)
    T.assertTrue(db.nextLocalCharacterID >= priorCounter)
    T.assertTrue(db.professionIndexDataIncomplete)
    T.assertTrue(db.professionIndexRepairNeeded)
    GGM.professionRosterMembershipCurrent = true
    local results, queryErr = GGM.GetProfessionRecipeCharacters(db, 164, 100)
    T.assertNil(results)
    T.assertEqual(queryErr, "profession-index-incomplete")
end)

T.test("canonical GUID record with mismatched storage key makes recipe queries unavailable", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local validIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local invalidIdentity = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    db.professions[validIdentity.key] = {
        identity = validIdentity,
        snapshots = { [164] = indexedSnapshot(GGM, 164, 100) },
    }
    local validID = assert(GGM.EnsureProfessionCharacter(db, validIdentity))
    assert(GGM.SetProfessionCharacterActive(db, validID, true))
    local malformedCanonical = {
        identity = invalidIdentity,
        snapshots = { [164] = indexedSnapshot(GGM, 164, 100) },
    }
    db.professions["Wrong-Key-Silvermoon"] = malformedCanonical
    db.professionRecipeIndexVersion = 0

    assert(GGM.EnsureProfessionIndex(db))

    T.assertTrue(db.professions["Wrong-Key-Silvermoon"] == malformedCanonical)
    T.assertTrue(db.professionIndexDataIncomplete)
    GGM.professionRosterMembershipCurrent = true
    local results, err = GGM.GetProfessionRecipeCharacters(db, 164, 100)
    T.assertNil(results)
    T.assertEqual(err, "profession-index-incomplete")
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

T.test("guild roster reconciliation deactivates departed characters and removes them from search", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[identity.guid]

    local ok, err = GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return false end,
    }, db)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertFalse(db.professionCharacters[localID].active)
    local results = assert(GGM.GetProfessionRecipeCharacters(db, 164, 100))
    T.assertEqual(#results, 0)
    T.assertNotNil(db.professions[identity.key])
end)

T.test("real guild roster reconciliation sends no addon messages or gear updates", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    db.professions[identity.key] = { identity = identity, snapshots = { [164] = snapshot } }
    local localID = assert(GGM.EnsureProfessionCharacter(db, identity))
    local addonMessageCalls = 0
    local publishCalls = 0
    GGM.PublishConfirmedSlot = function() publishCalls = publishCalls + 1 end
    local api = {
        IsInGuild = function() return true end,
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Alice-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-A"
        end,
        C_ChatInfo = {
            SendAddonMessage = function() addonMessageCalls = addonMessageCalls + 1 end,
        },
    }

    local ok, err = GGM.ReconcileProfessionGuildRoster(api, db)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertTrue(db.professionCharacters[localID].active)
    T.assertEqual(addonMessageCalls, 0)
    T.assertEqual(publishCalls, 0)
end)

T.test("incomplete guild roster leaves cached activity and index unchanged", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[identity.guid]
    local priorIndex = db.professionRecipeIndex

    local ok, err = GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return true end,
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Alice-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, nil
        end,
    }, db)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-roster-incomplete")
    T.assertTrue(db.professionCharacters[localID].active)
    T.assertEqual(db.professionRecipeIndex, priorIndex)
    T.assertTrue(db.professionRecipeIndex[164][100][localID])
end)

T.test("empty roster while still in a guild is unavailable, not an authoritative departure", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[identity.guid]

    local ok, err = GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return true end,
        GetNumGuildMembers = function() return 0 end,
        GetGuildRosterInfo = function() error("should not be called") end,
    }, db)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-roster-incomplete")
    T.assertTrue(db.professionCharacters[localID].active)
end)

T.test("guild roster reconciliation reactivates a known GUID and preserves merged records on rename", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        professionID = 171, professionName = "Alchemy", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 300, name = "Potion" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot))
    local localID = db.localCharacterIDByGUID[identity.guid]
    db.professions["Alice-Argent-Dawn"] = {
        identity = {
            key = "Alice-Argent-Dawn", name = "Alice", realm = "Argent-Dawn", guid = identity.guid,
        },
        snapshots = {
            [164] = {
                professionID = 164, professionName = "Blacksmithing", capturedAt = 2,
                source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
                recipes = { { recipeID = 100, name = "Copper Bracers" } },
            },
        },
    }
    assert(GGM.SetProfessionCharacterActive(db, localID, false))

    local ok = GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return true end,
        GetNumGuildMembers = function(includeOffline)
            T.assertTrue(includeOffline)
            return 1
        end,
        GetGuildRosterInfo = function()
            return "Alice-Argent-Dawn", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-A"
        end,
    }, db)

    T.assertTrue(ok)
    T.assertTrue(db.professionCharacters[localID].active)
    T.assertEqual(db.professionCharacters[localID].key, "Alice-Argent-Dawn")
    T.assertEqual(db.professions["Alice-Argent-Dawn"].identity.name, "Alice")
    T.assertEqual(db.professions["Alice-Argent-Dawn"].identity.realm, "Argent-Dawn")
    T.assertTrue(db.professionRecipeIndex[171][300][localID])
    T.assertTrue(db.professionRecipeIndex[164][100][localID])
    T.assertNil(db.professions["Alice-Silvermoon"])
end)

T.test("failed roster rename preserves the old key and inactive state on a collision", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[identity.guid]
    assert(GGM.SetProfessionCharacterActive(db, localID, false))
    assert(GGM.RebuildProfessionRecipeIndex(db))
    db.professions["Bob-Silvermoon"] = {
        identity = { key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B" },
        snapshots = {},
    }
    local priorIndex = db.professionRecipeIndex

    local ok, err = GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return true end,
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Bob-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-A"
        end,
    }, db)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-roster-rename-conflict")
    T.assertEqual(db.professionCharacters[localID].key, identity.key)
    T.assertFalse(db.professionCharacters[localID].active)
    T.assertEqual(db.professionRecipeIndex, priorIndex)
    T.assertTrue(db.professionIndexRepairNeeded)
    T.assertNotNil(db.professions[identity.key])
    T.assertEqual(db.professions["Bob-Silvermoon"].identity.guid, "Player-1-B")
end)

T.test("roster rename rejects a third canonical same-GUID record without mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[identity.guid]
    db.professions["Alice-Argent-Dawn"] = {
        identity = { key = "Alice-Argent-Dawn", name = "Alice", realm = "Argent-Dawn", guid = identity.guid },
        snapshots = {
            [171] = {
                professionID = 171, professionName = "Alchemy", capturedAt = 2,
                source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
                recipes = { { recipeID = 300, name = "Potion" } },
            },
        },
    }
    db.professions["Alicia-Silvermoon"] = {
        identity = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = identity.guid },
        snapshots = {},
    }
    assert(GGM.SetProfessionCharacterActive(db, localID, false))
    local entryKey = db.professionCharacters[localID].key
    local entryActive = db.professionCharacters[localID].active
    local mappedID = db.localCharacterIDByGUID[identity.guid]
    local priorIndex = db.professionRecipeIndex

    local ok, err = GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return true end,
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Alice-Argent-Dawn", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, identity.guid
        end,
    }, db)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-roster-rename-conflict")
    T.assertEqual(db.professionCharacters[localID].key, entryKey)
    T.assertEqual(db.professionCharacters[localID].active, entryActive)
    T.assertEqual(db.localCharacterIDByGUID[identity.guid], mappedID)
    T.assertEqual(db.professionRecipeIndex, priorIndex)
    T.assertTrue(db.professionIndexRepairNeeded)
    T.assertNotNil(db.professions["Alice-Silvermoon"])
    T.assertNotNil(db.professions["Alice-Argent-Dawn"])
    T.assertNotNil(db.professions["Alicia-Silvermoon"])
end)
