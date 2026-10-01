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
        complete = true,
        professionID = professionID,
        professionName = professionID == 171 and "Alchemy" or "Blacksmithing",
        capturedAt = 1700000000,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = recipeID, name = "Recipe" } },
    }
end

local function indexedMetadata(GGM, professionID)
    return {
        complete = true,
        professionID = professionID,
        professionName = professionID == 171 and "Alchemy" or "Blacksmithing",
        capturedAt = 1700000000,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
    }
end

T.test("profession browser reads saved recipes from the schema five recipe index", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local snapshot = indexedSnapshot(GGM, 164, 41234)
    snapshot.professionName = "Blacksmithing"
    snapshot.recipes[1].name = "Copper Bracers"

    local saved, saveErr = GGM.SaveProfessionSnapshot(db, identity, snapshot, {
        guildMembershipVerified = true,
    })

    T.assertTrue(saved, saveErr)
    T.assertNil(db.professions[identity.key].snapshots[164].recipes)
    T.assertEqual(db.professionRecipeIndex[164][41234].name, "Copper Bracers")
    T.assertEqual(db.professionRecipeIndex[164][41234].crafters[1], 1)

    GGM.professionRosterMembershipCurrent = true
    local model = GGM.BuildProfessionRecipeCatalog(db, 164, "Blacksmithing", {})

    T.assertEqual(model.state, "ready")
    T.assertTrue(model.hasSnapshot)
    T.assertEqual(#model.recipes, 1)
    T.assertEqual(model.recipes[1].recipeID, 41234)
    T.assertEqual(model.recipes[1].name, "Copper Bracers")
    T.assertEqual(model.recipes[1].knownBy[1].key, identity.key)
    T.assertEqual(model.recipes[1].knownBy[1].capturedAt, snapshot.capturedAt)
end)

T.test("first-run database creates profession index state", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))

    T.assertEqual(db.schemaVersion, 5)
    T.assertEqual(db.nextLocalCharacterID, 1)
    T.assertEqual(type(db.professionCharacters), "table")
    T.assertEqual(type(db.localCharacterIDByGUID), "table")
    T.assertEqual(type(db.professionRecipeIndex), "table")
    T.assertEqual(db.professionRecipeIndexVersion, GGM.PROFESSION_RECIPE_INDEX_VERSION)
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

T.test("startup fails closed on a malformed registry key without catalog mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local canonical = { identity = identity, snapshots = { [164] = indexedMetadata(GGM, 164) } }
    db.professions[identity.key] = canonical
    db.professionCharacters = {
        ["malformed-id"] = { guid = "Player-1-OLD", key = "Old-Silvermoon", active = true },
    }
    db.localCharacterIDByGUID = {}
    db.nextLocalCharacterID = 8
    local registry = db.professionCharacters
    local reverseRegistry = db.localCharacterIDByGUID
    local catalog = db.professionRecipeIndex

    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(initialized)
    T.assertEqual(err, "profession-index-invalid")
    T.assertTrue(db.professions[identity.key] == canonical)
    T.assertEqual(db.professionCharacters, registry)
    T.assertEqual(db.localCharacterIDByGUID, reverseRegistry)
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(db.professionCharacters["malformed-id"].guid, "Player-1-OLD")
end)

T.test("startup fails closed on a malformed reverse registry value without catalog mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local canonical = { identity = identity, snapshots = { [164] = indexedMetadata(GGM, 164) } }
    db.professions[identity.key] = canonical
    db.professionCharacters = {}
    db.localCharacterIDByGUID = { [identity.guid] = "malformed-id" }
    db.nextLocalCharacterID = 8
    local registry = db.professionCharacters
    local reverseRegistry = db.localCharacterIDByGUID
    local catalog = db.professionRecipeIndex

    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(initialized)
    T.assertEqual(err, "profession-index-invalid")
    T.assertTrue(db.professions[identity.key] == canonical)
    T.assertEqual(db.professionCharacters, registry)
    T.assertEqual(db.localCharacterIDByGUID, reverseRegistry)
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(db.localCharacterIDByGUID[identity.guid], "malformed-id")
end)

T.test("startup fails closed on malformed repair state without mutation", function()
    local malformedStates = {
        { field = "professionIndexRepairCandidates", value = nil },
        { field = "professionIndexRepairCandidates", value = "corrupt" },
        { field = "professionIndexRepairNeeded", value = nil },
        { field = "professionIndexRepairNeeded", value = "corrupt" },
    }

    for _, malformed in ipairs(malformedStates) do
        local GGM = loadModules()
        local db = assert(GGM.InitializeDatabase(nil))
        db.professionIndexRepairCandidates = { ["keep"] = { localID = 9 } }
        db.professionIndexRepairNeeded = false
        if malformed.value == nil then
            db[malformed.field] = nil
        else
            db[malformed.field] = malformed.value
        end
        local candidates = db.professionIndexRepairCandidates
        local repairNeeded = db.professionIndexRepairNeeded
        local professions = db.professions
        local catalog = db.professionRecipeIndex

        local initialized, err = GGM.InitializeDatabase(db)

        T.assertNil(initialized)
        T.assertEqual(err, "profession-index-invalid")
        T.assertEqual(db.professions, professions)
        T.assertEqual(db.professionIndexRepairCandidates, candidates)
        T.assertEqual(db.professionIndexRepairNeeded, repairNeeded)
        T.assertEqual(db.professionRecipeIndex, catalog)
    end
end)

