local _, GGM = ...
local recipeIndexConsistent

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function positiveInteger(value)
    return type(value) == "number"
        and value > 0
        and value < math.huge
        and value == math.floor(value)
end

local function canAdvance(value)
    local advanced = value + 1
    return positiveInteger(advanced) and advanced > value
end

local function highestReservedID(professionCharacters, localCharacterIDByGUID, repairCandidates)
    local highest = 0
    local malformed = false

    local function reserve(localID)
        if type(localID) == "number" then
            if localID > highest then highest = localID end
            if not positiveInteger(localID) then malformed = true end
        else
            malformed = true
        end
    end

    if type(professionCharacters) == "table" then
        for localID in pairs(professionCharacters) do
            reserve(localID)
        end
    end

    if type(localCharacterIDByGUID) == "table" then
        for guid, localID in pairs(localCharacterIDByGUID) do
            if not nonEmptyString(guid) then malformed = true end
            reserve(localID)
        end
    end

    if type(repairCandidates) == "table" then
        for _, candidate in pairs(repairCandidates) do
            if type(candidate) == "table" then
                reserve(candidate.localID)
            else
                malformed = true
            end
        end
    end

    return highest, nil, malformed
end

function GGM.InitializeProfessionIndexState(db)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return false, "database-professions-invalid"
    end

    local registryMissing = type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
    local indexMissing = type(db.professionRecipeIndex) ~= "table"

    local highestID, highestErr, registryMalformed = highestReservedID(
        db.professionCharacters,
        db.localCharacterIDByGUID,
        db.professionIndexRepairCandidates
    )
    if highestID == nil then return false, highestErr end

    local nextID = db.nextLocalCharacterID
    if type(nextID) == "number" and nextID ~= nextID then
        return false, "profession-character-id-exhausted"
    end
    if highestID == 0
        and type(nextID) ~= "number"
        and (nextID ~= nil or registryMalformed) then
        return false, "profession-character-id-exhausted"
    end

    local highWater = highestID
    if type(nextID) == "number" and nextID > highWater then highWater = nextID end
    local minimumNextID = math.floor(highWater) + 1
    if minimumNextID <= highestID or not positiveInteger(minimumNextID) then
        return false, "profession-character-id-exhausted"
    end

    if not positiveInteger(nextID) or nextID <= highestID then
        nextID = minimumNextID
    end
    if not canAdvance(nextID) then
        return false, "profession-character-id-exhausted"
    end

    db.nextLocalCharacterID = nextID
    db.professionCharacters = type(db.professionCharacters) == "table"
        and db.professionCharacters or {}
    db.localCharacterIDByGUID = type(db.localCharacterIDByGUID) == "table"
        and db.localCharacterIDByGUID or {}
    db.professionRecipeIndex = type(db.professionRecipeIndex) == "table"
        and db.professionRecipeIndex or {}
    db.professionRecipeIndexVersion = type(db.professionRecipeIndexVersion) == "number"
        and db.professionRecipeIndexVersion or 0
    db.professionIndexRepairCandidates = type(db.professionIndexRepairCandidates) == "table"
        and db.professionIndexRepairCandidates or {}
    if registryMissing or indexMissing or registryMalformed then db.professionRecipeIndexVersion = 0 end
    db.professionIndexRepairNeeded = db.professionIndexRepairNeeded == true

    return true, nil
end

function GGM.IsProfessionGUID(value)
    return nonEmptyString(value)
end

local function copyRegistryIdentity(identity, active)
    return { guid = identity.guid, key = identity.key, active = active == true }
end

local function highestReservedRegistryID(db)
    local highest = 0
    for localID in pairs(db.professionCharacters) do
        if positiveInteger(localID) and localID > highest then highest = localID end
    end
    local candidates = db.professionIndexRepairCandidates
    if type(candidates) == "table" then
        for _, candidate in pairs(candidates) do
            local localID = type(candidate) == "table" and candidate.localID or nil
            if positiveInteger(localID) and localID > highest then highest = localID end
        end
    end
    return highest
end

local function normalizeNextLocalCharacterID(db)
    local minimum = highestReservedRegistryID(db) + 1
    if not positiveInteger(db.nextLocalCharacterID) or db.nextLocalCharacterID < minimum then
        db.nextLocalCharacterID = minimum
    end
