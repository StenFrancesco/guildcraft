local _, GGM = ...

local function identitiesCompatible(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    if left.name ~= right.name or left.realm:gsub("%s", ""):lower() ~= right.realm:gsub("%s", ""):lower() then return false end
    local leftGuid = type(left.guid) == "string" and left.guid or nil
    local rightGuid = type(right.guid) == "string" and right.guid or nil
    return not (leftGuid and rightGuid and leftGuid ~= rightGuid)
end

-- Blizzard can omit the local realm or remove its spaces in transport names.
-- Canonical saved identities remain unchanged; normalize only at this boundary.
local function senderMatches(sync, sender, identity)
    if type(sender) ~= "string" or sender == "" then return false end
    local name, realm = sender:match("^([^-]+)%-(.+)$")
    if not name then
        if sender:find("-", 1, true) then return false end
        name = sender
        local ok, localRealm = pcall(sync.api.GetRealmName)
        if not ok or type(localRealm) ~= "string" or localRealm == "" then return false end
        realm = localRealm
    end
    local identityName, identityRealm = identity.key:match("^([^-]+)%-(.+)$")
    return name == identityName and identityRealm ~= nil and realm:gsub("%s", "") == identityRealm:gsub("%s", "")
end

local function notifyChanged(sync, dataChanged)
    if type(sync.onChanged) == "function" then pcall(sync.onChanged, dataChanged == true) end
end

local function setRequestResult(sync, targetKey, status, err)
    local results = sync.snapshotRequestResults
    if not results[targetKey] then
        local count, oldestKey, oldest = 0, nil, math.huge
        for key, result in pairs(results) do
            count = count + 1
            if result.at < oldest then oldestKey, oldest = key, result.at end
        end
        if count >= GGM.SYNC_MAX_SNAPSHOT_REQUEST_COOLDOWN_ENTRIES and oldestKey then results[oldestKey] = nil end
    end
    local ok, now = pcall(sync.api.GetTime)
    results[targetKey] = { status = status, error = err, at = ok and type(now) == "number" and now or 0 }
end

local function finishSnapshotRequest(sync, requestID, status, err)
    local pending = sync.pendingSnapshotRequests[requestID]
    if not pending then return end
    sync.pendingSnapshotRequests[requestID] = nil
    if sync.pendingSnapshotRequestTargets[pending.targetKey] == requestID then
        sync.pendingSnapshotRequestTargets[pending.targetKey] = nil
    end
    sync.pendingSnapshotRequestCount = sync.pendingSnapshotRequestCount - 1
    if pending.sendToken then GGM.CancelSyncPayload(sync.transport, pending.sendToken) end
    setRequestResult(sync, pending.targetKey, status, err)
    notifyChanged(sync, status == "synced")
    if type(pending.onFinished) == "function" then pcall(pending.onFinished, status == "synced") end
end

local function getResponseTime(sync)
    local ok, now = pcall(sync.api.GetTime)
    if not ok or type(now) ~= "number" or now < 0 then return nil, "sync-time-unavailable" end
    return now, nil
end

local function clearExpiredSnapshotRequests(sync, now)
    for requestID, pending in pairs(sync.pendingSnapshotRequests) do
        if type(pending.expiresAt) ~= "number" or now >= pending.expiresAt then
            finishSnapshotRequest(sync, requestID, "timeout")
        end
    end
end

local function clearExpiredSnapshotRequestCooldowns(sync, now)
    for targetKey, completedAt in pairs(sync.snapshotRequestCooldowns) do
        if type(completedAt) ~= "number" or (now >= completedAt and now - completedAt >= GGM.SYNC_SNAPSHOT_REQUEST_COOLDOWN_SECONDS) then
            sync.snapshotRequestCooldowns[targetKey] = nil
            sync.snapshotRequestCooldownEntryCount = sync.snapshotRequestCooldownEntryCount - 1
        end
    end
end

local function nextSnapshotRequestID(sync)
    for _ = 1, 999999 do
        sync.nextRequestID = (sync.nextRequestID % 999999) + 1
        local requestID = string.format("%06d", sync.nextRequestID)
        if not sync.pendingSnapshotRequests[requestID] then return requestID end
    end
    return nil
end

local function clearExpiredCooldowns(sync, now)
    for requesterKey, targetTimes in pairs(sync.snapshotResponseCooldowns) do
        for targetKey, response in pairs(targetTimes) do
            local queuedAt = response.at
            if type(queuedAt) ~= "number" or (now >= queuedAt and now - queuedAt >= GGM.SYNC_SNAPSHOT_RESPONSE_COOLDOWN_SECONDS) then
                targetTimes[targetKey] = nil
                sync.snapshotResponseCooldownEntryCount = sync.snapshotResponseCooldownEntryCount - 1
            end
        end
        if next(targetTimes) == nil then sync.snapshotResponseCooldowns[requesterKey] = nil end
    end
end

local function rateLimited(sync, requesterKey, targetKey, sequence, now, observedAt)
    local targetTimes = sync.snapshotResponseCooldowns[requesterKey]
    local previous = targetTimes and targetTimes[targetKey]
    if not previous then return false end
    return (sequence <= previous.sequence and observedAt <= (previous.observedAt or 0))
        or now - previous.at < GGM.SYNC_SNAPSHOT_REPAIR_BACKOFF_SECONDS
end

local function rememberResponse(sync, requesterKey, targetKey, now, sequence, observedAt)
    local targetTimes = sync.snapshotResponseCooldowns[requesterKey]
    if not targetTimes then targetTimes = {}; sync.snapshotResponseCooldowns[requesterKey] = targetTimes end
    if targetTimes[targetKey] == nil then
        sync.snapshotResponseCooldownEntryCount = sync.snapshotResponseCooldownEntryCount + 1
    end
    targetTimes[targetKey] = { at = now, sequence = sequence, observedAt = observedAt }
end

local function responseDelay(requesterKey, targetKey, responderKey)
    local hash = 0
    for textIndex = 1, #requesterKey do hash = (hash + string.byte(requesterKey, textIndex)) % 2147483647 end
    for textIndex = 1, #targetKey do hash = (hash + string.byte(targetKey, textIndex)) % 2147483647 end
    for textIndex = 1, #responderKey do hash = (hash + string.byte(responderKey, textIndex)) % 2147483647 end
    return GGM.SYNC_SNAPSHOT_RESPONSE_DELAY_STEP_SECONDS
        * (1 + (hash % GGM.SYNC_SNAPSHOT_RESPONSE_DELAY_BUCKETS))
end

local function snapshotResponseKey(requesterKey, targetKey, requestID)
    return requesterKey .. "\031" .. targetKey .. "\031" .. requestID
end

local function pendingSnapshotResponseTargetKey(requesterKey, targetKey)
    return requesterKey .. "\031" .. targetKey
end

local function rankIsBetter(observedAt, sequence, responderKey, otherObservedAt, otherSequence, otherResponderKey)
    if observedAt ~= otherObservedAt then return observedAt > otherObservedAt end
    if sequence ~= otherSequence then return sequence > otherSequence end
    return responderKey < otherResponderKey
end

local function meetsRequestFloor(request, observedAt, sequence)
    return sequence >= request.minimumSequence
        or (request.minimumObservedAt > 0 and observedAt >= request.minimumObservedAt)
end

local function removePendingSnapshotResponse(sync, key, pending)
    if sync.pendingSnapshotResponses[key] ~= pending then return false end
    sync.pendingSnapshotResponses[key] = nil
    if sync.pendingSnapshotResponseTargets[pending.responseTargetKey] == pending then
        sync.pendingSnapshotResponseTargets[pending.responseTargetKey] = nil
    end
    sync.pendingSnapshotResponseCount = sync.pendingSnapshotResponseCount - 1
    return true
end

local function cancelPendingSnapshotResponse(sync, requesterKey, targetKey, requestID)
    local key = snapshotResponseKey(requesterKey, targetKey, requestID)
    local pending = sync.pendingSnapshotResponses[key]
    if not pending then return end
    if pending.timer and type(pending.timer.Cancel) == "function" then pending.timer:Cancel() end
    if pending.settleTimer and type(pending.settleTimer.Cancel) == "function" then pending.settleTimer:Cancel() end
    if pending.claimToken then GGM.CancelSyncPayload(sync.transport, pending.claimToken) end
    if pending.sendToken then GGM.CancelSyncPayload(sync.transport, pending.sendToken) end
    removePendingSnapshotResponse(sync, key, pending)
end

local function requestRepair(sync, identity, minimumSequence, minimumObservedAt)
    local now, timeErr = getResponseTime(sync)
    if not now then return nil, timeErr end
    local result = sync.snapshotRequestResults[identity.key]
    if result and (result.status == "failed" or result.status == "timeout")
        and now - result.at < GGM.SYNC_SNAPSHOT_REPAIR_BACKOFF_SECONDS then
        return "snapshot-request-cooldown", nil
    end
    local requestID = sync.pendingSnapshotRequestTargets[identity.key]
    local pending = requestID and sync.pendingSnapshotRequests[requestID]
    if pending then
        pending.minimumSequence = math.max(pending.minimumSequence, minimumSequence)
        pending.minimumObservedAt = math.max(pending.minimumObservedAt, minimumObservedAt or 0)
    end
    local queued, err = GGM.RequestCompleteSnapshot(sync, identity, minimumSequence, minimumObservedAt)
    if queued then return "snapshot-requested", nil end
    if err == "sync-snapshot-request-pending" then return "snapshot-request-pending", nil end
    if err == "sync-snapshot-request-cooldown" then return "snapshot-request-cooldown", nil end
    return nil, err
end

local function requestGearReadyRepair(sync, identity, minimumSequence, minimumObservedAt)
    local now, timeErr = getResponseTime(sync)
    if not now then return nil, timeErr end
    clearExpiredSnapshotRequests(sync, now)
    clearExpiredSnapshotRequestCooldowns(sync, now)

    local requestID = sync.pendingSnapshotRequestTargets[identity.key]
    local pending = requestID and sync.pendingSnapshotRequests[requestID]
    if pending and not pending.gearReadyRefreshUsed then
        pending.minimumSequence = math.max(pending.minimumSequence or 0, minimumSequence or 0)
        pending.minimumObservedAt = math.max(pending.minimumObservedAt or 0, minimumObservedAt or 0)
        pending.gearReadyRefreshUsed = true

        -- A queued request will still reach the now-ready owner. Reissue only
        -- after the original Q was transmitted and may have been ignored while
        -- the owner's initial capture was unavailable.
        if pending.requestSent then
            local requester = pending.requesterIdentity
            if not requester then
                local identityOK, localIdentity, identityErr = pcall(GGM.BuildPlayerIdentity, sync.api)
                if not identityOK then return "snapshot-request-pending", nil end
                if not localIdentity then
                    pending.gearReadyRefreshError = identityErr
                    return "snapshot-request-pending", nil
                end
                requester = localIdentity
                pending.requesterIdentity = requester
            end
            local payload, encodeErr = GGM.EncodeSyncSnapshotRequest(requester, identity, requestID)
            if not payload then
                pending.gearReadyRefreshError = encodeErr
                return "snapshot-request-pending", nil
            end
            local function refreshSent(sent, err)
                if sync.pendingSnapshotRequests[requestID] ~= pending then return end
                pending.requestSent = sent == true
                if not sent then pending.gearReadyRefreshError = err end
            end
            local queued, sendErr, sendToken = GGM.SendSyncPayload(sync.transport, payload, refreshSent)
            if queued then
                pending.sendToken = sendToken
                pending.gearReadyRefreshError = nil
                return "snapshot-request-refreshed", nil
            end
            pending.gearReadyRefreshError = sendErr
        end

        setRequestResult(sync, identity.key, "waiting")
        return "snapshot-request-pending", nil
    end

    local state, err = requestRepair(sync, identity, minimumSequence, minimumObservedAt)
    if state == "snapshot-requested" or state == "snapshot-request-pending" then
        requestID = sync.pendingSnapshotRequestTargets[identity.key]
        pending = requestID and sync.pendingSnapshotRequests[requestID]
        if pending then pending.gearReadyRefreshUsed = true end
    end
    return state, err
end

local function handleSlotUpdate(sync, sender, message)
    if not senderMatches(sync, sender, message.identity) then return nil, "sync-sender-identity-mismatch" end
    local record, recordErr = GGM.GetCharacterRecord(sync.db, message.identity.key)
    if not record then
        if recordErr == "record-missing" then return requestRepair(sync, message.identity, message.confirmedSequence, message.confirmedAt) end
        return nil, recordErr
    end
    if not identitiesCompatible(record.identity, message.identity) then return nil, "identity-mismatch" end
    local wasComplete = record.complete == true
    local applied, applyErr = GGM.ApplyReceivedCharacterSlot(sync.db, message.identity.key, message.slotKey, message.slotValue, message.confirmedAt, message.confirmedSequence)
    if not applied then
        if applyErr == "confirmed-sequence-gap-advanced" then
            requestRepair(sync, message.identity, message.confirmedSequence, message.confirmedAt)
            return "sequence-floor-advanced", nil
        end
        if applyErr == "confirmed-sequence-gap" or applyErr == "record-missing" then
            if wasComplete then notifyChanged(sync, true) end
            return requestRepair(sync, message.identity, message.confirmedSequence, message.confirmedAt)
        end
        return nil, applyErr
    end
    notifyChanged(sync, true)
    return "slot-applied", nil
end

local function sameCharacterNameRealm(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.name == right.name
        and type(left.realm) == "string" and type(right.realm) == "string"
        and left.realm:gsub("%s", ""):lower() == right.realm:gsub("%s", ""):lower()
end

local function handleGearReady(sync, sender, message)
    if not senderMatches(sync, sender, message.identity) then return nil, "sync-sender-identity-mismatch" end
    local identityOk, playerIdentity, identityErr = pcall(GGM.BuildPlayerIdentity, sync.api)
    if not identityOk then return nil, tostring(playerIdentity) end
    if not playerIdentity then return nil, identityErr end
    if sameCharacterNameRealm(playerIdentity, message.identity) then
        if playerIdentity.guid and message.identity.guid and playerIdentity.guid ~= message.identity.guid then
            return nil, "identity-mismatch"
        end
        return "ignored", nil
    end

    local record, recordErr = GGM.GetCharacterRecord(sync.db, message.identity.key)
    if record then
        if not identitiesCompatible(record.identity, message.identity) then return nil, "identity-mismatch" end
        if record.complete == true then
            local sequence, sequenceErr = GGM.GetConfirmedSequence(record)
            if sequence == nil then return nil, sequenceErr end
            local observationFloor = GGM.GetGearObservationFloor(record.gear)
            if record.gear.capturedAt >= message.capturedAt
                and observationFloor >= message.baselineObservedAt
                and (sequence >= message.confirmedSequence or observationFloor > message.capturedAt) then
                return "gear-ready-current", nil
            end
        end
    elseif recordErr ~= "record-missing" then
        return nil, recordErr
    end

    return requestGearReadyRepair(sync, message.identity, message.confirmedSequence, message.baselineObservedAt)
end

local function handleSnapshotRequest(sync, sender, message)
    if not senderMatches(sync, sender, message.requester) then return nil, "sync-sender-identity-mismatch" end
    local record, recordErr = GGM.GetCompleteCharacterRecord(sync.db, message.target.key)
    if not record and recordErr == "record-missing" and type(sync.onLocalSnapshotRequest) == "function" then
        local recovered, recoveryValue, recoveryErr = pcall(sync.onLocalSnapshotRequest, message.target)
        if not recovered then sync.localSnapshotRecoveryError = tostring(recoveryValue)
        else sync.localSnapshotRecoveryError = recoveryErr end
        record, recordErr = GGM.GetCompleteCharacterRecord(sync.db, message.target.key)
    end
    if not record then
        if recordErr == "record-missing" then return "ignored", nil end
        return nil, recordErr
    end
    if not identitiesCompatible(record.identity, message.target) then return "ignored", nil end
    local sequence, sequenceErr = GGM.GetConfirmedSequence(record)
    if sequence == nil then return nil, sequenceErr end
    local now, timeErr = getResponseTime(sync)
    if now == nil then return nil, timeErr end
    clearExpiredCooldowns(sync, now)
    local observedAt = record.gear.capturedAt
    local baselineObservedAt = GGM.GetGearObservationFloor(record.gear)
    if rateLimited(sync, message.requester.key, message.target.key, sequence, now, observedAt) then return "ignored", nil end
    if sync.snapshotResponseCooldownEntryCount >= GGM.SYNC_MAX_SNAPSHOT_RESPONSE_COOLDOWN_ENTRIES then return "ignored", nil end
    local responder, responderErr = GGM.BuildPlayerIdentity(sync.api)
    if not responder then return nil, responderErr end
    local runtimeSnapshot, snapshotErr = GGM.BuildRuntimeGearSnapshot(sync.api, record.gear)
    if not runtimeSnapshot then return nil, snapshotErr end
    -- Reply using the requested key, even if our cache retains another valid
    -- realm spelling. The requester merges into its own canonical saved key.
    local responseIdentity = {
        key = message.target.key, name = message.target.name, realm = message.target.realm,
        guid = record.identity.guid, raceID = record.identity.raceID,
        sex = record.identity.sex, displayID = record.identity.displayID,
    }
    local payload, encodeErr = GGM.EncodeSyncSnapshotResponse(
        responseIdentity,
        message.requester,
        responder,
        runtimeSnapshot,
        sequence,
        message.requestID
    )
    if not payload then return nil, encodeErr end
    local responseKey = snapshotResponseKey(message.requester.key, message.target.key, message.requestID)
    if sync.pendingSnapshotResponses[responseKey] then return "ignored", nil end
    local responseTargetKey = pendingSnapshotResponseTargetKey(message.requester.key, message.target.key)
    if sync.pendingSnapshotResponseTargets[responseTargetKey] then return "ignored", nil end
    if sync.pendingSnapshotResponseCount >= GGM.SYNC_MAX_PENDING_SNAPSHOT_RESPONSES then return "ignored", nil end
    local claimPayload, claimErr = GGM.EncodeSyncSnapshotResponseClaim(responseIdentity, message.requester, responder, sequence, message.requestID, observedAt, baselineObservedAt)
    if not claimPayload then return nil, claimErr end
    local pending = { requesterKey = message.requester.key, targetKey = message.target.key, requestID = message.requestID, responseTargetKey = responseTargetKey, responderKey = responder.key, confirmedSequence = sequence, observedAt = observedAt }
    sync.pendingSnapshotResponses[responseKey] = pending
    sync.pendingSnapshotResponseTargets[responseTargetKey] = pending
    sync.pendingSnapshotResponseCount = sync.pendingSnapshotResponseCount + 1
    local function startClaim()
        if sync.pendingSnapshotResponses[responseKey] ~= pending then return end
        local at = getResponseTime(sync)
        if not at or at >= now + 30 then
            removePendingSnapshotResponse(sync, responseKey, pending)
            return
        end
        if #sync.transport.outboundFrames > 0 then
            pending.startClaim = startClaim
            if not pending.expiryTimer then
                local ok, handle = pcall(sync.api.C_Timer.NewTimer, math.max(0, now + 30 - at), function()
                    if sync.pendingSnapshotResponses[responseKey] == pending and pending.startClaim then
                        removePendingSnapshotResponse(sync, responseKey, pending)
                    end
                end)
                if not ok or not handle then removePendingSnapshotResponse(sync, responseKey, pending)
                else pending.expiryTimer = handle end
            end
            return
        end
        pending.startClaim = nil
        if type(sync.validateAutomaticResponse) == "function" and not sync.validateAutomaticResponse(message) then
            removePendingSnapshotResponse(sync, responseKey, pending)
            return
        end
        local function claimFinished(sent, sendErr)
            if sync.pendingSnapshotResponses[responseKey] ~= pending then return end
            if not sent then
                sync.transport.lastSendError = sendErr
                removePendingSnapshotResponse(sync, responseKey, pending)
                return
            end
            -- Settle from transmission, not queueing: peers must have had a
            -- chance to observe the claim before a complete response is sent.
            local settleOk, settleTimer = pcall(sync.api.C_Timer.NewTimer, GGM.SYNC_SNAPSHOT_RESPONSE_OFFER_SETTLE_SECONDS, function()
                if sync.pendingSnapshotResponses[responseKey] ~= pending then return end
                local function responseFinished(responseSent, responseErr)
                    if not removePendingSnapshotResponse(sync, responseKey, pending) then return end
                    if responseSent then
                        local sentAt = getResponseTime(sync)
                        rememberResponse(sync, message.requester.key, message.target.key, sentAt or now, sequence, observedAt)
                    else
                        sync.transport.lastSendError = responseErr
                    end
                end
                local queued, queueErr, sendToken = GGM.SendSyncPayload(sync.transport, payload, responseFinished)
                if queued then
                    pending.sendToken = sendToken
                else
                    removePendingSnapshotResponse(sync, responseKey, pending)
                    sync.transport.lastSendError = queueErr
                end
            end)
            if not settleOk or settleTimer == nil then
                removePendingSnapshotResponse(sync, responseKey, pending)
                sync.transport.lastSendError = "sync-response-timer-create-failed"
                return
            end
            pending.settleTimer = settleTimer
        end
        local claimQueued, claimQueueErr, claimToken = GGM.SendSyncPayload(sync.transport, claimPayload, claimFinished)
        if not claimQueued then
            sync.transport.lastSendError = claimQueueErr
            removePendingSnapshotResponse(sync, responseKey, pending)
            return
        end
        pending.claimToken = claimToken
    end
    local timerOk, timerOrError = pcall(sync.api.C_Timer.NewTimer, responseDelay(message.requester.key, message.target.key, responder.key), startClaim)
    if not timerOk or timerOrError == nil then
        removePendingSnapshotResponse(sync, responseKey, pending)
        return nil, "sync-response-timer-create-failed"
    end
    pending.timer = timerOrError
    return "snapshot-response-queued", nil
end

local function handleSnapshotResponseClaim(sync, sender, message)
    if not senderMatches(sync, sender, message.responder) then return "ignored", nil end
    local request = sync.pendingSnapshotRequests[message.requestID]
    if request and request.requesterKey == message.requester.key and request.targetKey == message.target.key then
        if not meetsRequestFloor(request, message.baselineObservedAt, message.confirmedSequence) then return "ignored", nil end
        if not request.selectedResponderKey or rankIsBetter(message.observedAt, message.confirmedSequence, message.responder.key, request.selectedObservedAt, request.selectedSequence, request.selectedResponderKey) then
            request.selectedObservedAt = message.observedAt
            request.selectedSequence = message.confirmedSequence
            request.selectedResponderKey = message.responder.key
        end
        return "snapshot-response-claim-recorded", nil
    end
    local responseKey = snapshotResponseKey(message.requester.key, message.target.key, message.requestID)
    local pending = sync.pendingSnapshotResponses[responseKey]
    if not pending then return "ignored", nil end
    if not rankIsBetter(message.observedAt, message.confirmedSequence, message.responder.key, pending.observedAt, pending.confirmedSequence, pending.responderKey) then return "ignored", nil end
    cancelPendingSnapshotResponse(sync, message.requester.key, message.target.key, message.requestID)
    return "snapshot-response-claim-accepted", nil
end

local function handleSnapshotResponse(sync, sender, message)
    if not senderMatches(sync, sender, message.responder) then return "ignored", nil end
    local pendingResponse = sync.pendingSnapshotResponses[snapshotResponseKey(message.requester.key, message.target.key, message.requestID)]
    if pendingResponse then
        local record = GGM.GetCompleteCharacterRecord(sync.db, message.target.key)
        local localSequence = record and GGM.GetConfirmedSequence(record)
        if localSequence and not rankIsBetter(record.gear.capturedAt, localSequence, pendingResponse.responderKey, message.snapshot.capturedAt, message.confirmedSequence, message.responder.key) then
            cancelPendingSnapshotResponse(sync, message.requester.key, message.target.key, message.requestID)
        end
    end
    local now, timeErr = getResponseTime(sync)
    if now == nil then return nil, timeErr end
    clearExpiredSnapshotRequests(sync, now)
    local pending = sync.pendingSnapshotRequests[message.requestID]
    if not pending or pending.targetKey ~= message.target.key or pending.requesterKey ~= message.requester.key then return "ignored", nil end
    if pending.onFinished and type(sync.validateAutomaticIncoming) == "function"
        and not sync.validateAutomaticIncoming(sender, message) then return "ignored", nil end
    if not pending.selectedResponderKey or pending.selectedResponderKey ~= message.responder.key then return "ignored", nil end
    local observedAt = message.snapshot.capturedAt
    if not meetsRequestFloor(pending, GGM.GetGearObservationFloor(message.snapshot), message.confirmedSequence)
        or observedAt < pending.selectedObservedAt
        or (observedAt == pending.selectedObservedAt and message.confirmedSequence < pending.selectedSequence) then
        return "ignored", nil
    end
    local saved, saveErr = GGM.SaveReceivedCompleteCharacterRecord(sync.db, message.target, message.snapshot, message.confirmedSequence)
    if not saved then
        if saveErr == "confirmed-sequence-regression" then return "ignored", nil end
        finishSnapshotRequest(sync, message.requestID, "failed", saveErr)
        return nil, saveErr
    end
    local tracker = sync.localGearTracker
    local savedRecord = GGM.GetCompleteCharacterRecord(sync.db, message.target.key)
    if tracker and savedRecord and tracker.characterKey == savedRecord.identity.key then
        local baseline = savedRecord and GGM.BuildRuntimeGearSnapshot(sync.api, savedRecord.gear)
        if baseline then GGM.RefreshStableGearTrackerBaseline(tracker, message.target.key, baseline) end
    end
    if not sync.snapshotRequestCooldowns[message.target.key] then
        if sync.snapshotRequestCooldownEntryCount < GGM.SYNC_MAX_SNAPSHOT_REQUEST_COOLDOWN_ENTRIES then
            sync.snapshotRequestCooldowns[message.target.key] = now
            sync.snapshotRequestCooldownEntryCount = sync.snapshotRequestCooldownEntryCount + 1
        end
    end
    finishSnapshotRequest(sync, message.requestID, "synced")
    return "snapshot-saved", nil
end

function GGM.AnnounceLocalGearReady(sync, onFinished)
    if type(sync) ~= "table" or type(sync.localGearTracker) ~= "table" then
        return false, "local-gear-tracker-unavailable"
    end
    local trackerKey = sync.localGearTracker.characterKey
    if type(trackerKey) ~= "string" or trackerKey == "" then return false, "local-gear-tracker-invalid" end
    local record, recordErr = GGM.GetCompleteCharacterRecord(sync.db, trackerKey)
    if not record then return false, recordErr end
    local identity, identityErr = GGM.BuildPlayerIdentity(sync.api)
    if not identity then return false, identityErr end
    if not identitiesCompatible(record.identity, identity)
        or (record.identity.guid and identity.guid and record.identity.guid ~= identity.guid) then
        return false, "identity-mismatch"
    end
    local sequence, sequenceErr = GGM.GetConfirmedSequence(record)
    if sequence == nil then return false, sequenceErr end
    local baselineObservedAt = GGM.GetGearObservationFloor(record.gear)
    local payload, encodeErr = GGM.EncodeSyncGearReady(
        record.identity,
        sequence,
        record.gear.capturedAt,
        baselineObservedAt
    )
    if not payload then return false, encodeErr end
    return GGM.SendSyncPayload(sync.transport, payload, onFinished)
end

function GGM.CreateGuildSync(api, db)
    if type(db) ~= "table" or type(db.characters) ~= "table" then return nil, "database-invalid" end
    local sync = { api = api, db = db, transport = nil, snapshotResponseCooldowns = {}, snapshotResponseCooldownEntryCount = 0, pendingSnapshotResponses = {}, pendingSnapshotResponseTargets = {}, pendingSnapshotResponseCount = 0, pendingSnapshotRequests = {}, pendingSnapshotRequestTargets = {}, pendingSnapshotRequestCount = 0, snapshotRequestResults = {}, snapshotRequestCooldowns = {}, snapshotRequestCooldownEntryCount = 0, nextRequestID = 0 }
    local transport, transportErr = GGM.CreateSyncTransport(api, function(sender, payload)
        return GGM.HandleGuildSyncPayload(sync, sender, payload)
    end)
    if not transport then return nil, transportErr end
    sync.transport = transport
    transport.onIdle = function()
        for _, pending in pairs(sync.pendingSnapshotResponses) do
            if #transport.outboundFrames > 0 then break end
            if pending.startClaim then pending.startClaim() end
        end
    end
    return sync, nil
end

function GGM.RegisterGuildSync(sync)
    return GGM.RegisterSyncPrefix(sync.transport)
end

function GGM.PublishConfirmedSlot(sync, characterKey, slotKey, slotValue, confirmedAt, confirmedSequence)
    local record, recordErr = GGM.GetCompleteCharacterRecord(sync.db, characterKey)
    if not record then return false, recordErr end
    local persistedSequence, sequenceErr = GGM.GetConfirmedSequence(record)
    if persistedSequence == nil then return false, sequenceErr end
    if persistedSequence ~= confirmedSequence then return false, "confirmed-sequence-mismatch" end
    local persistedSlot, persistedSlotErr = GGM.BuildRuntimeGearSlot(sync.api, record.gear, slotKey)
    if not persistedSlot then return false, persistedSlotErr end
    if not GGM.AreGearSlotValuesEqual(persistedSlot, slotValue) then return false, "confirmed-slot-mismatch" end
    local payload, encodeErr = GGM.EncodeSyncSlotUpdate(record.identity, confirmedSequence, slotKey, persistedSlot, confirmedAt)
    if not payload then return false, encodeErr end
    return GGM.SendSyncPayload(sync.transport, payload)
end

function GGM.RequestCompleteSnapshot(sync, targetIdentity, minimumSequence, minimumObservedAt, onFinished)
    local requester, requesterErr = GGM.BuildPlayerIdentity(sync.api)
    if not requester then return false, requesterErr end
    local targetValid, targetErr = GGM.ValidateSyncIdentity(targetIdentity)
    if not targetValid then return false, targetErr end
    local now, timeErr = getResponseTime(sync)
    if now == nil then return false, timeErr end
    clearExpiredSnapshotRequests(sync, now)
    clearExpiredSnapshotRequestCooldowns(sync, now)
    local completedAt = sync.snapshotRequestCooldowns[targetIdentity.key]
    if completedAt and (minimumSequence == nil or now - completedAt < GGM.SYNC_SNAPSHOT_REPAIR_BACKOFF_SECONDS) then
        return false, "sync-snapshot-request-cooldown"
    end
    if sync.pendingSnapshotRequestTargets[targetIdentity.key] then return false, "sync-snapshot-request-pending" end
    if sync.snapshotRequestCooldownEntryCount >= GGM.SYNC_MAX_SNAPSHOT_REQUEST_COOLDOWN_ENTRIES then return false, "sync-snapshot-request-cooldown-limit" end
    if sync.pendingSnapshotRequestCount >= GGM.SYNC_MAX_PENDING_SNAPSHOT_REQUESTS then return false, "sync-pending-request-limit" end
    local requestID = nextSnapshotRequestID(sync)
    if not requestID then return false, "sync-request-id-exhausted" end
    local payload, encodeErr = GGM.EncodeSyncSnapshotRequest(requester, targetIdentity, requestID)
    if not payload then return false, encodeErr end
    local record = GGM.GetCharacterRecord(sync.db, targetIdentity.key)
    local knownSequence = record and (record.requiredBaselineSequence or record.confirmedSequence) or 0
    local knownObservation = record and (record.requiredBaselineObservedAt or GGM.GetGearObservationFloor(record.gear)) or 0
    local pending = { onFinished = onFinished, minimumObservedAt = math.max(minimumObservedAt or 0, knownObservation), minimumSequence = math.max(minimumSequence or 0, knownSequence), requesterIdentity = requester, requesterKey = requester.key, targetKey = targetIdentity.key, expiresAt = now + GGM.SYNC_SNAPSHOT_REQUEST_TTL_SECONDS, selectedResponderKey = nil, selectedSequence = -1, selectedObservedAt = -1, requestSent = false }
    sync.pendingSnapshotRequests[requestID] = pending
    sync.pendingSnapshotRequestTargets[targetIdentity.key] = requestID
    sync.pendingSnapshotRequestCount = sync.pendingSnapshotRequestCount + 1
    setRequestResult(sync, targetIdentity.key, "waiting")
    local function requestSent(sent, err)
        if sync.pendingSnapshotRequests[requestID] ~= pending then return end
        if not sent then finishSnapshotRequest(sync, requestID, "failed", err)
        else pending.requestSent = true end
    end
    local sent, sendErr, sendToken = GGM.SendSyncPayload(sync.transport, payload, requestSent)
    if not sent then
        finishSnapshotRequest(sync, requestID, "failed", sendErr)
        return false, sendErr
    end
    pending.sendToken = sendToken
    notifyChanged(sync, false)
    return true, nil, requestID
end

function GGM.ExpireGuildSnapshotRequests(sync)
    local at = getResponseTime(sync)
    if at then clearExpiredSnapshotRequests(sync, at) end
end

-- Expiry is checked by the visible status control and at request/receive boundaries.
-- This avoids periodic network work and keeps hidden clients idle.
function GGM.GetGearSyncStatus(sync, targetKey)
    if type(sync) ~= "table" then return "Gear sync is unavailable.", false, "sync-unavailable" end
    local now, err = getResponseTime(sync)
    if not now then return "Gear sync is unavailable.", false, err end
    clearExpiredSnapshotRequests(sync, now)
    local result = sync.snapshotRequestResults[targetKey]
    if not result then return "", false end
    if result.status == "waiting" then return "Waiting for a gear snapshot...", true end
    if result.status == "synced" then return "Gear snapshot synchronized.", false end
    if result.status == "timeout" then return "No gear snapshot received. Try again.", false end
    return "Gear sync failed. Try again.", false, result.error
end

function GGM.HandleGuildSyncPayload(sync, sender, payload)
    local message, decodeErr = GGM.DecodeSyncMessage(payload)
    if not message then return nil, decodeErr end
    if message.type == "SLOT_UPDATE" then return handleSlotUpdate(sync, sender, message) end
    if message.type == "SNAPSHOT_REQUEST" then return handleSnapshotRequest(sync, sender, message) end
    if message.type == "GEAR_READY" then return handleGearReady(sync, sender, message) end
    if message.type == "SNAPSHOT_RESPONSE_CLAIM" then return handleSnapshotResponseClaim(sync, sender, message) end
    if message.type == "SNAPSHOT_RESPONSE" then return handleSnapshotResponse(sync, sender, message) end
    return nil, "sync-message-type-unknown"
end

function GGM.HandleGuildSyncAddonMessage(sync, prefix, text, channel, sender)
    return GGM.HandleSyncTransportMessage(sync.transport, prefix, text, channel, sender)
end
