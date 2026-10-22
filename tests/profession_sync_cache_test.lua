local T = require("tests.testlib")
local function load(reference)
    local G = {}
    for _,file in ipairs({"Constants","ProfessionSnapshot","ProfessionIndex","Storage","ProfessionSyncData"}) do
        T.loadAddonFile("The Guild Book/" .. file .. ".lua",G)
    end
    if reference then T.loadAddonFile("tests/fixtures/profession_sync_data_uncached.lua",G) end
    return G
end
local function identity(name)
    return {guid="Player-1-" .. name,key=name .. "-Realm",name=name,realm="Realm"}
end
local function save(G,db,owner,ids,time)
    local recipes = {}; for _,id in ipairs(ids) do recipes[#recipes+1]={recipeID=id,name="Recipe " .. id} end
    assert(G.SaveProfessionSnapshot(db,owner,{complete=true,professionID=164,professionName="Blacksmithing",
        capturedAt=time or 100,source=G.PROFESSION_SOURCE_GUILD_LINK,status="cached",recipes=recipes},
        {guildMembershipVerified=true}))
end
local function parity(G,U,db,members)
    for pass=1,2 do
        local actual,ae = G.GetProfessionSyncManifest(db,164)
        local expected,ee = U.GetProfessionSyncManifest(db,164)
        T.assertEqual(ae,ee)
        T.assertEqual(type(actual),type(expected))
        if actual then
            T.assertEqual(#actual,#expected)
            for i,row in ipairs(expected) do
                T.assertEqual(actual[i].guid,row.guid); T.assertEqual(actual[i].hash,row.hash)
                T.assertEqual(actual[i].capturedAt,row.capturedAt)
            end
        end
        local ad,de,ac = G.GetProfessionSyncDigest(db,164,members)
        local ed,ue,ec = U.GetProfessionSyncDigest(db,164,members)
        T.assertEqual(ad,ed); T.assertEqual(de,ue); T.assertEqual(ac,ec)
    end
end
T.test("cached synchronization matches frozen baseline through controlled mutations",function()
    local G,U = load(),load(true)
    local db = assert(G.InitializeDatabase(nil))
    local alice,bob = identity("Alice"),identity("Bob")
    save(G,db,alice,{3,8}); save(G,db,bob,{9})
    local members = {[alice.guid]=true}
    parity(G,U,db); parity(G,U,db,members)
    save(G,db,alice,{3,10},101); parity(G,U,db,members)
    save(G,db,alice,{3,10},200); parity(G,U,db)
    -- Metadata does not enter P1, but changes still go through normal saves.
    local capture = assert(G.GetProfessionSyncRecord(db,alice.guid,164))
    capture.recipes[1].name="Localized recipe"; capture.recipes[1].outputIcon=123
    capture.professionName="Localized profession"
    assert(G.SaveProfessionSnapshot(db,alice,capture,{guildMembershipVerified=true})); parity(G,U,db)
    assert(G.MarkLocalCharacterGUID(db,alice.guid)); parity(G,U,db)
    assert(G.SetProfessionCharacterActive(db,db.localCharacterIDByGUID[bob.guid],false)); parity(G,U,db)
    assert(G.SetProfessionCharacterActive(db,db.localCharacterIDByGUID[bob.guid],true)); parity(G,U,db)
    members[bob.guid]=true; parity(G,U,db,members)
    members[alice.guid]=nil; parity(G,U,db,members); parity(G,U,db,{})
    local renamed=identity("Renamed"); renamed.guid=alice.guid
    assert(G.RekeyProfessionCharacter(db,db.localCharacterIDByGUID[alice.guid],renamed)); parity(G,U,db)
    -- Registry reconciliation invalidates any prepared rows.
    assert(G.ReconcileProfessionRegistry(db)); parity(G,U,db)
    assert(G.ReconcileProfessionGuildRoster({IsInGuild=function() return false end},db)); parity(G,U,db)
    T.assertNil(db.localCharacterIDByGUID[bob.guid])
    T.assertNotNil(db.localCharacterIDByGUID[alice.guid])
    local replacement=assert(G.InitializeDatabase(nil)); save(G,replacement,bob,{17},300)
    parity(G,U,replacement); parity(G,U,db)
    assert(G.InitializeDatabase(replacement)); parity(G,U,replacement)
end)
T.test("cached synchronization detects replaced index tables and direct snapshot metadata",function()
    local G,U = load(),load(true)
    local db,alice = assert(G.InitializeDatabase(nil)),identity("Alice")
    save(G,db,alice,{3,8}); parity(G,U,db)
    db.professionRecipeIndex={[164]={[12]={name="Replacement",crafters={1}}}}
    parity(G,U,db)
    local snapshot=db.professions[alice.key].snapshots[164]
    snapshot.capturedAt=500; parity(G,U,db)
    snapshot.complete=false; parity(G,U,db)
    snapshot.complete=true; parity(G,U,db)
    db.professionRecipeIndex[164][12].outputIcon="invalid"; parity(G,U,db)
    db.professionRecipeIndex[164][12].outputIcon=nil; parity(G,U,db)
    snapshot.capturedAt=-1; parity(G,U,db)
end)
T.test("cached manifest results cannot be poisoned by a caller",function()
    local G,U = load(),load(true)
    local db=assert(G.InitializeDatabase(nil)); save(G,db,identity("Alice"),{3,8})
    local rows=assert(G.GetProfessionSyncManifest(db,164))
    rows[1].hash=string.rep("0",16); rows[1].capturedAt=999; rows[2]=rows[1]
    parity(G,U,db)
end)

T.test("cached synchronization agrees with baseline after failed and successful registry repair",function()
    local G,U = load(),load(true)
    local db,alice=assert(G.InitializeDatabase(nil)),identity("Alice")
    save(G,db,alice,{3,8}); parity(G,U,db)
    db.localCharacterIDByGUID[alice.guid]=999
    local ok,err=G.ReconcileProfessionRegistry(db)
    T.assertFalse(ok); T.assertEqual(err,"profession-index-repair-needed")
    parity(G,U,db)
    -- Restore the mapping and validate it before a fresh verified capture.
    db.localCharacterIDByGUID[alice.guid]=1
    assert(G.ReconcileProfessionRegistry(db))
    save(G,db,alice,{3,9},201); parity(G,U,db)
end)

T.test("cached synchronization retains canonical identity validation after warming",function()
    local G,U=load(),load(true)
    local db,alice=assert(G.InitializeDatabase(nil)),identity("Alice")
    save(G,db,alice,{3,8}); parity(G,U,db)
    db.professions[alice.key].identity.name=""; parity(G,U,db)
    db.professions[alice.key].identity.name=alice.name; parity(G,U,db)
    db.professions[alice.key].identity.realm=""; parity(G,U,db)
end)
T.test("warm synchronization signatures distinguish valid metadata from malformed types",function()
    local G,U=load(),load(true)
    local db,alice=assert(G.InitializeDatabase(nil)),identity("Alice")
    save(G,db,alice,{3,8}); parity(G,U,db)
    local snapshot=db.professions[alice.key].snapshots[164]
    snapshot.capturedAt="100"; parity(G,U,db)
    snapshot.capturedAt=100; parity(G,U,db)
    snapshot.complete="true"; parity(G,U,db)
    snapshot.complete=true; parity(G,U,db)
    snapshot.professionID="164"; parity(G,U,db)
end)
T.test("warm synchronization signatures preserve numeric precision before validation",function()
    local G,U=load(),load(true)
    local db,alice=assert(G.InitializeDatabase(nil)),identity("Alice")
    save(G,db,alice,{3,8},1700000000); parity(G,U,db)
    db.professions[alice.key].snapshots[164].capturedAt=1700000000.000001
    parity(G,U,db)
end)
