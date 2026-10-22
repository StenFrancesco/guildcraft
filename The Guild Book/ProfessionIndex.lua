local _, GGM = ...
local recipeIndexConsistent
local MAX_SAFE_INTEGER = 9007199254740991
local professionValidationOperations = setmetatable({}, { __mode = "k" })
local professionRosterValidationOperations = setmetatable({}, { __mode = "k" })

local function cpuCheckpoint()
    if type(GGM.CPUCheckpoint) == "function" then GGM.CPUCheckpoint() end
end

local function cpuSort(values, comparator)
    if type(GGM.CPUSort) == "function" then
        return GGM.CPUSort(values, comparator)
    end
    return table.sort(values, comparator)
end

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
    return value < MAX_SAFE_INTEGER and positiveInteger(advanced) and advanced > value
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
    -- Registry and roster mutators invalidate before changes so partial repairs cannot leave warm rows.
    if type(GGM.InvalidateProfessionSyncCache) == "function" then GGM.InvalidateProfessionSyncCache(db) end
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

function GGM.FilterProfessionLibraryEntries(entries, db, characterKey, characterGUID)
    local filtered = {}
    if type(entries) ~= "table"
        or type(db) ~= "table"
        or type(db.professions) ~= "table"
        or not nonEmptyString(characterKey)
        or not GGM.IsProfessionGUID(characterGUID) then
        return filtered
    end

    local record = GGM.GetProfessionRecord(db, characterKey)
    if not record then
        return filtered
    end
    if record.identity.guid ~= characterGUID then
        return filtered
    end

    for _, entry in ipairs(entries) do
        if type(entry) == "table" and positiveInteger(entry.professionID) then
            local snapshot = record.snapshots[entry.professionID]
            if type(snapshot) == "table"
                and snapshot.professionID == entry.professionID
                and GGM.ValidateProfessionSnapshot(snapshot) then
                filtered[#filtered + 1] = entry
            end
        end
    end

    return filtered
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
    if type(GGM.InvalidateProfessionSyncCache) == "function" then GGM.InvalidateProfessionSyncCache(db) end
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
    if type(GGM.InvalidateProfessionSyncCache) == "function" then GGM.InvalidateProfessionSyncCache(db) end
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
    if type(GGM.InvalidateProfessionSyncCache) == "function" then GGM.InvalidateProfessionSyncCache(db) end
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
    if type(GGM.InvalidateProfessionSyncCache) == "function" then GGM.InvalidateProfessionSyncCache(db) end
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

local function crafterPosition(crafters, localID)
    -- Membership writes follow full index validation (or a consumed operation
    -- proof), which establishes a dense strictly ascending local-ID array.
    local low, high = 1, #crafters
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local existing = crafters[middle]
        if existing == localID then return middle, true end
        if existing < localID then low = middle + 1 else high = middle - 1 end
    end
    return low, false
end
local function insertCrafterID(crafters, localID)
    local position, found = crafterPosition(crafters, localID)
    if found then return false end
    table.insert(crafters, position, localID)
    return true
end
local function removeCrafterID(crafters, localID)
    local position, found = crafterPosition(crafters, localID)
    if not found then return false end
    table.remove(crafters, position)
    return true
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
            outputIcon = recipe.outputIcon,
            crafters = {},
        }
        profession[recipe.recipeID] = entry
    else
        -- ID placeholders are missing metadata. A later complete observation
        -- may supply the label even while other crafters retain this entry.
        if entry.name == "Recipe " .. recipe.recipeID and recipe.name ~= entry.name then
            entry.name = recipe.name
        end
        -- Recipe output icons are stable metadata keyed by recipe ID. A new
        -- capture can fill the field for older cached memberships.
        if recipe.outputIcon ~= nil then entry.outputIcon = recipe.outputIcon end
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

local function localOwnershipSetIsTrusted(db)
    if type(db) ~= "table" or type(db.localCharacterGUIDs) ~= "table" then
        return false
    end
    for guid, owned in pairs(db.localCharacterGUIDs) do
        cpuCheckpoint()
        if not GGM.IsProfessionGUID(guid) or owned ~= true then
            return false
        end
    end
    return true
end

local function isLocallyOwnedGUID(db, guid)
    return type(db.localCharacterGUIDs) == "table"
        and db.localCharacterGUIDs[guid] == true
end

local function hasUnresolvedLegacyLocalMarker(db, characterKey, guid)
    return type(GGM.HasUnresolvedLocalGearMarker) == "function"
        and GGM.HasUnresolvedLocalGearMarker(db, characterKey, guid)
end

