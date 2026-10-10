local _, GGM = ...

local function copyIdentity(identity)
    return { key = identity.key, name = identity.name, realm = identity.realm, guid = identity.guid }
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

local function validLocalCharacterGUIDs(value)
    if type(value) ~= "table" then return false end
    for guid, owned in pairs(value) do
        if not GGM.IsProfessionGUID(guid) or owned ~= true then
            return false
        end
    end
    return true
end

function GGM.InitializeDatabase(existing)
    if existing == nil then
        return {
            schemaVersion = GGM.SCHEMA_VERSION,
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

    if existing.schemaVersion ~= GGM.SCHEMA_VERSION then
        return nil, "unsupported-schema-version:" .. tostring(existing.schemaVersion)
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
