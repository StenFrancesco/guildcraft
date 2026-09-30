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

    if type(professionCharacters) == "table" then
        for localID in pairs(professionCharacters) do
            if not positiveInteger(localID) then
                return nil, "profession-character-id-invalid"
            end
            if localID > highest then highest = localID end
        end
    end

    if type(localCharacterIDByGUID) == "table" then
        for _, localID in pairs(localCharacterIDByGUID) do
            if not positiveInteger(localID) then
                return nil, "profession-character-id-invalid"
            end
            if localID > highest then highest = localID end
        end
    end

    return highest, nil
end

function GGM.InitializeProfessionIndexState(db)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return false, "database-professions-invalid"
    end

    local registryMissing = type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
    local indexMissing = type(db.professionRecipeIndex) ~= "table"

    local highestID, highestErr = highestReservedID(
        db.professionCharacters,
        db.localCharacterIDByGUID
    )
    if highestID == nil then return false, highestErr end

    local minimumNextID = highestID + 1
    if minimumNextID <= highestID or not positiveInteger(minimumNextID) then
        return false, "profession-character-id-exhausted"
    end

    local nextID = db.nextLocalCharacterID
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
    if registryMissing or indexMissing then db.professionRecipeIndexVersion = 0 end
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
    local byGUID, ambiguous = {}, {}
    for key, record in pairs(db.professions) do
        local identity = type(record) == "table" and record.identity or nil
        local guid = type(identity) == "table" and identity.guid or nil
        if GGM.IsProfessionGUID(guid) and identity.key == key then
            if byGUID[guid] and byGUID[guid].key ~= key then
                ambiguous[guid] = true
            else
                byGUID[guid] = { key = key, record = record }
            end
        end
    end
    return byGUID, ambiguous
end

local function registryMatchesCanonical(db)
    local canonicalByGUID, ambiguous = canonicalGUIDRecords(db)
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
    local highest = highestReservedRegistryID(db)
    for _, localID in pairs(oldByGUID) do
        if positiveInteger(localID) and localID > highest then highest = localID end
    end
    if positiveInteger(db.nextLocalCharacterID) and db.nextLocalCharacterID - 1 > highest then
        highest = db.nextLocalCharacterID - 1
    end
    local minimumNext = math.floor(highest) + 1
    if not positiveInteger(minimumNext) or minimumNext <= highest then
        return false, "profession-character-id-exhausted"
    end
    if not positiveInteger(db.nextLocalCharacterID) or db.nextLocalCharacterID < minimumNext then
        db.nextLocalCharacterID = minimumNext
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

    local rebuilt, dataIncomplete = {}, false
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
    if not ok then return nil, err end
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
