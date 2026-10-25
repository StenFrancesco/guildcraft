local T = require("tests.testlib")

local function loadFilters()
    local GGM = {}
    T.loadAddonFile("The Guild Book/ProfessionRecipeFilters.lua", GGM)
    return GGM
end

local function entry(name, learned, craftable, categoryIDs, slotKeys)
    return {
        name = name,
        learned = learned,
        craftable = craftable,
        categoryIDs = categoryIDs or {},
        slotKeys = slotKeys or {},
    }
end

local SECRET = {}

local function modelAPI(professionID, recipeInfo, craftableCounts, categories, outputItems, enchantTargets)
    local categoryIDs = {}
    for id in pairs(categories or {}) do categoryIDs[#categoryIDs + 1] = id end
    table.sort(categoryIDs)
    local api = {
        issecretvalue = function(value) return value == SECRET end,
        C_TradeSkillUI = {
            IsTradeSkillReady = function() return true end,
            IsTradeSkillLinked = function() return false end,
            GetBaseProfessionInfo = function() return { professionID = professionID } end,
            GetCategories = function() return unpack(categoryIDs) end,
            GetCategoryInfo = function(categoryID) return (categories or {})[categoryID] end,
            GetRecipeInfo = function(recipeID) return (recipeInfo or {})[recipeID] end,
            GetCraftableCount = function(recipeID) return (craftableCounts or {})[recipeID] end,
            GetRecipeSchematic = function(recipeID)
                local itemID = (outputItems or {})[recipeID]
                return { outputItemID = itemID }
            end,
            GetRecipeOutputItemData = function(recipeID)
                local itemID = (outputItems or {})[recipeID]
                return itemID and { itemID = itemID } or nil
            end,
            GetEnchantItems = function(recipeID) return (enchantTargets or {})[recipeID] or {} end,
        },
        C_Item = {
            GetItemInfoInstant = function(itemID)
                local item = (outputItems or {}).items and outputItems.items[itemID]
                if not item then return itemID, nil, nil, nil, nil, nil, nil end
                return itemID, item.itemType, item.itemSubType, item.itemEquipLoc, 1, item.classID, item.subClassID
            end,
            GetItemIDByGUID = function(guid)
                return (outputItems or {}).guids and outputItems.guids[guid]
            end,
        },
        INVTYPE_HEAD = "Head",
        INVTYPE_CLOAK = "Cloak",
        INVTYPE_2HWEAPON = "Two-Handed",
    }
    return api
end

local function findNode(nodes, key)
    for _, node in ipairs(nodes or {}) do
        if node.key == key then return node end
        local child = findNode(node.children, key)
        if child then return child end
    end
end

T.test("profession recipe filter state enables both learning states and materials by default", function()
    local GGM = loadFilters()
    local state = GGM.CreateProfessionRecipeFilterState()

    T.assertTrue(state.showLearned)
    T.assertTrue(state.showUnlearned)
    T.assertTrue(state.haveMaterials)
    T.assertEqual(next(state.categoryIDs), nil)
    T.assertEqual(next(state.slotKeys), nil)
end)

T.test("profession recipe filter treats empty categories and slots as unrestricted", function()
    local GGM = loadFilters()
    local entries = {
        entry("Potion", true, true, { 10 }, { "trinket" }),
        entry("Untracked output", true, true),
    }

    local filtered = GGM.FilterProfessionRecipeEntries(entries, "", {
        showLearned = true,
        showUnlearned = true,
        haveMaterials = false,
        categoryIDs = {},
        slotKeys = {},
    })

    T.assertEqual(#filtered, 2)
    T.assertTrue(filtered[1] == entries[1])
    T.assertTrue(filtered[2] == entries[2])
end)

T.test("profession recipe filter applies learned and unlearned toggles", function()
    local GGM = loadFilters()
    local entries = {
        entry("Known", true, true),
        entry("Unknown", false, false),
    }
    local base = { haveMaterials = false, categoryIDs = {}, slotKeys = {} }

    local learned = GGM.FilterProfessionRecipeEntries(entries, "", {
        showLearned = true, showUnlearned = false, haveMaterials = base.haveMaterials,
        categoryIDs = base.categoryIDs, slotKeys = base.slotKeys,
    })
    local unlearned = GGM.FilterProfessionRecipeEntries(entries, "", {
        showLearned = false, showUnlearned = true, haveMaterials = base.haveMaterials,
        categoryIDs = base.categoryIDs, slotKeys = base.slotKeys,
    })
    local neither = GGM.FilterProfessionRecipeEntries(entries, "", {
        showLearned = false, showUnlearned = false, haveMaterials = base.haveMaterials,
        categoryIDs = base.categoryIDs, slotKeys = base.slotKeys,
    })

    T.assertEqual(#learned, 1)
    T.assertTrue(learned[1] == entries[1])
    T.assertEqual(#unlearned, 1)
    T.assertTrue(unlearned[1] == entries[2])
    T.assertEqual(#neither, 0)
end)

T.test("Have Materials requires a learned recipe with a currently craftable item", function()
    local GGM = loadFilters()
    local entries = {
        entry("Craftable", true, true),
        entry("Missing reagents", true, false),
        entry("Unlearned", false, true),
    }

    local filtered = GGM.FilterProfessionRecipeEntries(entries, "", GGM.CreateProfessionRecipeFilterState())

    T.assertEqual(#filtered, 1)
    T.assertTrue(filtered[1] == entries[1])
end)

T.test("profession recipe category and slot values match with OR and filters combine with AND", function()
    local GGM = loadFilters()
    local entries = {
        entry("Plate Mace", true, true, { 10, 11 }, { "two-handed-mace" }),
        entry("Plate Boots", true, true, { 10, 12 }, { "boots" }),
        entry("Leather Mace", true, true, { 20 }, { "two-handed-mace" }),
    }
    local filtered = GGM.FilterProfessionRecipeEntries(entries, "", {
        showLearned = true,
        showUnlearned = false,
        haveMaterials = true,
        categoryIDs = { [10] = true, [99] = true },
        slotKeys = { ["two-handed-mace"] = true, ["boots"] = true },
    })

    T.assertEqual(#filtered, 2)
    T.assertTrue(filtered[1] == entries[1])
    T.assertTrue(filtered[2] == entries[2])
end)

T.test("profession recipe search composes case-insensitively with other filters", function()
    local GGM = loadFilters()
    local entries = {
        entry("Greater Healing Potion", true, true, { 171 }, { "potion" }),
        entry("Greater Mana Potion", true, true, { 171 }, { "potion" }),
        entry("Greater Healing Elixir", true, true, { 171 }, { "elixir" }),
    }
    local filtered = GGM.FilterProfessionRecipeEntries(entries, "HEALING", {
        showLearned = true,
        showUnlearned = false,
        haveMaterials = true,
        categoryIDs = { [171] = true },
        slotKeys = { potion = true },
    })

    T.assertEqual(#filtered, 1)
    T.assertTrue(filtered[1] == entries[1])
end)

T.test("profession recipe filter returns a dense result and does not mutate input", function()
    local GGM = loadFilters()
    local entries = { entry("Match", true, true), false, entry("No match", false, false) }
    local filtered = GGM.FilterProfessionRecipeEntries(entries, "match", {
        showLearned = true,
        showUnlearned = false,
        haveMaterials = false,
        categoryIDs = {},
        slotKeys = {},
    })

    T.assertEqual(#filtered, 1)
    T.assertEqual(entries[2], false)
end)

T.test("profession recipe filter model reads current learned state and craftable count", function()
    local GGM = loadFilters()
    local api = modelAPI(171, {
        [101] = { recipeID = 101, name = "Known", categoryID = 10, learned = true, craftable = true },
        [102] = { recipeID = 102, name = "Unknown", categoryID = 10, learned = false, craftable = false },
    }, { [101] = 2, [102] = 0 }, { [10] = { categoryID = 10, name = "Potions" } })

    local model = GGM.BuildProfessionRecipeFilterModel(api, 171, {
        { recipeID = 101, name = "Known" },
        { recipeID = 102, name = "Unknown" },
    })

    T.assertEqual(model.state, "ready")
    T.assertTrue(model.recipes[1].learned)
    T.assertEqual(model.recipes[1].craftableCount, 2)
    T.assertTrue(model.recipes[1].craftable)
    T.assertFalse(model.recipes[2].learned)
    T.assertFalse(model.recipes[2].craftable)
    T.assertEqual(model.availability.materials, "available")
end)

T.test("profession recipe filter model builds category ancestry from live profession headings", function()
    local GGM = loadFilters()
    local categories = {
        [10] = { categoryID = 10, name = "Armor", uiOrder = 1 },
        [11] = { categoryID = 11, name = "Plate", parentCategoryID = 10, uiOrder = 1 },
        [12] = { categoryID = 12, name = "Helmets", parentCategoryID = 11, uiOrder = 1 },
    }
    local api = modelAPI(164, {
        [201] = { recipeID = 201, name = "Plate Helm", categoryID = 12, learned = true, craftable = true },
    }, { [201] = 1 }, categories)

    local model = GGM.BuildProfessionRecipeFilterModel(api, 164, { { recipeID = 201, name = "Plate Helm" } })

    T.assertEqual(#model.categories, 1)
    T.assertEqual(model.categories[1].name, "Armor")
    T.assertEqual(model.categories[1].children[1].name, "Plate")
    T.assertEqual(model.categories[1].children[1].children[1].name, "Helmets")
    T.assertEqual(#model.recipes[1].categoryIDs, 3)
    T.assertEqual(model.recipes[1].categoryIDs[1], 10)
    T.assertEqual(model.recipes[1].categoryIDs[2], 11)
    T.assertEqual(model.recipes[1].categoryIDs[3], 12)
end)

T.test("profession recipe filter model derives armor and two-handed weapon slots from item metadata", function()
    local GGM = loadFilters()
    local itemData = {
        [301] = { itemType = "Armor", itemSubType = "Plate", itemEquipLoc = "INVTYPE_HEAD", classID = 4, subClassID = 4 },
        [302] = { itemType = "Weapon", itemSubType = "Maces", itemEquipLoc = "INVTYPE_2HWEAPON", classID = 2, subClassID = 5 },
    }
    local outputItems = { [211] = 301, [212] = 302, items = itemData }
    local api = modelAPI(164, {
        [211] = { recipeID = 211, name = "Helm", categoryID = 10, learned = true, craftable = true },
        [212] = { recipeID = 212, name = "Mace", categoryID = 10, learned = true, craftable = true },
    }, { [211] = 1, [212] = 1 }, { [10] = { categoryID = 10, name = "Blacksmithing" } }, outputItems)

    local model = GGM.BuildProfessionRecipeFilterModel(api, 164, {
        { recipeID = 211, name = "Helm" }, { recipeID = 212, name = "Mace" },
    })
    local plateHead = findNode(model.slots, "armor:4:INVTYPE_HEAD")
    local twoHandedMaces = findNode(model.slots, "weapon:5:INVTYPE_2HWEAPON")

    T.assertNotNil(plateHead)
    T.assertEqual(plateHead.name, "Head")
    T.assertNotNil(twoHandedMaces)
    T.assertEqual(twoHandedMaces.name, "Two-Handed Maces")
    T.assertEqual(#model.recipes[2].slotKeys, 1)
    T.assertEqual(model.recipes[2].slotKeys[1], "weapon:5:INVTYPE_2HWEAPON")
end)

T.test("profession recipe filter model derives Enchanting targets from matching live inventory items", function()
    local GGM = loadFilters()
    local itemData = {
        [401] = { itemType = "Armor", itemSubType = "Cloth", itemEquipLoc = "INVTYPE_CLOAK", classID = 4, subClassID = 1 },
        [402] = { itemType = "Weapon", itemSubType = "Maces", itemEquipLoc = "INVTYPE_2HWEAPON", classID = 2, subClassID = 5 },
    }
    local outputItems = { items = itemData, guids = { cloak = 401, mace = 402 } }
    local api = modelAPI(333, {
        [310] = { recipeID = 310, name = "Enchant targets", categoryID = 20, learned = true, craftable = true, isEnchantingRecipe = true },
    }, { [310] = 1 }, { [20] = { categoryID = 20, name = "Enchantments" } }, outputItems,
        { [310] = { "cloak", "mace" } })

    local model = GGM.BuildProfessionRecipeFilterModel(api, 333, { { recipeID = 310, name = "Enchant targets" } })
    local cloak = findNode(model.slots, "enchant:INVTYPE_CLOAK")
    local twoHandedWeapon = findNode(model.slots, "enchant:INVTYPE_2HWEAPON")

    T.assertNotNil(cloak)
    T.assertEqual(cloak.name, "Cloak")
    T.assertNotNil(twoHandedWeapon)
    T.assertEqual(twoHandedWeapon.name, "Two-Handed Weapon")
    T.assertEqual(#model.recipes[1].slotKeys, 2)
end)

T.test("profession recipe filter model accepts the live craftable count for alternative reagents", function()
    local GGM = loadFilters()
    local api = modelAPI(171, {
        [320] = { recipeID = 320, name = "Either reagent", categoryID = 10, learned = true, craftable = true },
    }, { [320] = 1 }, { [10] = { categoryID = 10, name = "Potions" } })
    api.C_TradeSkillUI.GetRecipeSchematic = function()
        return { outputItemID = 501, reagentSlotSchematics = {
            { required = true, quantityRequired = 1, reagents = { { itemID = 601 }, { itemID = 602 } } },
        } }
    end

    local model = GGM.BuildProfessionRecipeFilterModel(api, 171, { { recipeID = 320, name = "Either reagent" } })

    T.assertTrue(model.recipes[1].craftable)
    T.assertEqual(model.recipes[1].craftableCount, 1)
end)

T.test("profession recipe filter model fails closed when live bank craftability is unavailable", function()
    local GGM = loadFilters()
    local api = modelAPI(171, {
        [330] = { recipeID = 330, name = "Bank-backed", categoryID = 10, learned = true, craftable = true },
    }, nil, { [10] = { categoryID = 10, name = "Potions" } })
    api.C_TradeSkillUI.GetCraftableCount = nil
    api.savedMaterialBanks = { [500] = 999 }

    local model = GGM.BuildProfessionRecipeFilterModel(api, 171, { { recipeID = 330, name = "Bank-backed" } })

    T.assertFalse(model.recipes[1].craftable)
    T.assertNil(model.recipes[1].craftableCount)
    T.assertEqual(model.availability.materials, "unavailable")
end)

T.test("profession recipe filter model marks secret recipe fields unavailable", function()
    local GGM = loadFilters()
    local api = modelAPI(171, {
        [340] = { recipeID = 340, name = "Hidden", categoryID = 10, learned = SECRET, craftable = true },
    }, { [340] = 99 }, { [10] = { categoryID = 10, name = "Potions" } })

    local model = GGM.BuildProfessionRecipeFilterModel(api, 171, { { recipeID = 340, name = "Hidden" } })

    T.assertNil(model.recipes[1].learned)
    T.assertFalse(model.recipes[1].craftable)
    T.assertNil(model.recipes[1].craftableCount)
    T.assertEqual(model.state, "partial")
end)

T.test("profession recipe filter model rejects linked and mismatched profession contexts", function()
    local GGM = loadFilters()
    local api = modelAPI(164, {}, {})
    api.C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 171 } end

    local mismatch = GGM.BuildProfessionRecipeFilterModel(api, 164, { { recipeID = 350, name = "Other" } })
    T.assertEqual(mismatch.state, "unavailable")
    T.assertFalse(mismatch.recipes[1].craftable)

    api.C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 164 } end
    api.C_TradeSkillUI.IsTradeSkillLinked = function() return true end
    local linked = GGM.BuildProfessionRecipeFilterModel(api, 164, { { recipeID = 350, name = "Other" } })
    T.assertEqual(linked.state, "unavailable")
end)
