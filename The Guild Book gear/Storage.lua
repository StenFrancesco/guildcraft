local _, GGM = ...
local resolveCharacterKey

local function isPositiveInteger(value, maximum)
    return type(value) == "number" and value > 0 and value <= maximum and value == math.floor(value)
end

local function copyModelIdentity(source, target)
    local pairCheckOk, validPair, raceID, sex = pcall(function()
        if isPositiveInteger(source.raceID, GGM.SYNC_MAX_RACE_ID) and (source.sex == 2 or source.sex == 3) then
            return true, source.raceID, source.sex
        end
        return false
    end)
    if pairCheckOk and validPair then
        target.raceID = raceID
        target.sex = sex
    else
        return
    end

    local displayCheckOk, validDisplay, displayID = pcall(function()
        if isPositiveInteger(source.displayID, GGM.SYNC_MAX_DISPLAY_ID) then return true, source.displayID end
        return false
    end)
    if displayCheckOk and validDisplay then target.displayID = displayID end
end

local function copyIdentity(identity)
    local copied = {
        key = identity.key,
        name = identity.name,
        realm = identity.realm,
        guid = identity.guid,
        classToken = GGM.NormalizeClassicClassToken(identity.classToken),
    }
    copyModelIdentity(identity, copied)
    return copied
end

local function isTrackedSlotKey(slotKey)
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        if slot.key == slotKey then
            return true
        end
    end

    return false
end

local function validateIdentity(identity)
    if type(identity) ~= "table" then
        return false, "identity-invalid"
    end

    if type(identity.key) ~= "string" or identity.key == "" then
        return false, "identity-key-invalid"
    end

    if type(identity.name) ~= "string" or identity.name == "" then
        return false, "identity-name-invalid"
    end

    if type(identity.realm) ~= "string" or identity.realm == "" then
        return false, "identity-realm-invalid"
    end

    return true, nil
end

local function isIntegerInRange(value, minimum, maximum)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= minimum
        and value <= maximum
end

local function readConfirmedSequence(record)
    if record.confirmedSequence == nil then
        return 0, nil
    end

    if not isIntegerInRange(record.confirmedSequence, 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE) then
        return nil, "confirmed-sequence-invalid"
    end

    return record.confirmedSequence, nil
end

local function identitiesCompatible(left, right)
    if left.name ~= right.name or left.realm:gsub("%s", ""):lower() ~= right.realm:gsub("%s", ""):lower() then
        return false
    end

    local leftGuid = type(left.guid) == "string" and left.guid or nil
    local rightGuid = type(right.guid) == "string" and right.guid or nil
    if leftGuid and rightGuid and leftGuid ~= rightGuid then
        return false
    end

    return true
end

function GGM.UpdateLocalCharacterModelIdentity(db, identity)
    if type(db) ~= "table" or type(db.characters) ~= "table" then
        return false, "database-invalid"
    end
    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end

    local identityValid, identityErr = validateIdentity(identity)
    if not identityValid then return false, identityErr end

    local record, recordErr = GGM.GetCharacterRecord(db, identity.key)
    if not record then return false, recordErr end
    if not identitiesCompatible(record.identity, identity) then
        return false, "identity-mismatch"
    end

    local updatedIdentity = copyIdentity(identity)
    updatedIdentity.key, updatedIdentity.name, updatedIdentity.realm = record.identity.key, record.identity.name, record.identity.realm
    local previousIdentity = copyIdentity(record.identity)
    updatedIdentity.classToken = updatedIdentity.classToken or previousIdentity.classToken
    if updatedIdentity.raceID == nil then
        if previousIdentity.raceID ~= nil then
            updatedIdentity.raceID = previousIdentity.raceID
            updatedIdentity.sex = previousIdentity.sex
            updatedIdentity.displayID = previousIdentity.displayID
        end
    elseif updatedIdentity.raceID == previousIdentity.raceID
        and updatedIdentity.sex == previousIdentity.sex
        and updatedIdentity.displayID == nil then
        updatedIdentity.displayID = previousIdentity.displayID
    end

    record.identity = updatedIdentity
    return true, nil
end

function GGM.GetConfirmedSequence(record)
    if type(record) ~= "table" then
        return nil, "record-invalid"
    end

    return readConfirmedSequence(record)
end