local function removeCrafterFromAllProfessions(index, localID)
    local professionIDs = {}
    for professionID in pairs(index) do
        professionIDs[#professionIDs + 1] = professionID
    end
    table.sort(professionIDs)

    for _, professionID in ipairs(professionIDs) do
        removeMembershipFromProfession(index, professionID, localID)
    end
end

local function purgeProfessionCharacter(db, localID)
    if type(GGM.InvalidateProfessionSyncCache) == "function" then GGM.InvalidateProfessionSyncCache(db) end
    local entry = db.professionCharacters[localID]
    if type(entry) ~= "table" then return end
    if hasUnresolvedLegacyLocalMarker(db, entry.key, entry.guid) then return end

    removeCrafterFromAllProfessions(db.professionRecipeIndex, localID)
    db.professions[entry.key] = nil
    db.localCharacterIDByGUID[entry.guid] = nil
    db.professionCharacters[localID] = nil
    if type(GGM.RemoveLocalGearMarker) == "function" then GGM.RemoveLocalGearMarker(db, entry.key) end
    if type(db.professionIndexRepairCandidates) == "table" then
        db.professionIndexRepairCandidates[entry.guid] = nil
    end
end

local function reconcileProfessionRecipeMembership(db, localID, capture, validatedOperation)
    if type(GGM.InvalidateProfessionSyncCache) == "function" then GGM.InvalidateProfessionSyncCache(db) end
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
    if not validatedOperation and not recipeIndexConsistent(db) then
        return false, "profession-index-invalid"
    end

    local character = db.professionCharacters[localID]
    if type(character) ~= "table" or not GGM.IsProfessionGUID(character.guid) then
        return false, "profession-character-missing"
    end

    local incoming = {}
    for _, recipe in ipairs(capture.recipes) do incoming[recipe.recipeID] = true end
    local profession = db.professionRecipeIndex[capture.professionID]
    for recipeID, recipe in pairs(profession or {}) do
        if not incoming[recipeID] then
            removeCrafterID(recipe.crafters, localID)
            if #recipe.crafters == 0 then profession[recipeID] = nil end
        end
    end
    for _, recipe in ipairs(capture.recipes) do
        local existing = profession and profession[recipe.recipeID]
        if existing and #existing.crafters == 1 and existing.crafters[1] == localID then
            -- Replacing the sole owner's observation used to remove/recreate this
            -- row. Preserve its exact metadata replacement semantics in place.
            existing.name, existing.outputIcon = recipe.name, recipe.outputIcon
        else
            addRecipeMembership(db.professionRecipeIndex, capture.professionID, recipe, localID)
        end
    end
    if profession and next(profession) == nil then db.professionRecipeIndex[capture.professionID] = nil end
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    return true, nil
end

function GGM.ReconcileProfessionRecipeMembership(db, localID, capture)
    return reconcileProfessionRecipeMembership(db, localID, capture, false)
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
        cpuCheckpoint()
        if not validRegistryPair(db, localID, entry) then return false end
    end
    for guid, localID in pairs(db.localCharacterIDByGUID) do
        cpuCheckpoint()
        local entry = db.professionCharacters[localID]
        if not GGM.IsProfessionGUID(guid) or type(entry) ~= "table" or entry.guid ~= guid then
            return false
        end
    end
    return true
end

local function addMembershipFingerprint(fingerprint, position, localID)
    local leftModulus, rightModulus = 2147483647, 2147483629
    fingerprint.left = (fingerprint.left * 33 + position % leftModulus) % leftModulus
    fingerprint.left = (fingerprint.left * 33 + localID % leftModulus) % leftModulus
    fingerprint.right = (fingerprint.right * 65599 + position % rightModulus) % rightModulus
    fingerprint.right = (fingerprint.right * 65599 + localID % rightModulus) % rightModulus
    fingerprint.count = fingerprint.count + 1
end

local function crafterListConsistent(db, crafters, fingerprint)
    if type(crafters) ~= "table" or next(crafters) == nil then return false end

    local count = 0
    for position in pairs(crafters) do
        cpuCheckpoint()
        if not positiveInteger(position) then return false end
        count = count + 1
    end

    local previousID = 0
    for position = 1, count do
        cpuCheckpoint()
        local localID = rawget(crafters, position)
        local entry = db.professionCharacters[localID]
        if not positiveInteger(localID)
            or localID <= previousID
            or type(entry) ~= "table"
            or not GGM.IsProfessionGUID(entry.guid)
            or db.localCharacterIDByGUID[entry.guid] ~= localID then
            return false
        end
        if fingerprint then addMembershipFingerprint(fingerprint, position, localID) end
        previousID = localID
    end

    return true
end

recipeIndexConsistent = function(db, includeMembershipFingerprint)
    if type(db) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table" then
        return false
    end

    local fingerprint = includeMembershipFingerprint and { recipes = {} } or nil
    for professionID, recipes in pairs(db.professionRecipeIndex) do
        cpuCheckpoint()
        if not positiveInteger(professionID) or type(recipes) ~= "table" then return false end
        for recipeID, recipe in pairs(recipes) do
            cpuCheckpoint()
            if not positiveInteger(recipeID)
                or type(recipe) ~= "table"
                or not nonEmptyString(recipe.name)
                or #recipe.name > GGM.PROFESSION_MAX_NAME_BYTES
                or (recipe.outputIcon ~= nil and not positiveInteger(recipe.outputIcon)) then
                return false
            end
            local recipeFingerprint = fingerprint and {
                professionID = professionID, recipeID = recipeID,
                left = (5381 * 33 + professionID % 2147483647) % 2147483647,
                right = (17 * 65599 + professionID % 2147483629) % 2147483629,
                count = 0,
            } or nil
            if recipeFingerprint then
                recipeFingerprint.left = (recipeFingerprint.left * 33 + recipeID % 2147483647) % 2147483647
                recipeFingerprint.right = (recipeFingerprint.right * 65599 + recipeID % 2147483629) % 2147483629
            end
            if not crafterListConsistent(db, recipe.crafters, recipeFingerprint) then
                return false
            end
            if recipeFingerprint then fingerprint.recipes[#fingerprint.recipes + 1] = recipeFingerprint end
        end
    end
    if fingerprint then
        cpuSort(fingerprint.recipes, function(a, b)
            if a.professionID ~= b.professionID then return a.professionID < b.professionID end
            return a.recipeID < b.recipeID
        end)
        local left, right = 5381, 17
        for _, recipe in ipairs(fingerprint.recipes) do
            cpuCheckpoint()
            left = (left * 33 + recipe.professionID % 2147483647) % 2147483647
            left = (left * 33 + recipe.recipeID % 2147483647) % 2147483647
            left = (left * 33 + recipe.left) % 2147483647
            left = (left * 33 + recipe.count) % 2147483647
            right = (right * 65599 + recipe.professionID % 2147483629) % 2147483629
            right = (right * 65599 + recipe.recipeID % 2147483629) % 2147483629
            right = (right * 65599 + recipe.right) % 2147483629
            right = (right * 65599 + recipe.count) % 2147483629
        end
        return true, "M1:" .. left .. ":" .. right .. ":" .. #fingerprint.recipes
    end
    return true
end

canonicalGUIDRecords = function(db)
    local byGUID, ambiguous, invalidRecord, snapshotsWithoutGUID = {}, {}, false, false
    for key, record in pairs(db.professions) do
        cpuCheckpoint()
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

local function registryMatchesCanonical(db, preserveRepairNeeded)
    local canonicalByGUID, ambiguous, invalidRecord = canonicalGUIDRecords(db)
    if invalidRecord then return false end
    for guid in pairs(ambiguous) do
        cpuCheckpoint()
        if db.localCharacterIDByGUID[guid] ~= nil or db.professionIndexRepairNeeded ~= true then return false end
    end
    for guid, localID in pairs(db.localCharacterIDByGUID) do
        cpuCheckpoint()
        local canonical, entry = canonicalByGUID[guid], db.professionCharacters[localID]
        if ambiguous[guid] or type(canonical) ~= "table" or type(entry) ~= "table"
            or canonical.key ~= entry.key then return false end
    end
    for guid in pairs(canonicalByGUID) do
        cpuCheckpoint()
        if not ambiguous[guid] and db.localCharacterIDByGUID[guid] == nil then return false end
    end
    if next(ambiguous) == nil and not preserveRepairNeeded then db.professionIndexRepairNeeded = false end
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
    if type(GGM.InvalidateProfessionSyncCache) == "function" then GGM.InvalidateProfessionSyncCache(db) end
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

function GGM.PrepareProfessionRosterValidation(api, db)
    if type(api) ~= "table" or type(api.IsInGuild) ~= "function"
        or type(db) ~= "table" or type(GGM.GetCPURevision) ~= "function"
        or not GGM.EnsureProfessionIndex(db, true, nil, true)
        or not localOwnershipSetIsTrusted(db) then
        return nil, "profession-index-invalid"
    end

    local guildOk, inGuild = pcall(api.IsInGuild)
    if not guildOk or type(inGuild) ~= "boolean" then
        return nil, "profession-roster-unavailable"
    end

    local currentByGUID = {}
    if inGuild then
        if type(api.GetNumGuildMembers) ~= "function"
            or type(api.GetGuildRosterInfo) ~= "function" then
            return nil, "profession-roster-unavailable"
        end
        local countOk, count = pcall(api.GetNumGuildMembers, true)
        if not countOk or type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
            return nil, "profession-roster-unavailable"
        end
        if count == 0 then return nil, "profession-roster-incomplete" end

        local currentByKey = {}
        for index = 1, count do
            local rowOk, row = pcall(function()
                return { api.GetGuildRosterInfo(index) }
            end)
            if not rowOk then return nil, "profession-roster-incomplete" end
            local identity = rosterIdentity(api, row[1], row[17])
            if not identity or currentByGUID[identity.guid] ~= nil
                or (currentByKey[identity.key] ~= nil and currentByKey[identity.key] ~= identity.guid) then
                return nil, "profession-roster-incomplete"
            end
            currentByGUID[identity.guid] = identity
            currentByKey[identity.key] = identity.guid
            cpuCheckpoint()
        end
    end

    local unchanged = true
    for _, entry in pairs(db.professionCharacters) do
        cpuCheckpoint()
        local current = currentByGUID[entry.guid]
        if current then
            if entry.key ~= current.key or entry.active ~= true then unchanged = false end
        elseif entry.active ~= false
            or isLocallyOwnedGUID(db, entry.guid)
            or hasUnresolvedLegacyLocalMarker(db, entry.key, entry.guid) then
            if entry.active ~= false then unchanged = false end
        else
            unchanged = false
        end
    end
    if unchanged and type(db.characters) == "table" then
        for _, record in pairs(db.characters) do
            cpuCheckpoint()
            local identity = type(record) == "table" and record.identity or nil
            if type(identity) == "table" and GGM.IsProfessionGUID(identity.guid)
                and currentByGUID[identity.guid] == nil
                and not isLocallyOwnedGUID(db, identity.guid)
                and not hasUnresolvedLegacyLocalMarker(db, identity.key, identity.guid) then
                unchanged = false
                break
            end
        end
    end

    local token = {}
    professionRosterValidationOperations[token] = {
        api = api,
        db = db,
        revision = GGM.GetCPURevision(db),
        inGuild = inGuild,
        unchanged = unchanged,
        currentByGUID = currentByGUID,
        schemaVersion = db.schemaVersion,
        professions = db.professions,
        professionRecipeIndex = db.professionRecipeIndex,
        professionCharacters = db.professionCharacters,
        localCharacterIDByGUID = db.localCharacterIDByGUID,
        localCharacterGUIDs = db.localCharacterGUIDs,
        professionIndexRepairCandidates = db.professionIndexRepairCandidates,
        professionRecipeIndexVersion = db.professionRecipeIndexVersion,
        professionIndexRepairNeeded = db.professionIndexRepairNeeded,
        nextLocalCharacterID = db.nextLocalCharacterID,
    }
    return token, nil
end

local function professionRosterProofIsCurrent(db, token, operation)
    return type(operation) == "table"
        and operation.db == db
        and type(GGM.GetCPURevision) == "function"
        and GGM.GetCPURevision(db) == operation.revision
        and db.schemaVersion == operation.schemaVersion
        and db.professions == operation.professions
        and db.professionRecipeIndex == operation.professionRecipeIndex
        and db.professionCharacters == operation.professionCharacters
        and db.localCharacterIDByGUID == operation.localCharacterIDByGUID
        and db.localCharacterGUIDs == operation.localCharacterGUIDs
        and db.professionIndexRepairCandidates == operation.professionIndexRepairCandidates
        and db.professionRecipeIndexVersion == operation.professionRecipeIndexVersion
        and db.professionIndexRepairNeeded == operation.professionIndexRepairNeeded
        and db.nextLocalCharacterID == operation.nextLocalCharacterID
end

function GGM.CompleteUnchangedProfessionRosterValidation(api, db, token)
    local operation = type(token) == "table" and professionRosterValidationOperations[token] or nil
    if not operation or not operation.unchanged then return false, "changed" end
    if operation.api ~= api or not professionRosterProofIsCurrent(db, token, operation) then
        professionRosterValidationOperations[token] = nil
        return false, "profession-roster-stale"
    end
    local guildOk, inGuild = pcall(api.IsInGuild)
    if not guildOk or inGuild ~= operation.inGuild then
        professionRosterValidationOperations[token] = nil
        return false, "profession-roster-stale"
    end
    professionRosterValidationOperations[token] = nil
    GGM.professionRosterMembershipCurrent = true
    return true, nil, false
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

function GGM.ReconcileProfessionGuildRoster(api, db, validationToken)
    local rosterProof = type(validationToken) == "table"
        and professionRosterValidationOperations[validationToken] or nil
    if type(validationToken) == "table" then
        professionRosterValidationOperations[validationToken] = nil
    end
    GGM.professionRosterMembershipCurrent = false
    if type(api) ~= "table"
        or type(api.IsInGuild) ~= "function"
        or type(db) ~= "table"
        or type(db.professions) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.localCharacterGUIDs) ~= "table" then
        return false, "profession-roster-unavailable"
    end

    local proofCurrent = type(rosterProof) == "table"
        and rosterProof.db == db
        and rosterProof.api == api
        and type(GGM.GetCPURevision) == "function"
        and GGM.GetCPURevision(db) == rosterProof.revision
        and db.schemaVersion == rosterProof.schemaVersion
        and db.professions == rosterProof.professions
        and db.professionRecipeIndex == rosterProof.professionRecipeIndex
        and db.professionCharacters == rosterProof.professionCharacters
        and db.localCharacterIDByGUID == rosterProof.localCharacterIDByGUID
        and db.localCharacterGUIDs == rosterProof.localCharacterGUIDs
        and db.professionIndexRepairCandidates == rosterProof.professionIndexRepairCandidates
        and db.professionRecipeIndexVersion == rosterProof.professionRecipeIndexVersion
        and db.professionIndexRepairNeeded == rosterProof.professionIndexRepairNeeded
        and db.nextLocalCharacterID == rosterProof.nextLocalCharacterID
    local guildOk, inGuild
    if proofCurrent then
        guildOk, inGuild = pcall(api.IsInGuild)
        proofCurrent = guildOk and inGuild == rosterProof.inGuild
        if proofCurrent then inGuild = rosterProof.inGuild end
    else
        guildOk, inGuild = pcall(api.IsInGuild)
    end
    if not guildOk or type(inGuild) ~= "boolean" then
        return false, "profession-roster-unavailable"
    end

    local currentByGUID = proofCurrent and rosterProof.currentByGUID or {}
    local currentByKey = {}
    local rosterIdentityChanged = false
    if inGuild and not proofCurrent then
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

    if not localOwnershipSetIsTrusted(db) or (not proofCurrent and not recipeIndexConsistent(db)) then
        return false, "profession-index-invalid"
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
            rosterIdentityChanged = true
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
                rosterIdentityChanged = true
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

    local purgeLocalIDs = {}
    for localID, entry in pairs(db.professionCharacters) do
        if currentByGUID[entry.guid] == nil
            and not isLocallyOwnedGUID(db, entry.guid)
            and not hasUnresolvedLegacyLocalMarker(db, entry.key, entry.guid) then
            purgeLocalIDs[#purgeLocalIDs + 1] = localID
        end
    end
    if #purgeLocalIDs > 0 then rosterIdentityChanged = true end
    table.sort(purgeLocalIDs)

    for _, entry in pairs(db.professionCharacters) do
        local active = currentByGUID[entry.guid] ~= nil
        if entry.active ~= active then rosterIdentityChanged = true end
        entry.active = active
    end

    for _, localID in ipairs(purgeLocalIDs) do
        purgeProfessionCharacter(db, localID)
    end

    if type(GGM.PurgeDepartedGearRecords) == "function" then GGM.PurgeDepartedGearRecords(db, currentByGUID) end
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION

    GGM.professionRosterMembershipCurrent = true
    if rosterIdentityChanged and type(GGM.InvalidateProfessionSyncCache) == "function" then
        GGM.InvalidateProfessionSyncCache(db)
    end
    return true, nil, rosterIdentityChanged
end

function GGM.EnsureProfessionIndex(db, validateFully, expectedSchemaVersion, preserveRepairNeeded, includeMembershipFingerprint)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return false, "database-professions-invalid"
    end
    local requiredSchemaVersion = expectedSchemaVersion or GGM.SCHEMA_VERSION
    if db.schemaVersion ~= nil and db.schemaVersion ~= requiredSchemaVersion then
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
    local readOnly = preserveRepairNeeded == true
        or (GGM.IsCPUWorkActive and GGM.IsCPUWorkActive())
    local membershipFingerprint
    if validateFully == true then
        if not registryConsistent(db) or not registryMatchesCanonical(db, readOnly) then
            return false, "profession-index-invalid"
        end
        local indexValid
        indexValid, membershipFingerprint = recipeIndexConsistent(db, includeMembershipFingerprint == true)
        if not indexValid then return false, "profession-index-invalid" end
    end
    return true, nil, membershipFingerprint
end

local function validationOperationIdentityIsSafe(db, identity)
    if type(identity) ~= "table" or not nonEmptyString(identity.key)
        or not GGM.IsProfessionGUID(identity.guid)
        or db.professionIndexRepairNeeded ~= false
        or not localOwnershipSetIsTrusted(db) then
        return false
    end

    local localID = db.localCharacterIDByGUID[identity.guid]
    if localID ~= nil then
        local entry = db.professionCharacters[localID]
        local record = db.professions[identity.key]
        return type(entry) == "table"
            and entry.guid == identity.guid
            and entry.key == identity.key
            and type(record) == "table"
            and type(record.identity) == "table"
            and record.identity.key == identity.key
            and record.identity.guid == identity.guid
    end

    return db.professions[identity.key] == nil
        and db.professionIndexRepairCandidates[identity.guid] == nil
end

function GGM.PrepareProfessionValidationOperation(db, identity)
    if type(db) ~= "table" or not GGM.EnsureProfessionIndex(db, true)
        or not validationOperationIdentityIsSafe(db, identity)
        or type(GGM.GetCPURevision) ~= "function" then
        return nil, "profession-index-operation-unavailable"
    end

    local localID = db.localCharacterIDByGUID[identity.guid]
    local token = {}
    professionValidationOperations[token] = {
        db = db,
        identityKey = identity.key,
        identityGUID = identity.guid,
        revision = GGM.GetCPURevision(db),
        revisionDelta = localID == nil and 3 or 2,
        professions = db.professions,
        professionRecipeIndex = db.professionRecipeIndex,
        professionCharacters = db.professionCharacters,
        localCharacterIDByGUID = db.localCharacterIDByGUID,
        professionIndexRepairCandidates = db.professionIndexRepairCandidates,
        localCharacterGUIDs = db.localCharacterGUIDs,
        recipeIndexVersion = db.professionRecipeIndexVersion,
        schemaVersion = db.schemaVersion,
    }
    return token, nil
end

local function validationOperationStillCurrent(db, operation, identity, localID)
    local identitySafe
    if operation.revisionDelta == 3 and type(db) == "table" then
        local entry = positiveInteger(localID) and db.professionCharacters[localID] or nil
        identitySafe = db.professionIndexRepairNeeded == false
            and localOwnershipSetIsTrusted(db)
            and db.professions[operation.identityKey] == nil
            and db.professionIndexRepairCandidates[operation.identityGUID] == nil
            and type(entry) == "table"
            and entry.guid == operation.identityGUID
            and entry.key == operation.identityKey
    else
        identitySafe = validationOperationIdentityIsSafe(db, identity)
    end
    if type(operation) ~= "table" or operation.db ~= db
        or type(db) ~= "table"
        or type(GGM.GetCPURevision) ~= "function"
        or GGM.GetCPURevision(db) ~= operation.revision + operation.revisionDelta
        or operation.identityKey ~= (type(identity) == "table" and identity.key)
        or operation.identityGUID ~= (type(identity) == "table" and identity.guid)
        or db.professions ~= operation.professions
        or db.professionRecipeIndex ~= operation.professionRecipeIndex
        or db.professionCharacters ~= operation.professionCharacters
        or db.localCharacterIDByGUID ~= operation.localCharacterIDByGUID
        or db.professionIndexRepairCandidates ~= operation.professionIndexRepairCandidates
        or db.localCharacterGUIDs ~= operation.localCharacterGUIDs
        or db.professionRecipeIndexVersion ~= operation.recipeIndexVersion
        or db.schemaVersion ~= operation.schemaVersion
        or not identitySafe then
        return false
    end

    if operation.revisionDelta == 3 then
        return positiveInteger(localID)
            and db.localCharacterIDByGUID[operation.identityGUID] == localID
            and db.professionCharacters[localID].key == operation.identityKey
    end
    return db.localCharacterIDByGUID[operation.identityGUID] == localID
end

function GGM.ConsumeProfessionValidationOperation(db, token, identity)
    local operation = type(token) == "table" and professionValidationOperations[token] or nil
    if type(token) == "table" then professionValidationOperations[token] = nil end
    if type(operation) ~= "table" or operation.db ~= db
        or type(db) ~= "table"
        or type(GGM.GetCPURevision) ~= "function"
        or GGM.GetCPURevision(db) ~= operation.revision
        or operation.identityKey ~= (type(identity) == "table" and identity.key)
        or operation.identityGUID ~= (type(identity) == "table" and identity.guid)
        or db.professions ~= operation.professions
        or db.professionRecipeIndex ~= operation.professionRecipeIndex
        or db.professionCharacters ~= operation.professionCharacters
        or db.localCharacterIDByGUID ~= operation.localCharacterIDByGUID
        or db.professionIndexRepairCandidates ~= operation.professionIndexRepairCandidates
        or db.localCharacterGUIDs ~= operation.localCharacterGUIDs
        or db.professionRecipeIndexVersion ~= operation.recipeIndexVersion
        or db.schemaVersion ~= operation.schemaVersion
        or not validationOperationIdentityIsSafe(db, identity) then
        return nil
    end

    local used = false
    return function(localID, capture)
        if used or not validationOperationStillCurrent(db, operation, identity, localID) then
            return false, "profession-index-operation-stale"
        end
        used = true
        return reconcileProfessionRecipeMembership(db, localID, capture, true)
    end
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
    local membershipCurrent = GGM.professionRosterMembershipCurrent == true
    if type(recipe) == "table" and type(recipe.crafters) == "table" then
        for _, localID in ipairs(recipe.crafters) do
            local entry = db.professionCharacters[localID]
            if type(entry) == "table" then
                table.insert(results, {
                    localCharacterID = localID,
                    guid = entry.guid,
                    key = entry.key,
                    active = entry.active == true,
                    membershipCurrent = membershipCurrent,
                })
            end
        end
    end
    table.sort(results, function(left, right)
        return left.localCharacterID < right.localCharacterID
    end)
    return results, nil, membershipCurrent
end

local function catalogMemberOwnershipIsTrusted(db)
    if type(db) ~= "table"
        or type(db.professions) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or not localOwnershipSetIsTrusted(db)
        or db.professionIndexRepairNeeded == true then
        return false
    end

    for localID, entry in pairs(db.professionCharacters) do
        cpuCheckpoint()
        if not positiveInteger(localID)
            or type(entry) ~= "table"
            or not GGM.IsProfessionGUID(entry.guid)
            or not nonEmptyString(entry.key)
            or type(entry.active) ~= "boolean"
            or db.localCharacterIDByGUID[entry.guid] ~= localID then
            return false
        end
    end

    for guid, localID in pairs(db.localCharacterIDByGUID) do
        cpuCheckpoint()
        local entry = db.professionCharacters[localID]
        if not GGM.IsProfessionGUID(guid)
            or not positiveInteger(localID)
            or type(entry) ~= "table"
            or entry.guid ~= guid then
            return false
        end
    end

    local canonicalByGUID = {}
    for key, record in pairs(db.professions) do
        cpuCheckpoint()
        local identity = type(record) == "table" and record.identity or nil
        if type(identity) ~= "table"
            or identity.key ~= key
            or not nonEmptyString(identity.name)
            or not nonEmptyString(identity.realm)
            or key ~= identity.name .. "-" .. identity.realm then
            return false
        end

        if GGM.IsProfessionGUID(identity.guid) then
            if canonicalByGUID[identity.guid] ~= nil then return false end
            canonicalByGUID[identity.guid] = { key = key, identity = identity }
        elseif (type(record.snapshots) == "table" and next(record.snapshots) ~= nil)
            or (record.snapshots ~= nil and type(record.snapshots) ~= "table") then
            return false
        end
    end

    for guid, localID in pairs(db.localCharacterIDByGUID) do
        cpuCheckpoint()
        local canonical = canonicalByGUID[guid]
        local entry = db.professionCharacters[localID]
        if not canonical or canonical.key ~= entry.key then return false end
    end
    for guid, canonical in pairs(canonicalByGUID) do
        cpuCheckpoint()
        local localID = db.localCharacterIDByGUID[guid]
        local entry = db.professionCharacters[localID]
        if not entry or entry.key ~= canonical.key then return false end
    end

    return true
end

local function catalogSavedDate(api, capturedAt)
    if capturedAt <= 0 or type(api) ~= "table" or type(api.date) ~= "function" then
        return "Date unavailable"
    end
    local ok, value = pcall(api.date, "%Y-%m-%d", capturedAt)
    if not ok or not nonEmptyString(value) then return "Date unavailable" end
    return value
end

local function catalogOwnerLess(left, right)
    local leftName, rightName = left.searchName, right.searchName
    if leftName ~= rightName then return leftName < rightName end
    local leftRealm, rightRealm = left.searchRealm, right.searchRealm
    if leftRealm ~= rightRealm then return leftRealm < rightRealm end
    return left.key < right.key
end

local function catalogCharacterEligible(db, member, membershipCurrent)
    if type(member) ~= "table" then return false end
    return isLocallyOwnedGUID(db, member.guid)
        or (membershipCurrent and member.active == true)
end

local function joinCatalogMessages(primary, secondary)
    if primary and secondary then return primary .. " " .. secondary end
    return primary or secondary
end

local function unconfirmedRosterMessage()
    return "Current guild membership could not be confirmed. Showing saved local characters only."
end

-- Runtime-only, bounded to the professions being browsed. Keep validated input
-- copies so in-place edits and repairs cannot serve an old model. Full validation
-- remains below; reducing its cost is a separate operation.
local catalogCaches = setmetatable({}, { __mode = "k" })
local function sameCatalogInput(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        cpuCheckpoint()
        if not sameCatalogInput(value, right[key]) then return false end
    end
    for key in pairs(right) do
        cpuCheckpoint()
        if left[key] == nil then return false end
    end
    return true
end

local function catalogInput(db, professionLabel, api, snapshots, hasSnapshot, incomplete)
    local owners, eligible = {}, {}
    for localID, member in pairs(db.professionCharacters) do
        cpuCheckpoint()
        eligible[localID] = catalogCharacterEligible(db, member, GGM.professionRosterMembershipCurrent == true)
    end
    for localID, snapshot in pairs(snapshots) do
        cpuCheckpoint()
        local member = db.professionCharacters[localID]
        local identity = db.professions[member.key].identity
        owners[localID] = {
            key = member.key, name = identity.name, realm = identity.realm,
            capturedAt = snapshot.capturedAt,
        }
    end
    return {
        owners = owners, eligible = eligible, hasSnapshot = hasSnapshot, incomplete = incomplete,
        membershipCurrent = GGM.professionRosterMembershipCurrent == true,
        label = professionLabel, date = type(api) == "table" and api.date or nil,
    }
end

local function sameCatalogRecipes(saved, current)
    local count = 0
    for id, recipe in pairs(current or {}) do
        cpuCheckpoint()
        count = count + 1
        local previous = saved[id]
        if not previous or previous.name ~= recipe.name or previous.outputIcon ~= recipe.outputIcon
            or #previous.crafters ~= #recipe.crafters then return false end
        for index, localID in ipairs(recipe.crafters) do
            cpuCheckpoint()
            if previous.crafters[index] ~= localID then return false end
        end
    end
    return count == saved.count
end

local function copyCatalogRecipes(recipes)
    local result = { count = 0 }
    for id, recipe in pairs(recipes or {}) do
        cpuCheckpoint()
        local crafters = {}
        for index, localID in ipairs(recipe.crafters) do
            cpuCheckpoint()
            crafters[index] = localID
        end
        result[id] = { name = recipe.name, outputIcon = recipe.outputIcon, crafters = crafters }
        result.count = result.count + 1
    end
    return result
end

function GGM.BuildProfessionRecipeCatalog(db, professionID, professionLabel, api)
    local emptyModel = {
        state = "unavailable",
        hasSnapshot = nil,
        recipes = {},
        message = nil,
    }

    if not positiveInteger(professionID)
        or not nonEmptyString(professionLabel)
        or not catalogMemberOwnershipIsTrusted(db) then
        emptyModel.message = "Saved profession character identities could not be confirmed."
        return emptyModel
    end

    local indexValid = GGM.EnsureProfessionIndex(db, true)
    if not indexValid then
        emptyModel.message = "Saved profession data could not be verified."
        return emptyModel
    end

    local membershipCurrent = GGM.professionRosterMembershipCurrent == true
    local rosterWarning
    if not membershipCurrent then
        rosterWarning = unconfirmedRosterMessage()
    end
    local hasSnapshot, incomplete = false, false
    local validSelectedSnapshot = false
    local validSnapshotsByLocalID = {}

    for localID, member in pairs(db.professionCharacters) do
        cpuCheckpoint()
        if catalogCharacterEligible(db, member, membershipCurrent) then
            local canonical = db.professions[member.key]
            local snapshots = canonical.snapshots
            if type(snapshots) ~= "table" then
                if hasSnapshot ~= true then hasSnapshot = nil end
                incomplete = true
            else
                for snapshotProfessionID in pairs(snapshots) do
                    cpuCheckpoint()
                    if not positiveInteger(snapshotProfessionID) then
                        if hasSnapshot ~= true then hasSnapshot = nil end
                        incomplete = true
                    end
                end
                local snapshot = rawget(snapshots, professionID)
                if snapshot ~= nil then
                    hasSnapshot = true
                    local valid = type(snapshot) == "table"
                        and snapshot.professionID == professionID
                        and GGM.ValidateProfessionSnapshot(snapshot)
                    if not valid then
                        incomplete = true
                    else
                        validSelectedSnapshot = true
                        validSnapshotsByLocalID[localID] = snapshot
                    end
                end
            end
        end
    end

    local input = catalogInput(db, professionLabel, api, validSnapshotsByLocalID, hasSnapshot, incomplete)
    local cache = catalogCaches[db]
    local cached = cache and cache[professionID]
    if cached and sameCatalogInput(cached.input, input)
        and sameCatalogRecipes(cached.recipes, db.professionRecipeIndex[professionID]) then return cached.model end
    if not cache then cache = {}; catalogCaches[db] = cache end
    local ownersByLocalID = {}
    local function publish(model)
        -- A caller can request arbitrary IDs; retain at most twelve catalog models.
        if not cache[professionID] then
            cache.order = cache.order or {}
            cache.order[#cache.order + 1] = professionID
            if #cache.order > 12 then cache[table.remove(cache.order, 1)] = nil end
        end
        cache[professionID] = {
            input = input, recipes = copyCatalogRecipes(db.professionRecipeIndex[professionID]),
            owners = ownersByLocalID, model = model,
        }
        return model
    end
    for localID, owner in pairs(input.owners) do
        cpuCheckpoint()
        if cached and cached.input.date == input.date
            and sameCatalogInput(cached.input.owners[localID], owner) then
            ownersByLocalID[localID] = cached.owners[localID]
        else
            ownersByLocalID[localID] = {
                key = owner.key, name = owner.name, realm = owner.realm,
                searchName = string.lower(owner.name), searchRealm = string.lower(owner.realm),
                capturedAt = owner.capturedAt, savedDate = catalogSavedDate(api, owner.capturedAt),
            }
        end
    end
    -- Dense catalogs share the same owner order. Sort it once rather than
    -- sorting hundreds of equivalent owner lists for every recipe.
    local sortedOwners, ownerEpoch = {}, {}
    for _, owner in pairs(ownersByLocalID) do cpuCheckpoint(); sortedOwners[#sortedOwners + 1] = owner end
    cpuSort(sortedOwners, catalogOwnerLess)
    local recipesByID = {}
    local indexedRecipes = db.professionRecipeIndex[professionID]
    if indexedRecipes ~= nil and type(indexedRecipes) ~= "table" then
        incomplete = true
        indexedRecipes = nil
    end

    for recipeID, indexedRecipe in pairs(indexedRecipes or {}) do
        cpuCheckpoint()
        if not positiveInteger(recipeID) or type(indexedRecipe) ~= "table"
            or not nonEmptyString(indexedRecipe.name) or type(indexedRecipe.crafters) ~= "table" then
            incomplete = true
        else
            local row = {
                recipeID = recipeID,
                name = indexedRecipe.name,
                searchName = string.lower(indexedRecipe.name),
                outputIcon = indexedRecipe.outputIcon,
                knownBy = {},
            }
            for _, localID in ipairs(indexedRecipe.crafters) do
                cpuCheckpoint()
                local member = db.professionCharacters[localID]
                if catalogCharacterEligible(db, member, membershipCurrent) then
                    local snapshot = validSnapshotsByLocalID[localID]
                    if not snapshot then
                        incomplete = true
                    else
                        row.knownBy[#row.knownBy + 1] = ownersByLocalID[localID]
                    end
                end
            end
            if #row.knownBy > 0 then
                if #row.knownBy > 16 and #sortedOwners <= #row.knownBy * 4 then
                    for _, owner in ipairs(row.knownBy) do cpuCheckpoint(); ownerEpoch[owner] = recipeID end
                    local position = 1
                    for _, owner in ipairs(sortedOwners) do
                        cpuCheckpoint()
                        if ownerEpoch[owner] == recipeID then row.knownBy[position] = owner; position = position + 1 end
                    end
                else
                    cpuSort(row.knownBy, catalogOwnerLess)
                end
                recipesByID[recipeID] = row
            end
        end
    end

    local recipes = {}
    for _, recipe in pairs(recipesByID) do
        cpuCheckpoint()
        recipes[#recipes + 1] = recipe
    end
    cpuSort(recipes, function(left, right)
        local leftName, rightName = left.searchName, right.searchName
        if leftName ~= rightName then return leftName < rightName end
        return left.recipeID < right.recipeID
    end)

    if not membershipCurrent and not validSelectedSnapshot then
        return publish({
            state = "unavailable",
            hasSnapshot = nil,
            recipes = {},
            message = rosterWarning,
        })
    end

    if incomplete or hasSnapshot == nil then
        return publish({
            state = "incomplete",
            hasSnapshot = hasSnapshot,
            recipes = recipes,
            message = joinCatalogMessages(
                "Some saved profession data is incomplete.",
                rosterWarning
            ),
        })
    end

    if not hasSnapshot then
        return publish({
            state = "empty",
            hasSnapshot = false,
            recipes = recipes,
            message = "No saved " .. professionLabel
                .. " snapshots for local characters or current guild members.",
        })
    end

    if #recipes == 0 then
        return publish({
            state = "empty",
            hasSnapshot = true,
            recipes = recipes,
            message = joinCatalogMessages(
                "Saved " .. professionLabel
                    .. " snapshots contain no learned recipes.",
                rosterWarning
            ),
        })
    end

    return publish({
        state = "ready",
        hasSnapshot = true,
        recipes = recipes,
        message = rosterWarning,
    })
end
