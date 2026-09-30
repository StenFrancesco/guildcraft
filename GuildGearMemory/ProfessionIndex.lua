local _, GGM = ...

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

local function highestReservedID(professionCharacters, localCharacterIDByGUID)
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
        db.localCharacterIDByGUID
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
    db.professionIndexDataIncomplete = db.professionIndexDataIncomplete == true
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

function GGM.PrepareProfessionCharacterForSave(db, identity)
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
            if GGM.IsProfessionGUID(targetGUID) and targetGUID ~= identity.guid then
                return nil, "profession-key-collision"
            end
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
        return false, "profession-registry-invalid"
    end
    if not positiveInteger(localID) or type(active) ~= "boolean" then
        return false, "profession-character-state-invalid"
    end
    local entry = db.professionCharacters[localID]
    if type(entry) ~= "table" or not GGM.IsProfessionGUID(entry.guid) then
        return false, "profession-character-missing"
    end
    entry.active = active
    db.professionRecipeIndexVersion = 0
    return true, nil
end

local function addRecipeMembership(index, professionID, recipeID, localID)
    index[professionID] = index[professionID] or {}
    index[professionID][recipeID] = index[professionID][recipeID] or {}
    index[professionID][recipeID][localID] = true
end

local function removeMembershipFromProfession(index, professionID, localID)
    local profession = index[professionID]
    if type(profession) ~= "table" then return end

    for recipeID, bucket in pairs(profession) do
        if type(bucket) == "table" then
            bucket[localID] = nil
            if next(bucket) == nil then profession[recipeID] = nil end
        end
    end
    if next(profession) == nil then index[professionID] = nil end
end

function GGM.ReconcileProfessionRecipeMembership(db, localID, snapshot)
    if not positiveInteger(localID) then
        return false, "profession-character-id-invalid"
    end
    local valid, err = GGM.ValidateProfessionSnapshot(snapshot)
    if not valid then return false, err end
    if type(db) ~= "table" or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionCharacters) ~= "table" then
        return false, "profession-index-invalid"
    end

    removeMembershipFromProfession(db.professionRecipeIndex, snapshot.professionID, localID)
    local entry = db.professionCharacters[localID]
    if type(entry) == "table" and entry.active == true then
        for _, recipe in ipairs(snapshot.recipes) do
            addRecipeMembership(
                db.professionRecipeIndex,
                snapshot.professionID,
                recipe.recipeID,
                localID
            )
        end
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

local function snapshotHasRecipe(snapshot, recipeID)
    for _, recipe in ipairs(snapshot.recipes) do
        if recipe.recipeID == recipeID then return true end
    end
    return false
end

local function recipeIndexConsistent(db)
    if type(db.professionRecipeIndex) ~= "table" then return false end
    local dataIncomplete = false

    for professionID, recipes in pairs(db.professionRecipeIndex) do
        if not positiveInteger(professionID) or type(recipes) ~= "table" then return false end
        for recipeID, bucket in pairs(recipes) do
            if not positiveInteger(recipeID) or type(bucket) ~= "table" then return false end
            for localID, present in pairs(bucket) do
                local entry = db.professionCharacters[localID]
                local record = type(entry) == "table" and db.professions[entry.key] or nil
                local snapshot = type(record) == "table" and type(record.snapshots) == "table"
                    and record.snapshots[professionID] or nil
                if not positiveInteger(localID)
                    or present ~= true
                    or type(entry) ~= "table"
                    or entry.active ~= true
                    or type(record) ~= "table"
                    or type(record.identity) ~= "table"
                    or record.identity.guid ~= entry.guid
                    or type(snapshot) ~= "table"
                    or not GGM.ValidateProfessionSnapshot(snapshot)
                    or not snapshotHasRecipe(snapshot, recipeID) then
                    return false
                end
            end
        end
    end

    for _, entry in pairs(db.professionCharacters) do
        if entry.active == true then
            local record = db.professions[entry.key]
            if type(record) ~= "table" or type(record.identity) ~= "table"
                or record.identity.guid ~= entry.guid or type(record.snapshots) ~= "table" then
                return false
            end
            for professionID, snapshot in pairs(record.snapshots) do
                local valid = type(snapshot) == "table"
                    and professionID == snapshot.professionID
                    and GGM.ValidateProfessionSnapshot(snapshot)
                if not valid then
                    dataIncomplete = true
                else
                    for _, recipe in ipairs(snapshot.recipes) do
                        local profession = db.professionRecipeIndex[professionID]
                        local bucket = type(profession) == "table" and profession[recipe.recipeID] or nil
                        if type(bucket) ~= "table" then return false end
                        if bucket[db.localCharacterIDByGUID[entry.guid]] ~= true then return false end
                    end
                end
            end
        end
    end

    db.professionIndexDataIncomplete = dataIncomplete
    return true
end

local function canonicalGUIDRecords(db)
    local byGUID, ambiguous, invalidRecord = {}, {}, false
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
        end
    end
    return byGUID, ambiguous, invalidRecord
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

