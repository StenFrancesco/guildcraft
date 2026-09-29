local _, GGM = ...

function GGM.CaptureAndStoreLocalPlayer(api, db)
    local identity, identityErr = GGM.BuildPlayerIdentity(api)
    if not identity then
        return nil, identityErr
    end

    local snapshot, snapshotErr = GGM.CapturePlayerGearSnapshot(api)
    if not snapshot then
        return nil, snapshotErr
    end

    local saved, saveErr = GGM.SaveCompleteCharacterRecord(db, identity, snapshot)
    if not saved then
        return nil, saveErr
    end

    return GGM.GetCompleteCharacterRecord(db, identity.key)
end

function GGM.GetLocalPlayerRecord(api, db)
    local identity, identityErr = GGM.BuildPlayerIdentity(api)
    if not identity then
        return nil, identityErr
    end

    return GGM.GetCompleteCharacterRecord(db, identity.key)
end

local function makeConfirmedSlotHandler(db, publishConfirmed)
    return function(characterKey, slotKey, slotValue, confirmedAt)
        local saved, saveErr, confirmedSequence = GGM.UpdateConfirmedCharacterSlot(
            db,
            characterKey,
            slotKey,
            slotValue,
            confirmedAt
        )
        if not saved then
            return false, saveErr
        end

        local notificationError
        if publishConfirmed then
            local callbackOk, callbackErr = pcall(
                publishConfirmed,
                characterKey,
                slotKey,
                GGM.CopyGearSlotValue(slotValue),
                confirmedAt,
                confirmedSequence
            )
            if not callbackOk then
                notificationError = tostring(callbackErr)
            end
        end

        return true, nil, notificationError
    end
end

function GGM.StartLocalPlayerGearTracking(api, db, stabilityDelaySeconds, onConfirmed)
    local identity, identityErr = GGM.BuildPlayerIdentity(api)
    if not identity then
        return nil, identityErr
    end

    local record, recordErr = GGM.GetCompleteCharacterRecord(db, identity.key)
    if not record then
        if recordErr ~= "record-missing" then
            return nil, recordErr
        end

        record, recordErr = GGM.CaptureAndStoreLocalPlayer(api, db)
        if not record then
            return nil, recordErr
        end
    else
        local identityUpdated, updateErr = GGM.UpdateLocalCharacterModelIdentity(db, identity)
        if not identityUpdated then
            return nil, updateErr
        end
    end

    local tracker, trackerErr = GGM.CreateStableGearTracker(
        api,
        identity.key,
        record.gear,
        stabilityDelaySeconds,
        makeConfirmedSlotHandler(db, onConfirmed)
    )
    if not tracker then
        return nil, trackerErr
    end

    local marked, markErr = GGM.MarkLocalCharacter(db, identity.key)
    if not marked then
        return nil, markErr
    end

    for slotKey in pairs(tracker.unavailableOptionalSlots) do
        local currentRecord, currentRecordErr = GGM.GetCompleteCharacterRecord(db, identity.key)
        if not currentRecord then
            return nil, currentRecordErr
        end
        currentRecord.gear.slots[slotKey] = { unavailable = true }
        tracker.confirmedSlots[slotKey] = { unavailable = true }
    end

    local _, reconcileErr = GGM.ReconcileAllGearSlots(tracker)
    return tracker, reconcileErr
end