T.test("unsafe profession ID high-water fails closed without replacing canonical data", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local canonical = { identity = identity, snapshots = { [164] = indexedMetadata(GGM, 164) } }
    db.professions[identity.key] = canonical
    db.professionCharacters = { [1e100] = { guid = "Player-1-OLD", key = "Old-Silvermoon", active = true } }
    db.localCharacterIDByGUID = {}
    db.nextLocalCharacterID = 1e100

    local priorCatalog = db.professionRecipeIndex
    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(initialized)
    T.assertEqual(err, "profession-index-invalid")
    T.assertTrue(db.professions[identity.key] == canonical)
    T.assertEqual(db.professionRecipeIndex, priorCatalog)
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

T.test("unsupported or malformed recipe catalog fails closed without replacement", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local id = assert(GGM.EnsureProfessionCharacter(db, identity))
    db.professions[identity.key] = { identity = identity, snapshots = {} }
    db.professionRecipeIndex = {
        [164] = {
            [100] = {
                name = "Copper Bracers",
                crafters = { id },
            },
        },
    }
    local priorIndex = db.professionRecipeIndex
    db.professionRecipeIndexVersion = 999

    local ok, err = GGM.EnsureProfessionIndex(db)
    T.assertFalse(ok)
    T.assertEqual(err, "profession-index-invalid")
    T.assertEqual(db.professionRecipeIndex, priorIndex)
    T.assertEqual(db.professionRecipeIndexVersion, 999)

    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    local malformedIndex = {
        [164] = {
            [100] = {
                name = "",
                crafters = { id },
            },
        },
    }
    db.professionRecipeIndex = malformedIndex

    local fullOk, fullErr = GGM.EnsureProfessionIndex(db, true)

    T.assertFalse(fullOk)
    T.assertEqual(fullErr, "profession-index-invalid")
    T.assertEqual(db.professionRecipeIndex, malformedIndex)
end)

T.test("profession index rejects old sets and malformed crafter ID lists", function()
    local GGM = loadModules()
    local cases = {
        { name = "old boolean set", crafters = { [1] = true } },
        { name = "duplicate ids", crafters = { 1, 1 } },
        { name = "descending ids", crafters = { 2, 1 } },
        { name = "unregistered id", crafters = { 999 } },
        { name = "sparse positions", crafters = { [1] = 1, [3] = 2 } },
        { name = "non-integer id", crafters = { 1.5 } },
    }

    for _, case in ipairs(cases) do
        local db = assert(GGM.InitializeDatabase(nil))
        local alice = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
        local bob = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
        assert(GGM.EnsureProfessionCharacter(db, alice))
        assert(GGM.EnsureProfessionCharacter(db, bob))
        db.professions[alice.key] = { identity = alice, snapshots = {} }
        db.professions[bob.key] = { identity = bob, snapshots = {} }
        db.professionRecipeIndex = {
            [164] = {
                [100] = {
                    name = "Copper Bracers",
                    crafters = case.crafters,
                },
            },
        }
        db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION

        local ok, err = GGM.EnsureProfessionIndex(db, true)

        T.assertFalse(ok, case.name)
        T.assertEqual(err, "profession-index-invalid", case.name)
    end
end)

T.test("stale registry key fails full validation without catalog mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local localID = assert(GGM.EnsureProfessionCharacter(db, identity))
    db.professionCharacters[localID].key = "OldName-Silvermoon"
    db.professionCharacters[localID].active = false
    db.professions[identity.key] = { identity = identity, snapshots = {} }
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    local catalog = db.professionRecipeIndex

    local ok, err = GGM.EnsureProfessionIndex(db, true)
    T.assertFalse(ok)
    T.assertEqual(err, "profession-index-invalid")
    T.assertEqual(db.localCharacterIDByGUID[identity.guid], localID)
    T.assertEqual(db.professionCharacters[localID].key, "OldName-Silvermoon")
    T.assertFalse(db.professionCharacters[localID].active)
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertNil(db.professionRecipeIndex[171])
end)

T.test("profession recipe lookup resolves active local IDs through the named catalog", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    db.professions[identity.key] = { identity = identity, snapshots = {} }
    local id = assert(GGM.EnsureProfessionCharacter(db, identity))
    db.professionCharacters[id].active = true
    db.professionRecipeIndex[164] = {
        [100] = {
            name = "Copper Bracers",
            crafters = { id },
        },
    }
    GGM.professionRosterMembershipCurrent = true

    local characters, queryErr, membershipCurrent = GGM.GetProfessionRecipeCharacters(db, 164, 100)
    assert(characters, queryErr)
    T.assertTrue(membershipCurrent)
    T.assertEqual(#characters, 1)
    T.assertEqual(characters[1].localCharacterID, id)
    T.assertEqual(characters[1].guid, identity.guid)
    T.assertEqual(characters[1].key, identity.key)
    T.assertTrue(characters[1].membershipCurrent)
end)

T.test("full index validation preserves the authoritative named catalog", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    db.professions[identity.key] = { identity = identity, snapshots = {} }
    local id = assert(GGM.EnsureProfessionCharacter(db, identity))
    local catalog = {
        [164] = {
            [100] = {
                name = "Copper Bracers",
                crafters = { id },
            },
        },
    }
    db.professionRecipeIndex = catalog
    local ok, err = GGM.EnsureProfessionIndex(db, true)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(db.professionRecipeIndex[164][100].name, "Copper Bracers")
    T.assertEqual(#db.professionRecipeIndex[164][100].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], id)
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

T.test("duplicate canonical GUIDs are preserved and omitted from the index", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local guid = "Player-1-A"
    local first = indexedIdentity(GGM, "Alice-Silvermoon", guid)
    local second = indexedIdentity(GGM, "Alice-ArgentDawn", guid)
    db.professions[first.key] = { identity = first, snapshots = { [171] = indexedMetadata(GGM, 171) } }
    db.professions[second.key] = { identity = second, snapshots = { [164] = indexedMetadata(GGM, 164) } }
    assert(GGM.ReconcileProfessionRegistry(db))
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
    local ok, err = GGM.ReconcileProfessionRegistry(db)

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
            snapshots = { [164] = indexedMetadata(GGM, 164) },
        },
        ["Alicia-Silvermoon"] = {
            identity = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = sharedGUID },
            snapshots = { [164] = indexedMetadata(GGM, 164) },
        },
    }
    assert(GGM.ReconcileProfessionRegistry(db))

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
            snapshots = { [164] = indexedMetadata(GGM, 164) },
        },
        ["Alicia-Silvermoon"] = {
            identity = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = sharedGUID },
            snapshots = { [171] = indexedMetadata(GGM, 171) },
        },
    }
    assert(GGM.ReconcileProfessionRegistry(db))

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

