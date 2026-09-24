local _, GGM = ...

local function isIntegerInRange(value, minimum, maximum)
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function validateBoundedString(value, maximum, errorPrefix, allowEmpty)
    if type(value) ~= "string" then return false, errorPrefix .. "-invalid" end
    if not allowEmpty and value == "" then return false, errorPrefix .. "-invalid" end
    if #value > maximum then return false, errorPrefix .. "-too-long" end
    return true, nil
end

local function isTrackedSlotKey(slotKey)
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        if trackedSlot.key == slotKey then return true end
    end
    return false
end

function GGM.ValidateSyncIdentity(identity)
    if type(identity) ~= "table" then return false, "sync-identity-invalid" end
    local keyValid, keyErr = validateBoundedString(identity.key, GGM.SYNC_MAX_IDENTITY_KEY_BYTES, "sync-identity-key", false)
    if not keyValid then return false, keyErr end
    local nameValid, nameErr = validateBoundedString(identity.name, GGM.SYNC_MAX_NAME_BYTES, "sync-identity-name", false)
    if not nameValid then return false, nameErr end
    local realmValid, realmErr = validateBoundedString(identity.realm, GGM.SYNC_MAX_REALM_BYTES, "sync-identity-realm", false)
    if not realmValid then return false, realmErr end
    if identity.key ~= identity.name .. "-" .. identity.realm then return false, "sync-identity-key-mismatch" end
    if identity.guid ~= nil and identity.guid ~= false then
        local guidValid, guidErr = validateBoundedString(identity.guid, GGM.SYNC_MAX_GUID_BYTES, "sync-identity-guid", false)
        if not guidValid then return false, guidErr end
    end
    return true, nil
end

local function validateSequence(sequence)
    if not isIntegerInRange(sequence, 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE) then return false, "sync-sequence-invalid" end
    return true, nil
end

local function validateTimestamp(timestamp, errorName)
    if not isIntegerInRange(timestamp, 0, GGM.SYNC_MAX_TIMESTAMP) then return false, errorName end
    return true, nil
end

local function validateRequestID(requestID)
    if type(requestID) ~= "string" or not requestID:match("^%d%d%d%d%d%d$") then return false, "sync-request-id-invalid" end
    return true, nil
end

local function validateSyncSlotValue(slotKey, slotValue)
    if not isTrackedSlotKey(slotKey) then return false, "tracked-slot-unknown:" .. tostring(slotKey) end
    local keyValid, keyErr = validateBoundedString(slotKey, GGM.SYNC_MAX_SLOT_KEY_BYTES, "sync-slot-key", false)
    if not keyValid then return false, keyErr end
    local baseValid, baseErr = GGM.ValidateGearSlotValue(slotKey, slotValue)
    if not baseValid then return false, baseErr end
    if not isIntegerInRange(slotValue.inventorySlotID, 1, 255) then return false, "sync-inventory-slot-id-invalid" end
    if slotValue.itemID == false and slotValue.itemLink == false then return true, nil end
    if not isIntegerInRange(slotValue.itemID, 1, 2147483647) then return false, "sync-item-id-invalid" end
    local linkValid, linkErr = validateBoundedString(slotValue.itemLink, GGM.SYNC_MAX_ITEM_LINK_BYTES, "sync-item-link", false)
    if not linkValid then return false, linkErr end
    return true, nil
end

