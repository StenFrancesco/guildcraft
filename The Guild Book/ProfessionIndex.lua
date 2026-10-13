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

local function registeredGUID(db, guid)
    if db.professionCharacters[guid] ~= nil then return guid end
end

function GGM.IsProfessionGUID(value)
    return nonEmptyString(value)
end

local function copyRegistryIdentity(identity, active)
    return { guid = identity.guid, key = identity.key, active = active == true }
end

function GGM.EnsureProfessionCharacter(db, identity)
    if type(db) ~= "table"
        or type(db.professionCharacters) ~= "table"
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

    local existingGUID = registeredGUID(db, identity.guid)
    if existingGUID ~= nil then
        if not GGM.IsProfessionGUID(existingGUID) then return nil, "profession-registry-inconsistent" end
        local entry = db.professionCharacters[existingGUID]
        if type(entry) ~= "table" or entry.guid ~= identity.guid then
            return nil, "profession-registry-inconsistent"
        end
        if entry.key ~= identity.key then return nil, "profession-registry-key-mismatch" end
        return existingGUID, nil
    end

    db.professionCharacters[identity.guid] = copyRegistryIdentity(identity, false)
    return identity.guid, nil
end

function GGM.RekeyProfessionCharacter(db, memberGUID, identity, validateOnly)
    local entry = type(db) == "table"
        and type(db.professionCharacters) == "table"
        and db.professionCharacters[memberGUID] or nil
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

    local existingGUID = registeredGUID(db, identity.guid)
    if existingGUID == nil then
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
                or db.professionCharacters[candidate.guid] ~= nil then
                db.professionIndexRepairNeeded = true
                return nil, "profession-identity-ambiguous"
            end

            local memberGUID = candidate.guid
            db.professionCharacters[memberGUID] = {
                guid = identity.guid,
                key = candidate.sourceKey,
                active = candidate.active,
            }

            local validated, validateErr = GGM.RekeyProfessionCharacter(db, memberGUID, identity, true)
            if not validated then
                db.professionCharacters[memberGUID] = nil

                db.professionIndexRepairNeeded = true
                return nil, validateErr
            end

            local rekeyed, rekeyResult = GGM.RekeyProfessionCharacter(db, memberGUID, identity)
            if not rekeyed then
                db.professionCharacters[memberGUID] = nil

                db.professionIndexRepairNeeded = true
                return nil, rekeyResult
            end

            db.professionIndexRepairCandidates[identity.guid] = nil
            local _, ambiguous, invalidCanonical = canonicalGUIDRecords(db)
            db.professionIndexRepairNeeded = next(ambiguous) ~= nil or invalidCanonical
                or next(db.professionIndexRepairCandidates) ~= nil
            return memberGUID, nil, rekeyResult
        end
        return nil, nil, false
    end

    local entry = db.professionCharacters[existingGUID]
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
        local ok, rekeyResult = GGM.RekeyProfessionCharacter(db, existingGUID, identity)
        if not ok then return nil, rekeyResult end
        db.professionIndexRepairCandidates[identity.guid] = nil
        local _, ambiguous, invalidCanonical = canonicalGUIDRecords(db)
        db.professionIndexRepairNeeded = next(ambiguous) ~= nil or invalidCanonical
            or next(db.professionIndexRepairCandidates) ~= nil
        return existingGUID, nil, rekeyResult
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

    return existingGUID, nil, false
end

function GGM.SetProfessionCharacterActive(db, memberGUID, active)
    if type(db) ~= "table" or type(db.professionCharacters) ~= "table" then
        return false, "profession-character-state-invalid"
    end
    if not GGM.IsProfessionGUID(memberGUID) or type(active) ~= "boolean" then
        return false, "profession-character-state-invalid"
    end
    local entry = db.professionCharacters[memberGUID]
    if type(entry) ~= "table" or not GGM.IsProfessionGUID(entry.guid) then
        return false, "profession-character-missing"
    end
    entry.active = active
    return true, nil
end