T.test("verified save recovers duplicate GUID records when registry provenance is trusted", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local sourceIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local destinationIdentity = indexedIdentity(GGM, "Alicia-Silvermoon", sourceIdentity.guid)
    local sourceSnapshot = indexedSnapshot(GGM, 164, 100)
    local destinationSnapshot = indexedMetadata(GGM, 171)
    assert(GGM.SaveProfessionSnapshot(db, sourceIdentity, sourceSnapshot, { guildMembershipVerified = true }))
    local trustedID = db.localCharacterIDByGUID[sourceIdentity.guid]
    db.professions[destinationIdentity.key] = {
        identity = destinationIdentity,
        snapshots = { [171] = destinationSnapshot },
    }
    db.professionRecipeIndex[171] = {
        [300] = {
            name = "Potion",
            crafters = { trustedID },
        },
    }
    local repaired, repairErr = GGM.ReconcileProfessionRegistry(db)
    T.assertFalse(repaired)
    T.assertEqual(repairErr, "profession-index-repair-needed")
    T.assertEqual(db.localCharacterIDByGUID[sourceIdentity.guid], trustedID)
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

T.test("registry validation keeps persisted repair candidate IDs reserved when counter rolls back", function()
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
        snapshots = { [171] = indexedMetadata(GGM, 171) },
    }
    local repaired, repairErr = GGM.ReconcileProfessionRegistry(db)
    T.assertFalse(repaired)
    T.assertEqual(repairErr, "profession-index-repair-needed")
    T.assertEqual(db.professionIndexRepairCandidates[sourceIdentity.guid].localID, reservedID)

    local otherIdentity = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    db.professions[otherIdentity.key] = {
        identity = otherIdentity,
        snapshots = { [164] = indexedMetadata(GGM, 164) },
    }
    db.nextLocalCharacterID = 1
    local otherID = assert(GGM.EnsureProfessionCharacter(db, otherIdentity))
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

T.test("successful registry repair keeps absent repair candidate IDs reserved after counter rollback", function()
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

    -- An empty catalog lets registry repair remove the ambiguous GUID while
    -- keeping its ID in the repair-candidate map for a later verified save.
    db.professionRecipeIndex = {}
    db.professions[destinationIdentity.key] = {
        identity = destinationIdentity,
        snapshots = { [171] = indexedMetadata(GGM, 171) },
    }
    local repaired, repairErr = GGM.ReconcileProfessionRegistry(db)
    T.assertTrue(repaired)
    T.assertNil(repairErr)
    T.assertNil(db.professionCharacters[reservedID])
    T.assertEqual(db.professionIndexRepairCandidates[sourceIdentity.guid].localID, reservedID)

    local otherIdentity = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    db.professions[otherIdentity.key] = {
        identity = otherIdentity,
        snapshots = { [164] = indexedMetadata(GGM, 164) },
    }
    db.nextLocalCharacterID = 1
    local otherID = assert(GGM.EnsureProfessionCharacter(db, otherIdentity))
    T.assertTrue(otherID ~= reservedID)

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
end)

T.test("duplicate GUID records without registry provenance remain fail-closed", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local sourceIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local destinationIdentity = indexedIdentity(GGM, "Alicia-Silvermoon", sourceIdentity.guid)
    local sourceRecord = { identity = sourceIdentity, snapshots = { [164] = indexedMetadata(GGM, 164) } }
    local destinationRecord = { identity = destinationIdentity, snapshots = { [171] = indexedMetadata(GGM, 171) } }
    db.professions[sourceIdentity.key] = sourceRecord
    db.professions[destinationIdentity.key] = destinationRecord
    db.professionCharacters = {}
    db.localCharacterIDByGUID = {}
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    local catalog = db.professionRecipeIndex

    local ok, err = GGM.EnsureProfessionIndex(db, true)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-index-invalid")
    T.assertTrue(db.professions[sourceIdentity.key] == sourceRecord)
    T.assertTrue(db.professions[destinationIdentity.key] == destinationRecord)
    T.assertNil(db.localCharacterIDByGUID[sourceIdentity.guid])
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(db.professionRecipeIndexVersion, GGM.PROFESSION_RECIPE_INDEX_VERSION)
end)

T.test("verified save keeps duplicate GUID records blocked when a third record appears", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local sourceIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local destinationIdentity = indexedIdentity(GGM, "Alicia-Silvermoon", sourceIdentity.guid)
    local thirdIdentity = indexedIdentity(GGM, "Ally-Silvermoon", sourceIdentity.guid)
    assert(GGM.SaveProfessionSnapshot(db, sourceIdentity, indexedSnapshot(GGM, 164, 100), {
        guildMembershipVerified = true,
    }))
    local trustedID = db.localCharacterIDByGUID[sourceIdentity.guid]
    local sourceRecord = db.professions[sourceIdentity.key]
    local destinationRecord = { identity = destinationIdentity, snapshots = { [171] = indexedMetadata(GGM, 171) } }
    db.professions[destinationIdentity.key] = destinationRecord
    local repaired, repairErr = GGM.ReconcileProfessionRegistry(db)
    T.assertFalse(repaired)
    T.assertEqual(repairErr, "profession-index-repair-needed")
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
    T.assertEqual(db.localCharacterIDByGUID[sourceIdentity.guid], trustedID)
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
    local trustedID = db.localCharacterIDByGUID[sourceIdentity.guid]
    local sourceRecord = db.professions[sourceIdentity.key]
    local destinationRecord = { identity = destinationIdentity, snapshots = { [171] = indexedMetadata(GGM, 171) } }
    db.professions[destinationIdentity.key] = destinationRecord
    local repaired, repairErr = GGM.ReconcileProfessionRegistry(db)
    T.assertFalse(repaired)
    T.assertEqual(repairErr, "profession-index-repair-needed")

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
    T.assertEqual(db.localCharacterIDByGUID[sourceIdentity.guid], trustedID)
    T.assertTrue(db.professionIndexRepairNeeded)
end)

T.test("near-exhausted profession ID counter fails closed and preserves canonical data", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local firstIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local secondIdentity = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    local firstRecord = { identity = firstIdentity, snapshots = { [164] = indexedMetadata(GGM, 164) } }
    local secondRecord = { identity = secondIdentity, snapshots = { [171] = indexedMetadata(GGM, 171) } }
    db.professions[firstIdentity.key] = firstRecord
    db.professions[secondIdentity.key] = secondRecord
    local priorCounter = 2 ^ 53 - 2
    db.nextLocalCharacterID = priorCounter
    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(initialized)
    T.assertEqual(err, "profession-index-invalid")
    T.assertTrue(db.professions[firstIdentity.key] == firstRecord)
    T.assertTrue(db.professions[secondIdentity.key] == secondRecord)
    T.assertEqual(db.nextLocalCharacterID, priorCounter)
    T.assertNil(next(db.professionCharacters))
    T.assertNil(next(db.localCharacterIDByGUID))
    T.assertNil(next(db.professionRecipeIndex))
end)

T.test("canonical GUID record with mismatched storage key fails full validation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local validIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local invalidIdentity = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    db.professions[validIdentity.key] = {
        identity = validIdentity,
        snapshots = { [164] = indexedMetadata(GGM, 164) },
    }
    local validID = assert(GGM.EnsureProfessionCharacter(db, validIdentity))
    assert(GGM.SetProfessionCharacterActive(db, validID, true))
    local malformedCanonical = {
        identity = invalidIdentity,
        snapshots = { [164] = indexedMetadata(GGM, 164) },
    }
    db.professions["Wrong-Key-Silvermoon"] = malformedCanonical
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION

    local ok, err = GGM.EnsureProfessionIndex(db, true)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-index-invalid")
    T.assertTrue(db.professions["Wrong-Key-Silvermoon"] == malformedCanonical)
    T.assertEqual(db.professionRecipeIndexVersion, GGM.PROFESSION_RECIPE_INDEX_VERSION)
    T.assertNil(next(db.professionRecipeIndex))
end)

