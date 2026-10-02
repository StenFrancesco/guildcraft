local _, GGM = ...

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
    }
    copyModelIdentity(identity, copied)
    return copied
end

local function copyProfessionSnapshot(snapshot)
    return {
        complete = true,
        professionID = snapshot.professionID,
        professionName = snapshot.professionName,
        capturedAt = snapshot.capturedAt,
        source = snapshot.source,
        status = snapshot.status,
    }
end

local function copySlotValue(source)
    if source == nil or source.unavailable == true then
        return { unavailable = true }
    end
    return {
        inventorySlotID = source.inventorySlotID,
        itemID = source.itemID,
        itemLink = source.itemLink,
    }
end

local function isTrackedSlotKey(slotKey)
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        if slot.key == slotKey then
            return true
        end
    end

    return false
end

local function copySnapshot(snapshot)
    local copied = {
        complete = snapshot.complete,
        capturedAt = snapshot.capturedAt,
        slots = {},
    }

    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        copied.slots[slot.key] = copySlotValue(snapshot.slots[slot.key])
    end

    return copied
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
    if left.key ~= right.key or left.name ~= right.name or left.realm ~= right.realm then
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
    local previousIdentity = copyIdentity(record.identity)
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

local PREVIOUS_SCHEMA_VERSION = 5

local function validLocalCharacterGUIDs(value)
    if type(value) ~= "table" then return false end
    for guid, owned in pairs(value) do
        if not GGM.IsProfessionGUID(guid) or owned ~= true then
            return false
        end
    end
    return true
end

local function storedIdentityGUID(record, expectedKey)
    local identity = type(record) == "table" and record.identity or nil
    if type(identity) ~= "table"
        or identity.key ~= expectedKey
        or not GGM.IsProfessionGUID(identity.guid) then
        return nil
    end
    return identity.guid
end

local function resolveLegacyLocalGUID(db, characterKey)
    local gearGUID = storedIdentityGUID(db.characters[characterKey], characterKey)
    local professionGUID = storedIdentityGUID(db.professions[characterKey], characterKey)

    if gearGUID and professionGUID and gearGUID ~= professionGUID then
        return nil
    end
    return gearGUID or professionGUID
end

local function migrateSchemaFive(db)
    if type(db.characters) ~= "table" then
        return nil, "database-characters-invalid"
    end
    if type(db.localCharacters) ~= "table" then
        return nil, "database-local-characters-invalid"
    end
    if type(db.professions) ~= "table" then
        return nil, "database-professions-invalid"
    end

    local indexOk, indexErr = GGM.EnsureProfessionIndex(
        db,
        true,
        PREVIOUS_SCHEMA_VERSION
    )
    if not indexOk then return nil, indexErr end

    local migratedLocalGUIDs = {}
    for characterKey, owned in pairs(db.localCharacters) do
        if owned == true and type(characterKey) == "string" and characterKey ~= "" then
            local guid = resolveLegacyLocalGUID(db, characterKey)
            if guid then migratedLocalGUIDs[guid] = true end
        end
    end

    db.localCharacterGUIDs = migratedLocalGUIDs
    db.schemaVersion = GGM.SCHEMA_VERSION
    return db, nil
end

function GGM.InitializeDatabase(existing)
    if existing == nil then
        return {
            schemaVersion = GGM.SCHEMA_VERSION,
            characters = {},
            localCharacters = {},
            localCharacterGUIDs = {},
            professions = {},
            nextLocalCharacterID = 1,
            professionCharacters = {},
            localCharacterIDByGUID = {},
            professionRecipeIndex = {},
            professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION,
            professionIndexRepairCandidates = {},
            professionIndexRepairNeeded = false,
        }, nil
    end

    if type(existing) ~= "table" then
        return nil, "database-invalid"
    end

    if existing.schemaVersion == PREVIOUS_SCHEMA_VERSION then
        local migrated, migrationErr = migrateSchemaFive(existing)
        if not migrated then return nil, migrationErr end
    elseif existing.schemaVersion ~= GGM.SCHEMA_VERSION then
        return nil, "unsupported-schema-version:" .. tostring(existing.schemaVersion)
    end

    if type(existing.characters) ~= "table" then
        return nil, "database-characters-invalid"
    end

    if type(existing.localCharacters) ~= "table" then
        return nil, "database-local-characters-invalid"
    end
    if not validLocalCharacterGUIDs(existing.localCharacterGUIDs) then
        return nil, "database-local-character-guids-invalid"
    end
    if type(existing.professions) ~= "table" then
        return nil, "database-professions-invalid"
    end

    local indexOk, indexErr = GGM.EnsureProfessionIndex(existing, true)
    if not indexOk then return nil, indexErr end
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

function GGM.MarkLocalCharacterGUID(db, guid)
    if type(db) ~= "table" then
        return false, "database-invalid"
    end
    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end
    if type(db.localCharacterGUIDs) ~= "table" then
        return false, "database-local-character-guids-invalid"
    end
    if not GGM.IsProfessionGUID(guid) then
        return false, "character-guid-invalid"
    end

    db.localCharacterGUIDs[guid] = true
    return true, nil
