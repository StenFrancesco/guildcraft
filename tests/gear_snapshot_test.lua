local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    return GGM
end

local function makeCompleteApi(GGM)
    local slotIDs = {}
    local itemIDs = {}
    local itemLinks = {}

    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        slotIDs[slot.inventoryName] = index
        itemIDs[index] = 1000 + index
        itemLinks[index] = "|Hitem:" .. tostring(1000 + index) .. "|h[Test Item " .. tostring(index) .. "]|h"
    end

    return {
        GetInventorySlotInfo = function(inventoryName)
            return slotIDs[inventoryName]
        end,
        GetInventoryItemID = function(unit, slotID)
            T.assertEqual(unit, "player")
            return itemIDs[slotID]
        end,
        GetInventoryItemLink = function(unit, slotID)
            T.assertEqual(unit, "player")
            return itemLinks[slotID]
        end,
        GetServerTime = function()
            return 1700000000
        end,
    }, itemIDs, itemLinks
end

T.test("capture creates a complete snapshot for every tracked slot", function()
    local GGM = loadModules()
    local api, itemIDs, itemLinks = makeCompleteApi(GGM)

    local snapshot, err = GGM.CapturePlayerGearSnapshot(api)

    T.assertNil(err)
    T.assertTrue(snapshot.complete)
    T.assertEqual(snapshot.capturedAt, 1700000000)

    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        local stored = snapshot.slots[slot.key]
        T.assertNotNil(stored, "missing slot " .. slot.key)
        T.assertEqual(stored.inventorySlotID, index)
        T.assertEqual(stored.itemID, itemIDs[index])
        T.assertEqual(stored.itemLink, itemLinks[index])
    end
end)

T.test("capture explicitly represents an empty slot", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    local offHandID = api.GetInventorySlotInfo("SecondaryHandSlot")

    local originalID = api.GetInventoryItemID
    local originalLink = api.GetInventoryItemLink
    api.GetInventoryItemID = function(unit, slotID)
        if slotID == offHandID then
            return nil
        end
        return originalID(unit, slotID)
    end
    api.GetInventoryItemLink = function(unit, slotID)
        if slotID == offHandID then
            return nil
        end
        return originalLink(unit, slotID)
    end

    local snapshot, err = GGM.CapturePlayerGearSnapshot(api)

    T.assertNil(err)
    T.assertTrue(snapshot.complete)
    T.assertFalse(snapshot.slots.OFF_HAND.itemID)
    T.assertFalse(snapshot.slots.OFF_HAND.itemLink)
end)

T.test("capture fails when a tracked inventory slot cannot be resolved", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    local original = api.GetInventorySlotInfo
    api.GetInventorySlotInfo = function(inventoryName)
        if inventoryName == "HeadSlot" then
            return nil
        end
        return original(inventoryName)
    end

    local snapshot, err = GGM.CapturePlayerGearSnapshot(api)

    T.assertNil(snapshot)
    T.assertEqual(err, "inventory-slot-unavailable:HEAD")
end)

T.test("capture fails when an equipped item id exists but its link is unavailable", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    local headID = api.GetInventorySlotInfo("HeadSlot")
    local original = api.GetInventoryItemLink
    api.GetInventoryItemLink = function(unit, slotID)
        if slotID == headID then
            return nil
        end
        return original(unit, slotID)
    end

    local snapshot, err = GGM.CapturePlayerGearSnapshot(api)

    T.assertNil(snapshot)
    T.assertEqual(err, "item-link-unavailable:HEAD")
end)

T.test("snapshot validator rejects a missing tracked slot", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    local snapshot = assert(GGM.CapturePlayerGearSnapshot(api))
    snapshot.slots.HEAD = nil

    local valid, err = GGM.ValidateCompleteSnapshot(snapshot)

    T.assertFalse(valid)
    T.assertEqual(err, "snapshot-slot-missing:HEAD")
end)

T.test("single-slot capture returns the same slot shape used by complete snapshots", function()
    local GGM = loadModules()
    local api, itemIDs, itemLinks = makeCompleteApi(GGM)

    local slotValue, err = GGM.CapturePlayerGearSlot(api, "HEAD")

    T.assertNil(err)
    T.assertEqual(slotValue.inventorySlotID, 1)
    T.assertEqual(slotValue.itemID, itemIDs[1])
    T.assertEqual(slotValue.itemLink, itemLinks[1])
end)

T.test("single-slot capture rejects an unknown tracked slot key", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)

    local slotValue, err = GGM.CapturePlayerGearSlot(api, "NOT_A_SLOT")

    T.assertNil(slotValue)
    T.assertEqual(err, "tracked-slot-unknown:NOT_A_SLOT")
end)

T.test("gear slot comparison notices an item-link change for the same item id", function()
    local GGM = loadModules()
    local left = {
        inventorySlotID = 1,
        itemID = 1234,
        itemLink = "|Hitem:1234::::::::|h[Item]|h",
    }
    local right = {
        inventorySlotID = 1,
        itemID = 1234,
        itemLink = "|Hitem:1234:999:::::::|h[Item]|h",
    }

    T.assertFalse(GGM.AreGearSlotValuesEqual(left, right))
    T.assertTrue(GGM.AreGearSlotValuesEqual(left, left))
end)