T.test("named catalog lookup includes inactive crafters without current roster membership", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local inactiveIdentity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local activeIdentity = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    local inactiveID = assert(GGM.EnsureProfessionCharacter(db, inactiveIdentity))
    local activeID = assert(GGM.EnsureProfessionCharacter(db, activeIdentity))
    db.professionCharacters[inactiveID].active = false
    db.professionCharacters[activeID].active = true
    db.professionRecipeIndex[164] = {
        [100] = {
            name = "Copper Bracers",
            crafters = { inactiveID, activeID },
        },
    }
    GGM.professionRosterMembershipCurrent = false

    local results, queryErr, membershipCurrent = GGM.GetProfessionRecipeCharacters(db, 164, 100)
    assert(results, queryErr)
    T.assertFalse(membershipCurrent)

    T.assertEqual(#results, 2)
    T.assertEqual(results[1].localCharacterID, inactiveID)
    T.assertEqual(results[1].guid, inactiveIdentity.guid)
    T.assertEqual(results[1].key, inactiveIdentity.key)
    T.assertFalse(results[1].active)
    T.assertEqual(results[2].localCharacterID, activeID)
    T.assertEqual(results[2].guid, activeIdentity.guid)
    T.assertEqual(results[2].key, activeIdentity.key)
    T.assertTrue(results[2].active)
    T.assertFalse(results[2].membershipCurrent)
end)

T.test("registry validation preserves numeric IDs reserved only by the reverse map", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local reservedID = 37
    local canonical = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    db.localCharacterIDByGUID["Player-1-Retired"] = reservedID
    db.nextLocalCharacterID = 2
    db.professions[canonical.key] = {
        identity = canonical,
        snapshots = { [171] = indexedMetadata(GGM, 171) },
    }

    assert(GGM.ReconcileProfessionRegistry(db))

    local allocatedID = db.localCharacterIDByGUID[canonical.guid]
    T.assertTrue(allocatedID > reservedID)
    T.assertEqual(db.nextLocalCharacterID, allocatedID + 1)
    T.assertNil(db.localCharacterIDByGUID["Player-1-Retired"])
    T.assertNil(db.professionCharacters[reservedID])
    T.assertEqual(db.professions[canonical.key].identity.guid, canonical.guid)
end)

T.test("registry validation preserves authoritative recipe membership and refuses ambiguous lookup", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local canonical = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    db.professions[canonical.key] = { identity = canonical, snapshots = {} }
    local localID = assert(GGM.EnsureProfessionCharacter(db, canonical))
    db.professionCharacters[localID] = {
        guid = "Player-1-Old", key = "Old-Silvermoon", active = true,
    }
    local catalog = {
        [164] = {
            [100] = {
                name = "Copper Bracers",
                crafters = { localID },
            },
        },
    }
    db.professionRecipeIndex = catalog
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    local registry = db.professionCharacters
    local reverseRegistry = db.localCharacterIDByGUID

    local rebuilt, rebuildErr = GGM.ReconcileProfessionRegistry(db)

    T.assertFalse(rebuilt)
    T.assertEqual(rebuildErr, "profession-index-repair-needed")
    T.assertEqual(db.professionCharacters, registry)
    T.assertEqual(db.localCharacterIDByGUID, reverseRegistry)
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(#db.professionRecipeIndex[164][100].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], localID)
    T.assertEqual(db.professionRecipeIndexVersion, GGM.PROFESSION_RECIPE_INDEX_VERSION)
    T.assertTrue(db.professionIndexRepairNeeded)
    local results, queryErr = GGM.GetProfessionRecipeCharacters(db, 164, 100)
    T.assertNil(results)
    T.assertEqual(queryErr, "profession-index-repair-needed")
end)

T.test("exhausted registry validation preserves authoritative recipe catalog and version", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local first = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local second = indexedIdentity(GGM, "Bob-Silvermoon", "Player-1-B")
    db.professions[first.key] = { identity = first, snapshots = {} }
    db.professions[second.key] = { identity = second, snapshots = {} }
    db.professionCharacters = {
        [5] = { guid = first.guid, key = first.key, active = false },
    }
    db.localCharacterIDByGUID = { [first.guid] = 5 }
    db.nextLocalCharacterID = 2 ^ 53
    local catalog = {
        [164] = {
            [100] = {
                name = "Copper Bracers",
                crafters = { 5 },
            },
        },
    }
    db.professionRecipeIndex = catalog
    local rebuilt, rebuildErr = GGM.ReconcileProfessionRegistry(db)

    T.assertFalse(rebuilt)
    T.assertEqual(rebuildErr, "profession-character-id-exhausted")
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(db.professionRecipeIndex[164][100].name, "Copper Bracers")
    T.assertEqual(#db.professionRecipeIndex[164][100].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], 5)
    T.assertEqual(db.professionRecipeIndexVersion, GGM.PROFESSION_RECIPE_INDEX_VERSION)
    T.assertTrue(db.professionIndexRepairNeeded)
end)

T.test("complete recipe replacement stores one name and sorted shared crafter list", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }
    local bob = {
        key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B",
    }
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, alice))
    local bobID = assert(GGM.EnsureProfessionCharacter(db, bob))
    local capture = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }

    assert(GGM.ReconcileProfessionRecipeMembership(db, aliceID, capture))
    capture.capturedAt = 2
    assert(GGM.ReconcileProfessionRecipeMembership(db, bobID, capture))

    local recipe = db.professionRecipeIndex[164][100]
    T.assertEqual(recipe.name, "Copper Bracers")
    T.assertEqual(#recipe.crafters, 2)
    T.assertEqual(recipe.crafters[1], aliceID)
    T.assertEqual(recipe.crafters[2], bobID)
end)