end

function GGM.EnsureProfessionCharacter(db, identity)
    if type(db) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or type(db.professions) ~= "table" then
        return nil, "profession-registry-invalid"
    end
    if type(identity) ~= "table"
        or not nonEmptyString(identity.key)
        or not GGM.IsProfessionGUID(identity.guid) then
        return nil, "profession-identity-guid-invalid"
    end

    local canonicalMatches = 0
    for key, record in pairs(db.professions) do
        local recordIdentity = type(record) == "table" and record.identity or nil
        if type(recordIdentity) == "table"
            and recordIdentity.key == key
            and recordIdentity.guid == identity.guid then
            canonicalMatches = canonicalMatches + 1
        end
    end
    if canonicalMatches > 1 then
        db.professionIndexRepairNeeded = true
        return nil, "profession-identity-ambiguous"
    end

    local existingID = db.localCharacterIDByGUID[identity.guid]
    if existingID ~= nil then
        if not positiveInteger(existingID) then return nil, "profession-registry-inconsistent" end
        local entry = db.professionCharacters[existingID]
        if type(entry) ~= "table" or entry.guid ~= identity.guid then
            return nil, "profession-registry-inconsistent"
        end
        if entry.key ~= identity.key then return nil, "profession-registry-key-mismatch" end
        return existingID, nil
    end

    normalizeNextLocalCharacterID(db)
    local localID = db.nextLocalCharacterID
    if not canAdvance(localID) then return nil, "profession-character-id-exhausted" end
    db.nextLocalCharacterID = localID + 1
    db.professionCharacters[localID] = copyRegistryIdentity(identity, false)
    db.localCharacterIDByGUID[identity.guid] = localID
    return localID, nil
end

function GGM.RekeyProfessionCharacter(db, localID, identity, validateOnly)
    local entry = type(db) == "table"
        and type(db.professionCharacters) == "table"
        and db.professionCharacters[localID] or nil
    if type(entry) ~= "table" or entry.guid ~= identity.guid then
        return false, "profession-registry-inconsistent"
    end
    if entry.key == identity.key then return true, false end

    local oldKey = entry.key
    local oldRecord = db.professions[oldKey]
    local targetRecord = db.professions[identity.key]
    if type(oldRecord) ~= "table"
        or type(oldRecord.identity) ~= "table"
        or oldRecord.identity.key ~= oldKey
        or oldRecord.identity.guid ~= identity.guid
        or type(oldRecord.snapshots) ~= "table" then
        return false, "profession-registry-key-mismatch"
    end
    for professionID, snapshot in pairs(oldRecord.snapshots) do
        if type(snapshot) ~= "table"
            or professionID ~= snapshot.professionID
            or not GGM.ValidateProfessionSnapshot(snapshot) then
            return false, "profession-record-invalid"
        end
    end

    if targetRecord ~= nil then
        if type(targetRecord) ~= "table"
            or type(targetRecord.identity) ~= "table"
            or targetRecord.identity.key ~= identity.key
            or targetRecord.identity.guid ~= identity.guid
            or type(targetRecord.snapshots) ~= "table" then
            return false, "profession-key-collision"
        end
        for professionID, snapshot in pairs(targetRecord.snapshots) do
            if type(snapshot) ~= "table"
                or professionID ~= snapshot.professionID
                or not GGM.ValidateProfessionSnapshot(snapshot) then
                return false, "profession-record-invalid"
            end
        end
        for professionID in pairs(oldRecord.snapshots) do
            if targetRecord.snapshots[professionID] ~= nil then
                db.professionIndexRepairNeeded = true
                return false, "profession-rename-profession-conflict"
            end
        end
        if validateOnly then return true, false end

        for professionID, snapshot in pairs(oldRecord.snapshots) do
            targetRecord.snapshots[professionID] = snapshot
        end
        targetRecord.identity.key = identity.key
        targetRecord.identity.name = identity.name
        targetRecord.identity.realm = identity.realm
        targetRecord.identity.guid = identity.guid
        db.professions[oldKey] = nil
    else
        if validateOnly then return true, false end
        db.professions[identity.key] = oldRecord
        db.professions[oldKey] = nil
        oldRecord.identity.key = identity.key
        oldRecord.identity.name = identity.name
        oldRecord.identity.realm = identity.realm
        oldRecord.identity.guid = identity.guid
    end

    entry.key = identity.key
    return true, true
