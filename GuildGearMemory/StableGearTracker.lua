local _, GGM = ...

local function clearPending(tracker, slotKey)
    local pending = tracker.pendingBySlot[slotKey]
    if not pending then
        return
    end

    if pending.timer and type(pending.timer.Cancel) == "function" then
        pending.timer:Cancel()
    end

    tracker.pendingBySlot[slotKey] = nil
end

local function schedulePending(tracker, slotKey, slotValue)
    tracker.nextPendingToken = tracker.nextPendingToken + 1
    local token = tracker.nextPendingToken

    local pending = {
        token = token,
        slot = GGM.CopyGearSlotValue(slotValue),
        timer = nil,
    }

    local timerCreated, timerOrError = pcall(
        tracker.api.C_Timer.NewTimer,
        tracker.stabilityDelaySeconds,
        function()
            GGM.ConfirmPendingGearSlot(tracker, slotKey, token)
        end
    )

    if not timerCreated or timerOrError == nil then
        tracker.lastError = "timer-create-failed"
        return nil, "timer-create-failed"
    end

    local handleReadable, cancelMethod = pcall(function()
        return timerOrError.Cancel
    end)
    if not handleReadable or type(cancelMethod) ~= "function" then
        tracker.lastError = "timer-handle-invalid"
        return nil, "timer-handle-invalid"
    end

    pending.timer = timerOrError
    tracker.pendingBySlot[slotKey] = pending
    tracker.lastError = nil
    return "pending", nil
end

function GGM.CreateStableGearTracker(api, db, characterKey, stabilityDelaySeconds, onConfirmed)
    if type(api) ~= "table"
        or type(api.C_Timer) ~= "table"
        or type(api.C_Timer.NewTimer) ~= "function" then
        return nil, "timer-api-unavailable"
    end

    if type(api.GetServerTime) ~= "function" then
        return nil, "server-time-api-unavailable"
    end

    if type(api.GetInventorySlotInfo) ~= "function" then
        return nil, "inventory-slot-api-unavailable"
    end

    if onConfirmed ~= nil and type(onConfirmed) ~= "function" then
        return nil, "confirmation-callback-invalid"
    end

    local delay = stabilityDelaySeconds or GGM.DEFAULT_STABILITY_DELAY_SECONDS
    if type(delay) ~= "number" or delay <= 0 then
        return nil, "stability-delay-invalid"
    end

    local record, recordErr = GGM.GetCompleteCharacterRecord(db, characterKey)
    if not record then
        return nil, recordErr
    end

    local runtimeSlotIDByKey = {}
    local seenRuntimeSlotIDs = {}
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local runtimeSlotID = api.GetInventorySlotInfo(trackedSlot.inventoryName)
        if type(runtimeSlotID) ~= "number" then
            return nil, "inventory-slot-unavailable:" .. trackedSlot.key
        end

        local sharedSlot = record.gear.slots[trackedSlot.key]
        if sharedSlot.inventorySlotID ~= runtimeSlotID then
            return nil, "snapshot-slot-id-mismatch:" .. trackedSlot.key
        end

        if seenRuntimeSlotIDs[runtimeSlotID] then
            return nil, "inventory-slot-id-duplicate:" .. tostring(runtimeSlotID)
        end

        seenRuntimeSlotIDs[runtimeSlotID] = true
        runtimeSlotIDByKey[trackedSlot.key] = runtimeSlotID
    end

    local slotKeyByInventorySlotID = {}
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local runtimeSlotID = runtimeSlotIDByKey[trackedSlot.key]
        slotKeyByInventorySlotID[runtimeSlotID] = trackedSlot.key
    end

    return {
        api = api,
        db = db,
        characterKey = characterKey,
        stabilityDelaySeconds = delay,
        pendingBySlot = {},
        slotKeyByInventorySlotID = slotKeyByInventorySlotID,
        nextPendingToken = 0,
        onConfirmed = onConfirmed,
        lastError = nil,
        lastConfirmationCallbackError = nil,
    }, nil
end

function GGM.ReconcileGearSlot(tracker, slotKey)
    local record, recordErr = GGM.GetCompleteCharacterRecord(tracker.db, tracker.characterKey)
    if not record then
        tracker.lastError = recordErr
        return nil, recordErr
    end

    local currentSlot, currentErr = GGM.CapturePlayerGearSlot(tracker.api, slotKey)
    if not currentSlot then
        tracker.lastError = currentErr
        return nil, currentErr
    end

    local sharedSlot = record.gear.slots[slotKey]
    if GGM.AreGearSlotValuesEqual(currentSlot, sharedSlot) then
        clearPending(tracker, slotKey)
        tracker.lastError = nil
        return "shared", nil
    end

    local pending = tracker.pendingBySlot[slotKey]
    if pending and GGM.AreGearSlotValuesEqual(currentSlot, pending.slot) then
        tracker.lastError = nil
        return "pending", nil
    end

    clearPending(tracker, slotKey)
    tracker.lastError = nil
    return schedulePending(tracker, slotKey, currentSlot)
end

function GGM.ReconcileAllGearSlots(tracker)
    local firstError

    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local _, err = GGM.ReconcileGearSlot(tracker, trackedSlot.key)
        if err and not firstError then
            firstError = err
        end
    end

    if firstError then
        tracker.lastError = firstError
        return false, firstError
    end

    tracker.lastError = nil
    return true, nil
end

function GGM.HandlePlayerEquipmentChanged(tracker, equipmentSlotID)
    local slotKey = tracker.slotKeyByInventorySlotID[equipmentSlotID]
    if not slotKey then
        return "ignored", nil
    end

    return GGM.ReconcileGearSlot(tracker, slotKey)
end

function GGM.ConfirmPendingGearSlot(tracker, slotKey, token)
    local pending = tracker.pendingBySlot[slotKey]
    if not pending or pending.token ~= token then
        return false, nil
    end

    local currentSlot, currentErr = GGM.CapturePlayerGearSlot(tracker.api, slotKey)
    if not currentSlot then
        clearPending(tracker, slotKey)
        tracker.lastError = currentErr
        return false, currentErr
    end

    if not GGM.AreGearSlotValuesEqual(currentSlot, pending.slot) then
        clearPending(tracker, slotKey)
        local _, reconcileErr = GGM.ReconcileGearSlot(tracker, slotKey)
        return false, reconcileErr
    end

    local confirmedAt = tracker.api.GetServerTime()
    local saved, saveErr, confirmedSequence = GGM.UpdateConfirmedCharacterSlot(
        tracker.db,
        tracker.characterKey,
        slotKey,
        currentSlot,
        confirmedAt
    )

    if not saved then
        clearPending(tracker, slotKey)
        tracker.lastError = saveErr
        return false, saveErr
    end

    tracker.pendingBySlot[slotKey] = nil
    tracker.lastError = nil
    tracker.lastConfirmationCallbackError = nil

    if tracker.onConfirmed then
        local callbackOk, callbackErr = pcall(
            tracker.onConfirmed,
            tracker.characterKey,
            slotKey,
            GGM.CopyGearSlotValue(currentSlot),
            confirmedAt,
            confirmedSequence
        )

        if not callbackOk then
            tracker.lastConfirmationCallbackError = tostring(callbackErr)
        end
    end

    return true, nil
end