local function insertCrafterGUID(crafters, memberGUID)
    for position, existingGUID in ipairs(crafters) do
        if existingGUID == memberGUID then return false end
        if existingGUID > memberGUID then
            table.insert(crafters, position, memberGUID)
            return true
        end
    end
    table.insert(crafters, memberGUID)
    return true
end

local function removeCrafterGUID(crafters, memberGUID)
    for position, existingGUID in ipairs(crafters) do
        if existingGUID == memberGUID then
            table.remove(crafters, position)
            return true
        end
        if existingGUID > memberGUID then return false end
    end
    return false
end

local function addRecipeMembership(index, professionID, recipe, memberGUID)
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
    elseif recipe.outputIcon ~= nil then
        -- Recipe output icons are stable metadata keyed by recipe ID. A new
        -- capture can fill the field for older cached memberships.
        entry.outputIcon = recipe.outputIcon
    end

    insertCrafterGUID(entry.crafters, memberGUID)
end

local function removeMembershipFromProfession(index, professionID, memberGUID)
    local profession = index[professionID]
    if type(profession) ~= "table" then return end

    for recipeID, entry in pairs(profession) do
        local crafters = type(entry) == "table" and entry.crafters or nil
        if type(crafters) == "table" then
            removeCrafterGUID(crafters, memberGUID)
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

local function removeCrafterFromAllProfessions(index, memberGUID)
    local professionIDs = {}
    for professionID in pairs(index) do
        professionIDs[#professionIDs + 1] = professionID
    end
    table.sort(professionIDs)

    for _, professionID in ipairs(professionIDs) do
        removeMembershipFromProfession(index, professionID, memberGUID)
    end
end

local function purgeProfessionCharacter(db, memberGUID)
    local entry = db.professionCharacters[memberGUID]
    if type(entry) ~= "table" then return end
    if hasUnresolvedLegacyLocalMarker(db, entry.key, entry.guid) then return end

    removeCrafterFromAllProfessions(db.professionRecipeIndex, memberGUID)
    db.professions[entry.key] = nil

    db.professionCharacters[memberGUID] = nil
    if type(GGM.RemoveLocalGearMarker) == "function" then GGM.RemoveLocalGearMarker(db, entry.key) end
    if type(db.professionIndexRepairCandidates) == "table" then
        db.professionIndexRepairCandidates[entry.guid] = nil
    end
end

function GGM.ReconcileProfessionRecipeMembership(db, memberGUID, capture)
    if not GGM.IsProfessionGUID(memberGUID) then
        return false, "profession-character-guid-invalid"
    end
    local valid, err = GGM.ValidateProfessionCapture(capture)
    if not valid then return false, err end
    if type(db) ~= "table" or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionCharacters) ~= "table" then
        return false, "profession-index-invalid"
    end
    if not recipeIndexConsistent(db) then
        return false, "profession-index-invalid"
    end

    local character = db.professionCharacters[memberGUID]
    if type(character) ~= "table" or not GGM.IsProfessionGUID(character.guid) then
        return false, "profession-character-missing"
    end

    removeMembershipFromProfession(
        db.professionRecipeIndex,
        capture.professionID,
        memberGUID
    )

    for _, recipe in ipairs(capture.recipes) do
        addRecipeMembership(
            db.professionRecipeIndex,
            capture.professionID,
            recipe,
            memberGUID
        )
    end
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    return true, nil
end

local function validRegistryPair(memberGUID, entry)
    return GGM.IsProfessionGUID(memberGUID)
        and type(entry) == "table"
        and GGM.IsProfessionGUID(entry.guid)
        and nonEmptyString(entry.key)
        and type(entry.active) == "boolean"
        and entry.guid == memberGUID
end

local function registryConsistent(db)
    if type(db.professionCharacters) ~= "table" then
        return false
    end
    for memberGUID, entry in pairs(db.professionCharacters) do
        if not validRegistryPair(memberGUID, entry) then return false end
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

    local previousGUID = ""
    for position = 1, count do
        local memberGUID = rawget(crafters, position)
        local entry = db.professionCharacters[memberGUID]
        if not GGM.IsProfessionGUID(memberGUID)
            or memberGUID <= previousGUID
            or type(entry) ~= "table"
            or not GGM.IsProfessionGUID(entry.guid)
            or entry.guid ~= memberGUID then
            return false
        end
        previousGUID = memberGUID
    end

    return true