end

function GGM.IsLocalCharacterGUID(db, guid)
    return type(db) == "table"
        and type(db.localCharacterGUIDs) == "table"
        and GGM.IsProfessionGUID(guid)
        and db.localCharacterGUIDs[guid] == true
end

function GGM.GetProfessionRecord(db, characterKey)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return nil, "database-invalid"
    end
    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return nil, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end
    if type(characterKey) ~= "string" or characterKey == "" then
        return nil, "character-key-invalid"
    end

    local record = db.professions[characterKey]
    if type(record) ~= "table" then return nil, "profession-record-missing" end

    local identityValid, identityErr = validateIdentity(record.identity)
    if not identityValid then return nil, identityErr end
    if record.identity.key ~= characterKey then return nil, "record-key-mismatch" end
    if type(record.snapshots) ~= "table" then return nil, "profession-snapshots-invalid" end

    for professionID, snapshot in pairs(record.snapshots) do
        if type(snapshot) ~= "table" then return nil, "profession-snapshot-invalid" end
        if professionID ~= snapshot.professionID then return nil, "profession-key-mismatch" end
        local valid, err = GGM.ValidateProfessionSnapshot(snapshot)
        if not valid then return nil, err end
    end

    return record, nil
end

local schemaOneSlotKeys = {
    "HEAD", "NECK", "SHOULDER", "BACK", "CHEST", "WRIST", "HANDS", "WAIST",
    "LEGS", "FEET", "FINGER_1", "FINGER_2", "TRINKET_1", "TRINKET_2", "MAIN_HAND", "OFF_HAND",
}

function GGM.SaveProfessionSnapshot(db, identity, snapshot, options)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return false, "database-invalid"
    end
    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end
    local identityValid, identityErr = validateIdentity(identity)
    if not identityValid then return false, identityErr end
    if not GGM.IsProfessionGUID(identity.guid) then
        return false, "profession-identity-guid-invalid"
    end
    local snapshotValid, snapshotErr = GGM.ValidateProfessionCapture(snapshot)
    if not snapshotValid then return false, snapshotErr end

    local guildMembershipVerified = type(options) == "table"
        and options.guildMembershipVerified == true

    local localID, characterErr = GGM.PrepareProfessionCharacterForSave(
        db,
        identity,
        guildMembershipVerified
    )
    if characterErr then return false, characterErr end

    local indexOk, indexErr = GGM.EnsureProfessionIndex(db, true)
    if not indexOk then return false, indexErr end

    if localID == nil then
        localID, characterErr = GGM.EnsureProfessionCharacter(db, identity)
        if not localID then return false, characterErr end
    end

    local record = db.professions[identity.key]
    if record ~= nil then
        local existing, existingErr = GGM.GetProfessionRecord(db, identity.key)
        if not existing then return false, existingErr end
        if not identitiesCompatible(existing.identity, identity) then
            return false, "identity-mismatch"
        end
        record = existing
    else
        record = {
            identity = copyIdentity(identity),
            snapshots = {},
        }
    end

    local indexed, reconcileErr = GGM.ReconcileProfessionRecipeMembership(
        db,
        localID,
        snapshot
    )
    if not indexed then return false, reconcileErr end

    record.identity = copyIdentity(identity)
    record.snapshots[snapshot.professionID] = copyProfessionSnapshot(snapshot)
    db.professions[identity.key] = record

    local entry = db.professionCharacters[localID]
    if guildMembershipVerified and entry.active ~= true then entry.active = true end
    return true, nil
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

    local snapshotValid, snapshotErr = GGM.ValidateCompleteSnapshot(snapshot)
    if not snapshotValid then
        return false, snapshotErr
    end

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

    db.characters[identity.key] = {
        complete = true,
        identity = copyIdentity(identity),
        gear = copySnapshot(snapshot),
        confirmedSequence = sequence,
    }

    return true, nil
end