T.test("recipe crafter lists preserve nonconsecutive local IDs in ascending order", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local skipped = indexedIdentity(GGM, "Skipped-Silvermoon", "Player-1-S")
    local charlie = indexedIdentity(GGM, "Charlie-Silvermoon", "Player-1-C")
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, alice))
    local skippedID = assert(GGM.EnsureProfessionCharacter(db, skipped))
    local charlieID = assert(GGM.EnsureProfessionCharacter(db, charlie))
    T.assertEqual(aliceID, 1)
    T.assertEqual(skippedID, 2)
    T.assertEqual(charlieID, 3)
    local capture = indexedSnapshot(GGM, 164, 100)

    assert(GGM.ReconcileProfessionRecipeMembership(db, charlieID, capture))
    capture.capturedAt = capture.capturedAt + 1
    assert(GGM.ReconcileProfessionRecipeMembership(db, aliceID, capture))

    local crafters = db.professionRecipeIndex[164][100].crafters
    T.assertEqual(#crafters, 2)
    T.assertEqual(crafters[1], aliceID)
    T.assertEqual(crafters[2], charlieID)

    local results = assert(GGM.GetProfessionRecipeCharacters(db, 164, 100))
    T.assertEqual(#results, 2)
    T.assertEqual(results[1].localCharacterID, aliceID)
    T.assertEqual(results[2].localCharacterID, charlieID)
end)

T.test("repeated profession reconciliation does not duplicate a crafter ID", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = indexedIdentity(GGM, "Alice-Silvermoon", "Player-1-A")
    local localID = assert(GGM.EnsureProfessionCharacter(db, identity))
    local capture = indexedSnapshot(GGM, 164, 100)

    assert(GGM.ReconcileProfessionRecipeMembership(db, localID, capture))
    capture.capturedAt = capture.capturedAt + 1
    assert(GGM.ReconcileProfessionRecipeMembership(db, localID, capture))

    local crafters = db.professionRecipeIndex[164][100].crafters
    T.assertEqual(#crafters, 1)
    T.assertEqual(crafters[1], localID)
end)

T.test("complete replacement removes only that characters stale memberships", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }
    local bob = {
        key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B",
    }
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, alice))
    local bobID = assert(GGM.EnsureProfessionCharacter(db, bob))

    local first = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = {
            { recipeID = 100, name = "Copper Bracers" },
            { recipeID = 200, name = "Silver Rod" },
        },
    }
    assert(GGM.ReconcileProfessionRecipeMembership(db, aliceID, first))
    assert(GGM.ReconcileProfessionRecipeMembership(db, bobID, first))

    local replacement = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 2,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 300, name = "Iron Buckle" } },
    }
    assert(GGM.ReconcileProfessionRecipeMembership(db, aliceID, replacement))

    T.assertEqual(#db.professionRecipeIndex[164][100].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], bobID)
    T.assertEqual(#db.professionRecipeIndex[164][200].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][200].crafters[1], bobID)
    T.assertEqual(#db.professionRecipeIndex[164][300].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][300].crafters[1], aliceID)
end)

T.test("existing catalog entry keeps its stored recipe name", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }))
    local bobID = assert(GGM.EnsureProfessionCharacter(db, {
        key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B",
    }))

    db.professionRecipeIndex[164] = {
        [100] = {
            name = "Copper Bracers",
            crafters = { aliceID },
        },
    }

    local capture = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 2,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Localized Copper Bracers" } },
    }

    assert(GGM.ReconcileProfessionRecipeMembership(db, bobID, capture))
    T.assertEqual(db.professionRecipeIndex[164][100].name, "Copper Bracers")
    T.assertEqual(#db.professionRecipeIndex[164][100].crafters, 2)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], aliceID)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[2], bobID)
end)

T.test("malformed existing recipe catalog fails reconciliation without mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }))
    local malformedRecipe = { name = "Copper Bracers" }
    local catalog = {
        [164] = { [100] = malformedRecipe },
    }
    db.professionRecipeIndex = catalog
    local capture = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 3,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }

    local ok, err = GGM.ReconcileProfessionRecipeMembership(db, aliceID, capture)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-index-invalid")
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(db.professionRecipeIndex[164][100], malformedRecipe)
    T.assertEqual(malformedRecipe.name, "Copper Bracers")
    T.assertNil(malformedRecipe.crafters)
end)