end

recipeIndexConsistent = function(db)
    if type(db) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionCharacters) ~= "table" then
        return false
    end

    for professionID, recipes in pairs(db.professionRecipeIndex) do
        if not positiveInteger(professionID) or type(recipes) ~= "table" then return false end
        for recipeID, recipe in pairs(recipes) do
            if not positiveInteger(recipeID)
                or type(recipe) ~= "table"
                or not nonEmptyString(recipe.name)
                or #recipe.name > GGM.PROFESSION_MAX_NAME_BYTES
                or (recipe.outputIcon ~= nil and not positiveInteger(recipe.outputIcon))
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
    local memberGUID = registeredGUID(db, guid)
    local entry = db.professionCharacters[memberGUID]
    if not validRegistryPair(memberGUID, entry) then return nil end
    if not hasExactlyTwoCanonicalRecords(db, guid, entry.key) then return nil end
    return { guid = memberGUID, sourceKey = entry.key, active = entry.active }
end

storedRepairCandidateIsValid = function(db, guid, candidate, destinationKey)
    return type(candidate) == "table"
        and candidate.guid == guid
        and nonEmptyString(candidate.sourceKey)
        and type(candidate.active) == "boolean"
        and hasExactlyTwoCanonicalRecords(db, guid, candidate.sourceKey, destinationKey)
end

local function recipeCatalogAssociationsRemainStable(db, rebuiltEntries)
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
            for _, memberGUID in ipairs(recipe.crafters) do
                local previous = db.professionCharacters[memberGUID]
                local rebuilt = rebuiltEntries[memberGUID]
                if type(previous) ~= "table"
                    or not GGM.IsProfessionGUID(previous.guid)
                    or previous.guid ~= memberGUID
                    or type(rebuilt) ~= "table"
                    or rebuilt.guid ~= previous.guid then
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
        if registeredGUID(db, guid) ~= nil or db.professionIndexRepairNeeded ~= true then return false end
    end
    for guid in pairs(db.professionCharacters) do
        local memberGUID = guid
        local canonical, entry = canonicalByGUID[guid], db.professionCharacters[memberGUID]
        if ambiguous[guid] or type(canonical) ~= "table" or type(entry) ~= "table"
            or canonical.key ~= entry.key then return false end
    end
    for guid in pairs(canonicalByGUID) do
        if not ambiguous[guid] and registeredGUID(db, guid) == nil then return false end
    end
    if next(ambiguous) == nil then db.professionIndexRepairNeeded = false end
    return true
end

local function rebuildRegistryFromCanonical(db, oldRegistryConsistent)
    local oldEntries = db.professionCharacters
    local candidates = type(db.professionIndexRepairCandidates) == "table"
        and db.professionIndexRepairCandidates or {}
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

    local rebuiltEntries = {}
    for guid, canonical in pairs(canonicalByGUID) do
        if not ambiguous[guid] then
            local memberGUID = guid
            local previous = oldEntries[guid]
            rebuiltEntries[memberGUID] = {
                guid = guid,
                key = canonical.key,
                active = type(previous) == "table" and previous.active == true,
            }
        end
    end
    if not recipeCatalogAssociationsRemainStable(db, rebuiltEntries) then
        db.professionIndexRepairCandidates = candidates
        db.professionIndexRepairNeeded = true
        return false, "profession-index-repair-needed"
    end
    db.professionCharacters = rebuiltEntries
    db.professionIndexRepairCandidates = candidates
    db.professionIndexRepairNeeded = next(ambiguous) ~= nil or next(candidates) ~= nil
    return true
end

