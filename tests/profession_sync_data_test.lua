local T = require("tests.testlib")

local function load()
    local G = {}
    for _, file in ipairs({ "Constants", "ProfessionSnapshot", "ProfessionIndex", "Storage", "ProfessionSyncData" }) do
        if file ~= "ProfessionSyncData" or io.open("The Guild Book/ProfessionSyncData.lua", "r") then
            T.loadAddonFile("The Guild Book/" .. file .. ".lua", G)
        end
    end
    return G
end

local function save(G, db, guid, ids, time)
    local recipes = {}
    for _, id in ipairs(ids) do recipes[#recipes + 1] = { recipeID = id, name = "Recipe " .. id } end
    table.sort(recipes, function(a, b) return a.recipeID < b.recipeID end)
    local identity = { guid = guid, key = guid .. "-Realm", name = guid, realm = "Realm" }
    T.assertTrue(G.SaveProfessionSnapshot(db, identity, {
        complete = true, professionID = 164, professionName = "Blacksmithing", capturedAt = time or 100,
        source = G.PROFESSION_SOURCE_GUILD_LINK, status = "cached", recipes = recipes,
    }, { guildMembershipVerified = true }))
end

T.test("profession digest includes capture times but ignores local IDs and localized names", function()
    local G = load()
    T.assertEqual(type(G.GetProfessionSyncDigest), "function")
    local a, b = G.InitializeDatabase(nil), G.InitializeDatabase(nil)
    save(G, a, "Player-1-AAA", { 3, 8 }, 100)
    save(G, b, "Player-1-BBB", { 9 })
    save(G, b, "Player-1-AAA", { 3, 8 }, 100)
    save(G, a, "Player-1-BBB", { 9 })
    b.professionRecipeIndex[164][3].name = "Localized label"
    T.assertEqual(G.GetProfessionSyncDigest(a, 164), G.GetProfessionSyncDigest(b, 164))
    save(G, b, "Player-1-AAA", { 3, 8 }, 200)
    T.assertFalse(G.GetProfessionSyncDigest(a, 164) == G.GetProfessionSyncDigest(b, 164))
    save(G, b, "Player-1-AAA", { 3, 10 }, 201)
    T.assertFalse(G.GetProfessionSyncDigest(a, 164) == G.GetProfessionSyncDigest(b, 164))
end)

T.test("profession sync reconstructs complete snapshots including empty professions", function()
    local G = load()
    T.assertEqual(type(G.GetProfessionSyncRecord), "function")
    local db = G.InitializeDatabase(nil)
    save(G, db, "Player-1-AAA", { 3, 8 })
    local row, err = G.GetProfessionSyncRecord(db, "Player-1-AAA", 164)
    T.assertNil(err)
    T.assertEqual(#row.recipes, 2)
    T.assertEqual(row.recipes[1].recipeID, 3)
    T.assertEqual(row.capturedAt, 100)
    save(G, db, "Player-1-AAA", {})
    row = G.GetProfessionSyncRecord(db, "Player-1-AAA", 164)
    T.assertEqual(#row.recipes, 0)
    T.assertEqual(row.hash, G.HashProfessionRecipes(164, {}))
end)

T.test("profession hashes reject malformed or unsorted membership", function()
    local G = load()
    T.assertEqual(type(G.HashProfessionRecipes), "function")
    T.assertNil(G.HashProfessionRecipes(164, { { recipeID = 8 }, { recipeID = 3 } }))
    T.assertNil(G.HashProfessionRecipes(164, { { recipeID = 3 }, { recipeID = 3 } }))
    T.assertNil(G.HashProfessionRecipes(164, { [2] = { recipeID = 3 } }))
    T.assertNil(G.HashProfessionRecipes(164, { { recipeID = math.huge } }))
end)

T.test("profession manifests exclude inactive or corrupt snapshots", function()
    local G = load()
    T.assertEqual(type(G.GetProfessionSyncManifest), "function")
    local db = G.InitializeDatabase(nil)
    save(G, db, "Player-1-AAA", { 3 })
    local manifest = G.GetProfessionSyncManifest(db, 164)
    T.assertEqual(#manifest, 1)
    db.professionCharacters[1].active = false
    T.assertEqual(#G.GetProfessionSyncManifest(db, 164), 0)
    db.professionCharacters[1].active = true
    db.professions["Player-1-AAA-Realm"].snapshots[164].complete = false
    T.assertNil(G.GetProfessionSyncManifest(db, 164))
end)

T.test("profession digests can be scoped to the current verified guild membership", function()
    local G = load()
    local a, b = G.InitializeDatabase(nil), G.InitializeDatabase(nil)
    save(G, a, "Player-1-AAA", { 3 }); save(G, b, "Player-1-AAA", { 3 })
    save(G, a, "Player-1-BBB", { 8 })
    local members = { ["Player-1-AAA"] = true }
    T.assertEqual(G.GetProfessionSyncDigest(a, 164, members), G.GetProfessionSyncDigest(b, 164, members))
end)
