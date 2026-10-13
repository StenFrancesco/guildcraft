local T = require("tests.testlib")
local function modules()
    local G = {}
    for _, name in ipairs({"Constants", "ProfessionSnapshot", "ProfessionIndex", "Storage"}) do
        T.loadAddonFile("The Guild Book/" .. name .. ".lua", G)
    end
    return G
end
local function capture(G, recipe)
    return {complete=true, professionID=164, professionName="Blacksmithing", capturedAt=1700000000,
        source=G.PROFESSION_SOURCE_PLAYER, status=G.PROFESSION_CACHE_STATUS,
        recipes={{recipeID=recipe, name="Copper Bracers"}}}
end
local function identity(name, guid)
    return {key=name.."-Silvermoon", name=name, realm="Silvermoon", guid=guid}
end
T.test("recipes store full GUIDs and replace only the selected crafter membership", function()
    local G = modules()
    local db = assert(G.InitializeDatabase(nil))
    local a, b = identity("Alice", "Player-1-A"), identity("Bob", "Player-2-B")
    assert(G.SaveProfessionSnapshot(db, b, capture(G, 100), {guildMembershipVerified=true}))
    assert(G.SaveProfessionSnapshot(db, a, capture(G, 100), {guildMembershipVerified=true}))
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], a.guid)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[2], b.guid)
    T.assertNotNil(db.professionCharacters[a.guid])
    T.assertNil(db.localCharacterIDByGUID)
    T.assertNil(db.nextLocalCharacterID)
    assert(G.SaveProfessionSnapshot(db, a, capture(G, 200)))
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], b.guid)
    T.assertEqual(db.professionRecipeIndex[164][200].crafters[1], a.guid)
    local owners = assert(G.GetProfessionRecipeCharacters(db, 164, 100))
    T.assertEqual(owners[1].guid, b.guid)
    T.assertNil(owners[1].localCharacterID)
end)
local function legacy(G)
    local a = identity("Alice", "Player-1-A")
    return {schemaVersion=G.SCHEMA_VERSION, localCharacterGUIDs={},
        professions={[a.key]={identity=a, snapshots={[164]={complete=true,professionID=164,
            professionName="Blacksmithing",capturedAt=1700000000,source=G.PROFESSION_SOURCE_PLAYER,status=G.PROFESSION_CACHE_STATUS}}}},
        professionCharacters={[12]={guid=a.guid,key=a.key,active=true}},
        localCharacterIDByGUID={[a.guid]=12},nextLocalCharacterID=13,
        professionRecipeIndexVersion=3,professionIndexRepairNeeded=false,professionIndexRepairCandidates={},
        professionRecipeIndex={[164]={[100]={name="Copper Bracers",crafters={12}}}}}
end
T.test("startup migrates numeric crafter IDs to GUIDs without losing catalog data", function()
    local G = modules()
    local db = legacy(G)
    assert(G.InitializeDatabase(db))
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], "Player-1-A")
    T.assertEqual(db.professionRecipeIndex[164][100].name, "Copper Bracers")
    T.assertTrue(db.professionCharacters["Player-1-A"].active)
    T.assertNil(db.localCharacterIDByGUID)
    T.assertNil(db.nextLocalCharacterID)
    assert(G.InitializeDatabase(db))
end)
T.test("ambiguous legacy mappings fail closed without replacing saved data", function()
    local G = modules()
    local db = legacy(G)
    db.localCharacterIDByGUID["Player-1-A"] = 99
    local original = db.professionRecipeIndex
    local result = G.InitializeDatabase(db)
    T.assertNil(result)
    T.assertEqual(db.professionRecipeIndex, original)
    T.assertEqual(original[164][100].crafters[1], 12)
end)

T.test("legacy migration rejects unsafe recipe references without partial conversion", function()
    local G = modules()
    local cases = {
        function(db) db.professionRecipeIndex[164][100].crafters = {12, 12} end,
        function(db) db.professionRecipeIndex[164][100].crafters = {[1]=12, [3]=12} end,
        function(db) db.professionRecipeIndex[164][100].crafters = {99} end,
        function(db) db.professionRecipeIndex[164][100].crafters = {} end,
        function(db) db.professionRecipeIndex[164][100].name = false end,
        function(db) db.professionCharacters[13] = db.professionCharacters[12] end,
        function(db) db.professionCharacters[12].key = "Other-Silvermoon" end,
    }
    for _, corrupt in ipairs(cases) do
        local db = legacy(G)
        corrupt(db)
        local registry, catalog, mappings = db.professionCharacters, db.professionRecipeIndex, db.localCharacterIDByGUID
        T.assertNil(G.InitializeDatabase(db))
        T.assertEqual(db.professionCharacters, registry)
        T.assertEqual(db.professionRecipeIndex, catalog)
        T.assertEqual(db.localCharacterIDByGUID, mappings)
        T.assertEqual(db.professionRecipeIndexVersion, 3)
    end
end)

T.test("legacy migration sorts by GUID rather than the former numeric IDs", function()
    local G = modules()
    local db = legacy(G)
    local bob = identity("Bob", "Player-0-B")
    db.professions[bob.key] = {identity=bob, snapshots={}}
    db.professionCharacters[40] = {guid=bob.guid,key=bob.key,active=false}
    db.localCharacterIDByGUID[bob.guid] = 40
    db.professionRecipeIndex[164][100].crafters = {12,40}
    assert(G.InitializeDatabase(db))
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[1], bob.guid)
    T.assertEqual(db.professionRecipeIndex[164][100].crafters[2], "Player-1-A")
end)

T.test("malformed GUID crafter lists fail closed without changing valid saved membership", function()
    local G = modules()
    local db = assert(G.InitializeDatabase(nil))
    local a = identity("Alice", "Player-1-A")
    assert(G.SaveProfessionSnapshot(db, a, capture(G,100)))
    db.professionRecipeIndex[164][100].crafters[1] = 1
    local catalog = db.professionRecipeIndex
    T.assertNil(G.InitializeDatabase(db))
    T.assertEqual(db.professionRecipeIndex, catalog)
    T.assertEqual(catalog[164][100].crafters[1], 1)
end)


T.test("legacy repair provenance migrates to GUIDs and permits a verified disjoint rename", function()
    local G = modules()
    local db = legacy(G)
    local destination = identity("Alicia", "Player-1-A")
    db.professions[destination.key] = {identity=destination,snapshots={}}
    db.professionCharacters, db.localCharacterIDByGUID, db.professionRecipeIndex = {}, {}, {}
    db.professionIndexRepairNeeded = true
    db.professionIndexRepairCandidates["Player-1-A"] = {localID=12,sourceKey="Alice-Silvermoon",active=true}
    assert(G.InitializeDatabase(db))
    local candidate = db.professionIndexRepairCandidates["Player-1-A"]
    T.assertEqual(candidate.guid, "Player-1-A")
    T.assertNil(candidate.localID)
    local snapshot = capture(G, 200)
    snapshot.professionID, snapshot.professionName = 171, "Alchemy"
    assert(G.SaveProfessionSnapshot(db, destination, snapshot, {guildMembershipVerified=true}))
    T.assertNil(db.professions["Alice-Silvermoon"])
    T.assertNotNil(db.professions[destination.key].snapshots[164])
    T.assertEqual(db.professionRecipeIndex[171][200].crafters[1], destination.guid)
    T.assertFalse(db.professionIndexRepairNeeded)
end)