end

local canonicalGUIDRecords
local storedRepairCandidateIsValid

function GGM.PrepareProfessionCharacterForSave(db, identity, guildMembershipVerified)
    if type(identity) ~= "table" or not GGM.IsProfessionGUID(identity.guid) then
        return nil, "profession-identity-guid-invalid"
    end

    local existingID = db.localCharacterIDByGUID[identity.guid]
    if existingID == nil then
        local targetRecord = db.professions[identity.key]
        if targetRecord ~= nil then
            if type(targetRecord) ~= "table"
                or type(targetRecord.identity) ~= "table"
                or targetRecord.identity.key ~= identity.key then
                return nil, "profession-record-invalid"
            end
            local targetGUID = targetRecord.identity.guid
            if targetGUID ~= nil and not GGM.IsProfessionGUID(targetGUID) then
                return nil, "profession-record-invalid"
            end
            if targetGUID == nil and type(targetRecord.snapshots) == "table"
                and next(targetRecord.snapshots) ~= nil then
                db.professionIndexRepairNeeded = true
                return nil, "profession-key-collision"
            end
            if GGM.IsProfessionGUID(targetGUID) and targetGUID ~= identity.guid then
                db.professionIndexRepairNeeded = true
                return nil, "profession-key-collision"
            end
        end

        local candidate = type(db.professionIndexRepairCandidates) == "table"
            and db.professionIndexRepairCandidates[identity.guid] or nil
        if candidate ~= nil then
            if guildMembershipVerified ~= true
                or not storedRepairCandidateIsValid(db, identity.guid, candidate, identity.key)
                or db.professionCharacters[candidate.localID] ~= nil then
                db.professionIndexRepairNeeded = true
                return nil, "profession-identity-ambiguous"
            end

            local localID = candidate.localID
            db.professionCharacters[localID] = {
                guid = identity.guid,
                key = candidate.sourceKey,
                active = candidate.active,
            }
            db.localCharacterIDByGUID[identity.guid] = localID

            local validated, validateErr = GGM.RekeyProfessionCharacter(db, localID, identity, true)
            if not validated then
                db.professionCharacters[localID] = nil
                db.localCharacterIDByGUID[identity.guid] = nil
                db.professionIndexRepairNeeded = true
                return nil, validateErr
            end

            local rekeyed, rekeyResult = GGM.RekeyProfessionCharacter(db, localID, identity)
            if not rekeyed then
                db.professionCharacters[localID] = nil
                db.localCharacterIDByGUID[identity.guid] = nil
                db.professionIndexRepairNeeded = true
                return nil, rekeyResult
            end

            db.professionIndexRepairCandidates[identity.guid] = nil
            local _, ambiguous, invalidCanonical = canonicalGUIDRecords(db)
            db.professionIndexRepairNeeded = next(ambiguous) ~= nil or invalidCanonical
                or next(db.professionIndexRepairCandidates) ~= nil
            return localID, nil, rekeyResult
        end
        return nil, nil, false
    end

    local entry = db.professionCharacters[existingID]
    if type(entry) ~= "table" or entry.guid ~= identity.guid then
        return nil, "profession-registry-inconsistent"
    end

    if entry.key ~= identity.key then
        local targetRecord = db.professions[identity.key]
        local targetIdentity = type(targetRecord) == "table" and targetRecord.identity or nil
        if targetRecord ~= nil and type(targetIdentity) == "table"
            and GGM.IsProfessionGUID(targetIdentity.guid)
            and targetIdentity.guid ~= identity.guid then
            db.professionIndexRepairNeeded = true
            return nil, "profession-key-collision"
        end
        local matchingCanonicalRecords = 0
        for key, candidate in pairs(db.professions) do
            local candidateIdentity = type(candidate) == "table" and candidate.identity or nil
            if type(candidateIdentity) == "table"
                and candidateIdentity.key == key
                and candidateIdentity.guid == identity.guid then
                matchingCanonicalRecords = matchingCanonicalRecords + 1
            end
        end
        local expectedRecords = db.professions[identity.key] ~= nil and 2 or 1
        if matchingCanonicalRecords ~= expectedRecords then
            db.professionIndexRepairNeeded = true
            return nil, "profession-identity-ambiguous"
        end
        local ok, rekeyResult = GGM.RekeyProfessionCharacter(db, existingID, identity)
        if not ok then return nil, rekeyResult end
        db.professionIndexRepairCandidates[identity.guid] = nil
        local _, ambiguous, invalidCanonical = canonicalGUIDRecords(db)
        db.professionIndexRepairNeeded = next(ambiguous) ~= nil or invalidCanonical
            or next(db.professionIndexRepairCandidates) ~= nil
        return existingID, nil, rekeyResult
    end

    local record = db.professions[identity.key]
    if type(record) ~= "table"
        or type(record.identity) ~= "table"
        or record.identity.guid ~= identity.guid then
        return nil, "profession-registry-key-mismatch"
    end

    local matchingCanonicalRecords = 0
    for key, candidate in pairs(db.professions) do
        local candidateIdentity = type(candidate) == "table" and candidate.identity or nil
        if type(candidateIdentity) == "table"
            and candidateIdentity.key == key
            and candidateIdentity.guid == identity.guid then
            matchingCanonicalRecords = matchingCanonicalRecords + 1
        end
    end
    if matchingCanonicalRecords > 1 then
        db.professionIndexRepairNeeded = true
        return nil, "profession-identity-ambiguous"
    end

    return existingID, nil, false
