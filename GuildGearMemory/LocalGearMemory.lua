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

        local capturedRecord, captureErr = GGM.CaptureAndStoreLocalPlayer(api, db)
        if not capturedRecord then
            return nil, captureErr
        end
    end

    local tracker, trackerErr = GGM.CreateStableGearTracker(
        api,
        db,
        identity.key,
        stabilityDelaySeconds,
        onConfirmed
    )
    if not tracker then
        return nil, trackerErr
    end

    local _, reconcileErr = GGM.ReconcileAllGearSlots(tracker)
    return tracker, reconcileErr
end
