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