end

function GGM.SetProfessionCharacterActive(db, localID, active)
    if type(db) ~= "table" or type(db.professionCharacters) ~= "table" then
        return false, "profession-character-state-invalid"
    end
    if not positiveInteger(localID) or type(active) ~= "boolean" then
        return false, "profession-character-state-invalid"
    end
    local entry = db.professionCharacters[localID]
    if type(entry) ~= "table" or not GGM.IsProfessionGUID(entry.guid) then
        return false, "profession-character-missing"
    end
    entry.active = active
    return true, nil
end

local function insertCrafterID(crafters, localID)
    for position, existingID in ipairs(crafters) do
        if existingID == localID then return false end
        if existingID > localID then
            table.insert(crafters, position, localID)
            return true
        end
    end
    table.insert(crafters, localID)
    return true
end

local function removeCrafterID(crafters, localID)
    for position, existingID in ipairs(crafters) do
        if existingID == localID then
            table.remove(crafters, position)
            return true
        end
        if existingID > localID then return false end
    end
    return false
end

local function addRecipeMembership(index, professionID, recipe, localID)
    local profession = index[professionID]
    if type(profession) ~= "table" then
        profession = {}
        index[professionID] = profession
    end

    local entry = profession[recipe.recipeID]
    if type(entry) ~= "table" then
        entry = {
            name = recipe.name,
            crafters = {},
        }
        profession[recipe.recipeID] = entry
    end

    insertCrafterID(entry.crafters, localID)
end

local function removeMembershipFromProfession(index, professionID, localID)
    local profession = index[professionID]
    if type(profession) ~= "table" then return end

    for recipeID, entry in pairs(profession) do
        local crafters = type(entry) == "table" and entry.crafters or nil
        if type(crafters) == "table" then
            removeCrafterID(crafters, localID)
            if #crafters == 0 then
                profession[recipeID] = nil
            end
        end
    end
    if next(profession) == nil then index[professionID] = nil end
end

function GGM.ReconcileProfessionRecipeMembership(db, localID, capture)
    if not positiveInteger(localID) then
        return false, "profession-character-id-invalid"
    end
    local valid, err = GGM.ValidateProfessionCapture(capture)
    if not valid then return false, err end
    if type(db) ~= "table" or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table" then
        return false, "profession-index-invalid"
    end
    if not recipeIndexConsistent(db) then
        return false, "profession-index-invalid"
    end

    local character = db.professionCharacters[localID]
    if type(character) ~= "table" or not GGM.IsProfessionGUID(character.guid) then
        return false, "profession-character-missing"
    end

    removeMembershipFromProfession(
        db.professionRecipeIndex,
        capture.professionID,
        localID
    )

    for _, recipe in ipairs(capture.recipes) do
        addRecipeMembership(
            db.professionRecipeIndex,
            capture.professionID,
            recipe,
            localID
        )
    end
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    return true, nil
end

