local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("DysgearMemory/Constants.lua", GGM)
    T.loadAddonFile("DysgearMemory/GearData.lua", GGM)
    return GGM
end

T.test("schema seven keeps protocol five and assigns canonical inventory slot ids", function()
    local GGM = loadModules()
    T.assertEqual(GGM.SCHEMA_VERSION, 7)
    T.assertEqual(GGM.SYNC_PROTOCOL_VERSION, 5)

    local expected = {
        HEAD = 1, NECK = 2, SHOULDER = 3, SHIRT = 4, CHEST = 5,
        WAIST = 6, LEGS = 7, FEET = 8, WRIST = 9, HANDS = 10,
        FINGER_1 = 11, FINGER_2 = 12, TRINKET_1 = 13, TRINKET_2 = 14,
        BACK = 15, MAIN_HAND = 16, OFF_HAND = 17, RANGED = 18, TABARD = 19,
    }
    local seen = {}
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        T.assertEqual(slot.inventorySlotID, expected[slot.key])
        T.assertFalse(seen[slot.inventorySlotID] == true)
        seen[slot.inventorySlotID] = true
    end
end)

T.test("item string parser preserves the exact instance payload and derives the item id", function()
    local GGM = loadModules()
    local itemString = "item:153787::::::::19:105::105:1:13572:2:9:19:28:2852:::::"
    local itemID, err = GGM.ParseItemString(itemString)
    T.assertNil(err)
    T.assertEqual(itemID, 153787)

    local extracted, extractedID, extractErr = GGM.ExtractItemString(
        "|cff0070dd|H" .. itemString .. "|h[Localized Name]|h|r"
    )
    T.assertNil(extractErr)
    T.assertEqual(extracted, itemString)
    T.assertEqual(extractedID, 153787)
end)

T.test("item string parser accepts signed suffix and unique ids within existing bounds", function()
    local GGM = loadModules()
    local itemString = "item:153787:0:0:0:0:0:-123:-456"
    local itemID, err = GGM.ParseItemString(itemString)
    T.assertNil(err)
    T.assertEqual(itemID, 153787)

    local normalized, normalizeErr = GGM.NormalizeRuntimeGearSlot("HEAD", {
        inventorySlotID = 1,
        itemID = 153787,
        itemLink = "|H" .. itemString .. "|h[Signed suffix item]|h",
    })
    T.assertNil(normalizeErr)
    T.assertEqual(normalized.itemString, itemString)

    T.assertNil(GGM.ParseItemString("item:153787:0:0:0:0:0:-2147483648:0"))
    T.assertNil(GGM.ParseItemString("item:153787:0:0:0:0:0:0:-2147483648"))
end)

T.test("item strings over limit or with invalid ids delimiters or control bytes fail closed", function()
    local GGM = loadModules()
    local overlong = "item:1:" .. string.rep("0", GGM.GEAR_MAX_ITEM_STRING_BYTES)
    T.assertNil(GGM.ParseItemString(overlong))
    T.assertNil(GGM.ParseItemString("item:0::::"))
    T.assertNil(GGM.ParseItemString("item:not-a-number::::"))
    T.assertNil(GGM.ParseItemString("item:2147483648::::"))
    T.assertNil(GGM.ParseItemString("item:153787:|h"))
    T.assertNil(GGM.ParseItemString("item:153787:bogus"))
    T.assertNil(GGM.ParseItemString("item:153787:12x"))
    T.assertNil(GGM.ParseItemString("item:153787:" .. string.char(1)))

    local malformedLink = "|Hitem:153787:" .. string.char(1) .. "|h[Malformed]|h"
    local extracted, itemID = GGM.ExtractItemString(malformedLink)
    T.assertNil(extracted)
    T.assertNil(itemID)
end)

T.test("hyperlink reconstruction preserves payload and falls back to an item id label", function()
    local GGM = loadModules()
    local itemString = "item:153787::::::::19:105::105:1:13572:2:9:19:28:2852:::::"
    local api = { C_Item = { GetItemNameByID = function(id)
        T.assertEqual(id, 153787)
        return "Known Name"
    end } }

    local link = assert(GGM.BuildItemHyperlink(api, itemString))
    T.assertEqual(link, "|H" .. itemString .. "|h[Known Name]|h")

    api.C_Item.GetItemNameByID = function() return nil end
    local fallback = assert(GGM.BuildItemHyperlink(api, itemString))
    T.assertEqual(fallback, "|H" .. itemString .. "|h[Item 153787]|h")
end)

