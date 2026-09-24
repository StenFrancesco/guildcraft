local _, GGM = ...

local function identitiesCompatible(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    if left.key ~= right.key or left.name ~= right.name or left.realm ~= right.realm then return false end
    local leftGuid = type(left.guid) == "string" and left.guid or nil
    local rightGuid = type(right.guid) == "string" and right.guid or nil
    return not (leftGuid and rightGuid and leftGuid ~= rightGuid)
end

local function getResponseTime(sync)
    local ok, now = pcall(sync.api.GetTime)
    if not ok or type(now) ~= "number" or now < 0 then return nil, "sync-time-unavailable" end
    return now, nil
end

local function clearExpiredSnapshotRequests(sync, now)
    for requestID, pending in pairs(sync.pendingSnapshotRequests) do
        if type(pending.expiresAt) ~= "number" or now >= pending.expiresAt then
            sync.pendingSnapshotRequests[requestID] = nil
            if sync.pendingSnapshotRequestTargets[pending.targetKey] == requestID then
                sync.pendingSnapshotRequestTargets[pending.targetKey] = nil
            end
            sync.pendingSnapshotRequestCount = sync.pendingSnapshotRequestCount - 1
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
        for targetKey, queuedAt in pairs(targetTimes) do
            if type(queuedAt) ~= "number" or (now >= queuedAt and now - queuedAt >= GGM.SYNC_SNAPSHOT_RESPONSE_COOLDOWN_SECONDS) then
                targetTimes[targetKey] = nil
                sync.snapshotResponseCooldownEntryCount = sync.snapshotResponseCooldownEntryCount - 1
            end
        end
        if next(targetTimes) == nil then sync.snapshotResponseCooldowns[requesterKey] = nil end
    end
end

local function rateLimited(sync, requesterKey, targetKey)
    local targetTimes = sync.snapshotResponseCooldowns[requesterKey]
    return targetTimes and targetTimes[targetKey] ~= nil
end

local function rememberResponse(sync, requesterKey, targetKey, now)
    local targetTimes = sync.snapshotResponseCooldowns[requesterKey]
    if not targetTimes then targetTimes = {}; sync.snapshotResponseCooldowns[requesterKey] = targetTimes end
    if targetTimes[targetKey] ~= nil then return end
    targetTimes[targetKey] = now
    sync.snapshotResponseCooldownEntryCount = sync.snapshotResponseCooldownEntryCount + 1
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

local function rankIsBetter(sequence, responderKey, otherSequence, otherResponderKey)
    if sequence ~= otherSequence then return sequence > otherSequence end
    return responderKey < otherResponderKey
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
    removePendingSnapshotResponse(sync, key, pending)
end

local function handleSlotUpdate(sync, sender, message)
    if sender ~= message.identity.key then return nil, "sync-sender-identity-mismatch" end
    local record, recordErr = GGM.GetCompleteCharacterRecord(sync.db, message.identity.key)
    if not record then return nil, recordErr end
    if not identitiesCompatible(record.identity, message.identity) then return nil, "identity-mismatch" end
    local applied, applyErr = GGM.ApplyReceivedCharacterSlot(sync.db, message.identity.key, message.slotKey, message.slotValue, message.confirmedAt, message.confirmedSequence)
    if not applied then return nil, applyErr end
    return "slot-applied", nil
end

local function handleSnapshotRequest(sync, sender, message)
    if sender ~= message.requester.key then return nil, "sync-sender-identity-mismatch" end
    local record, recordErr = GGM.GetCompleteCharacterRecord(sync.db, message.target.key)
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
    if rateLimited(sync, message.requester.key, message.target.key) then return "ignored", nil end
    if sync.snapshotResponseCooldownEntryCount >= GGM.SYNC_MAX_SNAPSHOT_RESPONSE_COOLDOWN_ENTRIES then return "ignored", nil end
    local responder, responderErr = GGM.BuildPlayerIdentity(sync.api)
    if not responder then return nil, responderErr end
    local payload, encodeErr = GGM.EncodeSyncSnapshotResponse(record.identity, message.requester, responder, record.gear, sequence, message.requestID)
    if not payload then return nil, encodeErr end
    local responseKey = snapshotResponseKey(message.requester.key, message.target.key, message.requestID)
    if sync.pendingSnapshotResponses[responseKey] then return "ignored", nil end
    local responseTargetKey = pendingSnapshotResponseTargetKey(message.requester.key, message.target.key)
    if sync.pendingSnapshotResponseTargets[responseTargetKey] then return "ignored", nil end
    if sync.pendingSnapshotResponseCount >= GGM.SYNC_MAX_PENDING_SNAPSHOT_RESPONSES then return "ignored", nil end
    local claimPayload, claimErr = GGM.EncodeSyncSnapshotResponseClaim(record.identity, message.requester, responder, sequence, message.requestID)
    if not claimPayload then return nil, claimErr end
    local pending = { requesterKey = message.requester.key, targetKey = message.target.key, requestID = message.requestID, responseTargetKey = responseTargetKey, responderKey = responder.key, confirmedSequence = sequence }
    sync.pendingSnapshotResponses[responseKey] = pending
    sync.pendingSnapshotResponseTargets[responseTargetKey] = pending
    sync.pendingSnapshotResponseCount = sync.pendingSnapshotResponseCount + 1
    local timerOk, timerOrError = pcall(sync.api.C_Timer.NewTimer, responseDelay(message.requester.key, message.target.key, responder.key), function()
        if sync.pendingSnapshotResponses[responseKey] ~= pending then return end
        local claimQueued, claimQueueErr = GGM.SendSyncPayload(sync.transport, claimPayload)
        if not claimQueued then
            sync.transport.lastSendError = claimQueueErr
            removePendingSnapshotResponse(sync, responseKey, pending)
            return
        end
        local settleOk, settleTimer = pcall(sync.api.C_Timer.NewTimer, GGM.SYNC_SNAPSHOT_RESPONSE_OFFER_SETTLE_SECONDS, function()
            if not removePendingSnapshotResponse(sync, responseKey, pending) then return end
            local queued, queueErr = GGM.SendSyncPayload(sync.transport, payload)
            if queued then
                local sentAt = getResponseTime(sync)
                rememberResponse(sync, message.requester.key, message.target.key, sentAt or now)
            else
                sync.transport.lastSendError = queueErr
            end
        end)
        if not settleOk or settleTimer == nil then
            removePendingSnapshotResponse(sync, responseKey, pending)
            sync.transport.lastSendError = "sync-response-timer-create-failed"
            return
        end
        pending.settleTimer = settleTimer
    end)
    if not timerOk or timerOrError == nil then
        removePendingSnapshotResponse(sync, responseKey, pending)
        return nil, "sync-response-timer-create-failed"
    end
    pending.timer = timerOrError
    return "snapshot-response-queued", nil
end

local function handleSnapshotResponseClaim(sync, sender, message)
    if sender ~= message.responder.key then return "ignored", nil end
    local request = sync.pendingSnapshotRequests[message.requestID]
    if request and request.requesterKey == message.requester.key and request.targetKey == message.target.key then
        if not request.selectedResponderKey or rankIsBetter(message.confirmedSequence, message.responder.key, request.selectedSequence, request.selectedResponderKey) then
            request.selectedSequence = message.confirmedSequence
            request.selectedResponderKey = message.responder.key
        end
        return "snapshot-response-claim-recorded", nil
    end
    local responseKey = snapshotResponseKey(message.requester.key, message.target.key, message.requestID)
    local pending = sync.pendingSnapshotResponses[responseKey]
    if not pending then return "ignored", nil end
    if not rankIsBetter(message.confirmedSequence, message.responder.key, pending.confirmedSequence, pending.responderKey) then return "ignored", nil end
    cancelPendingSnapshotResponse(sync, message.requester.key, message.target.key, message.requestID)
    return "snapshot-response-claim-accepted", nil
end

local function handleSnapshotResponse(sync, sender, message)
    if sender ~= message.responder.key then return "ignored", nil end
    local pendingResponse = sync.pendingSnapshotResponses[snapshotResponseKey(message.requester.key, message.target.key, message.requestID)]
    if pendingResponse then
        local record = GGM.GetCompleteCharacterRecord(sync.db, message.target.key)
        local localSequence = record and GGM.GetConfirmedSequence(record)
        if localSequence and message.confirmedSequence >= localSequence then
            cancelPendingSnapshotResponse(sync, message.requester.key, message.target.key, message.requestID)
        end
    end
    local now, timeErr = getResponseTime(sync)
    if now == nil then return nil, timeErr end
    clearExpiredSnapshotRequests(sync, now)
    local pending = sync.pendingSnapshotRequests[message.requestID]
    if not pending or pending.targetKey ~= message.target.key or pending.requesterKey ~= message.requester.key then return "ignored", nil end
    if not pending.selectedResponderKey or pending.selectedResponderKey ~= message.responder.key then return "ignored", nil end
    local saved, saveErr = GGM.SaveReceivedCompleteCharacterRecord(sync.db, message.target, message.snapshot, message.confirmedSequence)
    if not saved then
        if saveErr == "confirmed-sequence-regression" then return "ignored", nil end
        sync.pendingSnapshotRequests[message.requestID] = nil
        if sync.pendingSnapshotRequestTargets[message.target.key] == message.requestID then
            sync.pendingSnapshotRequestTargets[message.target.key] = nil
        end
        sync.pendingSnapshotRequestCount = sync.pendingSnapshotRequestCount - 1
        return nil, saveErr
    end
    sync.pendingSnapshotRequests[message.requestID] = nil
    if sync.pendingSnapshotRequestTargets[message.target.key] == message.requestID then
        sync.pendingSnapshotRequestTargets[message.target.key] = nil
    end
    sync.pendingSnapshotRequestCount = sync.pendingSnapshotRequestCount - 1
    if not sync.snapshotRequestCooldowns[message.target.key] then
        if sync.snapshotRequestCooldownEntryCount < GGM.SYNC_MAX_SNAPSHOT_REQUEST_COOLDOWN_ENTRIES then
            sync.snapshotRequestCooldowns[message.target.key] = now
            sync.snapshotRequestCooldownEntryCount = sync.snapshotRequestCooldownEntryCount + 1
        end
    end
    return "snapshot-saved", nil
end

function GGM.CreateGuildSync(api, db)
    if type(db) ~= "table" or type(db.characters) ~= "table" then return nil, "database-invalid" end
    local sync = { api = api, db = db, transport = nil, snapshotResponseCooldowns = {}, snapshotResponseCooldownEntryCount = 0, pendingSnapshotResponses = {}, pendingSnapshotResponseTargets = {}, pendingSnapshotResponseCount = 0, pendingSnapshotRequests = {}, pendingSnapshotRequestTargets = {}, pendingSnapshotRequestCount = 0, snapshotRequestCooldowns = {}, snapshotRequestCooldownEntryCount = 0, nextRequestID = 0 }
    local transport, transportErr = GGM.CreateSyncTransport(api, function(sender, payload)
        return GGM.HandleGuildSyncPayload(sync, sender, payload)
    end)
    if not transport then return nil, transportErr end
    sync.transport = transport
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
    local persistedSlot = record.gear.slots[slotKey]
    if not persistedSlot or not GGM.AreGearSlotValuesEqual(persistedSlot, slotValue) then return false, "confirmed-slot-mismatch" end
    local payload, encodeErr = GGM.EncodeSyncSlotUpdate(record.identity, confirmedSequence, slotKey, slotValue, confirmedAt)
    if not payload then return false, encodeErr end
    return GGM.SendSyncPayload(sync.transport, payload)
end

function GGM.RequestCompleteSnapshot(sync, targetIdentity)
    local requester, requesterErr = GGM.BuildPlayerIdentity(sync.api)
    if not requester then return false, requesterErr end
    local targetValid, targetErr = GGM.ValidateSyncIdentity(targetIdentity)
    if not targetValid then return false, targetErr end
    local now, timeErr = getResponseTime(sync)
    if now == nil then return false, timeErr end
    clearExpiredSnapshotRequests(sync, now)
    clearExpiredSnapshotRequestCooldowns(sync, now)
    if sync.snapshotRequestCooldowns[targetIdentity.key] then return false, "sync-snapshot-request-cooldown" end
    if sync.pendingSnapshotRequestTargets[targetIdentity.key] then return false, "sync-snapshot-request-pending" end
    if sync.snapshotRequestCooldownEntryCount >= GGM.SYNC_MAX_SNAPSHOT_REQUEST_COOLDOWN_ENTRIES then return false, "sync-snapshot-request-cooldown-limit" end
    if sync.pendingSnapshotRequestCount >= GGM.SYNC_MAX_PENDING_SNAPSHOT_REQUESTS then return false, "sync-pending-request-limit" end
    local requestID = nextSnapshotRequestID(sync)
    if not requestID then return false, "sync-request-id-exhausted" end
    local payload, encodeErr = GGM.EncodeSyncSnapshotRequest(requester, targetIdentity, requestID)
    if not payload then return false, encodeErr end
    sync.pendingSnapshotRequests[requestID] = { requesterKey = requester.key, targetKey = targetIdentity.key, expiresAt = now + GGM.SYNC_SNAPSHOT_REQUEST_TTL_SECONDS, selectedResponderKey = nil, selectedSequence = -1 }
    sync.pendingSnapshotRequestTargets[targetIdentity.key] = requestID
    sync.pendingSnapshotRequestCount = sync.pendingSnapshotRequestCount + 1
    local sent, sendErr = GGM.SendSyncPayload(sync.transport, payload)
    if not sent then
        sync.pendingSnapshotRequests[requestID] = nil
        sync.pendingSnapshotRequestTargets[targetIdentity.key] = nil
        sync.pendingSnapshotRequestCount = sync.pendingSnapshotRequestCount - 1
        return false, sendErr
    end
    return true, nil
end

function GGM.HandleGuildSyncPayload(sync, sender, payload)
    local message, decodeErr = GGM.DecodeSyncMessage(payload)
    if not message then return nil, decodeErr end
    if message.type == "SLOT_UPDATE" then return handleSlotUpdate(sync, sender, message) end
    if message.type == "SNAPSHOT_REQUEST" then return handleSnapshotRequest(sync, sender, message) end
    if message.type == "SNAPSHOT_RESPONSE_CLAIM" then return handleSnapshotResponseClaim(sync, sender, message) end
    if message.type == "SNAPSHOT_RESPONSE" then return handleSnapshotResponse(sync, sender, message) end
    return nil, "sync-message-type-unknown"
end

function GGM.HandleGuildSyncAddonMessage(sync, prefix, text, channel, sender)
    return GGM.HandleSyncTransportMessage(sync.transport, prefix, text, channel, sender)
end