local function validRegistryPair(db, localID, entry)
    return positiveInteger(localID)
        and type(entry) == "table"
        and GGM.IsProfessionGUID(entry.guid)
        and nonEmptyString(entry.key)
        and type(entry.active) == "boolean"
        and db.localCharacterIDByGUID[entry.guid] == localID
end

local function registryConsistent(db)
    if type(db.professionCharacters) ~= "table" or type(db.localCharacterIDByGUID) ~= "table" then
        return false
    end
    for localID, entry in pairs(db.professionCharacters) do
        if not validRegistryPair(db, localID, entry) then return false end
    end
    for guid, localID in pairs(db.localCharacterIDByGUID) do
        local entry = db.professionCharacters[localID]
        if not GGM.IsProfessionGUID(guid) or type(entry) ~= "table" or entry.guid ~= guid then
            return false
        end
    end
    return true
end

local function crafterListConsistent(db, crafters)
    if type(crafters) ~= "table" or next(crafters) == nil then return false end

    local count = 0
    for position in pairs(crafters) do
        if not positiveInteger(position) then return false end
        count = count + 1
    end

    local previousID = 0
    for position = 1, count do
        local localID = rawget(crafters, position)
        local entry = db.professionCharacters[localID]
        if not positiveInteger(localID)
            or localID <= previousID
            or type(entry) ~= "table"
            or not GGM.IsProfessionGUID(entry.guid)
            or db.localCharacterIDByGUID[entry.guid] ~= localID then
            return false
        end
        previousID = localID
    end

    return true
end

recipeIndexConsistent = function(db)
    if type(db) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table" then
        return false
    end

    for professionID, recipes in pairs(db.professionRecipeIndex) do
        if not positiveInteger(professionID) or type(recipes) ~= "table" then return false end
        for recipeID, recipe in pairs(recipes) do
            if not positiveInteger(recipeID)
                or type(recipe) ~= "table"
                or not nonEmptyString(recipe.name)
                or #recipe.name > GGM.PROFESSION_MAX_NAME_BYTES
                or not crafterListConsistent(db, recipe.crafters) then
                return false
            end
        end
    end
    return true
end

canonicalGUIDRecords = function(db)
    local byGUID, ambiguous, invalidRecord, snapshotsWithoutGUID = {}, {}, false, false
    for key, record in pairs(db.professions) do
        local identity = type(record) == "table" and record.identity or nil
        local guid = type(identity) == "table" and identity.guid or nil
        if GGM.IsProfessionGUID(guid) then
            if identity.key ~= key then
                invalidRecord = true
            else
                if byGUID[guid] and byGUID[guid].key ~= key then
                    ambiguous[guid] = true
                else
                    byGUID[guid] = { key = key, record = record }
                end
            end
        elseif type(record) == "table" and type(record.snapshots) == "table"
            and next(record.snapshots) ~= nil then
            snapshotsWithoutGUID = true
        end
    end
    return byGUID, ambiguous, invalidRecord, snapshotsWithoutGUID
end

local function canonicalRecordsForGUID(db, guid)
    local records = {}
    for key, record in pairs(db.professions) do
        local identity = type(record) == "table" and record.identity or nil
        if type(identity) == "table" and identity.guid == guid then
            records[#records + 1] = {
                key = key,
                record = record,
                identity = identity,
                keyMatches = identity.key == key,
            }
        end
    end
    return records
end

local function hasExactlyTwoCanonicalRecords(db, guid, sourceKey, destinationKey)
    local records = canonicalRecordsForGUID(db, guid)
    if #records ~= 2 or sourceKey == destinationKey then return false end
    local sourceMatches, destinationMatches = 0, 0
    for _, row in ipairs(records) do
        if not row.keyMatches then return false end
        if row.key == sourceKey then sourceMatches = sourceMatches + 1 end
        if destinationKey ~= nil and row.key == destinationKey then
            destinationMatches = destinationMatches + 1
        end
    end
    return sourceMatches == 1 and (destinationKey == nil or destinationMatches == 1)
end

