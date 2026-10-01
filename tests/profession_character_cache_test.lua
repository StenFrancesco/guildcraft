local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionIndex.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionCharacterCache.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    return GGM
end

local function identity(key, guid)
    return {
        key = key,
        name = key:match("^([^-]+)"),
        realm = "Silvermoon",
        guid = guid,
    }
end

T.test("character profession cache builds only the requested slice on demand", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = identity("Alice-Silvermoon", "Player-1-A")
    local localID = assert(GGM.EnsureProfessionCharacter(db, alice))

    db.professions[alice.key] = {
        identity = alice,
        snapshots = {},
    }
    db.professionRecipeIndex = {
        [164] = {
            [100] = { name = "Copper Bracers", crafters = { localID } },
            [200] = { name = "Silver Rod", crafters = { localID } },
        },
        [171] = {
            [300] = { name = "Potion", crafters = { localID } },
        },
    }

    local cache = assert(GGM.CreateProfessionCharacterCache(db))

    T.assertNil(cache.byCharacter[localID])

    local recipes, err = GGM.GetCharacterProfessionRecipes(cache, localID, 164)

    T.assertNil(err)
    T.assertEqual(#recipes, 2)
    T.assertEqual(recipes[1].recipeID, 100)
    T.assertEqual(recipes[1].name, "Copper Bracers")
    T.assertEqual(recipes[2].recipeID, 200)
    T.assertEqual(recipes[2].name, "Silver Rod")
    T.assertNil(cache.byCharacter[localID][171])
end)

T.test("character profession cache is never stored in SavedVariables", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local cache = assert(GGM.CreateProfessionCharacterCache(db))

    T.assertNotNil(cache)
    T.assertNil(db.professionCharacterCache)
    T.assertNil(db.characterProfessionCache)
end)

local function cachedMembershipCount(cache)
    local count = 0
    for _, professions in pairs(cache.byCharacter) do
        for _, recipes in pairs(professions) do
            for _ in pairs(recipes) do
                count = count + 1
            end
        end
    end
    return count
end

local function seededCache(GGM)
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = identity("Alice-Silvermoon", "Player-1-A")
    local bob = identity("Bob-Silvermoon", "Player-1-B")
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, alice))
    local bobID = assert(GGM.EnsureProfessionCharacter(db, bob))

    db.professions[alice.key] = { identity = alice, snapshots = {} }
    db.professions[bob.key] = { identity = bob, snapshots = {} }
    db.professionRecipeIndex = {
        [164] = {
            [100] = {
                name = "Copper Bracers",
                crafters = { aliceID, bobID },
            },
            [200] = {
                name = "Silver Rod",
                crafters = { aliceID },
            },
        },
    }

    return db, assert(GGM.CreateProfessionCharacterCache(db))
end

T.test("profession cache warmup processes a bounded membership budget", function()
    local GGM = loadModules()
    local _, cache = seededCache(GGM)

    local complete, err, processed =
        GGM.StepProfessionCharacterCacheWarmup(cache, 1)

    T.assertFalse(complete)
    T.assertNil(err)
    T.assertEqual(processed, 1)
    T.assertEqual(cachedMembershipCount(cache), 1)

    while not complete do
        complete, err, processed =
            GGM.StepProfessionCharacterCacheWarmup(cache, 1)
        T.assertNil(err)
        T.assertTrue(processed <= 1)
    end

    T.assertTrue(cache.warmup.complete)
    T.assertEqual(cachedMembershipCount(cache), 3)
end)

