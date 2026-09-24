local T = require("tests.testlib")

T.test("tracked slot catalog contains the 16 Phase 1 gear slots", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)

    T.assertEqual(#GGM.TRACKED_SLOTS, 16)

    local expected = {
        HEAD = "HeadSlot",
        NECK = "NeckSlot",
        SHOULDER = "ShoulderSlot",
        BACK = "BackSlot",
        CHEST = "ChestSlot",
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
    }

    local seen = {}
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        T.assertEqual(slot.inventoryName, expected[slot.key], "unexpected slot mapping for " .. tostring(slot.key))
        T.assertFalse(seen[slot.key] == true, "duplicate slot key " .. tostring(slot.key))
        seen[slot.key] = true
    end

    for key, _ in pairs(expected) do
        T.assertTrue(seen[key] == true, "missing slot " .. key)
    end
end)

T.test("schema version starts at one", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.assertEqual(GGM.SCHEMA_VERSION, 1)
end)

T.test("default stability delay is five minutes", function()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)

    T.assertEqual(GGM.DEFAULT_STABILITY_DELAY_SECONDS, 300)
end)