function GGM.ReconcileProfessionRegistry(db)
    if type(db) ~= "table" or type(db.professions) ~= "table"
        or type(db.professionCharacters) ~= "table"
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
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.localCharacterGUIDs) ~= "table" then
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

    if not localOwnershipSetIsTrusted(db) or not recipeIndexConsistent(db) then
        return false, "profession-index-invalid"
    end

    if not registryConsistent(db) then
        local repaired, repairErr = GGM.ReconcileProfessionRegistry(db)
        if not repaired then return false, repairErr end
    end

    -- Check all canonical key changes before touching cached membership or index state.
    for memberGUID, entry in pairs(db.professionCharacters) do
        if type(entry) ~= "table" or not GGM.IsProfessionGUID(entry.guid)
            or entry.guid ~= memberGUID
            or type(entry.key) ~= "string" or type(entry.active) ~= "boolean" then
            return false, "profession-roster-unavailable"
        end
        local current = currentByGUID[entry.guid]
        if current and entry.key ~= current.key then
            if hasUnexpectedCanonicalRecordForGUID(db, entry.guid, entry.key, current.key) then
                db.professionIndexRepairNeeded = true
                return false, "profession-roster-rename-conflict"
            end
            local rekeyOk = GGM.RekeyProfessionCharacter(db, memberGUID, current, true)
            if not rekeyOk then
                db.professionIndexRepairNeeded = true
                return false, "profession-roster-rename-conflict"
            end
        end
    end

    for memberGUID, entry in pairs(db.professionCharacters) do
        local current = currentByGUID[entry.guid]
        if current then
            if entry.key ~= current.key then
                local rekeyOk = GGM.RekeyProfessionCharacter(db, memberGUID, current)
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

    local purgeGUIDs = {}
    for memberGUID, entry in pairs(db.professionCharacters) do
        if currentByGUID[entry.guid] == nil
            and not isLocallyOwnedGUID(db, entry.guid)
            and not hasUnresolvedLegacyLocalMarker(db, entry.key, entry.guid) then
            purgeGUIDs[#purgeGUIDs + 1] = memberGUID
        end
    end
    table.sort(purgeGUIDs)

    for _, entry in pairs(db.professionCharacters) do
        entry.active = currentByGUID[entry.guid] ~= nil
    end

    for _, memberGUID in ipairs(purgeGUIDs) do
        purgeProfessionCharacter(db, memberGUID)
    end

    if type(GGM.PurgeDepartedGearRecords) == "function" then GGM.PurgeDepartedGearRecords(db, currentByGUID) end
    db.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION

    GGM.professionRosterMembershipCurrent = true
    return true, nil
end

function GGM.EnsureProfessionIndex(db, validateFully, expectedSchemaVersion)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return false, "database-professions-invalid"
    end
    local requiredSchemaVersion = expectedSchemaVersion or GGM.SCHEMA_VERSION
    if db.schemaVersion ~= nil and db.schemaVersion ~= requiredSchemaVersion then
        return false, "unsupported-schema-version:" .. tostring(db.schemaVersion)
    end

    if type(db.professionCharacters) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionIndexRepairCandidates) ~= "table"
        or type(db.professionIndexRepairNeeded) ~= "boolean"
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
    local membershipCurrent = GGM.professionRosterMembershipCurrent == true
    if type(recipe) == "table" and type(recipe.crafters) == "table" then
        for _, memberGUID in ipairs(recipe.crafters) do
            local entry = db.professionCharacters[memberGUID]
            if type(entry) == "table" then
                table.insert(results, {
                    guid = memberGUID,
                    key = entry.key,
                    active = entry.active == true,
                    membershipCurrent = membershipCurrent,
                })
            end
        end
    end
    table.sort(results, function(left, right)
        return left.guid < right.guid
    end)
    return results, nil, membershipCurrent
end