T.test("profession cache warmup schedules later chunks instead of draining synchronously", function()
    local GGM = loadModules()
    local _, cache = seededCache(GGM)
    local scheduled = {}

    local started, err = GGM.StartProfessionCharacterCacheWarmup(
        cache,
        function(callback)
            scheduled[#scheduled + 1] = callback
        end,
        1
    )

    T.assertTrue(started)
    T.assertNil(err)
    T.assertEqual(cachedMembershipCount(cache), 1)
    T.assertEqual(#scheduled, 1)
    T.assertFalse(cache.warmup.complete)

    scheduled[1]()

    T.assertEqual(cachedMembershipCount(cache), 2)
    T.assertTrue(#scheduled >= 1)
end)

T.test("profession cache warmup defaults to 64 crafter memberships per step", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local crafters = {}

    for index = 1, 65 do
        local character = identity(
            "Crafter-" .. index .. "-Silvermoon",
            "Player-1-" .. index
        )
        crafters[#crafters + 1] =
            assert(GGM.EnsureProfessionCharacter(db, character))
    end

    db.professionRecipeIndex = {
        [164] = {
            [100] = { name = "Copper Bracers", crafters = crafters },
        },
    }

    local cache = assert(GGM.CreateProfessionCharacterCache(db))
    local complete, err, processed =
        GGM.StepProfessionCharacterCacheWarmup(cache)

    T.assertFalse(complete)
    T.assertNil(err)
    T.assertEqual(processed, 64)
    T.assertEqual(cachedMembershipCount(cache), 64)

    while not complete do
        complete, err = GGM.StepProfessionCharacterCacheWarmup(cache)
        T.assertNil(err)
    end

    T.assertEqual(cachedMembershipCount(cache), 65)
end)

T.test("profession cache warmup restarts traversal when the revision changes", function()
    local GGM = loadModules()
    local db, cache = seededCache(GGM)
    local third = identity("Carol-Silvermoon", "Player-1-C")
    local thirdID = assert(GGM.EnsureProfessionCharacter(db, third))
    local crafters = db.professionRecipeIndex[164][100].crafters

    GGM.StepProfessionCharacterCacheWarmup(cache, 1)
    T.assertEqual(cachedMembershipCount(cache), 1)

    crafters[#crafters + 1] = thirdID
    cache.revision = cache.revision + 1

    local complete, err = GGM.StepProfessionCharacterCacheWarmup(cache, 1)

    T.assertFalse(complete)
    T.assertNil(err)
    T.assertEqual(cache.warmup.seenRevision, cache.revision)
    T.assertEqual(cachedMembershipCount(cache), 1)

    while not complete do
        complete, err = GGM.StepProfessionCharacterCacheWarmup(cache, 1)
        T.assertNil(err)
    end

    T.assertEqual(cachedMembershipCount(cache), 4)
end)

T.test("profession cache warmup removes stale memberships after a revision restart", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = identity("Alice-Silvermoon", "Player-1-A")
    local bob = identity("Bob-Silvermoon", "Player-1-B")
    local aliceID = assert(GGM.EnsureProfessionCharacter(db, alice))
    local bobID = assert(GGM.EnsureProfessionCharacter(db, bob))

    db.professionRecipeIndex = {
        [164] = {
            [100] = {
                name = "Copper Bracers",
                crafters = { aliceID, bobID },
            },
        },
    }

    local cache = assert(GGM.CreateProfessionCharacterCache(db))
    local complete, err, processed =
        GGM.StepProfessionCharacterCacheWarmup(cache, 1)

    T.assertFalse(complete)
    T.assertNil(err)
    T.assertEqual(processed, 1)
    T.assertEqual(cache.byCharacter[aliceID][164][100], "Copper Bracers")

    local recipe = db.professionRecipeIndex[164][100]
    table.remove(recipe.crafters, 1)
    cache.revision = cache.revision + 1

    while not complete do
        complete, err = GGM.StepProfessionCharacterCacheWarmup(cache, 1)
        T.assertNil(err)
    end

    local aliceRecipes
    aliceRecipes, err = GGM.GetCharacterProfessionRecipes(cache, aliceID, 164)
    T.assertNil(err)
    T.assertEqual(#aliceRecipes, 0)

    local bobRecipes
    bobRecipes, err = GGM.GetCharacterProfessionRecipes(cache, bobID, 164)
    T.assertNil(err)
    T.assertEqual(#bobRecipes, 1)
    T.assertEqual(bobRecipes[1].recipeID, 100)
end)

local function capture(GGM, professionID, recipes, capturedAt)
    return {
        complete = true,
        professionID = professionID,
        professionName = professionID == 164 and "Blacksmithing" or "Alchemy",
        capturedAt = capturedAt,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = recipes,
    }
end

T.test("successful profession save replaces only the affected cache slice", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local cache = assert(GGM.CreateProfessionCharacterCache(db))
    GGM.professionCharacterCache = cache

    local alice = identity("Alice-Silvermoon", "Player-1-A")

    assert(GGM.SaveProfessionSnapshot(
        db,
        alice,
        capture(GGM, 164, {
            { recipeID = 100, name = "Copper Bracers" },
            { recipeID = 200, name = "Silver Rod" },
        }, 1)
    ))

    local localID = db.localCharacterIDByGUID[alice.guid]
    local first = assert(GGM.GetCharacterProfessionRecipes(cache, localID, 164))
    T.assertEqual(#first, 2)
    T.assertEqual(cache.revision, 1)
    local firstBlacksmithingSlice = cache.byCharacter[localID][164]

    assert(GGM.SaveProfessionSnapshot(
        db,
        alice,
        capture(GGM, 171, {
            { recipeID = 500, name = "Healing Potion" },
        }, 2)
    ))
    T.assertEqual(cache.revision, 2)
    local firstAlchemy =
        assert(GGM.GetCharacterProfessionRecipes(cache, localID, 171))
    T.assertEqual(#firstAlchemy, 1)
    local alchemySlice = cache.byCharacter[localID][171]
    T.assertEqual(cache.byCharacter[localID][164], firstBlacksmithingSlice)

    assert(GGM.SaveProfessionSnapshot(
        db,
        alice,
        capture(GGM, 164, {
            { recipeID = 300, name = "Steel Belt" },
        }, 3)
    ))
    T.assertEqual(cache.revision, 3)
    T.assertTrue(cache.byCharacter[localID][164] ~= firstBlacksmithingSlice)
    T.assertEqual(cache.byCharacter[localID][171], alchemySlice)

    local blacksmithing =
        assert(GGM.GetCharacterProfessionRecipes(cache, localID, 164))
    local alchemy =
        assert(GGM.GetCharacterProfessionRecipes(cache, localID, 171))

    T.assertEqual(#blacksmithing, 1)
    T.assertEqual(blacksmithing[1].recipeID, 300)
    T.assertEqual(#alchemy, 1)
    T.assertEqual(alchemy[1].recipeID, 500)

    T.assertNil(db.professionCharacterCache)
    T.assertNil(db.characterProfessionCache)
end)

T.test("failed rebuild clears slice readiness so a later lookup retries", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = identity("Alice-Silvermoon", "Player-1-A")
    local localID = assert(GGM.EnsureProfessionCharacter(db, alice))
    db.professionRecipeIndex = {
        [164] = {
            [100] = {
                name = "Copper Bracers",
                crafters = { localID },
            },
        },
    }

    local cache = assert(GGM.CreateProfessionCharacterCache(db))
    local initial = assert(GGM.GetCharacterProfessionRecipes(cache, localID, 164))
    T.assertEqual(#initial, 1)
    T.assertTrue(cache.readySlices[localID][164])

    local indexedRecipe = db.professionRecipeIndex[164][100]
    indexedRecipe.name = ""
    local rebuilt, rebuildErr = GGM.UpdateProfessionCharacterCacheFromCapture(
        cache,
        localID,
        capture(GGM, 164, {
            { recipeID = 100, name = "Copper Bracers" },
        }, 2)
    )

    T.assertFalse(rebuilt)
    T.assertEqual(rebuildErr, "profession-character-cache-source-invalid")
    T.assertNil(cache.readySlices[localID])
    T.assertNil(cache.byCharacter[localID])

    indexedRecipe.name = "Copper Bracers"
    local retried = assert(GGM.GetCharacterProfessionRecipes(cache, localID, 164))

    T.assertEqual(#retried, 1)
    T.assertEqual(retried[1].recipeID, 100)
    T.assertEqual(retried[1].name, "Copper Bracers")
    T.assertTrue(cache.readySlices[localID][164])
end)

T.test("profession cache uses the authoritative catalog name for shared recipes", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local cache = assert(GGM.CreateProfessionCharacterCache(db))
    GGM.professionCharacterCache = cache

    local alice = identity("Alice-Silvermoon", "Player-1-A")
    local bob = identity("Bob-Silvermoon", "Player-1-B")

    assert(GGM.SaveProfessionSnapshot(
        db,
        alice,
        capture(GGM, 164, {
            { recipeID = 100, name = "Canonical Recipe Name" },
        }, 1)
    ))
    assert(GGM.SaveProfessionSnapshot(
        db,
        bob,
        capture(GGM, 164, {
            { recipeID = 100, name = "Different Capture Name" },
        }, 2)
    ))

    local bobID = db.localCharacterIDByGUID[bob.guid]
    local recipes = assert(GGM.GetCharacterProfessionRecipes(cache, bobID, 164))

    T.assertEqual(db.professionRecipeIndex[164][100].name, "Canonical Recipe Name")
    T.assertEqual(#recipes, 1)
    T.assertEqual(recipes[1].name, "Canonical Recipe Name")
end)

T.test("derived cache failure never fails authoritative profession save", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = identity("Alice-Silvermoon", "Player-1-A")

    GGM.professionCharacterCache = { db = db }
    GGM.UpdateProfessionCharacterCacheFromCapture = function()
        return false, "forced-cache-failure"
    end

    local saved, err = GGM.SaveProfessionSnapshot(
        db,
        alice,
        capture(GGM, 164, {
            { recipeID = 100, name = "Copper Bracers" },
        }, 1)
    )

    T.assertTrue(saved)
    T.assertNil(err)
    T.assertNotNil(db.professions[alice.key])
    T.assertEqual(
        GGM.lastProfessionCharacterCacheError,
        "forced-cache-failure"
    )
end)

T.test("thrown derived cache failure never fails authoritative profession save", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = identity("Alice-Silvermoon", "Player-1-A")

    GGM.professionCharacterCache = { db = db }
    GGM.UpdateProfessionCharacterCacheFromCapture = function()
        error("forced-cache-throw")
    end

    local saved, err = GGM.SaveProfessionSnapshot(
        db,
        alice,
        capture(GGM, 164, {
            { recipeID = 100, name = "Copper Bracers" },
        }, 1)
    )

    T.assertTrue(saved)
    T.assertNil(err)
    T.assertNotNil(db.professions[alice.key])
    T.assertTrue(
        GGM.lastProfessionCharacterCacheError:find(
            "profession%-character%-cache%-update%-threw:.*forced%-cache%-throw"
        ) ~= nil
    )
end)

T.test("unprintable derived cache error never fails authoritative profession save", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local alice = identity("Alice-Silvermoon", "Player-1-A")

    GGM.professionCharacterCache = { db = db }
    GGM.UpdateProfessionCharacterCacheFromCapture = function()
        error(setmetatable({}, {
            __tostring = function()
                error("forced-format-throw")
            end,
        }))
    end

    local saved, err = GGM.SaveProfessionSnapshot(
        db,
        alice,
        capture(GGM, 164, {
            { recipeID = 100, name = "Copper Bracers" },
        }, 1)
    )

    T.assertTrue(saved)
    T.assertNil(err)
    T.assertNotNil(db.professions[alice.key])
    T.assertEqual(
        GGM.lastProfessionCharacterCacheError,
        "profession-character-cache-update-threw:unprintable-error"
    )
end)
