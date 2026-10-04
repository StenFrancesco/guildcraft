local T = require("tests.testlib")

local function loadGGM()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/RecipeDetails.lua", GGM)
    return GGM
end

local function schematicWith(slots)
    return { reagentSlotSchematics = slots }
end

local function makeAPI(schematic)
    local calls = { schematic = 0, itemName = 0, itemIcon = 0, currency = 0 }
    local api = {
        issecretvalue = function() return false end,
        InCombatLockdown = function() return false end,
        C_TradeSkillUI = {
            GetRecipeSchematic = function(recipeID, isRecraft, recipeLevel)
                calls.schematic = calls.schematic + 1
                T.assertEqual(recipeID, 123)
                T.assertFalse(isRecraft)
                T.assertNil(recipeLevel)
                return schematic
            end,
            OpenTradeSkill = function() error("must not change profession context") end,
            SelectRecipe = function() error("must not change profession selection") end,
        },
        C_Item = {
            GetItemNameByID = function(itemID)
                calls.itemName = calls.itemName + 1
                return ({ [101] = "Dense Ore", [102] = "Bright Ore" })[itemID]
            end,
            GetItemIconByID = function(itemID)
                calls.itemIcon = calls.itemIcon + 1
                return ({ [101] = 6001, [102] = "Interface\\Icons\\INV_Ore" })[itemID]
            end,
        },
        C_CurrencyInfo = {
            GetCurrencyInfo = function(currencyID)
                calls.currency = calls.currency + 1
                if currencyID == 301 then
                    return { name = "Guild Token", iconFileID = 7001 }
                end
            end,
        },
        SendAddonMessage = function() error("must not send addon messages") end,
        InspectUnit = function() error("must not inspect a character") end,
        SaveVariables = function() error("must not write saved data") end,
    }
    return api, calls
end

