local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearData.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    return GGM
end

local function makeCompleteApi(GGM)
    local slotIDs = {}
    local itemIDs = {}
    local itemLinks = {}

    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        slotIDs[slot.inventoryName] = slot.inventorySlotID
        itemIDs[slot.inventorySlotID] = 1000 + index
        itemLinks[slot.inventorySlotID] = "|Hitem:" .. tostring(1000 + index) .. "|h[Test Item " .. tostring(index) .. "]|h"
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
        T.assertEqual(stored.inventorySlotID, slot.inventorySlotID)
        T.assertEqual(stored.itemID, itemIDs[slot.inventorySlotID])
        T.assertEqual(stored.itemLink, itemLinks[slot.inventorySlotID])
    end
end)

T.test("complete snapshot accepts crafted metadata in every tracked slot", function()
    local GGM = loadModules()
    local api, itemIDs, itemLinks = makeCompleteApi(GGM)
    local function addCraftedMetadata(itemLink)
        return itemLink:gsub("|h", ":1:2:3:4:5:6:7:8:9:47:240167:48:245782:49:-2147480301::::Player-1301-0CFA0615:|h", 1)
    end
    for slotID, itemLink in pairs(itemLinks) do
        itemLinks[slotID] = addCraftedMetadata(itemLink)
    end

    local snapshot, err = GGM.CapturePlayerGearSnapshot(api)

    T.assertNil(err)
    T.assertTrue(snapshot.complete)
    local storedGear, storeErr = GGM.CreateStoredGear(snapshot)
    T.assertNil(storeErr)
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        local itemID = itemIDs[slot.inventorySlotID]
        T.assertEqual(
            storedGear.slots[slot.inventorySlotID],
            "item:" .. tostring(itemID) .. ":1:2:3:4:5:6:7:8:9:47:240167:48:245782:49"
        )
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

T.test("capture treats only paired nil item results as empty", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    local headID = api.GetInventorySlotInfo("HeadSlot")
    api.GetInventoryItemID = function(_, slotID)
        if slotID == headID then return false end
        return 1000 + slotID
    end
    api.GetInventoryItemLink = function(_, slotID)
        if slotID == headID then return false end
        return "|Hitem:" .. tostring(1000 + slotID) .. "|h[Item]|h"
    end

    local snapshot, err = GGM.CapturePlayerGearSnapshot(api)

    T.assertNil(snapshot)
    T.assertEqual(err, "snapshot-slot-value-invalid:HEAD")
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

T.test("capture rejects a runtime inventory id that disagrees with the code-owned slot id", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    local original = api.GetInventorySlotInfo
    api.GetInventorySlotInfo = function(name)
        if name == "HeadSlot" then return 99 end
        return original(name)
    end
    local snapshot, err = GGM.CapturePlayerGearSnapshot(api)
    T.assertNil(snapshot)
    T.assertEqual(err, "snapshot-slot-id-mismatch:HEAD")
end)

T.test("capture rejects an item id that disagrees with the exact item link payload", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    local headID = api.GetInventorySlotInfo("HeadSlot")
    local original = api.GetInventoryItemID
    api.GetInventoryItemID = function(unit, slotID)
        if slotID == headID then return 999999 end
        return original(unit, slotID)
    end
    local snapshot, err = GGM.CapturePlayerGearSnapshot(api)
    T.assertNil(snapshot)
    T.assertEqual(err, "snapshot-item-id-mismatch:HEAD")
end)

T.test("gear comparison ignores hyperlink display wrappers but detects item-string variants", function()
    local GGM = loadModules()
    local base = { inventorySlotID = 1, itemID = 1234, itemLink = "|Hitem:1234:1:2|h[One Name]|h" }
    local displayOnly = { inventorySlotID = 1, itemID = 1234, itemLink = "|cff00ff00|Hitem:1234:1:2|h[Another Name]|h|r" }
    local variant = { inventorySlotID = 1, itemID = 1234, itemLink = "|Hitem:1234:1:3|h[One Name]|h" }
    T.assertTrue(GGM.AreGearSlotValuesEqual(base, displayOnly))
    T.assertFalse(GGM.AreGearSlotValuesEqual(base, variant))
end)

T.test("gear comparison rejects equal-looking values with an unknown inventory slot id", function()
    local GGM = loadModules()
    local left = { inventorySlotID = 99, itemID = 1234, itemLink = "|Hitem:1234:1:2|h[One Name]|h" }
    local right = { inventorySlotID = 99, itemID = 1234, itemLink = "|Hitem:1234:1:2|h[One Name]|h" }
    T.assertFalse(GGM.AreGearSlotValuesEqual(left, right))
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

T.test("capture preserves the snapshot when the optional ranged slot is unavailable", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    api.GetInventorySlotInfo = function(inventoryName)
        if inventoryName == "RangedSlot" then return nil end
        for _, slot in ipairs(GGM.TRACKED_SLOTS) do
            if slot.inventoryName == inventoryName then return slot.inventorySlotID end
        end
    end
    local snapshot, err = GGM.CapturePlayerGearSnapshot(api)
    T.assertNil(err)
    T.assertNotNil(snapshot)
    T.assertTrue(snapshot.slots.RANGED.unavailable)
    T.assertTrue(type(snapshot.slots.HEAD.itemID) == "number")
end)

T.test("runtime gear slot resolution centralizes event slot lookup and optional availability", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    local snapshot = assert(GGM.CapturePlayerGearSnapshot(api))
    local originalGetInventorySlotInfo = api.GetInventorySlotInfo
    api.GetInventorySlotInfo = function(inventoryName)
        if inventoryName == "RangedSlot" then return nil end
        return originalGetInventorySlotInfo(inventoryName)
    end

    local resolved, err = GGM.ResolvePlayerGearSlots(api)

    T.assertNil(err)
    T.assertEqual(resolved.slotKeyByInventorySlotID[GGM.FindTrackedSlot("HEAD").inventorySlotID], "HEAD")
    T.assertTrue(resolved.unavailableOptionalSlots.RANGED)
end)

T.test("runtime gear slot resolution rejects runtime ids that disagree with the catalog", function()
    local GGM = loadModules()
    local api = makeCompleteApi(GGM)
    local original = api.GetInventorySlotInfo
    api.GetInventorySlotInfo = function(name)
        if name == "HeadSlot" then return 99 end
        return original(name)
    end

    local resolved, err = GGM.ResolvePlayerGearSlots(api)

    T.assertNil(resolved)
    T.assertEqual(err, "snapshot-slot-id-mismatch:HEAD")
end)