function GGM.InitializeGearDatabase(existing)
    if existing == nil then
        return { schemaVersion = GGM.SCHEMA_VERSION, characters = {}, localCharacters = {} }, nil
    end
    if type(existing) ~= "table" then return nil, "database-invalid" end
    if existing.schemaVersion ~= GGM.SCHEMA_VERSION then
        return nil, "unsupported-schema-version:" .. tostring(existing.schemaVersion)
    end
    if type(existing.characters) ~= "table" or type(existing.localCharacters) ~= "table" then
        return nil, "gear-database-invalid"
    end
    return existing, nil
end

function GGM.MarkLocalCharacter(db, characterKey)
    if type(db) ~= "table" or type(db.characters) ~= "table" then
        return false, "database-invalid"
    end
    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end
    if type(db.localCharacters) ~= "table" then
        return false, "database-local-characters-invalid"
    end
    if type(characterKey) ~= "string" or characterKey == "" then
        return false, "character-key-invalid"
    end

    db.localCharacters[characterKey] = true
    return true
end

function GGM.IsLocalCharacter(db, characterKey)
    return type(db) == "table"
        and type(db.localCharacters) == "table"
        and type(characterKey) == "string"
        and db.localCharacters[characterKey] == true
end

local function isLocallyOwnedGUID(db, guid)
    return type(db.localCharacterGUIDs) == "table" and db.localCharacterGUIDs[guid] == true
end

function GGM.HasUnresolvedLocalGearMarker(db, characterKey, guid)
    return type(db.localCharacters) == "table"
        and db.localCharacters[characterKey] == true
        and not isLocallyOwnedGUID(db, guid)
end

function GGM.RemoveLocalGearMarker(db, characterKey)
    if type(db.localCharacters) == "table" then db.localCharacters[characterKey] = nil end
end