T.test("runtime snapshot compacts equipped empty and unavailable slots", function()
    local GGM = loadModules()
    local snapshot = { complete = true, capturedAt = 1790846723, slots = {} }
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        snapshot.slots[trackedSlot.key] = {
            inventorySlotID = trackedSlot.inventorySlotID,
            itemID = 1000 + trackedSlot.inventorySlotID,
            itemLink = "|Hitem:" .. tostring(1000 + trackedSlot.inventorySlotID) .. ":0:0|h[Test]|h",
        }
    end
    snapshot.slots.OFF_HAND = { inventorySlotID = 17, itemID = false, itemLink = false }
    snapshot.slots.RANGED = { unavailable = true }

    local gear, err = GGM.CreateStoredGear(snapshot)
    T.assertNil(err)
    T.assertEqual(gear.capturedAt, 1790846723)
    T.assertTrue(gear.complete)
    T.assertEqual(gear.slots[1], "item:1001:0:0")
    T.assertNil(gear.slots[17])
    T.assertNil(gear.slots[18])
    T.assertTrue(gear.unavailableSlots[18])
    T.assertNil(gear.slots.HEAD)
end)

T.test("stored slot helper distinguishes equipped empty and unavailable", function()
    local GGM = loadModules()
    local gear = {
        complete = true,
        capturedAt = 1,
        slots = { [1] = "item:1234:1:2:3" },
        unavailableSlots = { [18] = true },
    }
    local head = assert(GGM.GetStoredGearSlot(gear, "HEAD"))
    local offhand = assert(GGM.GetStoredGearSlot(gear, "OFF_HAND"))
    local ranged = assert(GGM.GetStoredGearSlot(gear, "RANGED"))
    T.assertEqual(head.state, "equipped")
    T.assertEqual(head.itemID, 1234)
    T.assertEqual(head.itemString, "item:1234:1:2:3")
    T.assertEqual(offhand.state, "empty")
    T.assertEqual(ranged.state, "unavailable")
end)

T.test("stored slot setter removes empty items and clears unavailable markers on equip", function()
    local GGM = loadModules()
    local gear = { complete = true, capturedAt = 1, slots = {}, unavailableSlots = { [18] = true } }
    assert(GGM.SetStoredGearSlot(gear, "RANGED", {
        inventorySlotID = 18, itemID = 2222, itemLink = "|Hitem:2222:9|h[Ranged]|h",
    }))
    T.assertEqual(gear.slots[18], "item:2222:9")
    T.assertNil(gear.unavailableSlots[18])

    assert(GGM.SetStoredGearSlot(gear, "RANGED", {
        inventorySlotID = 18, itemID = false, itemLink = false,
    }))
    T.assertNil(gear.slots[18])
    T.assertNil(gear.unavailableSlots[18])
end)

T.test("stored gear validation rejects unknown ids overlap required unavailable and duplicate catalog ids", function()
    local GGM = loadModules()
    local gear = { complete = true, capturedAt = 1, slots = { [99] = "item:1" }, unavailableSlots = {} }
    T.assertFalse(GGM.ValidateStoredGear(gear, true))

    gear = { complete = true, capturedAt = 1, slots = { [18] = "item:1" }, unavailableSlots = { [18] = true } }
    T.assertFalse(GGM.ValidateStoredGear(gear, true))

    gear = { complete = true, capturedAt = 1, slots = {}, unavailableSlots = { [1] = true } }
    T.assertFalse(GGM.ValidateStoredGear(gear, true))

    GGM.TRACKED_SLOTS[2].inventorySlotID = GGM.TRACKED_SLOTS[1].inventorySlotID
    T.assertFalse(GGM.ValidateStoredGear({ complete = true, capturedAt = 1, slots = {}, unavailableSlots = {} }, true))
end)

T.test("stored gear converts back to named runtime slots with reconstructed item links", function()
    local GGM = loadModules()
    local snapshot = { complete = true, capturedAt = 1790846723, slots = {} }
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        snapshot.slots[trackedSlot.key] = {
            inventorySlotID = trackedSlot.inventorySlotID,
            itemID = 1000 + trackedSlot.inventorySlotID,
            itemLink = "|Hitem:" .. tostring(1000 + trackedSlot.inventorySlotID) .. ":0:0|h[Test]|h",
        }
    end
    snapshot.slots.OFF_HAND = { inventorySlotID = 17, itemID = false, itemLink = false }
    snapshot.slots.RANGED = { unavailable = true }

    local gear = assert(GGM.CreateStoredGear(snapshot))
    local runtime = assert(GGM.BuildRuntimeGearSnapshot({}, gear))
    T.assertEqual(runtime.capturedAt, snapshot.capturedAt)
    T.assertEqual(runtime.slots.HEAD.inventorySlotID, 1)
    T.assertEqual(runtime.slots.HEAD.itemID, 1001)
    T.assertEqual(runtime.slots.HEAD.itemLink, "|Hitem:1001:0:0|h[Item 1001]|h")
    T.assertEqual(runtime.slots.OFF_HAND.itemID, false)
    T.assertEqual(runtime.slots.OFF_HAND.itemLink, false)
    T.assertTrue(runtime.slots.RANGED.unavailable)
    T.assertNil(runtime.slots.RANGED.inventorySlotID)
end)

