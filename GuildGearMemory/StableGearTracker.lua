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

function GGM.CreateStableGearTracker(api, characterKey, savedSnapshot, stabilityDelaySeconds, onConfirmed)
    if type(api) ~= "table"
        or type(api.C_Timer) ~= "table"
        or type(api.C_Timer.NewTimer) ~= "function" then
        return nil, "timer-api-unavailable"
    end

    if type(api.GetServerTime) ~= "function" then
        return nil, "server-time-api-unavailable"
    end

    if onConfirmed ~= nil and type(onConfirmed) ~= "function" then
        return nil, "confirmation-callback-invalid"
    end

    local delay = stabilityDelaySeconds or GGM.DEFAULT_STABILITY_DELAY_SECONDS
    if type(delay) ~= "number" or delay <= 0 then
        return nil, "stability-delay-invalid"
    end

    local snapshotValid, snapshotErr = GGM.ValidateCompleteSnapshot(savedSnapshot)
    if not snapshotValid then
        return nil, snapshotErr
    end

    local resolvedSlots, resolveErr = GGM.ResolvePlayerGearSlots(api, savedSnapshot.slots)
    if not resolvedSlots then
        return nil, resolveErr
    end

    local confirmedSlots = {}
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local slotValue = savedSnapshot.slots[trackedSlot.key]
        if slotValue ~= nil then
            confirmedSlots[trackedSlot.key] = GGM.CopyGearSlotValue(slotValue)
        end
    end

    return {
        api = api,
        characterKey = characterKey,
        stabilityDelaySeconds = delay,
        confirmedSlots = confirmedSlots,
        pendingBySlot = {},
        slotKeyByInventorySlotID = resolvedSlots.slotKeyByInventorySlotID,
        unavailableOptionalSlots = resolvedSlots.unavailableOptionalSlots,
        nextPendingToken = 0,
        onConfirmed = onConfirmed,
        lastError = nil,
        lastConfirmationCallbackError = nil,
    }, nil
end

local function reconcileGearSlotValue(tracker, slotKey, currentSlot)
    if tracker.unavailableOptionalSlots[slotKey] then
        return "unavailable", nil
    end

    if currentSlot.unavailable == true then
        tracker.unavailableOptionalSlots[slotKey] = true
        clearPending(tracker, slotKey)
        tracker.lastError = nil
        return "unavailable", nil
    end

    local confirmedSlot = tracker.confirmedSlots[slotKey]
    if GGM.AreGearSlotValuesEqual(currentSlot, confirmedSlot) then
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

function GGM.ReconcileGearSlot(tracker, slotKey)
    if tracker.unavailableOptionalSlots[slotKey] then
        return "unavailable", nil
    end

    local currentSlot, currentErr = GGM.CapturePlayerGearSlot(tracker.api, slotKey)
    if not currentSlot then
        tracker.lastError = currentErr
        return nil, currentErr
    end

    return reconcileGearSlotValue(tracker, slotKey, currentSlot)
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
        local _, reconcileErr = reconcileGearSlotValue(tracker, slotKey, currentSlot)
        return false, reconcileErr
    end

    local confirmedAt = tracker.api.GetServerTime()
    local callbackError
    if tracker.onConfirmed then
        local callbackOk, confirmed, confirmErr, notificationError = pcall(
            tracker.onConfirmed,
            tracker.characterKey,
            slotKey,
            GGM.CopyGearSlotValue(currentSlot),
            confirmedAt
        )

        if not callbackOk then
            callbackError = tostring(confirmed)
            clearPending(tracker, slotKey)
            tracker.lastError = callbackError
            tracker.lastConfirmationCallbackError = callbackError
            return false, callbackError
        elseif confirmed == false then
            clearPending(tracker, slotKey)
            tracker.lastError = confirmErr or "confirmation-rejected"
            return false, tracker.lastError
        else
            callbackError = notificationError
        end
    end

    tracker.confirmedSlots[slotKey] = GGM.CopyGearSlotValue(currentSlot)
    tracker.pendingBySlot[slotKey] = nil
    tracker.lastError = nil
    tracker.lastConfirmationCallbackError = callbackError
    return true, nil
end