function GGM.PurgeDepartedGearRecords(db, currentByGUID)
    if type(db.characters) ~= "table" or type(db.localCharacters) ~= "table" then return end
    local keysToRemove = {}
    for characterKey, record in pairs(db.characters) do
        local identity = type(record) == "table" and record.identity or nil
        local guid = type(identity) == "table" and identity.guid or nil
        if type(guid) == "string" and guid ~= "" and currentByGUID[guid] == nil
            and not isLocallyOwnedGUID(db, guid)
            and not GGM.HasUnresolvedLocalGearMarker(db, characterKey, guid) then
            keysToRemove[#keysToRemove + 1] = characterKey
        end
    end
    table.sort(keysToRemove)
    for _, characterKey in ipairs(keysToRemove) do
        db.characters[characterKey] = nil
        GGM.RemoveLocalGearMarker(db, characterKey)
    end
end

function GGM.SaveCompleteCharacterRecord(db, identity, snapshot, confirmedSequence)
    if type(db) ~= "table" or type(db.characters) ~= "table" then
        return false, "database-invalid"
    end

    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end

    local identityValid, identityErr = validateIdentity(identity)
    if not identityValid then
        return false, identityErr
    end

    local resolvedKey, resolveErr = resolveCharacterKey(db, identity.key)
    if not resolvedKey then return false, resolveErr end
    if resolvedKey ~= identity.key then
        local existing, existingErr = GGM.GetCharacterRecord(db, resolvedKey)
        if not existing then return false, existingErr end
        if not identitiesCompatible(existing.identity, identity) then return false, "identity-mismatch" end
        identity = copyIdentity(identity)
        identity.key, identity.name, identity.realm = existing.identity.key, existing.identity.name, existing.identity.realm
    end

    local compactGear, compactErr = GGM.CreateStoredGear(snapshot)
    if not compactGear then return false, compactErr end

    local sequence = confirmedSequence
    if sequence == nil then
        local existing = db.characters[identity.key]
        if type(existing) == "table" then
            local existingSequence, sequenceErr = readConfirmedSequence(existing)
            if existingSequence == nil then
                return false, sequenceErr
            end
            sequence = existingSequence
        else
            sequence = 0
        end
    end

    if not isIntegerInRange(sequence, 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE) then
        return false, "confirmed-sequence-invalid"
    end

    local savedIdentity = copyIdentity(identity)
    local previous = db.characters[identity.key]
    if type(previous) == "table" and type(previous.identity) == "table"
        and identitiesCompatible(previous.identity, identity) then
        savedIdentity.classToken = savedIdentity.classToken
            or GGM.NormalizeClassicClassToken(previous.identity.classToken)
    end
    db.characters[identity.key] = {
        complete = true,
        identity = savedIdentity,
        gear = compactGear,
        confirmedSequence = sequence,
    }

    return true, nil
end

-- Preserve existing saved keys while accepting the realm spellings used by
-- UnitFullName and addon transport. Ambiguous aliases are never merged.
resolveCharacterKey = function(db, characterKey)
    if db.characters[characterKey] ~= nil or type(characterKey) ~= "string" then return characterKey end
    local name, realm = characterKey:match("^([^-]+)%-(.+)$")
    if not name then return characterKey end
    realm = realm:gsub("%s", ""):lower()
    local found
    for key in pairs(db.characters) do
        if type(key) == "string" then
            local otherName, otherRealm = key:match("^([^-]+)%-(.+)$")
            if otherName == name and otherRealm:gsub("%s", ""):lower() == realm then
                if found then return nil, "identity-alias-ambiguous" end
                found = key
            end
        end
    end
    return found or characterKey
end

function GGM.GetCompleteCharacterRecord(db, characterKey)
    if type(db) ~= "table" or type(db.characters) ~= "table" then
        return nil, "database-invalid"
    end

    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return nil, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end

    local resolvedKey, resolveErr = resolveCharacterKey(db, characterKey)
    if not resolvedKey then return nil, resolveErr end
    characterKey = resolvedKey
    local record = db.characters[characterKey]
    if type(record) ~= "table" or record.complete ~= true then
        return nil, "record-missing"
    end

    local identityValid, identityErr = validateIdentity(record.identity)
    if not identityValid then
        return nil, identityErr
    end

    if record.identity.key ~= characterKey then
        return nil, "record-key-mismatch"
    end

    local gearValid, gearErr = GGM.ValidateStoredGear(record.gear, true)
    if not gearValid then return nil, gearErr end

    local _, sequenceErr = readConfirmedSequence(record)
    if sequenceErr then
        return nil, sequenceErr
    end

    return record, nil
end

function GGM.GetCharacterRecord(db, characterKey)
    if type(db) ~= "table" or type(db.characters) ~= "table" then
        return nil, "database-invalid"
    end
    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return nil, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end
    local resolvedKey, resolveErr = resolveCharacterKey(db, characterKey)
    if not resolvedKey then return nil, resolveErr end
    characterKey = resolvedKey
    local record = db.characters[characterKey]
    if type(record) ~= "table" then return nil, "record-missing" end
    local identityValid, identityErr = validateIdentity(record.identity)
    if not identityValid then return nil, identityErr end
    if record.identity.key ~= characterKey then return nil, "record-key-mismatch" end
    if record.complete == true then return GGM.GetCompleteCharacterRecord(db, characterKey) end
    if record.complete ~= false or record.completeness ~= "incomplete" then return nil, "record-incomplete-invalid" end
    if type(record.gear) ~= "table" or record.gear.complete ~= false then
        return nil, "record-incomplete-invalid"
    end
    local staleGearValid, staleGearErr = GGM.ValidateStoredGear(record.gear, false)
    if not staleGearValid then return nil, staleGearErr end
    local _, sequenceErr = readConfirmedSequence(record)
    if sequenceErr then return nil, sequenceErr end

    if record.refreshNeeded == true then
        if record.incompleteReason ~= "sequence-gap" then return nil, "record-incomplete-invalid" end
        if record.requiredBaselineObservedAt ~= nil
            and not isIntegerInRange(record.requiredBaselineObservedAt, 0, GGM.SYNC_MAX_TIMESTAMP) then
            return nil, "record-incomplete-invalid"
        end
        local confirmedSequence = readConfirmedSequence(record)
        if not isIntegerInRange(record.requiredBaselineSequence, 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE)
            or record.requiredBaselineSequence <= confirmedSequence then
            return nil, "record-incomplete-invalid"
        end
        return record, nil
    end
    if record.refreshNeeded ~= nil or record.incompleteReason ~= nil then return nil, "record-incomplete-invalid" end
    return nil, "record-incomplete-invalid"
end

function GGM.UpdateConfirmedCharacterSlot(db, characterKey, slotKey, slotValue, confirmedAt)
    if not isTrackedSlotKey(slotKey) then
        return false, "tracked-slot-unknown:" .. tostring(slotKey)
    end

    if not isIntegerInRange(confirmedAt, 0, GGM.SYNC_MAX_TIMESTAMP) then
        return false, "confirmed-at-invalid"
    end

    local record, recordErr = GGM.GetCompleteCharacterRecord(db, characterKey)
    if not record then
        return false, recordErr
    end

    local slotValid, slotErr = GGM.ValidateGearSlotValue(slotKey, slotValue)
    if not slotValid then
        return false, slotErr
    end

    local sequence, sequenceErr = readConfirmedSequence(record)
    if sequence == nil then
        return false, sequenceErr
    end

    if sequence >= GGM.SYNC_MAX_CONFIRMED_SEQUENCE then
        return false, "confirmed-sequence-exhausted"
    end

    local stored, storeErr = GGM.SetStoredGearSlot(record.gear, slotKey, slotValue)
    if not stored then return false, storeErr end
    local observationTimes = GGM.CopyGearObservationTimes(record.gear)
    observationTimes[GGM.FindTrackedSlot(slotKey).inventorySlotID] = confirmedAt
    record.gear.slotObservedAt = observationTimes
    record.gear.capturedAt = math.max(record.gear.capturedAt, confirmedAt)
    local nextSequence = sequence + 1
    record.confirmedSequence = nextSequence

    return true, nil, nextSequence
end

function GGM.ApplyReceivedCharacterSlot(db, characterKey, slotKey, slotValue, confirmedAt, confirmedSequence)
    if not isTrackedSlotKey(slotKey) then
        return false, "tracked-slot-unknown:" .. tostring(slotKey)
    end

    if not isIntegerInRange(confirmedAt, 0, GGM.SYNC_MAX_TIMESTAMP) then
        return false, "confirmed-at-invalid"
    end

    if not isIntegerInRange(confirmedSequence, 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE) then
        return false, "confirmed-sequence-invalid"
    end

    local record, recordErr = GGM.GetCharacterRecord(db, characterKey)
    if not record then
        return false, recordErr
    end

    local slotValid, slotErr = GGM.ValidateGearSlotValue(slotKey, slotValue)
    if not slotValid then
        return false, slotErr
    end

    local existingSequence, sequenceErr = readConfirmedSequence(record)
    if existingSequence == nil then
        return false, sequenceErr
    end

    local floor = GGM.GetGearObservationFloor(record.gear)
    -- A complete observation covers earlier owner messages even when their
    -- sequence was unknown at inspection time. Learn ordering, keep the gear.
    if record.complete == true and confirmedAt <= floor then
        record.confirmedSequence = math.max(existingSequence, confirmedSequence)
        return true, nil
    end
    if record.refreshNeeded == true then
        if confirmedSequence > record.requiredBaselineSequence then
            record.requiredBaselineSequence = confirmedSequence
            record.requiredBaselineObservedAt = math.max(record.requiredBaselineObservedAt or 0, confirmedAt)
            return false, "confirmed-sequence-gap-advanced"
        end
        return false, "confirmed-sequence-gap"
    end
    if record.complete ~= true then return false, "record-missing" end

    if confirmedSequence > existingSequence + 1 then
        record.complete = false
        record.completeness = "incomplete"
        record.refreshNeeded = true
        record.incompleteReason = "sequence-gap"
        record.requiredBaselineSequence = confirmedSequence
        record.requiredBaselineObservedAt = confirmedAt
        record.gear.complete = false
        return false, "confirmed-sequence-gap"
    end

    local slotID = GGM.FindTrackedSlot(slotKey).inventorySlotID
    local observedAt = GGM.GetGearSlotObservedAt(record.gear, slotID)
    if confirmedAt > observedAt then
        local observationTimes = GGM.CopyGearObservationTimes(record.gear)
        local stored, storeErr = GGM.SetStoredGearSlot(record.gear, slotKey, slotValue)
        if not stored then return false, storeErr end
        observationTimes[slotID] = confirmedAt
        record.gear.slotObservedAt = observationTimes
        record.gear.capturedAt = math.max(record.gear.capturedAt, confirmedAt)
    end
    record.confirmedSequence = math.max(existingSequence, confirmedSequence)
    return true, nil
end

local function mergeCompleteObservation(db, identity, snapshot, confirmedSequence, direct)
    local candidate, candidateErr = GGM.CreateStoredGear(snapshot)
    if not candidate then return false, candidateErr end
    local resolvedKey, resolveErr = resolveCharacterKey(db, identity.key)
    if not resolvedKey then return false, resolveErr end
    local previous = db.characters[resolvedKey]
    if previous == nil then
        return GGM.SaveCompleteCharacterRecord(db, identity, snapshot, confirmedSequence or 0)
    end
    local existing, existingErr = GGM.GetCharacterRecord(db, identity.key)
    if not existing then return false, existingErr end
    if not identitiesCompatible(existing.identity, identity) then return false, "identity-mismatch" end
    if resolvedKey ~= identity.key then
        identity = copyIdentity(identity)
        identity.key, identity.name, identity.realm = existing.identity.key, existing.identity.name, existing.identity.realm
    end
    local knownSequence = GGM.GetConfirmedSequence(existing)
    local incomingSequence = confirmedSequence or knownSequence
    if existing.refreshNeeded == true then
        local coveredByTime = (direct and existing.requiredBaselineObservedAt == nil)
            or (existing.requiredBaselineObservedAt ~= nil
                and GGM.GetGearObservationFloor(candidate) >= existing.requiredBaselineObservedAt)
        if not coveredByTime and incomingSequence < existing.requiredBaselineSequence then
            return false, "confirmed-sequence-before-required-baseline"
        end
        knownSequence = math.max(knownSequence, existing.requiredBaselineSequence)
    end
    local candidateTimes = GGM.CopyGearObservationTimes(candidate)
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        local slotID = slot.inventorySlotID
        local oldAt = GGM.GetGearSlotObservedAt(existing.gear, slotID)
        local newAt = candidateTimes[slotID]
        if oldAt > newAt or (oldAt == newAt and not direct) then
            candidate.slots[slotID] = existing.gear.slots[slotID]
            candidate.unavailableSlots[slotID] = existing.gear.unavailableSlots[slotID]
            candidateTimes[slotID] = oldAt
        end
    end
    candidate.slotObservedAt = candidateTimes
    candidate.capturedAt = math.max(candidate.capturedAt, existing.gear.capturedAt)
    local valid, validateErr = GGM.ValidateStoredGear(candidate, true)
    if not valid then return false, validateErr end
    db.characters[identity.key] = {
        complete = true,
        identity = copyIdentity(identity),
        gear = candidate,
        confirmedSequence = math.max(knownSequence, incomingSequence),
    }
    db.characters[identity.key].identity.classToken = db.characters[identity.key].identity.classToken
        or GGM.NormalizeClassicClassToken(existing.identity.classToken)
    -- Inspection APIs may omit optional model information available in cache.
    if direct and db.characters[identity.key].identity.raceID == nil then
        copyModelIdentity(existing.identity, db.characters[identity.key].identity)
    end
    return true, nil
end

function GGM.SaveObservedCharacterRecord(db, identity, snapshot)
    if type(db) ~= "table" or type(db.characters) ~= "table" then return false, "database-invalid" end
    if db.schemaVersion ~= GGM.SCHEMA_VERSION then return false, "unsupported-schema-version:" .. tostring(db.schemaVersion) end
    local valid, err = validateIdentity(identity)
    if not valid then return false, err end
    return mergeCompleteObservation(db, identity, snapshot, nil, true)
end

function GGM.SaveReceivedCompleteCharacterRecord(db, identity, snapshot, confirmedSequence)
    if type(db) ~= "table" or type(db.characters) ~= "table" then
        return false, "database-invalid"
    end

    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end

    local identityValid, identityErr = validateIdentity(identity)
    if not identityValid then
        return false, identityErr
    end

    local snapshotValid, snapshotErr = GGM.ValidateCompleteSnapshot(snapshot)
    if not snapshotValid then
        return false, snapshotErr
    end

    if not isIntegerInRange(confirmedSequence, 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE) then
        return false, "confirmed-sequence-invalid"
    end

    return mergeCompleteObservation(db, identity, snapshot, confirmedSequence, false)
end
