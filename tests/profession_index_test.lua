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
