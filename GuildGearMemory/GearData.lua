local _, GGM = ...

local function positiveInteger(value, maximum)
    return type(value) == "number"
        and value == math.floor(value)
        and value > 0
        and value <= maximum
end

local function isProtocolTimestamp(value)
    local maximum = GGM.SYNC_MAX_TIMESTAMP
    if type(value) ~= "number" or type(maximum) ~= "number"
        or value ~= value or value < 0 or value > maximum then
        return false
    end
    return value == math.floor(value)
end

local function buildTrackedSlotIndexes()
    if type(GGM.TRACKED_SLOTS) ~= "table" then
        return nil, nil, "tracked-slot-catalog-invalid"
    end

    local byKey, byID = {}, {}
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        if type(slot) ~= "table"
            or type(slot.key) ~= "string" or slot.key == ""
            or type(slot.inventoryName) ~= "string" or slot.inventoryName == ""
            or not positiveInteger(slot.inventorySlotID, 255) then
            return nil, nil, "tracked-slot-definition-invalid"
        end
        if byKey[slot.key] ~= nil then
            return nil, nil, "tracked-slot-key-duplicate:" .. slot.key
        end
        if byID[slot.inventorySlotID] ~= nil then
            return nil, nil, "tracked-slot-id-duplicate:" .. tostring(slot.inventorySlotID)
        end
        byKey[slot.key] = slot
        byID[slot.inventorySlotID] = slot
    end
    return byKey, byID, nil
end

function GGM.FindTrackedSlot(slotKey)
    local byKey, _, catalogErr = buildTrackedSlotIndexes()
    if not byKey then return nil, catalogErr end
    local slot = byKey[slotKey]
    if not slot then return nil, "tracked-slot-unknown:" .. tostring(slotKey) end
    return slot, nil
end

function GGM.FindTrackedSlotByID(inventorySlotID)
    local _, byID, catalogErr = buildTrackedSlotIndexes()
    if not byID then return nil, catalogErr end
    local slot = byID[inventorySlotID]
    if not slot then return nil, "tracked-slot-id-unknown:" .. tostring(inventorySlotID) end
    return slot, nil
end

function GGM.ParseItemString(itemString)
    if type(itemString) ~= "string" or itemString == "" then
        return nil, "item-string-invalid"
    end
    if #itemString > GGM.GEAR_MAX_ITEM_STRING_BYTES then
        return nil, "item-string-too-long"
    end
    if itemString:find("|", 1, true) or itemString:find("%c") then
        return nil, "item-string-delimiter-invalid"
    end

    local digits, suffix = itemString:match("^item:(%d+)(.*)$")
    if not digits or (suffix ~= "" and suffix:sub(1, 1) ~= ":") then
        return nil, "item-string-invalid"
    end
    if suffix ~= "" then
        local suffixFields = suffix:sub(2)
        for field in (suffixFields .. ":"):gmatch("(.-):") do
            if field ~= "" then
                if not field:match("^%d+$") or #field > 10
                    or tonumber(field) > GGM.GEAR_MAX_ITEM_ID then
                    return nil, "item-string-suffix-invalid"
                end
            end
        end
    end
    local itemID = tonumber(digits)
    if not positiveInteger(itemID, GGM.GEAR_MAX_ITEM_ID) then
        return nil, "item-id-invalid"
    end
    return itemID, nil
end

function GGM.ExtractItemString(itemLink)
    if type(itemLink) ~= "string" or itemLink == "" then
        return nil, nil, "item-link-invalid"
    end
    local itemString = itemLink:match("|H(item:[^|]+)|h.-|h")
    if not itemString then return nil, nil, "item-link-invalid" end
    local itemID, itemErr = GGM.ParseItemString(itemString)
    if not itemID then return nil, nil, itemErr end
    return itemString, itemID, nil
end

local function itemNameFor(api, itemID)
    if type(api) == "table" and type(api.C_Item) == "table"
        and type(api.C_Item.GetItemNameByID) == "function" then
        local ok, name = pcall(api.C_Item.GetItemNameByID, itemID)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if type(api) == "table" and type(api.GetItemInfo) == "function" then
        local ok, name = pcall(api.GetItemInfo, itemID)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return "Item " .. tostring(itemID)
end

function GGM.BuildItemHyperlink(api, itemString)
    local itemID, itemErr = GGM.ParseItemString(itemString)
    if not itemID then return nil, itemErr end
    return "|H" .. itemString .. "|h[" .. itemNameFor(api, itemID) .. "]|h", nil
end

