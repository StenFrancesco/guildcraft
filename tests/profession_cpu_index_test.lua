local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("The Guild Book/Constants.lua", GGM)
    T.loadAddonFile("The Guild Book gear/Constants.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionSnapshot.lua", GGM)
    T.loadAddonFile("The Guild Book/CPUWork.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionIndex.lua", GGM)
    T.loadAddonFile("The Guild Book/Storage.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionSyncData.lua", GGM)
    return GGM
end

T.test("read-only profession index validation and catalog work use CPU helpers", function()
    local GGM = loadModules()
    local checkpoints, sorts = 0, 0
    GGM.CPUCheckpoint = function() checkpoints = checkpoints + 1 end
    GGM.CPUSort = function(items, comparator)
        sorts = sorts + 1
        table.sort(items, comparator)
    end
    local db = assert(T.initializeDatabase(GGM, nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true, professionID = 164, professionName = "Blacksmithing", capturedAt = 1700000000,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Recipe" }, { recipeID = 101, name = "Another" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot, { guildMembershipVerified = true }))
    GGM.professionRosterMembershipCurrent = true
    local model = GGM.BuildProfessionRecipeCatalog(db, 164, "Blacksmithing", {})
    T.assertEqual(model.state, "ready")
    T.assertTrue(checkpoints > 0, "expected safe read-only index/catalog loops to checkpoint")
    T.assertTrue(sorts > 0, "expected catalog sorting to use CPUSort")
end)

local function cpuSnapshot(GGM, professionID, recipeID)
    return {
        complete = true, professionID = professionID,
        professionName = professionID == 171 and "Alchemy" or "Blacksmithing",
        capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = recipeID, name = "Recipe " .. recipeID } },
    }
end

local function cpuIdentity(key, guid)
    return { key = key, name = key:match("^([^-]+)"), realm = "Silvermoon", guid = guid }
end

T.test("validated profession operation skips the second full save validation", function()
    local GGM = loadModules()
    local db = assert(T.initializeDatabase(GGM, nil))
    local identity = cpuIdentity("Alice-Silvermoon", "Player-1-A")
    assert(GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 164, 100)))
    local token = assert(GGM.PrepareProfessionValidationOperation(db, identity))
    local fullValidations = 0
    local ensure = GGM.EnsureProfessionIndex
    GGM.EnsureProfessionIndex = function(...)
        if select(2, ...) == true then fullValidations = fullValidations + 1 end
        return ensure(...)
    end

    local saved, err = GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 171, 200), {
        indexValidationOperation = token,
    })

    T.assertTrue(saved, err)
    T.assertEqual(fullValidations, 0, "the consumed operation should replace both synchronous full walks")
    T.assertEqual(#db.professionRecipeIndex[171][200].crafters, 1)
end)

T.test("new GUID validation operation remains safe while adding a fresh registry ID", function()
    local GGM = loadModules()
    local db = assert(T.initializeDatabase(GGM, nil))
    local identity = cpuIdentity("New-Silvermoon", "Player-1-NEW")
    local token = assert(GGM.PrepareProfessionValidationOperation(db, identity))
    local saved, err = GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 164, 100), {
        indexValidationOperation = token,
    })
    T.assertTrue(saved, err)
    T.assertEqual(db.localCharacterIDByGUID[identity.guid], 1)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], 1)
end)

T.test("stale validation operation falls back and rejects in-place malformed membership", function()
    local GGM = loadModules()
    local db = assert(T.initializeDatabase(GGM, nil))
    local identity = cpuIdentity("Alice-Silvermoon", "Player-1-A")
    assert(GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 164, 100)))
    local token = assert(GGM.PrepareProfessionValidationOperation(db, identity))
    db.professionRecipeIndex[164][100].crafters[2] = 999
    GGM.InvalidateProfessionSyncCache(db)

    local saved, err = GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 171, 200), {
        indexValidationOperation = token,
    })

    T.assertFalse(saved)
    T.assertEqual(err, "profession-index-invalid")
end)

T.test("forged and reused validation tokens fall back to full validation", function()
    local GGM = loadModules()
    local db = assert(T.initializeDatabase(GGM, nil))
    local identity = cpuIdentity("Alice-Silvermoon", "Player-1-A")
    assert(GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 164, 100)))
    local fullValidations = 0
    local ensure = GGM.EnsureProfessionIndex
    GGM.EnsureProfessionIndex = function(...)
        if select(2, ...) == true then fullValidations = fullValidations + 1 end
        return ensure(...)
    end
    local forgedSaved = GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 171, 200), {
        indexValidationOperation = {},
    })
    T.assertTrue(forgedSaved)
    T.assertEqual(fullValidations, 1)

    local token = assert(GGM.PrepareProfessionValidationOperation(db, identity))
    local firstSaved = GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 164, 101), {
        indexValidationOperation = token,
    })
    T.assertTrue(firstSaved)
    fullValidations = 0
    local secondSaved = GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 171, 201), {
        indexValidationOperation = token,
    })
    T.assertTrue(secondSaved)
    T.assertEqual(fullValidations, 1)
