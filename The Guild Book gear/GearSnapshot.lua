local _, GGM = ...

function GGM.ValidateGearSlotValue(slotKey, slotValue)
    local state, err = GGM.NormalizeRuntimeGearSlot(slotKey, slotValue)
    return state ~= nil, err
end

function GGM.CopyGearSlotValue(slotValue)
    if slotValue.unavailable == true then
        return { unavailable = true }
    end
    return {
        inventorySlotID = slotValue.inventorySlotID,
        itemID = slotValue.itemID,
        itemLink = slotValue.itemLink,
    }
end

local function runtimeStateForEquality(slotValue)
    if type(slotValue) ~= "table" then return nil end
    if slotValue.unavailable == true then
        if slotValue.inventorySlotID == nil and slotValue.itemID == nil and slotValue.itemLink == nil then
            return { state = "unavailable" }
        end
        return nil
    end
    if type(slotValue.inventorySlotID) ~= "number" then return nil end
    if not GGM.FindTrackedSlotByID(slotValue.inventorySlotID) then return nil end
    if slotValue.itemID == false and slotValue.itemLink == false then
        return { state = "empty", inventorySlotID = slotValue.inventorySlotID }
    end
    if type(slotValue.itemID) ~= "number" or type(slotValue.itemLink) ~= "string" or slotValue.itemLink == "" then
        return nil
    end
    local itemString, itemID = GGM.ExtractItemString(slotValue.itemLink)
    if not itemString or itemID ~= slotValue.itemID then return nil end
    return {
        state = "equipped",
        inventorySlotID = slotValue.inventorySlotID,
        itemID = itemID,
        itemString = itemString,
    }
end

function GGM.AreGearSlotValuesEqual(left, right)
    local leftState = runtimeStateForEquality(left)
    local rightState = runtimeStateForEquality(right)
    if not leftState or not rightState or leftState.state ~= rightState.state then return false end
    if leftState.state == "unavailable" then return true end
    if leftState.inventorySlotID ~= rightState.inventorySlotID then return false end
    if leftState.state == "empty" then return true end
    return leftState.itemID == rightState.itemID
        and leftState.itemString == rightState.itemString
end

function GGM.CapturePlayerGearSlot(api, slotKey)
    local trackedSlot, trackedSlotErr = GGM.FindTrackedSlot(slotKey)
    if not trackedSlot then
        return nil, trackedSlotErr
    end

    local inventorySlotID = api.GetInventorySlotInfo(trackedSlot.inventoryName)
    if inventorySlotID == nil and GGM.OPTIONAL_TRACKED_SLOTS[slotKey] == true then
        return { unavailable = true }, nil
    end
    if inventorySlotID == nil then
        return nil, "inventory-slot-unavailable:" .. slotKey
    end
    if inventorySlotID ~= trackedSlot.inventorySlotID then
        return nil, "snapshot-slot-id-mismatch:" .. slotKey
    end
    if type(inventorySlotID) ~= "number" then
        return nil, "inventory-slot-unavailable:" .. slotKey
    end

    local itemID = api.GetInventoryItemID("player", inventorySlotID)
    local itemLink = api.GetInventoryItemLink("player", inventorySlotID)

    if itemID == nil and itemLink == nil then
        itemID = false
        itemLink = false
    elseif itemID ~= nil and itemLink == nil then
        return nil, "item-link-unavailable:" .. slotKey
    elseif itemID == nil and itemLink ~= nil then
        return nil, "item-id-unavailable:" .. slotKey
    elseif itemID == false or itemLink == false then
        return nil, "snapshot-slot-value-invalid:" .. slotKey
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

function GGM.ResolvePlayerGearSlots(api)
    if type(api) ~= "table" or type(api.GetInventorySlotInfo) ~= "function" then
        return nil, "inventory-slot-api-unavailable"
    end

    local resolved = {
        slotKeyByInventorySlotID = {},
        unavailableOptionalSlots = {},
    }
    local seenInventorySlotIDs = {}

    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local runtimeSlotID = api.GetInventorySlotInfo(trackedSlot.inventoryName)
        if runtimeSlotID == nil and GGM.OPTIONAL_TRACKED_SLOTS[trackedSlot.key] == true then
            resolved.unavailableOptionalSlots[trackedSlot.key] = true
        elseif runtimeSlotID ~= trackedSlot.inventorySlotID then
            return nil, "snapshot-slot-id-mismatch:" .. trackedSlot.key
        elseif seenInventorySlotIDs[runtimeSlotID] then
            return nil, "inventory-slot-id-duplicate:" .. tostring(runtimeSlotID)
        else
            seenInventorySlotIDs[runtimeSlotID] = true
            resolved.slotKeyByInventorySlotID[runtimeSlotID] = trackedSlot.key
        end
    end

    return resolved, nil
end

function GGM.ValidateCompleteSnapshot(snapshot)
    local compact, err = GGM.CreateStoredGear(snapshot)
    return compact ~= nil, err
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