local function catalogMemberOwnershipIsTrusted(db)
    if type(db) ~= "table"
        or type(db.professions) ~= "table"
        or type(db.professionCharacters) ~= "table"
        or not localOwnershipSetIsTrusted(db)
        or db.professionIndexRepairNeeded == true then
        return false
    end

    for memberGUID, entry in pairs(db.professionCharacters) do
        if not GGM.IsProfessionGUID(memberGUID)
            or type(entry) ~= "table"
            or not GGM.IsProfessionGUID(entry.guid)
            or not nonEmptyString(entry.key)
            or type(entry.active) ~= "boolean"
            or entry.guid ~= memberGUID then
            return false
        end
    end

    local canonicalByGUID = {}
    for key, record in pairs(db.professions) do
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

    for guid in pairs(db.professionCharacters) do
        local memberGUID = guid
        local canonical = canonicalByGUID[guid]
        local entry = db.professionCharacters[memberGUID]
        if not canonical or canonical.key ~= entry.key then return false end
    end
    for guid, canonical in pairs(canonicalByGUID) do
        local memberGUID = registeredGUID(db, guid)
        local entry = db.professionCharacters[memberGUID]
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
    local leftName, rightName = string.lower(left.name), string.lower(right.name)
    if leftName ~= rightName then return leftName < rightName end
    local leftRealm, rightRealm = string.lower(left.realm), string.lower(right.realm)
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
    local validSnapshotsByGUID = {}

    for memberGUID, member in pairs(db.professionCharacters) do
        if catalogCharacterEligible(db, member, membershipCurrent) then
            local canonical = db.professions[member.key]
            local snapshots = canonical.snapshots
            if type(snapshots) ~= "table" then
                if hasSnapshot ~= true then hasSnapshot = nil end
                incomplete = true
            else
                for snapshotProfessionID in pairs(snapshots) do
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
                        validSnapshotsByGUID[memberGUID] = snapshot
                    end
                end
            end
        end
    end

    local recipesByID = {}
    local indexedRecipes = db.professionRecipeIndex[professionID]
    if indexedRecipes ~= nil and type(indexedRecipes) ~= "table" then
        incomplete = true
        indexedRecipes = nil
    end

    for recipeID, indexedRecipe in pairs(indexedRecipes or {}) do
        if not positiveInteger(recipeID) or type(indexedRecipe) ~= "table"
            or not nonEmptyString(indexedRecipe.name) or type(indexedRecipe.crafters) ~= "table" then
            incomplete = true
        else
            local row = {
                recipeID = recipeID,
                name = indexedRecipe.name,
                outputIcon = indexedRecipe.outputIcon,
                knownBy = {},
            }
            for _, memberGUID in ipairs(indexedRecipe.crafters) do
                local member = db.professionCharacters[memberGUID]
                if catalogCharacterEligible(db, member, membershipCurrent) then
                    local snapshot = validSnapshotsByGUID[memberGUID]
                    if not snapshot then
                        incomplete = true
                    else
                        local canonical = db.professions[member.key]
                        row.knownBy[#row.knownBy + 1] = {
                            key = member.key,
                            name = canonical.identity.name,
                            realm = canonical.identity.realm,
                            capturedAt = snapshot.capturedAt,
                            savedDate = catalogSavedDate(api, snapshot.capturedAt),
                        }
                    end
                end
            end
            if #row.knownBy > 0 then
                table.sort(row.knownBy, catalogOwnerLess)
                recipesByID[recipeID] = row
            end
        end
    end

    local recipes = {}
    for _, recipe in pairs(recipesByID) do
        recipes[#recipes + 1] = recipe
    end
    table.sort(recipes, function(left, right)
        local leftName, rightName = string.lower(left.name), string.lower(right.name)
        if leftName ~= rightName then return leftName < rightName end
        return left.recipeID < right.recipeID
    end)

    if not membershipCurrent and not validSelectedSnapshot then
        return {
            state = "unavailable",
            hasSnapshot = nil,
            recipes = {},
            message = rosterWarning,
        }
    end

    if incomplete or hasSnapshot == nil then
        return {
            state = "incomplete",
            hasSnapshot = hasSnapshot,
            recipes = recipes,
            message = joinCatalogMessages(
                "Some saved profession data is incomplete.",
                rosterWarning
            ),
        }
    end

    if not hasSnapshot then
        return {
            state = "empty",
            hasSnapshot = false,
            recipes = recipes,
            message = "No saved " .. professionLabel
                .. " snapshots for local characters or current guild members.",
        }
    end

    if #recipes == 0 then
        return {
            state = "empty",
            hasSnapshot = true,
            recipes = recipes,
            message = joinCatalogMessages(
                "Saved " .. professionLabel
                    .. " snapshots contain no learned recipes.",
                rosterWarning
            ),
        }
    end

    return {
        state = "ready",
        hasSnapshot = true,
        recipes = recipes,
        message = rosterWarning,
    }
end

-- Stage the old numeric registry and catalog before replacing any saved tables.
-- A missing or conflicting mapping cannot safely identify a recipe owner.
function GGM.MigrateProfessionGUIDIndex(db)
    if db.professionRecipeIndexVersion == GGM.PROFESSION_RECIPE_INDEX_VERSION then
        return true, nil
    end
    if db.professionRecipeIndexVersion ~= 3
        or type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionIndexRepairCandidates) ~= "table" then
        return false, "profession-index-invalid"
    end
    local staged = {}
    for key, value in pairs(db) do staged[key] = value end
    staged.professionCharacters, staged.professionRecipeIndex, staged.professionIndexRepairCandidates = {}, {}, {}
    for oldID, entry in pairs(db.professionCharacters) do
        if not positiveInteger(oldID) or type(entry) ~= "table"
            or not GGM.IsProfessionGUID(entry.guid)
            or db.localCharacterIDByGUID[entry.guid] ~= oldID
            or staged.professionCharacters[entry.guid] ~= nil then
            return false, "profession-index-repair-needed"
        end
        staged.professionCharacters[entry.guid] = { guid = entry.guid, key = entry.key, active = entry.active }
    end
    for guid, oldID in pairs(db.localCharacterIDByGUID) do
        local entry = db.professionCharacters[oldID]
        if not positiveInteger(oldID) or type(entry) ~= "table" or entry.guid ~= guid then
            return false, "profession-index-repair-needed"
        end
    end
    for guid, candidate in pairs(db.professionIndexRepairCandidates) do
        if not GGM.IsProfessionGUID(guid) or type(candidate) ~= "table"
            or not positiveInteger(candidate.localID)
            or not nonEmptyString(candidate.sourceKey) or type(candidate.active) ~= "boolean" then
            return false, "profession-index-repair-needed"
        end
        staged.professionIndexRepairCandidates[guid] = { guid = guid, sourceKey = candidate.sourceKey, active = candidate.active }
    end
    for professionID, recipes in pairs(db.professionRecipeIndex) do
        if not positiveInteger(professionID) or type(recipes) ~= "table" then
            return false, "profession-index-invalid"
        end
        local converted = {}
        staged.professionRecipeIndex[professionID] = converted
        for recipeID, recipe in pairs(recipes) do
            if type(recipe) ~= "table" or type(recipe.crafters) ~= "table" then
                return false, "profession-index-invalid"
            end
            local crafters, count, previous = {}, 0, 0
            for position in pairs(recipe.crafters) do
                if not positiveInteger(position) then return false, "profession-index-invalid" end
                count = count + 1
            end
            for position = 1, count do
                local oldID = rawget(recipe.crafters, position)
                if not positiveInteger(oldID) or oldID <= previous then
                    return false, "profession-index-invalid"
                end
                local entry = db.professionCharacters[oldID]
                if type(entry) ~= "table" or not staged.professionCharacters[entry.guid] then
                    return false, "profession-index-repair-needed"
                end
                crafters[position], previous = entry.guid, oldID
            end
            table.sort(crafters)
            local convertedRecipe = {}
            for key, value in pairs(recipe) do convertedRecipe[key] = value end
            convertedRecipe.crafters = crafters
            converted[recipeID] = convertedRecipe
        end
    end
    staged.professionRecipeIndexVersion = GGM.PROFESSION_RECIPE_INDEX_VERSION
    staged.localCharacterIDByGUID, staged.nextLocalCharacterID = nil, nil
    local valid, err = GGM.EnsureProfessionIndex(staged, true)
    if not valid then return false, err end
    db.professionCharacters = staged.professionCharacters
    db.professionRecipeIndex = staged.professionRecipeIndex
    db.professionIndexRepairCandidates = staged.professionIndexRepairCandidates
    db.professionIndexRepairNeeded = staged.professionIndexRepairNeeded
    db.professionRecipeIndexVersion = staged.professionRecipeIndexVersion
    db.localCharacterIDByGUID, db.nextLocalCharacterID = nil, nil
    return true, nil
end
