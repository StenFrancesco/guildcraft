local _, GGM = ...

local function findTrackedSlot(slotKey)
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        if slot.key == slotKey then
            return slot
        end
    end

    return nil
end

function GGM.ValidateGearSlotValue(slotKey, slotValue)
    if type(slotValue) ~= "table" then
        return false, "snapshot-slot-missing:" .. slotKey
    end

    if type(slotValue.inventorySlotID) ~= "number" then
        return false, "snapshot-slot-id-invalid:" .. slotKey
    end

    local hasItem = type(slotValue.itemID) == "number"
    local hasLink = type(slotValue.itemLink) == "string" and slotValue.itemLink ~= ""
    local isEmpty = slotValue.itemID == false and slotValue.itemLink == false

    if hasItem and hasLink then
        return true, nil
    end

    if isEmpty then
        return true, nil
    end

    return false, "snapshot-slot-value-invalid:" .. slotKey
end

function GGM.CopyGearSlotValue(slotValue)
    return {
        inventorySlotID = slotValue.inventorySlotID,
        itemID = slotValue.itemID,
        itemLink = slotValue.itemLink,
    }
end

function GGM.AreGearSlotValuesEqual(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end

    return left.inventorySlotID == right.inventorySlotID
        and left.itemID == right.itemID
        and left.itemLink == right.itemLink
end

function GGM.CapturePlayerGearSlot(api, slotKey)
    local trackedSlot = findTrackedSlot(slotKey)
    if not trackedSlot then
        return nil, "tracked-slot-unknown:" .. tostring(slotKey)
    end

    local inventorySlotID = api.GetInventorySlotInfo(trackedSlot.inventoryName)
    if type(inventorySlotID) ~= "number" then
        return nil, "inventory-slot-unavailable:" .. slotKey
    end

    local itemID = api.GetInventoryItemID("player", inventorySlotID)
    local itemLink = api.GetInventoryItemLink("player", inventorySlotID)

    if itemID ~= nil and itemLink == nil then
        return nil, "item-link-unavailable:" .. slotKey
    end

    if itemID == nil and itemLink ~= nil then
        return nil, "item-id-unavailable:" .. slotKey
    end

    local slotValue = {
        inventorySlotID = inventorySlotID,
        itemID = itemID or false,
        itemLink = itemLink or false,
    }

    local valid, err = GGM.ValidateGearSlotValue(slotKey, slotValue)
    if not valid then
        return nil, err
    end

    return slotValue, nil
end

function GGM.ValidateCompleteSnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return false, "snapshot-invalid"
    end

    if snapshot.complete ~= true then
        return false, "snapshot-not-complete"
    end

    if type(snapshot.capturedAt) ~= "number" then
        return false, "snapshot-captured-at-invalid"
    end

    if type(snapshot.slots) ~= "table" then
        return false, "snapshot-slots-invalid"
    end

    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        local valid, err = GGM.ValidateGearSlotValue(slot.key, snapshot.slots[slot.key])
        if not valid then
            return false, err
        end
    end

    return true, nil
end

function GGM.CapturePlayerGearSnapshot(api)
    local snapshot = {
        complete = true,
        capturedAt = api.GetServerTime(),
        slots = {},
    }

    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        local slotValue, err = GGM.CapturePlayerGearSlot(api, slot.key)
        if not slotValue then
            return nil, err
        end

        snapshot.slots[slot.key] = slotValue
    end

    local valid, err = GGM.ValidateCompleteSnapshot(snapshot)
    if not valid then
        return nil, err
    end

    return snapshot, nil
end