local function rebuildRegistryFromCanonical(db)
    local oldEntries, oldByGUID = db.professionCharacters, db.localCharacterIDByGUID
    local highest = 0
    for localID in pairs(oldEntries) do
        if type(localID) == "number" and localID > highest then highest = localID end
    end
    for _, localID in pairs(oldByGUID) do
        if type(localID) == "number" and localID > highest then highest = localID end
    end
    if type(db.nextLocalCharacterID) == "number" and db.nextLocalCharacterID > highest then
        highest = db.nextLocalCharacterID
    end
    local minimumNext = math.floor(highest) + 1
    if not positiveInteger(minimumNext) or minimumNext <= highest then
        return false, "profession-character-id-exhausted"
    end
    local nextID = db.nextLocalCharacterID
    if not positiveInteger(nextID) or nextID < minimumNext then
        db.nextLocalCharacterID = minimumNext
    else
        db.nextLocalCharacterID = nextID
    end

    local rebuiltEntries, rebuiltByGUID = {}, {}
    local canonicalByGUID, ambiguous = canonicalGUIDRecords(db)
    local repairNeeded = next(ambiguous) ~= nil
    for guid, canonical in pairs(canonicalByGUID) do
        if not ambiguous[guid] then
            local localID = oldByGUID[guid]
            local previous = localID and oldEntries[localID] or nil
            if not (positiveInteger(localID) and type(previous) == "table" and previous.guid == guid) then
                localID = db.nextLocalCharacterID
                if not canAdvance(localID) then return false, "profession-character-id-exhausted" end
                db.nextLocalCharacterID = localID + 1
            end
            rebuiltEntries[localID] = {
                guid = guid,
                key = canonical.key,
                active = type(previous) == "table" and previous.active == true,
            }
            rebuiltByGUID[guid] = localID
        end
    end
    db.professionCharacters, db.localCharacterIDByGUID = rebuiltEntries, rebuiltByGUID
    db.professionIndexRepairNeeded = repairNeeded
    return true
end

function GGM.RebuildProfessionRecipeIndex(db)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return false, "database-professions-invalid"
    end
    if not registryConsistent(db) or not registryMatchesCanonical(db) then
        local registryOk, registryErr = rebuildRegistryFromCanonical(db)
        if not registryOk then return false, registryErr end
    end

    local _, _, invalidCanonical = canonicalGUIDRecords(db)
    local rebuilt, dataIncomplete = {}, invalidCanonical
    for localID, entry in pairs(db.professionCharacters) do
        if entry.active == true then
            local record = db.professions[entry.key]
            if type(record) == "table" and type(record.identity) == "table"
                and record.identity.guid == entry.guid then
                if type(record.snapshots) == "table" then
                    for professionID, snapshot in pairs(record.snapshots) do
                        local valid = type(snapshot) == "table"
                            and professionID == snapshot.professionID
                            and GGM.ValidateProfessionSnapshot(snapshot)
                        if valid then
                            for _, recipe in ipairs(snapshot.recipes) do
                                addRecipeMembership(rebuilt, professionID, recipe.recipeID, localID)
                            end
                        else
                            dataIncomplete = true
                        end
                    end
                else
                    dataIncomplete = true
                end
            end
        end
    end
    db.professionRecipeIndex = rebuilt
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    db.professionIndexDataIncomplete = dataIncomplete
    return true, nil
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

    local changed = false
    for localID, entry in pairs(db.professionCharacters) do
        local current = currentByGUID[entry.guid]
        if current then
            if entry.key ~= current.key then
                local rekeyOk, rekeyed = GGM.RekeyProfessionCharacter(db, localID, current)
                if not rekeyOk then
                    db.professionIndexRepairNeeded = true
                    return false, "profession-roster-rename-conflict"
                end
                changed = changed or rekeyed
            end
            if entry.active ~= true then
                entry.active = true
                changed = true
            end
        elseif entry.active ~= false then
            entry.active = false
            changed = true
        end
    end

    if changed then
        local rebuilt, rebuildErr = GGM.RebuildProfessionRecipeIndex(db)
        if not rebuilt then return false, rebuildErr end
    end
    GGM.professionRosterMembershipCurrent = true
    return true, nil
end

function GGM.ValidateProfessionIndexCache(db)
    return registryConsistent(db) and registryMatchesCanonical(db) and recipeIndexConsistent(db)
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
        or not positiveInteger(db.nextLocalCharacterID)
        or type(db.professionRecipeIndexVersion) ~= "number" then
        local stateOk, stateErr = GGM.InitializeProfessionIndexState(db)
        if not stateOk then return false, stateErr end
    end
    db.professionIndexDataIncomplete = db.professionIndexDataIncomplete == true
    db.professionIndexRepairNeeded = db.professionIndexRepairNeeded == true

    local invalidState = type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
    local rebuild = db.professionRecipeIndexVersion ~= GGM.PROFESSION_RECIPE_INDEX_VERSION or invalidState
    if validateFully == true and not rebuild then rebuild = not GGM.ValidateProfessionIndexCache(db) end
    if rebuild then return GGM.RebuildProfessionRecipeIndex(db) end
    return true, nil
end

function GGM.GetProfessionRecipeCharacters(db, professionID, recipeID)
    if not positiveInteger(professionID) or not positiveInteger(recipeID) then
        return nil, "profession-recipe-query-invalid"
    end
    if GGM.professionRosterMembershipCurrent ~= true then
        return nil, "profession-roster-incomplete"
    end
    local ok, err = GGM.EnsureProfessionIndex(db)
    if not ok then
        if type(db) == "table" and db.professionIndexDataIncomplete then
            return nil, "profession-index-incomplete"
        end
        return nil, err
    end
    if db.professionIndexDataIncomplete then return nil, "profession-index-incomplete" end
    if db.professionIndexRepairNeeded then return nil, "profession-index-repair-needed" end

    local profession = db.professionRecipeIndex[professionID]
    local bucket = type(profession) == "table" and profession[recipeID] or nil
    local results = {}
    if type(bucket) == "table" then
        for localID in pairs(bucket) do
            local entry = db.professionCharacters[localID]
            if type(entry) == "table" and entry.active == true then
                table.insert(results, { localCharacterID = localID, guid = entry.guid, key = entry.key })
            end
        end
    end
    table.sort(results, function(left, right) return left.localCharacterID < right.localCharacterID end)
    return results, nil
end