function GGM.NormalizeRuntimeGearSlot(slotKey, slotValue)
    local trackedSlot, slotErr = GGM.FindTrackedSlot(slotKey)
    if not trackedSlot then return nil, slotErr end
    if type(slotValue) ~= "table" then return nil, "snapshot-slot-missing:" .. slotKey end

    if slotValue.unavailable == true then
        if GGM.OPTIONAL_TRACKED_SLOTS[slotKey] == true
            and slotValue.inventorySlotID == nil
            and slotValue.itemID == nil
            and slotValue.itemLink == nil then
            return { state = "unavailable", inventorySlotID = trackedSlot.inventorySlotID }, nil
        end
        return nil, "snapshot-slot-unavailable-invalid:" .. slotKey
    end

    if slotValue.inventorySlotID ~= trackedSlot.inventorySlotID then
        return nil, "snapshot-slot-id-mismatch:" .. slotKey
    end
    if slotValue.itemID == false and slotValue.itemLink == false then
        return { state = "empty", inventorySlotID = trackedSlot.inventorySlotID }, nil
    end
    if type(slotValue.itemID) ~= "number" or type(slotValue.itemLink) ~= "string" or slotValue.itemLink == "" then
        return nil, "snapshot-slot-value-invalid:" .. slotKey
    end

    local itemString, parsedID, itemErr = GGM.ExtractItemString(slotValue.itemLink)
    if not itemString then return nil, itemErr .. ":" .. slotKey end
    if parsedID ~= slotValue.itemID then return nil, "snapshot-item-id-mismatch:" .. slotKey end
    return {
        state = "equipped",
        inventorySlotID = trackedSlot.inventorySlotID,
        itemID = parsedID,
        itemString = itemString,
    }, nil
end

function GGM.ValidateStoredGear(gear, expectedComplete)
    if type(gear) ~= "table" then return false, "stored-gear-invalid" end
    for key in pairs(gear) do
        if key ~= "complete" and key ~= "capturedAt" and key ~= "slots" and key ~= "unavailableSlots" then
            return false, "stored-gear-invalid"
        end
    end
    if type(gear.complete) ~= "boolean" then return false, "stored-gear-complete-invalid" end
    if expectedComplete ~= nil and gear.complete ~= expectedComplete then
        return false, expectedComplete and "snapshot-not-complete" or "stored-gear-completeness-invalid"
    end
    if not isProtocolTimestamp(gear.capturedAt) then return false, "snapshot-captured-at-invalid" end
    if type(gear.slots) ~= "table" then return false, "snapshot-slots-invalid" end
    if type(gear.unavailableSlots) ~= "table" then return false, "snapshot-unavailable-slots-invalid" end

    local _, byID, catalogErr = buildTrackedSlotIndexes()
    if not byID then return false, catalogErr end

    for slotID, itemString in pairs(gear.slots) do
        local trackedSlot = byID[slotID]
        if not trackedSlot then return false, "tracked-slot-id-unknown:" .. tostring(slotID) end
        local itemID, itemErr = GGM.ParseItemString(itemString)
        if not itemID then return false, itemErr .. ":" .. trackedSlot.key end
        if gear.unavailableSlots[slotID] ~= nil then
            return false, "snapshot-slot-state-conflict:" .. trackedSlot.key
        end
    end

    for slotID, unavailable in pairs(gear.unavailableSlots) do
        local trackedSlot = byID[slotID]
        if not trackedSlot then return false, "tracked-slot-id-unknown:" .. tostring(slotID) end
        if unavailable ~= true or GGM.OPTIONAL_TRACKED_SLOTS[trackedSlot.key] ~= true then
            return false, "snapshot-slot-unavailable-invalid:" .. trackedSlot.key
        end
        if gear.slots[slotID] ~= nil then
            return false, "snapshot-slot-state-conflict:" .. trackedSlot.key
        end
    end
    return true, nil
end

function GGM.GetStoredGearSlot(gear, slotKey)
    local trackedSlot, slotErr = GGM.FindTrackedSlot(slotKey)
    if not trackedSlot then return nil, slotErr end
    local valid, validateErr = GGM.ValidateStoredGear(gear)
    if not valid then return nil, validateErr end

    local itemString = gear.slots[trackedSlot.inventorySlotID]
    local unavailable = gear.unavailableSlots[trackedSlot.inventorySlotID]
    if itemString ~= nil and unavailable ~= nil then
        return nil, "snapshot-slot-state-conflict:" .. slotKey
    end
    if unavailable ~= nil then
        if unavailable ~= true or GGM.OPTIONAL_TRACKED_SLOTS[slotKey] ~= true then
            return nil, "snapshot-slot-unavailable-invalid:" .. slotKey
        end
        return { state = "unavailable", inventorySlotID = trackedSlot.inventorySlotID }, nil
    end
    if itemString == nil then
        return { state = "empty", inventorySlotID = trackedSlot.inventorySlotID }, nil
    end

    local itemID, itemErr = GGM.ParseItemString(itemString)
    if not itemID then return nil, itemErr .. ":" .. slotKey end
    return {
        state = "equipped",
        inventorySlotID = trackedSlot.inventorySlotID,
        itemID = itemID,
        itemString = itemString,
    }, nil
