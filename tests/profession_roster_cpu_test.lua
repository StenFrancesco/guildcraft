local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("The Guild Book/Constants.lua", GGM)
    T.loadAddonFile("The Guild Book gear/Constants.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionSnapshot.lua", GGM)
    T.loadAddonFile("The Guild Book/CPUWork.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionIndex.lua", GGM)
    T.loadAddonFile("The Guild Book/Storage.lua", GGM)
    T.loadAddonFile("The Guild Book gear/Storage.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionSyncData.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionRosterWork.lua", GGM)
    GGM.CPUManualDriver = true
    return GGM
end

local function populatedDatabase(GGM, memberCount, recipeCount)
    local db = assert(T.initializeDatabase(GGM, nil))
    local roster = {}
    for localID = 1, memberCount do
        local name = "Member" .. localID
        local key = name .. "-Realm"
        local guid = "Player-CPU-" .. localID
        local identity = { key = key, name = name, realm = "Realm", guid = guid }
        db.professions[key] = { identity = identity, snapshots = {} }
        db.professionCharacters[localID] = { key = key, guid = guid, active = true }
        db.localCharacterIDByGUID[guid] = localID
        roster[#roster + 1] = { key = key, guid = guid }
    end
    db.nextLocalCharacterID = memberCount + 1
    db.professionRecipeIndex[164] = {}
    for recipeID = 1, recipeCount do
        local localID = ((recipeID - 1) % memberCount) + 1
        db.professionRecipeIndex[164][recipeID] = {
            name = "Recipe " .. recipeID,
            crafters = { localID },
        }
    end
    return db, roster
end

local function rosterAPI(roster, inGuild)
    return {
        IsInGuild = function() return inGuild ~= false end,
        GetNumGuildMembers = function() return #roster end,
        GetGuildRosterInfo = function(index)
            local row = roster[index]
            return row.key, nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, row.guid
        end,
        GetRealmName = function() return "Realm" end,
    }
end

local function drain(GGM)
    for _ = 1, 200 do
        if GGM.GetCPUJobCount() == 0 then return end
        GGM.RunCPUFrame()
    end
    error("CPU work did not finish within the test bound")
end

T.test("large unchanged roster validation yields, then restores membership without invalidation", function()
    local GGM = loadModules()
    local db, roster = populatedDatabase(GGM, 1000, 2000)
    local invalidations = 0
    local invalidate = GGM.InvalidateProfessionSyncCache
    GGM.InvalidateProfessionSyncCache = function(target)
        invalidations = invalidations + 1
        return invalidate(target)
    end
    GGM.professionRosterMembershipCurrent = false
    local reconcileCalls = 0
    local reconcile = GGM.ReconcileProfessionGuildRoster
    GGM.ReconcileProfessionGuildRoster = function(...)
        reconcileCalls = reconcileCalls + 1
        return reconcile(...)
    end
    local calls, result, err, changed = 0
    local job = GGM.QueueProfessionRosterReconciliation(rosterAPI(roster), db, function(ok, reason, didChange)
        calls, result, err, changed = calls + 1, ok, reason, didChange
    end)
    T.assertNotNil(job)
    GGM.RunCPUFrame()
    T.assertTrue(GGM.GetCPUJobCount() > 0, "full recipe membership validation should yield across frames")
    T.assertFalse(GGM.professionRosterMembershipCurrent)
    T.assertEqual(db.professionCharacters[1].active, true)
    drain(GGM)
    T.assertEqual(calls, 1)
    T.assertTrue(result, err)
    T.assertFalse(changed)
    T.assertTrue(GGM.professionRosterMembershipCurrent)
    T.assertEqual(reconcileCalls, 0, "identical snapshots should not repeat synchronous registry reconciliation")
    T.assertEqual(invalidations, 0, "a validated identical roster should not invalidate sync state")
end)

T.test("malformed recipe membership fails after queued validation without partial roster writes", function()
    local GGM = loadModules()
    local db, roster = populatedDatabase(GGM, 2, 5)
    db.professionRecipeIndex[164][1].crafters[2] = 999
    local beforeActive = db.professionCharacters[1].active
    local calls, result, err = 0
    GGM.QueueProfessionRosterReconciliation(rosterAPI(roster), db, function(ok, reason)
        calls, result, err = calls + 1, ok, reason
    end)
    drain(GGM)
    T.assertEqual(calls, 1)
    T.assertFalse(result)
    T.assertEqual(err, "profession-index-invalid")
    T.assertEqual(db.professionCharacters[1].active, beforeActive)
    T.assertFalse(GGM.professionRosterMembershipCurrent)
end)

T.test("controlled revision change cancels queued roster validation before mutations", function()
    local GGM = loadModules()
    local db, roster = populatedDatabase(GGM, 700, 1200)
    local calls, result, err = 0
    GGM.QueueProfessionRosterReconciliation(rosterAPI(roster), db, function(ok, reason)
        calls, result, err = calls + 1, ok, reason
    end)
    GGM.RunCPUFrame()
    T.assertTrue(GGM.GetCPUJobCount() > 0)
    local active = db.professionCharacters[1].active
    GGM.InvalidateCPURevision(db)
    drain(GGM)
    T.assertEqual(calls, 1)
    T.assertFalse(result)
    T.assertEqual(err, "profession-roster-stale")
    T.assertEqual(db.professionCharacters[1].active, active)
end)

T.test("replacing the active database cancels queued roster validation", function()
    local GGM = loadModules()
    local db, roster = populatedDatabase(GGM, 700, 1200)
    GGM.db = db
    local calls, result, err = 0
    GGM.QueueProfessionRosterReconciliation(rosterAPI(roster), db, function(ok, reason)
        calls, result, err = calls + 1, ok, reason
    end)
    GGM.RunCPUFrame()
    T.assertTrue(GGM.GetCPUJobCount() > 0)
    GGM.db = {}
    drain(GGM)
    T.assertEqual(calls, 1)
    T.assertFalse(result)
    T.assertEqual(err, "profession-roster-stale")
    T.assertEqual(db.professionCharacters[1].active, true)
end)

T.test("changed roster purges departed members only after validation completes", function()
    local GGM = loadModules()
    local db, roster = populatedDatabase(GGM, 700, 1200)
    local departedGUID = "Player-CPU-700"
    local departedID = db.localCharacterIDByGUID[departedGUID]
    table.remove(roster, #roster)
    local calls, result, changed = 0
    GGM.QueueProfessionRosterReconciliation(rosterAPI(roster), db, function(ok, _, didChange)
        calls, result, changed = calls + 1, ok, didChange
    end)
    GGM.RunCPUFrame()
    T.assertNotNil(db.professionCharacters[departedID], "validation must not partially purge before it completes")
    drain(GGM)
    T.assertEqual(calls, 1)
    T.assertTrue(result)
    T.assertTrue(changed)
    T.assertNil(db.professionCharacters[departedID])
    T.assertNil(db.localCharacterIDByGUID[departedGUID])
end)
T.test('queued roster keeps the full canonical registry recovery path',function()
    local G=loadModules()
    local db,roster=populatedDatabase(G,2,0)
    db.professionCharacters[1]=nil
    local result
    G.QueueProfessionRosterReconciliation(rosterAPI(roster),db,function(ok,err) result=ok;T.assertNil(err) end)
    drain(G)
    T.assertTrue(result)
    T.assertEqual(db.professionCharacters[db.localCharacterIDByGUID['Player-CPU-1']].key,'Member1-Realm')
    T.assertTrue(G.EnsureProfessionIndex(db,true))
end)