local function trustedRepairCandidate(db, guid)
    local localID = db.localCharacterIDByGUID[guid]
    local entry = db.professionCharacters[localID]
    if not validRegistryPair(db, localID, entry) then return nil end
    if not hasExactlyTwoCanonicalRecords(db, guid, entry.key) then return nil end
    return { localID = localID, sourceKey = entry.key, active = entry.active }
end

storedRepairCandidateIsValid = function(db, guid, candidate, destinationKey)
    return type(candidate) == "table"
        and positiveInteger(candidate.localID)
        and nonEmptyString(candidate.sourceKey)
        and type(candidate.active) == "boolean"
        and hasExactlyTwoCanonicalRecords(db, guid, candidate.sourceKey, destinationKey)
end

local function recipeCatalogAssociationsRemainStable(db, rebuiltEntries, rebuiltByGUID)
    local catalog = db.professionRecipeIndex
    if type(catalog) ~= "table" or next(catalog) == nil then return true end

    for professionID, recipes in pairs(catalog) do
        if not positiveInteger(professionID) or type(recipes) ~= "table" then return false end
        for recipeID, recipe in pairs(recipes) do
            if not positiveInteger(recipeID)
                or type(recipe) ~= "table"
                or not crafterListConsistent(db, recipe.crafters) then
                return false
            end
            for _, localID in ipairs(recipe.crafters) do
                local previous = db.professionCharacters[localID]
                local rebuilt = rebuiltEntries[localID]
                if type(previous) ~= "table"
                    or not GGM.IsProfessionGUID(previous.guid)
                    or db.localCharacterIDByGUID[previous.guid] ~= localID
                    or type(rebuilt) ~= "table"
                    or rebuilt.guid ~= previous.guid
                    or rebuiltByGUID[previous.guid] ~= localID then
                    return false
                end
            end
        end
    end
    return true
end

local function registryMatchesCanonical(db)
    local canonicalByGUID, ambiguous, invalidRecord = canonicalGUIDRecords(db)
    if invalidRecord then return false end
    for guid in pairs(ambiguous) do
        if db.localCharacterIDByGUID[guid] ~= nil or db.professionIndexRepairNeeded ~= true then return false end
    end
    for guid, localID in pairs(db.localCharacterIDByGUID) do
        local canonical, entry = canonicalByGUID[guid], db.professionCharacters[localID]
        if ambiguous[guid] or type(canonical) ~= "table" or type(entry) ~= "table"
            or canonical.key ~= entry.key then return false end
    end
    for guid in pairs(canonicalByGUID) do
        if not ambiguous[guid] and db.localCharacterIDByGUID[guid] == nil then return false end
    end
    if next(ambiguous) == nil then db.professionIndexRepairNeeded = false end
    return true
end

local function rebuildRegistryFromCanonical(db, oldRegistryConsistent)
    local oldEntries, oldByGUID = db.professionCharacters, db.localCharacterIDByGUID
    local candidates = type(db.professionIndexRepairCandidates) == "table"
        and db.professionIndexRepairCandidates or {}
    local highest = 0
    for localID in pairs(oldEntries) do
        if type(localID) == "number" and localID > highest then highest = localID end
    end
    for _, localID in pairs(oldByGUID) do
        if type(localID) == "number" and localID > highest then highest = localID end
    end
    for _, candidate in pairs(candidates) do
        local localID = type(candidate) == "table" and candidate.localID or nil
        if type(localID) == "number" and localID > highest then highest = localID end
    end
    if type(db.nextLocalCharacterID) == "number" and db.nextLocalCharacterID > highest then
        highest = db.nextLocalCharacterID
    end
    local minimumNext = math.floor(highest) + 1
    if not positiveInteger(minimumNext) or minimumNext <= highest then
        db.professionIndexRepairNeeded = true
        return false, "profession-character-id-exhausted"
    end
    local nextID = db.nextLocalCharacterID
    if not positiveInteger(nextID) or nextID < minimumNext then
        nextID = minimumNext
    end

    local canonicalByGUID, ambiguous = canonicalGUIDRecords(db)
    for guid, candidate in pairs(candidates) do
        if not ambiguous[guid] or not storedRepairCandidateIsValid(db, guid, candidate) then
            candidates[guid] = nil
        end
    end
    if oldRegistryConsistent then
        for guid in pairs(ambiguous) do
            local candidate = trustedRepairCandidate(db, guid)
            if candidate then candidates[guid] = candidate end
        end
    end

    local rebuiltEntries, rebuiltByGUID = {}, {}
    local proposedNextID = nextID
    for guid, canonical in pairs(canonicalByGUID) do
        if not ambiguous[guid] then
            local localID = oldByGUID[guid]
            local previous = localID and oldEntries[localID] or nil
            if not (positiveInteger(localID) and type(previous) == "table" and previous.guid == guid) then
                localID = proposedNextID
                if not canAdvance(proposedNextID) then
                    db.professionIndexRepairNeeded = true
                    db.professionIndexRepairCandidates = candidates
                    return false, "profession-character-id-exhausted"
                end
                proposedNextID = proposedNextID + 1
            end
            rebuiltEntries[localID] = {
                guid = guid,
                key = canonical.key,
                active = type(previous) == "table" and previous.active == true,
            }
            rebuiltByGUID[guid] = localID
        end
    end
    if not recipeCatalogAssociationsRemainStable(db, rebuiltEntries, rebuiltByGUID) then
        db.professionIndexRepairCandidates = candidates
        db.professionIndexRepairNeeded = true
        return false, "profession-index-repair-needed"
    end
    db.professionCharacters, db.localCharacterIDByGUID = rebuiltEntries, rebuiltByGUID
    db.nextLocalCharacterID = proposedNextID
    db.professionIndexRepairCandidates = candidates
    db.professionIndexRepairNeeded = next(ambiguous) ~= nil or next(candidates) ~= nil
    return true