end)

T.test("validation operations reject key renames and repair candidates", function()
    local GGM = loadModules()
    local db = assert(T.initializeDatabase(GGM, nil))
    local alice = cpuIdentity("Alice-Silvermoon", "Player-1-A")
    assert(GGM.SaveProfessionSnapshot(db, alice, cpuSnapshot(GGM, 164, 100)))
    local rename = cpuIdentity("Alice-Argent-Dawn", alice.guid)
    T.assertNil(GGM.PrepareProfessionValidationOperation(db, rename))

    local repairDB = assert(T.initializeDatabase(GGM, nil))
    local unknown = cpuIdentity("Unknown-Silvermoon", "Player-1-U")
    repairDB.professionIndexRepairCandidates[unknown.guid] = { localID = 2, sourceKey = unknown.key, active = false }
    T.assertNil(GGM.PrepareProfessionValidationOperation(repairDB, unknown))
end)

T.test("database and index replacement invalidate the scoped save operation", function()
    local GGM = loadModules()
    local db = assert(T.initializeDatabase(GGM, nil))
    local identity = cpuIdentity("Alice-Silvermoon", "Player-1-A")
    assert(GGM.SaveProfessionSnapshot(db, identity, cpuSnapshot(GGM, 164, 100)))
    local token = assert(GGM.PrepareProfessionValidationOperation(db, identity))
    local otherDB = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveProfessionSnapshot(otherDB, identity, cpuSnapshot(GGM, 164, 100)))
    local fullValidations = 0
    local ensure = GGM.EnsureProfessionIndex
    GGM.EnsureProfessionIndex = function(...)
        if select(2, ...) == true then fullValidations = fullValidations + 1 end
        return ensure(...)
    end

    local saved, err = GGM.SaveProfessionSnapshot(otherDB, identity, cpuSnapshot(GGM, 171, 200), {
        indexValidationOperation = token,
    })

    T.assertTrue(saved, err)
    T.assertEqual(fullValidations, 1, "a token for another database must use the ordinary full validation path")

    local indexToken = assert(GGM.PrepareProfessionValidationOperation(db, identity))
    db.professionRecipeIndex = {}
    fullValidations = 0
    local replacedIndexSaved, replacedIndexErr = GGM.SaveProfessionSnapshot(db, identity,
        cpuSnapshot(GGM, 171, 201), { indexValidationOperation = indexToken })
    T.assertTrue(replacedIndexSaved, replacedIndexErr)
    T.assertEqual(fullValidations, 1, "replacing an index table must invalidate the operation proof")
end)

T.test("successful repeated roster reconciliation reports unchanged identity state", function()
    local GGM = loadModules()
    local db = assert(T.initializeDatabase(GGM, nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true, professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Recipe" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot))
    local invalidations = 0
    GGM.InvalidateProfessionSyncCache = function() invalidations = invalidations + 1 end
    local api = {
        IsInGuild = function() return true end,
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Alice-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-A"
        end,
        GetRealmName = function() return "Silvermoon" end,
    }
    local first, _, firstChanged = GGM.ReconcileProfessionGuildRoster(api, db)
    T.assertTrue(first)
    T.assertTrue(firstChanged)
    local second, _, secondChanged = GGM.ReconcileProfessionGuildRoster(api, db)
    T.assertTrue(second)
    T.assertFalse(secondChanged, "third return is true only when registry membership, identity, or active state changes")
    T.assertEqual(invalidations, 1, "an unchanged successful roster should not invalidate the profession cache")
end)
T.test('unchanged memberships do not remove and reinsert every crafter during a save',function()
    local G=loadModules()
    local db=assert(T.initializeDatabase(G,nil))
    local identity=cpuIdentity('Alice-Silvermoon','Player-1-A')
    local snapshot=cpuSnapshot(G,164,100)
    assert(G.SaveProfessionSnapshot(db,identity,snapshot))
    local removes, inserts=0,0
    local remove,insert=table.remove,table.insert
    table.remove=function(...) removes=removes+1;return remove(...) end
    table.insert=function(...) inserts=inserts+1;return insert(...) end
    local ok,err=G.SaveProfessionSnapshot(db,identity,snapshot)
    table.remove,table.insert=remove,insert
    T.assertTrue(ok,err)
    T.assertEqual(removes,0);T.assertEqual(inserts,0)
    local changed=cpuSnapshot(G,164,100);changed.recipes[1].name='New label'
    assert(G.SaveProfessionSnapshot(db,identity,changed))
    T.assertEqual(db.professionRecipeIndex[164][100].name,'New label')
end)