local function packField(value)
    local text = tostring(value)
    return tostring(#text) .. ":" .. text
end

local function encodePayload(typeCode, fields)
    local parts = { tostring(GGM.SYNC_PROTOCOL_VERSION), typeCode }
    for _, field in ipairs(fields) do table.insert(parts, packField(field)) end
    local payload = table.concat(parts)
    if #payload > GGM.SYNC_MAX_LOGICAL_BYTES then return nil, "sync-payload-too-large" end
    return payload, nil
end

local function appendIdentity(fields, identity)
    table.insert(fields, identity.key)
    table.insert(fields, identity.name)
    table.insert(fields, identity.realm)
    table.insert(fields, type(identity.guid) == "string" and identity.guid or "")
end

local function encodeSlotFields(fields, slotKey, slotValue)
    table.insert(fields, slotKey)
    table.insert(fields, tostring(slotValue.inventorySlotID))
    if slotValue.itemID == false then
        table.insert(fields, "0")
        table.insert(fields, "")
    else
        table.insert(fields, tostring(slotValue.itemID))
        table.insert(fields, slotValue.itemLink)
    end
end

function GGM.EncodeSyncSlotUpdate(identity, confirmedSequence, slotKey, slotValue, confirmedAt)
    local identityValid, identityErr = GGM.ValidateSyncIdentity(identity)
    if not identityValid then return nil, identityErr end
    local sequenceValid, sequenceErr = validateSequence(confirmedSequence)
    if not sequenceValid then return nil, sequenceErr end
    local slotValid, slotErr = validateSyncSlotValue(slotKey, slotValue)
    if not slotValid then return nil, slotErr end
    local timeValid, timeErr = validateTimestamp(confirmedAt, "sync-confirmed-at-invalid")
    if not timeValid then return nil, timeErr end
    local fields = {}
    appendIdentity(fields, identity)
    table.insert(fields, tostring(confirmedSequence))
    encodeSlotFields(fields, slotKey, slotValue)
    table.insert(fields, tostring(confirmedAt))
    return encodePayload("U", fields)
end

function GGM.EncodeSyncSnapshotRequest(requester, target, requestID)
    local requesterValid, requesterErr = GGM.ValidateSyncIdentity(requester)
    if not requesterValid then return nil, requesterErr end
    local targetValid, targetErr = GGM.ValidateSyncIdentity(target)
    if not targetValid then return nil, targetErr end
    local requestIDValid, requestIDErr = validateRequestID(requestID)
    if not requestIDValid then return nil, requestIDErr end
    local fields = {}
    appendIdentity(fields, requester)
    appendIdentity(fields, target)
    table.insert(fields, requestID)
    return encodePayload("Q", fields)
end

function GGM.EncodeSyncSnapshotResponseClaim(target, requester, responder, confirmedSequence, requestID)
    local targetValid, targetErr = GGM.ValidateSyncIdentity(target)
    if not targetValid then return nil, targetErr end
    local requesterValid, requesterErr = GGM.ValidateSyncIdentity(requester)
    if not requesterValid then return nil, requesterErr end
    local responderValid, responderErr = GGM.ValidateSyncIdentity(responder)
    if not responderValid then return nil, responderErr end
    local sequenceValid, sequenceErr = validateSequence(confirmedSequence)
    if not sequenceValid then return nil, sequenceErr end
    local requestIDValid, requestIDErr = validateRequestID(requestID)
    if not requestIDValid then return nil, requestIDErr end
    local keyMaximum = GGM.SYNC_MAX_NAME_BYTES + GGM.SYNC_MAX_REALM_BYTES + 1
    local targetKeyValid, targetKeyErr = validateBoundedString(target.key, keyMaximum, "sync-claim-target-key", false)
    if not targetKeyValid then return nil, targetKeyErr end
    local requesterKeyValid, requesterKeyErr = validateBoundedString(requester.key, keyMaximum, "sync-claim-requester-key", false)
    if not requesterKeyValid then return nil, requesterKeyErr end
    local responderKeyValid, responderKeyErr = validateBoundedString(responder.key, keyMaximum, "sync-claim-responder-key", false)
    if not responderKeyValid then return nil, responderKeyErr end
    local fields = {}
    table.insert(fields, target.key)
    table.insert(fields, requester.key)
    table.insert(fields, responder.key)
    table.insert(fields, tostring(confirmedSequence))
    table.insert(fields, requestID)
    return encodePayload("C", fields)
end

function GGM.EncodeSyncSnapshotResponse(target, requester, responder, snapshot, confirmedSequence, requestID)
    local targetValid, targetErr = GGM.ValidateSyncIdentity(target)
    if not targetValid then return nil, targetErr end
    local requesterValid, requesterErr = GGM.ValidateSyncIdentity(requester)
    if not requesterValid then return nil, requesterErr end
    local responderValid, responderErr = GGM.ValidateSyncIdentity(responder)
    if not responderValid then return nil, responderErr end
    local snapshotValid, snapshotErr = GGM.ValidateCompleteSnapshot(snapshot)
    if not snapshotValid then return nil, snapshotErr end
    local sequenceValid, sequenceErr = validateSequence(confirmedSequence)
    if not sequenceValid then return nil, sequenceErr end
    local requestIDValid, requestIDErr = validateRequestID(requestID)
    if not requestIDValid then return nil, requestIDErr end
    local timeValid, timeErr = validateTimestamp(snapshot.capturedAt, "sync-captured-at-invalid")
    if not timeValid then return nil, timeErr end
    local fields = {}
    appendIdentity(fields, target)
    appendIdentity(fields, requester)
    appendIdentity(fields, responder)
    table.insert(fields, requestID)
    table.insert(fields, tostring(confirmedSequence))
    table.insert(fields, tostring(snapshot.capturedAt))
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local slotValue = snapshot.slots[trackedSlot.key]
        local slotValid, slotErr = validateSyncSlotValue(trackedSlot.key, slotValue)
        if not slotValid then return nil, slotErr end
        encodeSlotFields(fields, trackedSlot.key, slotValue)
    end
    return encodePayload("S", fields)
end

local function readField(payload, cursor)
    local colon = payload:find(":", cursor, true)
    if not colon then return nil, nil, "sync-field-length-missing" end
    local lengthText = payload:sub(cursor, colon - 1)
    if lengthText == "" or #lengthText > 4 or not lengthText:match("^%d+$") then return nil, nil, "sync-field-length-invalid" end
    local length = tonumber(lengthText)
    if not length or length > GGM.SYNC_MAX_LOGICAL_BYTES then return nil, nil, "sync-field-length-invalid" end
    local valueStart = colon + 1
    local valueEnd = valueStart + length - 1
    if valueEnd > #payload then return nil, nil, "sync-field-truncated" end
    return payload:sub(valueStart, valueEnd), valueEnd + 1, nil
end

local function readFields(payload, cursor, count)
    local fields = {}
    for index = 1, count do
        local value, nextCursor, err = readField(payload, cursor)
        if err then return nil, nil, err end
        fields[index] = value
        cursor = nextCursor
    end
    return fields, cursor, nil
end

local function parseUnsignedInteger(text, minimum, maximum, errorName)
    if type(text) ~= "string" or text == "" or not text:match("^%d+$") then return nil, errorName end
    local value = tonumber(text)
    if not value or not isIntegerInRange(value, minimum, maximum) then return nil, errorName end
    return value, nil
end

local function decodeIdentity(fields, offset)
    local identity = { key = fields[offset], name = fields[offset + 1], realm = fields[offset + 2], guid = fields[offset + 3] ~= "" and fields[offset + 3] or nil }
    local valid, err = GGM.ValidateSyncIdentity(identity)
    if not valid then return nil, err end
    return identity, nil
end

local function decodeSlot(fields, offset, expectedSlotKey)
    local slotKey = fields[offset]
    if expectedSlotKey and slotKey ~= expectedSlotKey then return nil, nil, "sync-snapshot-slot-order-mismatch:" .. expectedSlotKey end
    local inventorySlotID, inventoryErr = parseUnsignedInteger(fields[offset + 1], 1, 255, "sync-inventory-slot-id-invalid")
    if not inventorySlotID then return nil, nil, inventoryErr end
    local itemID, itemErr = parseUnsignedInteger(fields[offset + 2], 0, 2147483647, "sync-item-id-invalid")
    if itemID == nil then return nil, nil, itemErr end
    local itemLink = fields[offset + 3]
    local slotValue
    if itemID == 0 then
        if itemLink ~= "" then return nil, nil, "sync-empty-slot-link-invalid" end
        slotValue = { inventorySlotID = inventorySlotID, itemID = false, itemLink = false }
    else
        slotValue = { inventorySlotID = inventorySlotID, itemID = itemID, itemLink = itemLink }
    end
    local valid, err = validateSyncSlotValue(slotKey, slotValue)
    if not valid then return nil, nil, err end
    return slotKey, slotValue, nil
end

function GGM.DecodeSyncMessage(payload)
    if type(payload) ~= "string" then return nil, "sync-payload-invalid" end
    if #payload > GGM.SYNC_MAX_LOGICAL_BYTES then return nil, "sync-payload-too-large" end
    if #payload < 2 then return nil, "sync-payload-too-short" end
    if payload:sub(1, 1) ~= tostring(GGM.SYNC_PROTOCOL_VERSION) then return nil, "sync-protocol-version-unsupported" end
    local typeCode = payload:sub(2, 2)
    local fieldCount
    if typeCode == "U" then fieldCount = 10
    elseif typeCode == "Q" then fieldCount = 9
    elseif typeCode == "S" then fieldCount = 15 + (#GGM.TRACKED_SLOTS * 4)
    elseif typeCode == "C" then fieldCount = 5
    else return nil, "sync-message-type-unknown" end
    local fields, cursor, fieldsErr = readFields(payload, 3, fieldCount)
    if not fields then return nil, fieldsErr end
    if cursor ~= #payload + 1 then return nil, "sync-payload-trailing-data" end
    if typeCode == "U" then
        local identity, identityErr = decodeIdentity(fields, 1)
        if not identity then return nil, identityErr end
        local sequence, sequenceErr = parseUnsignedInteger(fields[5], 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE, "sync-sequence-invalid")
        if sequence == nil then return nil, sequenceErr end
        local slotKey, slotValue, slotErr = decodeSlot(fields, 6, nil)
        if not slotKey then return nil, slotErr end
        local confirmedAt, timeErr = parseUnsignedInteger(fields[10], 0, GGM.SYNC_MAX_TIMESTAMP, "sync-confirmed-at-invalid")
        if confirmedAt == nil then return nil, timeErr end
        return { type = "SLOT_UPDATE", identity = identity, confirmedSequence = sequence, slotKey = slotKey, slotValue = slotValue, confirmedAt = confirmedAt }, nil
    end
    if typeCode == "Q" then
        local requester, requesterErr = decodeIdentity(fields, 1)
        if not requester then return nil, requesterErr end
        local target, targetErr = decodeIdentity(fields, 5)
        if not target then return nil, targetErr end
        local requestIDValid, requestIDErr = validateRequestID(fields[9])
        if not requestIDValid then return nil, requestIDErr end
        return { type = "SNAPSHOT_REQUEST", requester = requester, target = target, requestID = fields[9] }, nil
    end
    if typeCode == "C" then
        local keyMaximum = GGM.SYNC_MAX_NAME_BYTES + GGM.SYNC_MAX_REALM_BYTES + 1
        local targetValid, targetErr = validateBoundedString(fields[1], keyMaximum, "sync-claim-target-key", false)
        if not targetValid then return nil, targetErr end
        local requesterValid, requesterErr = validateBoundedString(fields[2], keyMaximum, "sync-claim-requester-key", false)
        if not requesterValid then return nil, requesterErr end
        local responderValid, responderErr = validateBoundedString(fields[3], keyMaximum, "sync-claim-responder-key", false)
        if not responderValid then return nil, responderErr end
        local sequence, sequenceErr = parseUnsignedInteger(fields[4], 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE, "sync-sequence-invalid")
        if sequence == nil then return nil, sequenceErr end
        local requestIDValid, requestIDErr = validateRequestID(fields[5])
        if not requestIDValid then return nil, requestIDErr end
        return { type = "SNAPSHOT_RESPONSE_CLAIM", target = { key = fields[1] }, requester = { key = fields[2] }, responder = { key = fields[3] }, confirmedSequence = sequence, requestID = fields[5] }, nil
    end
    local target, targetErr = decodeIdentity(fields, 1)
    if not target then return nil, targetErr end
    local requester, requesterErr = decodeIdentity(fields, 5)
    if not requester then return nil, requesterErr end
    local responder, responderErr = decodeIdentity(fields, 9)
    if not responder then return nil, responderErr end
    local requestIDValid, requestIDErr = validateRequestID(fields[13])
    if not requestIDValid then return nil, requestIDErr end
    local sequence, sequenceErr = parseUnsignedInteger(fields[14], 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE, "sync-sequence-invalid")
    if sequence == nil then return nil, sequenceErr end
    local capturedAt, capturedErr = parseUnsignedInteger(fields[15], 0, GGM.SYNC_MAX_TIMESTAMP, "sync-captured-at-invalid")
    if capturedAt == nil then return nil, capturedErr end
    local snapshot = { complete = true, capturedAt = capturedAt, slots = {} }
    local offset = 16
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local slotKey, slotValue, slotErr = decodeSlot(fields, offset, trackedSlot.key)
        if not slotKey then return nil, slotErr end
        snapshot.slots[slotKey] = slotValue
        offset = offset + 4
    end
    local snapshotValid, snapshotErr = GGM.ValidateCompleteSnapshot(snapshot)
    if not snapshotValid then return nil, snapshotErr end
    return { type = "SNAPSHOT_RESPONSE", target = target, requester = requester, responder = responder, requestID = fields[13], confirmedSequence = sequence, snapshot = snapshot }, nil
end
