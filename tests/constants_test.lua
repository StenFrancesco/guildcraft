local T = require("tests.testlib")

T.test("tracked slot catalog contains the exact 19-slot paper-doll mapping", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)

    T.assertEqual(#GGM.TRACKED_SLOTS, 19)

    local expected = {
        HEAD = { name = "HeadSlot", id = 1 },
        NECK = { name = "NeckSlot", id = 2 },
        SHOULDER = { name = "ShoulderSlot", id = 3 },
        BACK = { name = "BackSlot", id = 15 },
        CHEST = { name = "ChestSlot", id = 5 },
        SHIRT = { name = "ShirtSlot", id = 4 },
        TABARD = { name = "TabardSlot", id = 19 },
        WRIST = { name = "WristSlot", id = 9 },
        HANDS = { name = "HandsSlot", id = 10 },
        WAIST = { name = "WaistSlot", id = 6 },
        LEGS = { name = "LegsSlot", id = 7 },
        FEET = { name = "FeetSlot", id = 8 },
        FINGER_1 = { name = "Finger0Slot", id = 11 },
        FINGER_2 = { name = "Finger1Slot", id = 12 },
        TRINKET_1 = { name = "Trinket0Slot", id = 13 },
        TRINKET_2 = { name = "Trinket1Slot", id = 14 },
        MAIN_HAND = { name = "MainHandSlot", id = 16 },
        OFF_HAND = { name = "SecondaryHandSlot", id = 17 },
        RANGED = { name = "RangedSlot", id = 18 },
    }

    local seen = {}
    local expectedOrder = { "HEAD", "NECK", "SHOULDER", "BACK", "CHEST", "SHIRT", "TABARD", "WRIST", "HANDS", "WAIST", "LEGS", "FEET", "FINGER_1", "FINGER_2", "TRINKET_1", "TRINKET_2", "MAIN_HAND", "OFF_HAND", "RANGED" }
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        T.assertEqual(slot.key, expectedOrder[index])
        T.assertEqual(slot.inventoryName, expected[slot.key].name, "unexpected slot mapping for " .. tostring(slot.key))
        T.assertEqual(slot.inventorySlotID, expected[slot.key].id, "unexpected inventory slot ID for " .. tostring(slot.key))
        T.assertFalse(seen[slot.key] == true, "duplicate slot key " .. tostring(slot.key))
        seen[slot.key] = true
    end

    for key, _ in pairs(expected) do
        T.assertTrue(seen[key] == true, "missing slot " .. key)
    end
end)

T.test("schema version is seven and protocol version stays five", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.assertEqual(GGM.SCHEMA_VERSION, 7)
    T.assertEqual(GGM.SYNC_PROTOCOL_VERSION, 5)
end)

T.test("profession recipe index version is three", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.assertEqual(GGM.PROFESSION_RECIPE_INDEX_VERSION, 3)
end)

T.test("profession snapshot limits are conservative", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)

    T.assertEqual(GGM.PROFESSION_MAX_RECIPES, 4096)
    T.assertEqual(GGM.PROFESSION_MAX_NAME_BYTES, 128)
    T.assertEqual(GGM.PROFESSION_SOURCE_GUILD_LINK, "guild-profession-link")
    T.assertEqual(GGM.PROFESSION_CACHE_STATUS, "cached")
end)

T.test("default stability delay is five minutes", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)

    T.assertEqual(GGM.DEFAULT_STABILITY_DELAY_SECONDS, 300)
end)
