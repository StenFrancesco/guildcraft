local T = require("tests.testlib")

local function loadModule()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionSnapshot.lua", GGM)
    return GGM
end

T.test("captures only learned recipes from an open linked profession", function()
    local GGM = loadModule()
    local api = {
        time = function() return 1700004000 end,
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return true end,
            IsTradeSkillReady = function() return true end,
            GetBaseProfessionInfo = function()
                return {
                    professionID = 164,
                    professionName = "Blacksmithing",
                    skillLevel = 75,
                    maxSkillLevel = 100,
                }
            end,
            GetAllRecipeIDs = function() return { 300, 100, 200 } end,
            GetRecipeInfo = function(recipeID)
                local info = {
                    [100] = { recipeID = 100, name = "Copper Bracers", learned = true },
                    [200] = { recipeID = 200, name = "Unknown Recipe", learned = false },
                    [300] = { recipeID = 300, name = "Iron Buckle", learned = true },
                }
                return info[recipeID]
            end,
        },
    }

    local snapshot, err = GGM.CaptureLinkedProfessionSnapshot(api)

    T.assertNil(err)
    T.assertEqual(snapshot.professionID, 164)
    T.assertEqual(snapshot.professionName, "Blacksmithing")
    T.assertEqual(snapshot.skillLevel, 75)
    T.assertEqual(snapshot.maxSkillLevel, 100)
    T.assertEqual(snapshot.capturedAt, 1700004000)
    T.assertEqual(snapshot.source, "guild-profession-link")
    T.assertEqual(snapshot.status, "cached")
    T.assertEqual(#snapshot.recipes, 2)
    T.assertEqual(snapshot.recipes[1].recipeID, 100)
    T.assertEqual(snapshot.recipes[2].recipeID, 300)
end)

T.test("capture fails when the open profession is not linked", function()
    local GGM = loadModule()
    local api = {
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return false end,
            IsTradeSkillReady = function() return true end,
        },
    }

    local snapshot, err = GGM.CaptureLinkedProfessionSnapshot(api)
    T.assertNil(snapshot)
    T.assertEqual(err, "profession-not-linked")
end)

T.test("capture fails when linked profession data is not ready", function()
    local GGM = loadModule()
    local api = {
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return true end,
            IsTradeSkillReady = function() return false end,
        },
    }

    local snapshot, err = GGM.CaptureLinkedProfessionSnapshot(api)
    T.assertNil(snapshot)
    T.assertEqual(err, "profession-data-unavailable")
end)

T.test("capture fails closed when required Forever profession APIs are missing", function()
    local GGM = loadModule()
    local snapshot, err = GGM.CaptureLinkedProfessionSnapshot({ C_TradeSkillUI = {} })
    T.assertNil(snapshot)
    T.assertEqual(err, "profession-api-unavailable")
end)

T.test("capture rejects an oversized learned recipe set", function()
    local GGM = loadModule()
    GGM.PROFESSION_MAX_RECIPES = 2
    local api = {
        time = function() return 1700004000 end,
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return true end,
            IsTradeSkillReady = function() return true end,
            GetBaseProfessionInfo = function()
                return { professionID = 164, professionName = "Blacksmithing", skillLevel = 1, maxSkillLevel = 100 }
            end,
            GetAllRecipeIDs = function() return { 1, 2, 3 } end,
            GetRecipeInfo = function(recipeID)
                return { recipeID = recipeID, name = "Recipe " .. recipeID, learned = true }
            end,
        },
    }

    local snapshot, err = GGM.CaptureLinkedProfessionSnapshot(api)
    T.assertNil(snapshot)
    T.assertEqual(err, "profession-recipe-limit-exceeded")
end)