local function assertUnavailable(result)
    T.assertEqual(result.state, "unavailable")
    T.assertTrue(type(result.message) == "string" and result.message ~= "")
    T.assertEqual(#result.materials, 0)
end

T.test("recipe material details preserve groups, quantities, optional state, and alternatives", function()
    local GGM = loadGGM()
    local api, calls = makeAPI(schematicWith({
        {
            required = true,
            quantityRequired = 5,
            reagentType = 1,
            reagents = { { itemID = 101 }, { itemID = 102 } },
        },
        {
            required = false,
            quantityRequired = 1,
            reagentType = 0,
            reagents = { { currencyID = 301 } },
        },
    }))

    local result = GGM.BuildRecipeMaterialDetails(api, 123)

    T.assertEqual(result.state, "ready")
    T.assertNil(result.message)
    T.assertEqual(#result.materials, 2)
    T.assertEqual(result.materials[1].quantity, 5)
    T.assertFalse(result.materials[1].optional)
    T.assertEqual(result.materials[1].name, "Dense Ore")
    T.assertEqual(#result.materials[1].choices, 2)
    T.assertEqual(result.materials[1].choices[1].itemID, 101)
    T.assertEqual(result.materials[1].choices[1].icon, 6001)
    T.assertEqual(result.materials[1].choices[2].itemID, 102)
    T.assertEqual(result.materials[1].choices[2].name, "Bright Ore")
    T.assertEqual(result.materials[1].choices[2].icon, "Interface\\Icons\\INV_Ore")
    T.assertEqual(result.materials[2].quantity, 1)
    T.assertTrue(result.materials[2].optional)
    T.assertEqual(result.materials[2].choices[1].currencyID, 301)
    T.assertEqual(result.materials[2].choices[1].name, "Guild Token")
    T.assertEqual(result.materials[2].choices[1].icon, 7001)
    T.assertEqual(calls.schematic, 1)
end)

T.test("recipe material details use readable item-ID placeholders when item names are not loaded", function()
    local GGM = loadGGM()
    local api = makeAPI(schematicWith({
        { required = true, quantityRequired = 2, reagentType = 1, reagents = { { itemID = 909 } } },
    }))

    local result = GGM.BuildRecipeMaterialDetails(api, 123)

    T.assertEqual(result.state, "ready")
    T.assertEqual(result.materials[1].name, "Item #909")
    T.assertEqual(result.materials[1].choices[1].name, "Item #909")
    T.assertNil(result.materials[1].choices[1].icon)
end)

T.test("recipe material details reject missing, throwing, or nil schematic APIs", function()
    local GGM = loadGGM()
    local result = GGM.BuildRecipeMaterialDetails({}, 123)
    assertUnavailable(result)

    local throwingAPI = makeAPI(nil)
    throwingAPI.C_TradeSkillUI.GetRecipeSchematic = function() error("unavailable") end
    assertUnavailable(GGM.BuildRecipeMaterialDetails(throwingAPI, 123))

    local nilAPI = makeAPI(nil)
    assertUnavailable(GGM.BuildRecipeMaterialDetails(nilAPI, 123))
end)

T.test("recipe material details reject malformed and sparse schematic groups", function()
    local GGM = loadGGM()
    assertUnavailable(GGM.BuildRecipeMaterialDetails(makeAPI(nil), 123))
    local malformed = {
        schematicWith({ { required = "yes", quantityRequired = 2, reagents = { { itemID = 101 } } } }),
        schematicWith({ { required = true, quantityRequired = 0, reagents = { { itemID = 101 } } } }),
        schematicWith({ { required = true, quantityRequired = 2, reagents = {} } }),
        schematicWith({ [1] = { required = true, quantityRequired = 2, reagents = { { itemID = 101 } } }, [3] = {} }),
        schematicWith({ { required = true, quantityRequired = 2, reagents = { { itemID = 101, currencyID = 301 } } } }),
        schematicWith({ { required = true, quantityRequired = 2, reagents = { { itemID = 0 } } } }),
    }

    for _, schematic in ipairs(malformed) do
        local api = makeAPI(schematic)
        assertUnavailable(GGM.BuildRecipeMaterialDetails(api, 123))
    end
end)

T.test("recipe material details reject oversized material arrays", function()
    local GGM = loadGGM()
    local slots = {}
    for index = 1, 129 do
        slots[index] = { required = true, quantityRequired = 1, reagents = { { itemID = 101 } } }
    end
    local api = makeAPI(schematicWith(slots))

    assertUnavailable(GGM.BuildRecipeMaterialDetails(api, 123))
end)

T.test("recipe material details fail closed on secret schematic, slot, or choice values", function()
    local GGM = loadGGM()
    local secret = {}
    local api = makeAPI(secret)
    api.issecretvalue = function(value) return value == secret end
    assertUnavailable(GGM.BuildRecipeMaterialDetails(api, 123))

    local apiWithSecretSlot, calls = makeAPI(schematicWith({ secret }))
    apiWithSecretSlot.issecretvalue = function(value) return value == secret end
    assertUnavailable(GGM.BuildRecipeMaterialDetails(apiWithSecretSlot, 123))
    T.assertEqual(calls.itemName, 0)

    local apiWithSecretID, idCalls = makeAPI(schematicWith({
        { required = true, quantityRequired = 2, reagents = { { itemID = secret } } },
    }))
    apiWithSecretID.issecretvalue = function(value) return value == secret end
    assertUnavailable(GGM.BuildRecipeMaterialDetails(apiWithSecretID, 123))
    T.assertEqual(idCalls.itemName, 0)
end)

T.test("recipe material details reject combat, unknown combat state, and missing secret checks", function()
    local GGM = loadGGM()
    local api, calls = makeAPI(schematicWith({}))
    api.InCombatLockdown = function() return true end
    assertUnavailable(GGM.BuildRecipeMaterialDetails(api, 123))
    T.assertEqual(calls.schematic, 0)

    local unknownCombat = makeAPI(schematicWith({}))
    unknownCombat.InCombatLockdown = nil
    assertUnavailable(GGM.BuildRecipeMaterialDetails(unknownCombat, 123))

    local noSecretCheck = makeAPI(schematicWith({}))
    noSecretCheck.issecretvalue = nil
    assertUnavailable(GGM.BuildRecipeMaterialDetails(noSecretCheck, 123))
end)

return true