end

function GGM.SetStoredGearSlot(gear, slotKey, slotValue)
    local valid, validateErr = GGM.ValidateStoredGear(gear)
    if not valid then return false, validateErr end
    local state, stateErr = GGM.NormalizeRuntimeGearSlot(slotKey, slotValue)
    if not state then return false, stateErr end

    local candidate = {
        complete = gear.complete,
        capturedAt = gear.capturedAt,
        slots = {},
        unavailableSlots = {},
    }
    for slotID, itemString in pairs(gear.slots) do candidate.slots[slotID] = itemString end
    for slotID, unavailable in pairs(gear.unavailableSlots) do candidate.unavailableSlots[slotID] = unavailable end

    local slotID = state.inventorySlotID
    if state.state == "equipped" then
        candidate.slots[slotID] = state.itemString
        candidate.unavailableSlots[slotID] = nil
    elseif state.state == "unavailable" then
        candidate.slots[slotID] = nil
        candidate.unavailableSlots[slotID] = true
    else
        candidate.slots[slotID] = nil
        candidate.unavailableSlots[slotID] = nil
    end
    valid, validateErr = GGM.ValidateStoredGear(candidate, gear.complete)
    if not valid then return false, validateErr end
    gear.slots = candidate.slots
    gear.unavailableSlots = candidate.unavailableSlots
    return true, nil
end

function GGM.CreateStoredGear(snapshot)
    if type(snapshot) ~= "table" then return nil, "snapshot-invalid" end
    if snapshot.complete ~= true then return nil, "snapshot-not-complete" end
    if not isProtocolTimestamp(snapshot.capturedAt) then return nil, "snapshot-captured-at-invalid" end
    if type(snapshot.slots) ~= "table" then return nil, "snapshot-slots-invalid" end

    for slotKey in pairs(snapshot.slots) do
        local trackedSlot, trackedErr = GGM.FindTrackedSlot(slotKey)
        if not trackedSlot then return nil, trackedErr end
    end

    local gear = {
        complete = true,
        capturedAt = snapshot.capturedAt,
        slots = {},
        unavailableSlots = {},
    }
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local slotValue = snapshot.slots[trackedSlot.key]
        if slotValue == nil and GGM.OPTIONAL_TRACKED_SLOTS[trackedSlot.key] == true then
            slotValue = { unavailable = true }
        elseif slotValue == nil then
            return nil, "snapshot-slot-missing:" .. trackedSlot.key
        end
        local stored, storeErr = GGM.SetStoredGearSlot(gear, trackedSlot.key, slotValue)
        if not stored then return nil, storeErr end
    end
    local valid, validateErr = GGM.ValidateStoredGear(gear, true)
    if not valid then return nil, validateErr end
    return gear, nil
end

function GGM.BuildRuntimeGearSlot(api, gear, slotKey)
    local valid, validateErr = GGM.ValidateStoredGear(gear, true)
    if not valid then return nil, validateErr end
    local state, stateErr = GGM.GetStoredGearSlot(gear, slotKey)
    if not state then return nil, stateErr end
    if state.state == "unavailable" then return { unavailable = true }, nil end
    if state.state == "empty" then
        return { inventorySlotID = state.inventorySlotID, itemID = false, itemLink = false }, nil
    end
    local itemLink, linkErr = GGM.BuildItemHyperlink(api, state.itemString)
    if not itemLink then return nil, linkErr end
    return { inventorySlotID = state.inventorySlotID, itemID = state.itemID, itemLink = itemLink }, nil
end

function GGM.BuildRuntimeGearSnapshot(api, gear)
    local valid, validateErr = GGM.ValidateStoredGear(gear, true)
    if not valid then return nil, validateErr end
    local snapshot = { complete = true, capturedAt = gear.capturedAt, slots = {} }
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local slotValue, slotErr = GGM.BuildRuntimeGearSlot(api, gear, trackedSlot.key)
        if not slotValue then return nil, slotErr end
        snapshot.slots[trackedSlot.key] = slotValue
    end
    return snapshot, nil
end