T.test("stored slot reads allow valid incomplete gear but runtime reconstruction rejects it", function()
    local GGM = loadModules()
    local gear = { complete = false, capturedAt = 1, slots = {}, unavailableSlots = {} }
    local state, stateErr = GGM.GetStoredGearSlot(gear, "HEAD")
    T.assertNil(stateErr)
    T.assertEqual(state.state, "empty")

    local runtime, runtimeErr = GGM.BuildRuntimeGearSlot({}, gear, "HEAD")
    T.assertNil(runtime)
    T.assertEqual(runtimeErr, "snapshot-not-complete")

    runtime, runtimeErr = GGM.BuildRuntimeGearSnapshot({}, gear)
    T.assertNil(runtime)
    T.assertEqual(runtimeErr, "snapshot-not-complete")
end)

T.test("stored slot reads allow validated stale gear while runtime reconstruction stays complete-only", function()
    local GGM = loadModules()
    local gear = { complete = false, capturedAt = 1, slots = { [1] = "item:1234:5" }, unavailableSlots = {} }
    local state = assert(GGM.GetStoredGearSlot(gear, "HEAD"))
    T.assertEqual(state.state, "equipped")
    T.assertEqual(state.itemString, "item:1234:5")

    local runtime, runtimeErr = GGM.BuildRuntimeGearSlot({}, gear, "HEAD")
    T.assertNil(runtime)
    T.assertEqual(runtimeErr, "snapshot-not-complete")

    gear.slots[1] = "item:broken"
    state = GGM.GetStoredGearSlot(gear, "HEAD")
    T.assertNil(state)
end)

T.test("stored gear and snapshot timestamps must be protocol-bounded integers", function()
    local GGM = loadModules()
    local invalidTimes = { -1, 0.5, 4294967296, math.huge, 0 / 0 }
    for _, capturedAt in ipairs(invalidTimes) do
        local gear = { complete = true, capturedAt = capturedAt, slots = {}, unavailableSlots = {} }
        T.assertFalse(GGM.ValidateStoredGear(gear, true))
        local runtime, runtimeErr = GGM.BuildRuntimeGearSnapshot({}, gear)
        T.assertNil(runtime)
        T.assertEqual(runtimeErr, "snapshot-captured-at-invalid")

        local snapshot = { complete = true, capturedAt = capturedAt, slots = {} }
        for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
            snapshot.slots[trackedSlot.key] = {
                inventorySlotID = trackedSlot.inventorySlotID, itemID = false, itemLink = false,
            }
        end
        local stored, storedErr = GGM.CreateStoredGear(snapshot)
        T.assertNil(stored)
        T.assertEqual(storedErr, "snapshot-captured-at-invalid")
    end

    local gear = { complete = true, capturedAt = 0, slots = {}, unavailableSlots = {} }
    T.assertTrue(GGM.ValidateStoredGear(gear, true))
    gear.capturedAt = GGM.SYNC_MAX_TIMESTAMP
    T.assertTrue(GGM.ValidateStoredGear(gear, true))
end)

T.test("stored gear rejects extra fields and setters preserve invalid records atomically", function()
    local GGM = loadModules()
    local gear = { complete = true, capturedAt = 1, slots = {}, unavailableSlots = {}, extra = true }
    T.assertFalse(GGM.ValidateStoredGear(gear, true))
    local state, stateErr = GGM.GetStoredGearSlot(gear, "HEAD")
    T.assertNil(state)
    T.assertEqual(stateErr, "stored-gear-invalid")

    gear = { complete = true, capturedAt = 1, slots = { [99] = "item:1" }, unavailableSlots = {} }
    local originalSlots = gear.slots
    local originalUnknown = gear.slots[99]
    local stored, storedErr = GGM.SetStoredGearSlot(gear, "HEAD", {
        inventorySlotID = 1, itemID = 2222, itemLink = "|Hitem:2222:9|h[Head]|h",
    })
    T.assertFalse(stored)
    T.assertEqual(storedErr, "tracked-slot-id-unknown:99")
    T.assertEqual(gear.slots, originalSlots)
    T.assertEqual(gear.slots[99], originalUnknown)
    T.assertNil(gear.slots[1])

    gear = { complete = true, capturedAt = 1, slots = {}, unavailableSlots = {} }
    gear.unknown = "extra"
    stored, storedErr = GGM.SetStoredGearSlot(gear, "HEAD", {
        inventorySlotID = 1, itemID = 2222, itemLink = "|Hitem:2222:9|h[Head]|h",
    })
    T.assertFalse(stored)
    T.assertEqual(storedErr, "stored-gear-invalid")
    T.assertNil(gear.slots[1])
end)