end

function GGM.ReconcileProfessionRegistry(db)
    if type(db) ~= "table" or type(db.professions) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or type(db.professionRecipeIndex) ~= "table" then
        return false, "profession-index-invalid"
    end
    if db.schemaVersion ~= nil and db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end

    local oldRegistryConsistent = registryConsistent(db)
    local registryMatches = oldRegistryConsistent and registryMatchesCanonical(db)
    if oldRegistryConsistent and registryMatches then return true, nil end
    return rebuildRegistryFromCanonical(db, oldRegistryConsistent)
end

local function rosterIdentity(api, rawName, guid)
    if not nonEmptyString(rawName) or not GGM.IsProfessionGUID(guid) then return nil end
    local name, realm = rawName:match("^([^-]+)%-(.+)$")
    if not name then
        name = rawName
        if type(api.GetRealmName) == "function" then
            local ok, currentRealm = pcall(api.GetRealmName)
            if ok then realm = currentRealm end
        end
    end
    if not nonEmptyString(name) or not nonEmptyString(realm) then return nil end
    return { key = name .. "-" .. realm, name = name, realm = realm, guid = guid }
end

local function hasUnexpectedCanonicalRecordForGUID(db, guid, sourceKey, destinationKey)
    for key, record in pairs(db.professions) do
        local identity = type(record) == "table" and record.identity or nil
        if type(identity) == "table" and identity.key == key and identity.guid == guid
            and key ~= sourceKey and key ~= destinationKey then
            return true
        end
    end
    return false
end