T.test("profession recipe reconciliation accepts complete transient captures", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, alice))
    assert(GGM.SetProfessionCharacterActive(db, aliceID, true))
    db.professionRecipeIndex = {
        [164] = {
            [100] = { name = "Copper Bracers", crafters = { aliceID } },
        },
    }
    local capture = {
        professionID = 164, professionName = "Blacksmithing", capturedAt = 2,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        complete = true,
        recipes = { { recipeID = 400, name = "Steel Belt" } },
    }

    local ok, err = GGM.ReconcileProfessionRecipeMembership(db, aliceID, capture)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertNil(db.professionRecipeIndex[164][100])
    T.assertEqual(db.professionRecipeIndex[164][400].name, "Steel Belt")
    T.assertEqual(#db.professionRecipeIndex[164][400].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][400].crafters[1], aliceID)
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
        [164] = {
            [100] = { name = "Copper Bracers", crafters = { aliceID } },
            [200] = { name = "Silver Rod", crafters = { aliceID } },
        },
        [171] = {
            [300] = { name = "Potion", crafters = { aliceID, bobID } },
        },
    }
    local replacement = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 2,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 400, name = "Steel Belt" } },
    }

    assert(GGM.ReconcileProfessionRecipeMembership(db, aliceID, replacement))

    T.assertNil(db.professionRecipeIndex[164][100])
    T.assertNil(db.professionRecipeIndex[164][200])
    T.assertEqual(db.professionRecipeIndex[164][400].name, "Steel Belt")
    T.assertEqual(#db.professionRecipeIndex[164][400].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][400].crafters[1], aliceID)
    T.assertEqual(#db.professionRecipeIndex[171][300].crafters, 2)
    T.assertEqual(db.professionRecipeIndex[171][300].crafters[1], aliceID)
    T.assertEqual(db.professionRecipeIndex[171][300].crafters[2], bobID)
end)

T.test("guild roster reconciliation deactivates departed characters but lookup retains them", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true,
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
    T.assertEqual(#results, 1)
    T.assertEqual(results[1].localCharacterID, localID)
    T.assertFalse(results[1].active)
    T.assertNotNil(db.professions[identity.key])
end)

T.test("inactive saved characters remain recipe crafters without invalidating the catalog", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local capture = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, capture, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[identity.guid]
    local catalog = db.professionRecipeIndex
    local recipe = catalog[164][100]
    local indexVersion = db.professionRecipeIndexVersion

    assert(GGM.SetProfessionCharacterActive(db, localID, false))
    GGM.professionRosterMembershipCurrent = false
    local crafters = assert(GGM.GetProfessionRecipeCharacters(db, 164, 100))

    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(db.professionRecipeIndex[164][100], recipe)
    T.assertEqual(db.professionRecipeIndexVersion, indexVersion)
    T.assertEqual(#crafters, 1)
    T.assertEqual(crafters[1].localCharacterID, localID)
    T.assertFalse(crafters[1].active)
end)

T.test("guild roster departure changes activity without changing recipe catalog", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local capture = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, capture, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[identity.guid]
    local catalog = db.professionRecipeIndex
    local recipe = catalog[164][100]
    local indexVersion = db.professionRecipeIndexVersion

    assert(GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return false end,
    }, db))

    T.assertFalse(db.professionCharacters[localID].active)
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(db.professionRecipeIndex[164][100], recipe)
    T.assertEqual(#recipe.crafters, 1)
    T.assertEqual(recipe.crafters[1], localID)
    T.assertEqual(db.professionRecipeIndexVersion, indexVersion)
    GGM.professionRosterMembershipCurrent = false
    local crafters = assert(GGM.GetProfessionRecipeCharacters(db, 164, 100))
    T.assertEqual(#crafters, 1)
    T.assertFalse(crafters[1].active)
end)

T.test("guild roster reconciliation fails closed when a same-key registry entry disagrees with canonical identity", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local key = "Alice-Silvermoon"
    local catalog = db.professionRecipeIndex
    db.professions[key] = {
        identity = { key = key, name = "Alice", realm = "Silvermoon", guid = "Player-1-CANONICAL" },
        snapshots = {},
    }
    db.professionCharacters[1] = { guid = "Player-1-REGISTRY", key = key, active = false }
    db.localCharacterIDByGUID["Player-1-REGISTRY"] = 1
    db.nextLocalCharacterID = 2
    db.professionRecipeIndex[164] = {
        [100] = { name = "Copper Bracers", crafters = { 1 } },
    }
    local recipe = db.professionRecipeIndex[164][100]

    local ok, err = GGM.ReconcileProfessionGuildRoster({
        IsInGuild = function() return true end,
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return key, nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-REGISTRY"
        end,
    }, db)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-index-repair-needed")
    T.assertFalse(db.professionCharacters[1].active)
    T.assertEqual(db.professionCharacters[1].guid, "Player-1-REGISTRY")
    T.assertEqual(db.professionCharacters[1].key, key)
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(db.professionRecipeIndex[164][100], recipe)
    T.assertEqual(#recipe.crafters, 1)
    T.assertEqual(recipe.crafters[1], 1)
    T.assertFalse(GGM.professionRosterMembershipCurrent)
end)

T.test("real guild roster reconciliation sends no addon messages or gear updates", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true,
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
        complete = true,
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
    T.assertEqual(#db.professionRecipeIndex[164][100].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], localID)
end)

T.test("empty roster while still in a guild is unavailable, not an authoritative departure", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true,
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
        complete = true,
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
                complete = true,
                professionID = 164, professionName = "Blacksmithing", capturedAt = 2,
                source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
            },
        },
    }
    db.professionRecipeIndex[164] = {
        [100] = {
            name = "Copper Bracers",
            crafters = { localID },
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
    T.assertEqual(#db.professionRecipeIndex[171][300].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[171][300].crafters[1], localID)
    T.assertEqual(#db.professionRecipeIndex[164][100].crafters, 1)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], localID)
    T.assertNil(db.professions["Alice-Silvermoon"])
end)

T.test("failed roster rename preserves the old key and inactive state on a collision", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[identity.guid]
    assert(GGM.SetProfessionCharacterActive(db, localID, false))
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

local catalogRecipeFixtures = setmetatable({}, { __mode = "k" })

local function catalogSnapshot(GGM, professionID, capturedAt, recipes, professionName)
    local snapshot = {
        complete = true,
        professionID = professionID,
        professionName = professionName or "Localized profession",
        capturedAt = capturedAt,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
    }
    catalogRecipeFixtures[snapshot] = recipes or {}
    return snapshot
end

local function catalogDB(members)
    local GGM = loadModules()
    local db = {
        schemaVersion = GGM.SCHEMA_VERSION,
        professions = {},
        professionCharacters = {},
        localCharacterIDByGUID = {},
        nextLocalCharacterID = 1,
        professionRecipeIndex = {},
        professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION,
        professionIndexRepairCandidates = {},
        professionIndexRepairNeeded = false,
    }

    for index, member in ipairs(members) do
        local localID = member.localID or index
        db.nextLocalCharacterID = math.max(db.nextLocalCharacterID, localID + 1)
        db.professionCharacters[localID] = {
            guid = member.guid,
            key = member.key,
            active = member.active,
        }
        db.localCharacterIDByGUID[member.guid] = localID
        db.professions[member.key] = {
            identity = {
                key = member.key,
                name = member.name,
                realm = member.realm,
                guid = member.guid,
            },
            snapshots = member.snapshots,
        }

        if type(member.snapshots) == "table" then
            for professionID, snapshot in pairs(member.snapshots) do
                local recipes = catalogRecipeFixtures[snapshot]
                if type(professionID) == "number" and type(recipes) == "table" then
                    local professionRecipes = db.professionRecipeIndex[professionID]
                    if type(professionRecipes) ~= "table" then
                        professionRecipes = {}
                        db.professionRecipeIndex[professionID] = professionRecipes
                    end
                    for _, recipe in ipairs(recipes) do
                        local indexedRecipe = professionRecipes[recipe.recipeID]
                        if type(indexedRecipe) ~= "table" then
                            indexedRecipe = { name = recipe.name, crafters = {} }
                            professionRecipes[recipe.recipeID] = indexedRecipe
                        end
                        local alreadyIndexed = false
                        for _, existingID in ipairs(indexedRecipe.crafters) do
                            if existingID == localID then alreadyIndexed = true; break end
                        end
                        if not alreadyIndexed then
                            indexedRecipe.crafters[#indexedRecipe.crafters + 1] = localID
                        end
                    end
                end
            end
        end
    end

    for _, professionRecipes in pairs(db.professionRecipeIndex) do
        for _, recipe in pairs(professionRecipes) do
            table.sort(recipe.crafters)
        end
    end

    return db
end

local function copyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, nested in pairs(value) do result[copyTable(key)] = copyTable(nested) end
    return result
end

local function assertTablesEqual(actual, expected, path)
    path = path or "database"
    T.assertEqual(type(actual), type(expected), path .. " type changed")
    if type(expected) ~= "table" then
        T.assertEqual(actual, expected, path .. " value changed")
        return
    end

    for key, value in pairs(expected) do
        T.assertNotNil(actual[key], path .. " lost key " .. tostring(key))
        assertTablesEqual(actual[key], value, path .. "." .. tostring(key))
    end
    for key in pairs(actual) do
        T.assertNotNil(expected[key], path .. " gained key " .. tostring(key))
    end
end

local function buildCatalog(GGM, db, professionID, professionLabel, api)
    GGM.professionRosterMembershipCurrent = true
    return GGM.BuildProfessionRecipeCatalog(db, professionID, professionLabel, api)
end

T.test("catalog groups localized snapshots by profession ID and sorts recipe owners with their own saved dates", function()
    local GGM = loadModules()
    local db = catalogDB({
        {
            key = "Zoe-Silvermoon", name = "Zoe", realm = "Silvermoon", guid = "Player-1-Z",
            active = true, snapshots = {
                [171] = catalogSnapshot(GGM, 171, 1700000000, {
                    { recipeID = 101, name = "Amber Draught" },
                    { recipeID = 202, name = "Zinc Alloy" },
                }, "Alchimie"),
                [164] = catalogSnapshot(GGM, 164, 1700000000, {
                    { recipeID = 999, name = "Wrong Profession" },
                }, "Forgeron"),
            },
        },
        {
            key = "Amy-ArgentDawn", name = "Amy", realm = "ArgentDawn", guid = "Player-1-A",
            active = true, snapshots = {
                [171] = catalogSnapshot(GGM, 171, 1700000100, {
                    { recipeID = 101, name = "Amber Draught" },
                    { recipeID = 303, name = "Azure Elixir" },
                }, "Alchimie"),
            },
        },
        {
            key = "Inactive-Silvermoon", name = "Inactive", realm = "Silvermoon", guid = "Player-1-I",
            active = false, snapshots = {
                [171] = catalogSnapshot(GGM, 171, 1700000200, {
                    { recipeID = 404, name = "Hidden Recipe" },
                }),
            },
        },
    })
    local before = copyTable(db)
    local api = { date = function(format, timestamp) return format .. ":" .. tostring(timestamp) end }

    local model = buildCatalog(GGM, db, 171, "Alchemy", api)

    T.assertEqual(model.state, "ready")
    T.assertTrue(model.hasSnapshot)
    T.assertEqual(#model.recipes, 3)
    T.assertEqual(model.recipes[1].recipeID, 101)
    T.assertEqual(model.recipes[1].name, "Amber Draught")
    T.assertEqual(#model.recipes[1].knownBy, 2)
    T.assertEqual(model.recipes[1].knownBy[1].key, "Amy-ArgentDawn")
    T.assertEqual(model.recipes[1].knownBy[1].capturedAt, 1700000100)
    T.assertEqual(model.recipes[1].knownBy[1].savedDate, "%Y-%m-%d:1700000100")
    T.assertEqual(model.recipes[1].knownBy[2].key, "Zoe-Silvermoon")
    T.assertEqual(model.recipes[1].knownBy[2].capturedAt, 1700000000)
    T.assertEqual(model.recipes[1].knownBy[2].savedDate, "%Y-%m-%d:1700000000")
    T.assertEqual(model.recipes[2].recipeID, 303)
    T.assertEqual(model.recipes[3].recipeID, 202)
    T.assertEqual(model.message, nil)
    assertTablesEqual(db, before)
end)

T.test("catalog distinguishes no snapshot from a valid empty snapshot", function()
    local GGM = loadModules()
    local db = catalogDB({
        { key = "NoSnapshot-Silvermoon", name = "NoSnapshot", realm = "Silvermoon", guid = "Player-1-N", active = true, snapshots = {} },
        { key = "Empty-Silvermoon", name = "Empty", realm = "Silvermoon", guid = "Player-1-E", active = true, snapshots = {
            [171] = catalogSnapshot(GGM, 171, 1700000000, {}),
        } },
    })
    local before = copyTable(db)

    local noSnapshot = buildCatalog(GGM, db, 164, "Blacksmithing", {})
    T.assertEqual(noSnapshot.state, "empty")
    T.assertFalse(noSnapshot.hasSnapshot)
    T.assertEqual(noSnapshot.message, "No saved Blacksmithing snapshots for current guild members.")
    assertTablesEqual(db, before)

    local emptySnapshot = buildCatalog(GGM, db, 171, "Alchemy", {})
    T.assertEqual(emptySnapshot.state, "empty")
    T.assertTrue(emptySnapshot.hasSnapshot)
    T.assertEqual(emptySnapshot.message, "Saved Alchemy snapshots contain no learned recipes.")
    assertTablesEqual(db, before)
end)

T.test("catalog treats malformed selected snapshots and containers as incomplete without claiming no snapshot", function()
    local GGM = loadModules()
    local malformedOnly = catalogDB({
        { key = "Broken-Silvermoon", name = "Broken", realm = "Silvermoon", guid = "Player-1-B", active = true, snapshots = {
            [171] = { professionID = 171, recipes = "not-a-recipe-list" },
        } },
    })
    local beforeMalformed = copyTable(malformedOnly)

    local malformed = buildCatalog(GGM, malformedOnly, 171, "Alchemy", {})

    T.assertEqual(malformed.state, "incomplete")
    T.assertTrue(malformed.hasSnapshot)
    T.assertEqual(#malformed.recipes, 0)
    T.assertEqual(malformed.message, "Some saved profession data is incomplete.")
    assertTablesEqual(malformedOnly, beforeMalformed)

    local badContainer = catalogDB({
        { key = "Unknown-Silvermoon", name = "Unknown", realm = "Silvermoon", guid = "Player-1-U", active = true, snapshots = false },
    })
    local beforeContainer = copyTable(badContainer)
    local uncertain = buildCatalog(GGM, badContainer, 171, "Alchemy", {})
    T.assertEqual(uncertain.state, "incomplete")
    T.assertNil(uncertain.hasSnapshot)
    T.assertEqual(#uncertain.recipes, 0)
    assertTablesEqual(badContainer, beforeContainer)

    local malformedKeys = catalogDB({
        { key = "OddKey-Silvermoon", name = "OddKey", realm = "Silvermoon", guid = "Player-1-O", active = true, snapshots = {
            ["171"] = catalogSnapshot(GGM, 171, 1700000000, { { recipeID = 100, name = "Recipe" } }),
        } },
    })
    local beforeKeys = copyTable(malformedKeys)
    local unknownPresence = buildCatalog(GGM, malformedKeys, 171, "Alchemy", {})
    T.assertEqual(unknownPresence.state, "incomplete")
    T.assertNil(unknownPresence.hasSnapshot)
    T.assertEqual(#unknownPresence.recipes, 0)
    assertTablesEqual(malformedKeys, beforeKeys)
end)

T.test("catalog fails closed without confirmed membership or unambiguous canonical ownership", function()
    local GGM = loadModules()
    local member = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A", active = true,
        snapshots = { [171] = catalogSnapshot(GGM, 171, 1700000000, { { recipeID = 100, name = "Recipe" } }) },
    }
    local db = catalogDB({ member })
    local before = copyTable(db)
    GGM.professionRosterMembershipCurrent = false
    local unconfirmed = GGM.BuildProfessionRecipeCatalog(db, 171, "Alchemy", {})
    T.assertEqual(unconfirmed.state, "unavailable")
    T.assertNil(unconfirmed.hasSnapshot)
    T.assertEqual(#unconfirmed.recipes, 0)
    T.assertEqual(unconfirmed.message, "Current guild membership could not be confirmed.")
    assertTablesEqual(db, before)

    local ambiguous = catalogDB({ member })
    ambiguous.professions["Alicia-Silvermoon"] = {
        identity = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = member.guid },
        snapshots = {},
    }
    local beforeAmbiguous = copyTable(ambiguous)
    GGM.professionRosterMembershipCurrent = true
    local unavailable = GGM.BuildProfessionRecipeCatalog(ambiguous, 171, "Alchemy", {})
    T.assertEqual(unavailable.state, "unavailable")
    T.assertNil(unavailable.hasSnapshot)
    T.assertEqual(#unavailable.recipes, 0)
    assertTablesEqual(ambiguous, beforeAmbiguous)
end)

T.test("catalog rejects canonical profession identity key name realm disagreement without mutation", function()
    local GGM = loadModules()
    local member = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A", active = true,
        snapshots = { [171] = catalogSnapshot(GGM, 171, 1700000000, { { recipeID = 100, name = "Recipe" } }) },
    }
    local db = catalogDB({ member })
    db.professions[member.key].identity.name = "Alicia"
    local before = copyTable(db)

    local model = buildCatalog(GGM, db, 171, "Alchemy", {})

    T.assertEqual(model.state, "unavailable")
    T.assertNil(model.hasSnapshot)
    T.assertEqual(#model.recipes, 0)
    assertTablesEqual(db, before)
end)

T.test("catalog rejects snapshot-bearing profession orphans without valid roster GUIDs", function()
    local GGM = loadModules()
    for _, guid in ipairs({ false, "not-a-guid" }) do
        local member = {
            key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A", active = true,
            snapshots = { [171] = catalogSnapshot(GGM, 171, 1700000000, { { recipeID = 100, name = "Recipe" } }) },
        }
        local db = catalogDB({ member })
        local orphan = db.professions[member.key]
        if guid == false then orphan.identity.guid = nil else orphan.identity.guid = guid end
        db.professionCharacters = {}
        db.localCharacterIDByGUID = {}
        local before = copyTable(db)

        local model = buildCatalog(GGM, db, 171, "Alchemy", {})

        T.assertEqual(model.state, "unavailable")
        T.assertNil(model.hasSnapshot)
        T.assertEqual(#model.recipes, 0)
        assertTablesEqual(db, before)
    end
end)

T.test("catalog keeps safely attributable recipes when another active snapshot is malformed", function()
    local GGM = loadModules()
    local db = catalogDB({
        {
            key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A", active = true,
            snapshots = { [171] = catalogSnapshot(GGM, 171, 1700000000, { { recipeID = 100, name = "Recipe" } }) },
        },
        {
            key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B", active = true,
            snapshots = { [171] = { professionID = 171, recipes = "broken" } },
        },
    })
    local before = copyTable(db)

    local model = buildCatalog(GGM, db, 171, "Alchemy", {})

    T.assertEqual(model.state, "incomplete")
    T.assertTrue(model.hasSnapshot)
    T.assertEqual(#model.recipes, 1)
    T.assertEqual(model.recipes[1].recipeID, 100)
    T.assertEqual(#model.recipes[1].knownBy, 1)
    T.assertEqual(model.recipes[1].knownBy[1].key, "Alice-Silvermoon")
    T.assertEqual(model.message, "Some saved profession data is incomplete.")
    assertTablesEqual(db, before)
end)

T.test("catalog uses the persisted recipe name and retains each crafter's saved date", function()
    local GGM = loadModules()
    local db = catalogDB({
        {
            key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A", active = true,
            snapshots = { [171] = catalogSnapshot(GGM, 171, 1700000000, { { recipeID = 100, name = "Old Name" } }) },
        },
        {
            key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B", active = true,
            snapshots = { [171] = catalogSnapshot(GGM, 171, 1700000100, { { recipeID = 100, name = "New Name" } }) },
        },
    })
    local before = copyTable(db)

    local model = buildCatalog(GGM, db, 171, "Alchemy", {})

    T.assertEqual(model.state, "ready")
    T.assertTrue(model.hasSnapshot)
    T.assertEqual(#model.recipes, 1)
    T.assertEqual(model.recipes[1].name, "Old Name")
    T.assertEqual(#model.recipes[1].knownBy, 2)
    T.assertEqual(model.recipes[1].knownBy[1].capturedAt, 1700000000)
    T.assertEqual(model.recipes[1].knownBy[2].capturedAt, 1700000100)
    assertTablesEqual(db, before)
end)

T.test("catalog uses the persisted name when crafter snapshots have equal timestamps", function()
    local GGM = loadModules()
    local db = catalogDB({
        {
            key = "Zoe-Silvermoon", name = "Zoe", realm = "Silvermoon", guid = "Player-1-Z", active = true,
            snapshots = { [171] = catalogSnapshot(GGM, 171, 1700000000, { { recipeID = 100, name = "Name from Zoe" } }) },
        },
        {
            key = "Amy-Silvermoon", name = "Amy", realm = "Silvermoon", guid = "Player-1-A", active = true,
            snapshots = { [171] = catalogSnapshot(GGM, 171, 1700000000, { { recipeID = 100, name = "Name from Amy" } }) },
        },
    })

    local model = buildCatalog(GGM, db, 171, "Alchemy", {})

    T.assertEqual(model.state, "ready")
    T.assertEqual(model.recipes[1].name, "Name from Zoe")
    T.assertEqual(model.recipes[1].knownBy[1].key, "Amy-Silvermoon")
    T.assertEqual(model.recipes[1].knownBy[2].key, "Zoe-Silvermoon")
end)

T.test("catalog reports unavailable dates for zero timestamps and absent date formatting", function()
    local GGM = loadModules()
    local db = catalogDB({
        {
            key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A", active = true,
            snapshots = { [171] = catalogSnapshot(GGM, 171, 0, { { recipeID = 100, name = "Recipe" } }) },
        },
    })

    local withDate = buildCatalog(GGM, db, 171, "Alchemy", {
        date = function() error("zero timestamp must not be formatted") end,
    })
    T.assertEqual(withDate.recipes[1].knownBy[1].savedDate, "Date unavailable")

    db.professions["Alice-Silvermoon"].snapshots[171].capturedAt = 1700000000
    local withoutDate = buildCatalog(GGM, db, 171, "Alchemy", {})
    T.assertEqual(withoutDate.recipes[1].knownBy[1].savedDate, "Date unavailable")
end)

T.test("roster rename rejects a third canonical same-GUID record without mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true,
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
                complete = true,
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