function GGM.GetCompleteCharacterRecord(db, characterKey)
    if type(db) ~= "table" or type(db.characters) ~= "table" then
        return nil, "database-invalid"
    end

    if db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return nil, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end

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

    local snapshotValid, snapshotErr = GGM.ValidateCompleteSnapshot(record.gear)
    if not snapshotValid then
        return nil, snapshotErr
    end

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
    local record = db.characters[characterKey]
    if type(record) ~= "table" then return nil, "record-missing" end
    local identityValid, identityErr = validateIdentity(record.identity)
    if not identityValid then return nil, identityErr end
    if record.identity.key ~= characterKey then return nil, "record-key-mismatch" end
    if record.complete == true then return GGM.GetCompleteCharacterRecord(db, characterKey) end
    if record.complete ~= false or record.completeness ~= "incomplete" then return nil, "record-incomplete-invalid" end
    if type(record.gear) ~= "table" or record.gear.complete ~= false
        or type(record.gear.capturedAt) ~= "number" or type(record.gear.slots) ~= "table" then
        return nil, "record-incomplete-invalid"
    end
    local _, sequenceErr = readConfirmedSequence(record)
    if sequenceErr then return nil, sequenceErr end

    if record.refreshNeeded == true then
        if record.incompleteReason ~= "sequence-gap" then return nil, "record-incomplete-invalid" end
        local confirmedSequence = readConfirmedSequence(record)
        if not isIntegerInRange(record.requiredBaselineSequence, 0, GGM.SYNC_MAX_CONFIRMED_SEQUENCE)
            or record.requiredBaselineSequence <= confirmedSequence then
            return nil, "record-incomplete-invalid"
        end
        local staleSnapshot = {
            complete = true,
            capturedAt = record.gear.capturedAt,
            slots = record.gear.slots,
        }
        local staleValid, staleErr = GGM.ValidateCompleteSnapshot(staleSnapshot)
        if not staleValid then return nil, staleErr end
        return record, nil
    end
    if record.refreshNeeded ~= nil or record.incompleteReason ~= nil then
        return nil, "record-incomplete-invalid"
    end

    local legacyKeys = {}
    for _, key in ipairs(schemaOneSlotKeys) do legacyKeys[key] = true end
    for key, value in pairs(record.gear.slots) do
        if not legacyKeys[key] then
            if isTrackedSlotKey(key) then return nil, "incomplete-record-new-slot-present:" .. tostring(key) end
            return nil, "tracked-slot-unknown:" .. tostring(key)
        end
        local slotValid, slotErr = GGM.ValidateGearSlotValue(key, value)
        if not slotValid then return nil, slotErr end
    end
    for _, key in ipairs(schemaOneSlotKeys) do
        if type(record.gear.slots[key]) ~= "table" then
            return nil, "snapshot-slot-missing:" .. key
        end
    end
    return record, nil
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

    local sharedSlot = record.gear.slots[slotKey]
    if not (GGM.OPTIONAL_TRACKED_SLOTS[slotKey] == true
        and (sharedSlot == nil or sharedSlot.unavailable == true))
        and slotValue.inventorySlotID ~= sharedSlot.inventorySlotID then
        return false, "snapshot-slot-id-mismatch:" .. slotKey
    end

    local sequence, sequenceErr = readConfirmedSequence(record)
    if sequence == nil then
        return false, sequenceErr
    end

    if sequence >= GGM.SYNC_MAX_CONFIRMED_SEQUENCE then
        return false, "confirmed-sequence-exhausted"
    end

    record.gear.slots[slotKey] = copySlotValue(slotValue)
    record.gear.capturedAt = confirmedAt
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

    local sharedSlot = record.gear.slots[slotKey]
    if not (GGM.OPTIONAL_TRACKED_SLOTS[slotKey] == true
        and (sharedSlot == nil or sharedSlot.unavailable == true))
        and slotValue.inventorySlotID ~= sharedSlot.inventorySlotID then
        return false, "snapshot-slot-id-mismatch:" .. slotKey
    end

    local existingSequence, sequenceErr = readConfirmedSequence(record)
    if existingSequence == nil then
        return false, sequenceErr
    end

    if record.refreshNeeded == true then
        if confirmedSequence < existingSequence then return false, "confirmed-sequence-regression" end
        if confirmedSequence > record.requiredBaselineSequence then
            record.requiredBaselineSequence = confirmedSequence
            return false, "confirmed-sequence-gap-advanced"
        end
        return false, "confirmed-sequence-gap"
    end
    if record.complete ~= true then return false, "record-missing" end

    if confirmedSequence < existingSequence then
        return false, "confirmed-sequence-regression"
    end

    if confirmedSequence > existingSequence + 1 then
        record.complete = false
        record.completeness = "incomplete"
        record.refreshNeeded = true
        record.incompleteReason = "sequence-gap"
        record.requiredBaselineSequence = confirmedSequence
        record.gear.complete = false
        return false, "confirmed-sequence-gap"
    end

    record.gear.slots[slotKey] = copySlotValue(slotValue)
    record.gear.capturedAt = confirmedAt
    record.confirmedSequence = confirmedSequence

    return true, nil
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

    local existing = db.characters[identity.key]
    if type(existing) == "table" then
        local existingRecord, existingErr = GGM.GetCharacterRecord(db, identity.key)
        if not existingRecord then
            return false, existingErr
        end

        if not identitiesCompatible(existingRecord.identity, identity) then
            return false, "identity-mismatch"
        end

        local existingSequence, sequenceErr = readConfirmedSequence(existingRecord)
        if existingSequence == nil then
            return false, sequenceErr
        end

        if existingRecord.refreshNeeded == true
            and confirmedSequence < existingRecord.requiredBaselineSequence then
            return false, "confirmed-sequence-before-required-baseline"
        end

        if confirmedSequence < existingSequence then
            return false, "confirmed-sequence-regression"
        end
    end

    return GGM.SaveCompleteCharacterRecord(db, identity, snapshot, confirmedSequence)
end
