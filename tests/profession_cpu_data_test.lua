local T = require('tests.testlib')
local function fixture()
    local G = { CPUManualDriver = true }
    for _, name in ipairs({'CPUWork','Constants','ProfessionSnapshot','ProfessionIndex','Storage','ProfessionSyncData'}) do
        T.loadAddonFile('The Guild Book/' .. name .. '.lua', G)
    end
    local db = assert(G.InitializeDatabase(nil))
    G.professionRosterMembershipCurrent = true
    for i = 1, 8 do
        local guid, key = 'Player-1-' .. i, 'Crafter' .. i .. '-Realm'
        db.professionCharacters[i] = {guid=guid,key=key,active=true}
        db.localCharacterIDByGUID[guid] = i
        db.professions[key] = {identity={guid=guid,key=key,name='Crafter'..i,realm='Realm'},snapshots={
            [164]={complete=true,professionID=164,professionName='Blacksmithing',capturedAt=1700000000,
                source=G.PROFESSION_SOURCE_GUILD_LINK,status='cached'}}}
    end
    db.nextLocalCharacterID = 9
    local recipes = {}; db.professionRecipeIndex[164] = recipes
    for id = 1, 600 do recipes[id] = {name='Recipe '..id,crafters={1,2,3,4,5,6,7,8}} end
    return G, db
end
T.test('cold manifest and hash preparation yield with identical complete digest', function()
    local G, db = fixture()
    local reference = {}; for key,value in pairs(G) do reference[key]=value end
    T.loadAddonFile('tests/fixtures/profession_sync_data_uncached.lua', reference)
    local expected = assert(reference.GetProfessionSyncDigest(db,164))
    local result
    G.StartCPUJob('manifest', function() return G.GetProfessionSyncDigest(db,164) end, function(value) result=value end)
    G.RunCPUFrame(); T.assertNil(result, 'cold manifest must yield')
    for i=1,10000 do if G.GetCPUJobCount()==0 then break end; G.RunCPUFrame() end
    T.assertEqual(result,expected); T.assertEqual(G.GetCPUJobCount(),0)
end)
T.test('controlled invalidation cancels an unfinished read revision', function()
    local G, db = fixture()
    local revision, published = G.GetCPURevision(db), false
    G.StartCPUJob('manifest', function() return G.GetProfessionSyncDigest(db,164) end,
        function() published=true end, {current=function() return G.GetCPURevision(db)==revision end})
    G.RunCPUFrame(); G.InvalidateProfessionSyncCache(db)
    T.assertTrue(G.GetCPURevision(db)>revision)
    G.RunCPUFrame(); T.assertFalse(published); T.assertEqual(G.GetCPUJobCount(),0)
end)
T.test('recipe hashing itself yields without changing P1 hashes', function()
    local G = {CPUManualDriver=true}
    T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    T.loadAddonFile('The Guild Book/Constants.lua',G)
    T.loadAddonFile('The Guild Book/ProfessionSyncData.lua',G)
    local recipes={}; for i=1,4096 do recipes[i]={recipeID=i} end
    local expected=assert(G.HashProfessionRecipes(164,recipes))
    local result
    G.StartCPUJob('hash',function() return G.HashProfessionRecipes(164,recipes) end,function(value) result=value end)
    G.RunCPUFrame(); T.assertNil(result)
    for i=1,1000 do if G.GetCPUJobCount()==0 then break end; G.RunCPUFrame() end
    T.assertEqual(result,expected)
end)
T.test('queued full validation never clears repair state while a read is unfinished',function()
    local G,db=fixture()
    db.professionIndexRepairNeeded=true
    G.StartCPUJob('repair-read',function() return G.GetProfessionSyncDigest(db,164) end,function() end)
    G.RunCPUFrame()
    T.assertTrue(db.professionIndexRepairNeeded)
    G.CancelCPUJob('repair-read')
    T.assertTrue(db.professionIndexRepairNeeded)
end)
return T