function GGM.ReconcileProfessionGuildRoster(api, db)
    GGM.professionRosterMembershipCurrent = false
    if type(api) ~= "table"
        or type(api.IsInGuild) ~= "function"
        or type(db) ~= "table"
        or type(db.professions) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or type(db.professionRecipeIndex) ~= "table" then
        return false, "profession-roster-unavailable"
    end

    local guildOk, inGuild = pcall(api.IsInGuild)
    if not guildOk or type(inGuild) ~= "boolean" then
        return false, "profession-roster-unavailable"
    end

    local currentByGUID, currentByKey = {}, {}
    if inGuild then
        if type(api.GetNumGuildMembers) ~= "function"
            or type(api.GetGuildRosterInfo) ~= "function" then
            return false, "profession-roster-unavailable"
        end

        local countOk, count = pcall(api.GetNumGuildMembers, true)
        if not countOk or type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
            return false, "profession-roster-unavailable"
        end
        if count == 0 then return false, "profession-roster-incomplete" end

        for index = 1, count do
            local rowOk, row = pcall(function()
                return { api.GetGuildRosterInfo(index) }
            end)
            if not rowOk then return false, "profession-roster-incomplete" end
            local identity = rosterIdentity(api, row[1], row[17])
            if not identity
                or currentByGUID[identity.guid] ~= nil
                or (currentByKey[identity.key] ~= nil and currentByKey[identity.key] ~= identity.guid) then
                return false, "profession-roster-incomplete"
            end
            currentByGUID[identity.guid] = identity
            currentByKey[identity.key] = identity.guid
        end
    end

    if not registryConsistent(db) then
        local repaired, repairErr = GGM.ReconcileProfessionRegistry(db)
        if not repaired then return false, repairErr end
    end

    -- Check all canonical key changes before touching cached membership or index state.
    for localID, entry in pairs(db.professionCharacters) do
        if type(entry) ~= "table" or not GGM.IsProfessionGUID(entry.guid)
            or db.localCharacterIDByGUID[entry.guid] ~= localID
            or type(entry.key) ~= "string" or type(entry.active) ~= "boolean" then
            return false, "profession-roster-unavailable"
        end
        local current = currentByGUID[entry.guid]
        if current and entry.key ~= current.key then
            if hasUnexpectedCanonicalRecordForGUID(db, entry.guid, entry.key, current.key) then
                db.professionIndexRepairNeeded = true
                return false, "profession-roster-rename-conflict"
            end
            local rekeyOk = GGM.RekeyProfessionCharacter(db, localID, current, true)
            if not rekeyOk then
                db.professionIndexRepairNeeded = true
                return false, "profession-roster-rename-conflict"
            end
        end
    end

    for localID, entry in pairs(db.professionCharacters) do
        local current = currentByGUID[entry.guid]
        if current then
            if entry.key ~= current.key then
                local rekeyOk = GGM.RekeyProfessionCharacter(db, localID, current)
                if not rekeyOk then
                    db.professionIndexRepairNeeded = true
                    return false, "profession-roster-rename-conflict"
                end
            end
        end
    end

    if not registryConsistent(db) or not registryMatchesCanonical(db) then
        local repaired, repairErr = GGM.ReconcileProfessionRegistry(db)
        if not repaired then return false, repairErr end
        if not registryConsistent(db) or not registryMatchesCanonical(db) then
            return false, "profession-index-invalid"
        end
    end

    for _, entry in pairs(db.professionCharacters) do
        entry.active = currentByGUID[entry.guid] ~= nil
    end

    GGM.professionRosterMembershipCurrent = true
    return true, nil
end

function GGM.EnsureProfessionIndex(db, validateFully)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return false, "database-professions-invalid"
    end
    if db.schemaVersion ~= nil and db.schemaVersion ~= GGM.SCHEMA_VERSION then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end

    if type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionIndexRepairCandidates) ~= "table"
        or type(db.professionIndexRepairNeeded) ~= "boolean"
        or not positiveInteger(db.nextLocalCharacterID)
        or db.professionRecipeIndexVersion ~= GGM.PROFESSION_RECIPE_INDEX_VERSION then
        return false, "profession-index-invalid"
    end
    if validateFully == true
        and (not registryConsistent(db)
            or not registryMatchesCanonical(db)
            or not recipeIndexConsistent(db)) then
        return false, "profession-index-invalid"
    end
    return true, nil
end

function GGM.GetProfessionRecipeCharacters(db, professionID, recipeID)
    if not positiveInteger(professionID) or not positiveInteger(recipeID) then
        return nil, "profession-recipe-query-invalid"
    end
    local ok, err = GGM.EnsureProfessionIndex(db)
    if not ok then
        return nil, err
    end
    if db.professionIndexRepairNeeded then return nil, "profession-index-repair-needed" end

    local profession = db.professionRecipeIndex[professionID]
    local recipe = type(profession) == "table" and profession[recipeID] or nil
    local results = {}
    if type(recipe) == "table" and type(recipe.crafters) == "table" then
        for _, localID in ipairs(recipe.crafters) do
            local entry = db.professionCharacters[localID]
            if type(entry) == "table" then
                table.insert(results, {
                    localCharacterID = localID,
                    guid = entry.guid,
                    key = entry.key,
                    active = entry.active == true,
                })
            end
        end
    end
    table.sort(results, function(left, right)
        return left.localCharacterID < right.localCharacterID
    end)
    return results, nil
end
