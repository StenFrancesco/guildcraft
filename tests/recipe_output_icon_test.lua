local T = require("tests.testlib")
local function fixture()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/RecipeOutputIcon.lua", GGM)
    local calls = 0
    local api = {
        issecretvalue = function() return false end,
        InCombatLockdown = function() return false end,
        C_TradeSkillUI = { GetRecipeOutputItemData = function(id)
            calls = calls + 1
            T.assertEqual(id, 3919)
            return { icon = 1234 }
        end },
    }
    return GGM, api, function() return calls end
end
T.test("missing cached recipe output icons resolve without modifying saved data", function()
    local GGM, api, calls = fixture()
    T.assertEqual(GGM.ResolveRecipeOutputIcon(api, 3919), 1234)
    T.assertEqual(calls(), 1)
    T.assertEqual(GGM.ResolveRecipeOutputIcon(api, 3919, 5678), 5678)
    T.assertEqual(calls(), 1)
end)
T.test("recipe output icons respect combat secret and unavailable API boundaries", function()
    local GGM, api, calls = fixture()
    api.InCombatLockdown = function() return true end
    T.assertNil(GGM.ResolveRecipeOutputIcon(api, 3919))
    T.assertEqual(calls(), 0)
    api.InCombatLockdown = function() return false end
    local secret = {}
    api.issecretvalue = function(value) return value == secret end
    T.assertNil(GGM.ResolveRecipeOutputIcon(api, secret, secret))
    T.assertNil(GGM.ResolveRecipeOutputIcon(api, secret))
    T.assertEqual(calls(), 0)
    api.C_TradeSkillUI.GetRecipeOutputItemData = function() return { icon = secret } end
    T.assertNil(GGM.ResolveRecipeOutputIcon(api, 3919))
    api.C_TradeSkillUI.GetRecipeOutputItemData = function() error("unavailable") end
    T.assertNil(GGM.ResolveRecipeOutputIcon(api, 3919))
    api.issecretvalue = nil
    T.assertNil(GGM.ResolveRecipeOutputIcon(api, 3919))
end)
return true
