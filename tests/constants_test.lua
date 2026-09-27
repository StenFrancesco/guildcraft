local T = require("tests.testlib")

T.test("tracked slot catalog contains the exact 19-slot paper-doll mapping", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)

    T.assertEqual(#GGM.TRACKED_SLOTS, 19)

    local expected = {
        HEAD = "HeadSlot",
        NECK = "NeckSlot",
        SHOULDER = "ShoulderSlot",
        BACK = "BackSlot",
        CHEST = "ChestSlot",
        SHIRT = "ShirtSlot",
        TABARD = "TabardSlot",
        WRIST = "WristSlot",
        HANDS = "HandsSlot",
        WAIST = "WaistSlot",
        LEGS = "LegsSlot",
        FEET = "FeetSlot",
        FINGER_1 = "Finger0Slot",
        FINGER_2 = "Finger1Slot",
        TRINKET_1 = "Trinket0Slot",
        TRINKET_2 = "Trinket1Slot",
        MAIN_HAND = "MainHandSlot",
        OFF_HAND = "SecondaryHandSlot",
        RANGED = "RangedSlot",
    }

    local seen = {}
    local expectedOrder = { "HEAD", "NECK", "SHOULDER", "BACK", "CHEST", "SHIRT", "TABARD", "WRIST", "HANDS", "WAIST", "LEGS", "FEET", "FINGER_1", "FINGER_2", "TRINKET_1", "TRINKET_2", "MAIN_HAND", "OFF_HAND", "RANGED" }
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        T.assertEqual(slot.key, expectedOrder[index])
        T.assertEqual(slot.inventoryName, expected[slot.key], "unexpected slot mapping for " .. tostring(slot.key))
        T.assertFalse(seen[slot.key] == true, "duplicate slot key " .. tostring(slot.key))
        seen[slot.key] = true
    end

    for key, _ in pairs(expected) do
        T.assertTrue(seen[key] == true, "missing slot " .. key)
    end
end)

T.test("schema version is three", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.assertEqual(GGM.SCHEMA_VERSION, 3)
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
