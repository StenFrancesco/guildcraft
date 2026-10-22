local _, GGM = ...

local function checkpoint()
    if GGM.CPUCheckpoint then GGM.CPUCheckpoint() end
end
local function sort(rows, less)
    if GGM.CPUSort then return GGM.CPUSort(rows, less) end
    return table.sort(rows, less)
end

function GGM.IsProfessionSyncInteger(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value == math.floor(value)
end

local function hashText(text)
    -- Two small polynomial hashes use integer-exact arithmetic in Lua 5.1.
    -- This is a versioned equality hint, never an authentication mechanism.
    local left, right = 5381, 17
    for index = 1, #text do
        if index % 32 == 1 then checkpoint() end
        local byte = text:byte(index)
        left = (left * 33 + byte) % 2147483647
        right = (right * 65599 + byte) % 2147483647
    end
    return string.format("%08x%08x", left, right)
end

local syncCacheByDatabase = setmetatable({}, { __mode = "k" })

local function signatureField(value)
    local kind = type(value)
    -- Cache metadata must distinguish fractional values rounded by Lua tostring.
    local text = kind == "number" and string.format("%.17g", value) or tostring(value)
    return tostring(#kind) .. ":" .. kind .. tostring(#text) .. ":" .. text
end

-- The cache is weakly keyed by database. Writers invalidate it after mutations;
-- signatures also catch direct SavedVariables edits made between reads.
function GGM.InvalidateProfessionSyncCache(db)
    if type(db) == "table" then
        syncCacheByDatabase[db] = nil
        if GGM.InvalidateCPURevision then GGM.InvalidateCPURevision(db) end
    end
end

local function cacheSignatures(db)
    local identities, metadata = {
        signatureField(db.professions), signatureField(db.professionRecipeIndex),
        signatureField(db.professionCharacters), signatureField(db.localCharacterIDByGUID),
        signatureField(db.localCharacterGUIDs), signatureField(db.professionIndexRepairCandidates),
        signatureField(db.professionRecipeIndexVersion),
    }, {}
    metadata[#metadata + 1] = signatureField(db.professionIndexRepairNeeded)
    if type(db.localCharacterGUIDs) == "table" then
        for guid, owned in pairs(db.localCharacterGUIDs) do
            checkpoint()
            metadata[#metadata + 1] = signatureField(guid) .. signatureField(owned)
        end
    end
    for localID, character in pairs(db.professionCharacters) do
        checkpoint()
        if type(character) ~= "table" then return nil, nil end
        identities[#identities + 1] = signatureField(localID) .. signatureField(character.guid) .. signatureField(character.key)
        metadata[#metadata + 1] = signatureField(localID) .. signatureField(character.active)
        local record = db.professions[character.key]
        identities[#identities + 1] = signatureField(record)
        local identity = type(record) == "table" and record.identity or nil
        metadata[#metadata + 1] = signatureField(type(identity) == "table" and identity.key or nil)
            .. signatureField(type(identity) == "table" and identity.guid or nil)
            .. signatureField(type(identity) == "table" and identity.name or nil)
            .. signatureField(type(identity) == "table" and identity.realm or nil)
        local snapshots = type(record) == "table" and record.snapshots or nil
        metadata[#metadata + 1] = signatureField(snapshots)
        if type(snapshots) == "table" then
            identities[#identities + 1] = signatureField(snapshots)
            for professionID, snapshot in pairs(snapshots) do
                checkpoint()
                metadata[#metadata + 1] = signatureField(localID) .. signatureField(professionID)
                    .. signatureField(snapshot)
                if type(snapshot) == "table" then
                    identities[#identities + 1] = signatureField(professionID) .. signatureField(snapshot)
                    metadata[#metadata + 1] = signatureField(snapshot.professionID) .. signatureField(snapshot.capturedAt)
                        .. signatureField(snapshot.complete) .. signatureField(snapshot.professionName)
                        .. signatureField(snapshot.source) .. signatureField(snapshot.status)
                        .. signatureField(snapshot.recipes)
                end
            end
        end
    end
    for professionID, recipes in pairs(db.professionRecipeIndex) do
        checkpoint()
        identities[#identities + 1] = signatureField(professionID) .. signatureField(recipes)
    end
    sort(identities)
    sort(metadata)
    return table.concat(identities, ";"), table.concat(metadata, ";")
end

local function getSyncCache(db)
    local identitySignature, metadataSignature = cacheSignatures(db)
    if not identitySignature then return nil end
    local cache = syncCacheByDatabase[db]
    if not cache then
        cache = { contentHashes = {}, manifests = {} }
        syncCacheByDatabase[db] = cache
    end
    if cache.identitySignature ~= identitySignature then
        cache.identitySignature = identitySignature
        cache.contentHashes = {}
        cache.metadataSignature = nil
        cache.manifests = {}
    elseif cache.metadataSignature ~= metadataSignature then
        cache.metadataSignature = metadataSignature
        cache.manifests = {}
    end
    cache.metadataSignature = metadataSignature
    return cache
end


function GGM.HashProfessionRecipes(professionID, recipes)
    if not GGM.IsProfessionSyncInteger(professionID, 1, 1000000) or type(recipes) ~= "table" then
        return nil, "profession-sync-membership-invalid"
    end
    local count = 0
    for key in pairs(recipes) do
        checkpoint()
        if not GGM.IsProfessionSyncInteger(key, 1, GGM.PROFESSION_MAX_RECIPES) then return nil, "profession-sync-membership-invalid" end
        count = count + 1
    end
    local parts, previous = { "P1:", tostring(professionID), ":" }, 0
    for index = 1, count do
        checkpoint()
        local row = recipes[index]
        local id = type(row) == "table" and row.recipeID or nil
        if not GGM.IsProfessionSyncInteger(id, 1, 2147483647) or id <= previous then
            return nil, "profession-sync-membership-invalid"
        end
        parts[#parts + 1] = tostring(id) .. ","
        previous = id
    end
    return hashText(table.concat(parts)), nil
end

function GGM.GetProfessionSyncRecord(db, guid, professionID)
    if type(db) ~= "table" or type(db.localCharacterIDByGUID) ~= "table"
        or type(db.professionCharacters) ~= "table" or not GGM.IsProfessionGUID(guid) then
        return nil, "profession-sync-database-invalid"
    end
    local localID = db.localCharacterIDByGUID[guid]
    local character = localID and db.professionCharacters[localID]
    if type(character) ~= "table" or character.guid ~= guid or character.active ~= true then
        return nil, "profession-sync-record-missing"
    end
    local record, err = GGM.GetProfessionRecord(db, character.key)
    if not record then return nil, err end
    local snapshot = record.snapshots[professionID]
    if not snapshot then return nil, "profession-sync-record-missing" end
    local recipes = {}
    local index = db.professionRecipeIndex[professionID]
    if index ~= nil and type(index) ~= "table" then return nil, "profession-sync-index-invalid" end
    for recipeID, entry in pairs(index or {}) do
        checkpoint()
        if type(entry) ~= "table" or type(entry.crafters) ~= "table" then return nil, "profession-sync-index-invalid" end
        for _, crafterID in ipairs(entry.crafters) do
            checkpoint()
            if crafterID == localID then
                recipes[#recipes + 1] = { recipeID = recipeID, name = entry.name, outputIcon = entry.outputIcon }
                break
            end
        end
    end
    sort(recipes, function(a, b) return a.recipeID < b.recipeID end)
    local capture = {
        guid = guid, professionID = professionID, professionName = snapshot.professionName,
        capturedAt = snapshot.capturedAt, source = snapshot.source, status = "cached", complete = true, recipes = recipes,
    }
    local valid, captureErr = GGM.ValidateProfessionCapture(capture)
    if not valid then return nil, captureErr end
    capture.hash, err = GGM.HashProfessionRecipes(professionID, recipes)
    if not capture.hash then return nil, err end
    return capture, nil
end

local function hasRecipeLabel(recipe, recipeID)
    return type(recipe.name) == "string" and recipe.name ~= "" and recipe.name ~= "Recipe " .. recipeID
end

-- Merge cached recipe knowledge without treating capture time as deletion
-- authority. The newest real observation supplies the snapshot provenance;
-- its timestamp is copied as-is and never replaced with the current time.
function GGM.MergeProfessionSyncRecord(db, identity, incoming, options)
    if type(identity) ~= "table" or type(incoming) ~= "table"
        or not GGM.IsProfessionGUID(identity.guid) or incoming.guid ~= identity.guid then
        return false, "profession-sync-identity-invalid"
    end
    local valid, validationErr = GGM.ValidateProfessionCapture(incoming)
    if not valid then return false, validationErr end
    if incoming.hash ~= nil then
        local incomingHash, hashErr = GGM.HashProfessionRecipes(incoming.professionID, incoming.recipes)
        if not incomingHash then return false, hashErr end
        if incomingHash ~= incoming.hash then return false, "profession-sync-hash-invalid" end
    end

    local current, currentErr = GGM.GetProfessionSyncRecord(db, identity.guid, incoming.professionID)
    if not current and currentErr ~= "profession-sync-record-missing" then return false, currentErr end
    if not current then
        return GGM.SaveProfessionSnapshot(db, identity, incoming, options)
    end

    local recipesByID, recipeIDs = {}, {}
    local function addRecipes(rows, preferExisting)
        for _, recipe in ipairs(rows) do
            local recipeID = recipe.recipeID
            local stored = recipesByID[recipeID]
            if not stored then
                stored = { recipeID = recipeID, name = recipe.name, outputIcon = recipe.outputIcon }
                recipesByID[recipeID] = stored
                recipeIDs[#recipeIDs + 1] = recipeID
            else
                if not hasRecipeLabel(stored, recipeID) and hasRecipeLabel(recipe, recipeID) then
                    stored.name = recipe.name
                elseif not preferExisting and not hasRecipeLabel(stored, recipeID) and recipe.name then
                    stored.name = recipe.name
                end
                if not stored.outputIcon and recipe.outputIcon then stored.outputIcon = recipe.outputIcon end
            end
        end
    end
    addRecipes(current.recipes, true)
    addRecipes(incoming.recipes, false)
    table.sort(recipeIDs)
    local recipes = {}
    for _, recipeID in ipairs(recipeIDs) do recipes[#recipes + 1] = recipesByID[recipeID] end

    local provenance = incoming.capturedAt > current.capturedAt and incoming or current
    local merged = {
        guid = identity.guid, professionID = incoming.professionID,
        professionName = provenance.professionName, capturedAt = provenance.capturedAt,
        source = provenance.source, status = "cached", complete = true, recipes = recipes,
    }
    valid, validationErr = GGM.ValidateProfessionCapture(merged)
    if not valid then return false, validationErr end
    local mergedHash, hashErr = GGM.HashProfessionRecipes(merged.professionID, merged.recipes)
    if not mergedHash then return false, hashErr end
    merged.hash = mergedHash
    return GGM.SaveProfessionSnapshot(db, identity, merged, options)
end

function GGM.GetProfessionSyncManifest(db, professionID)
    if not GGM.IsProfessionSyncInteger(professionID, 1, 1000000) then return nil, "profession-sync-id-invalid" end
    -- Warm reads still validate the full index; caching only skips rebuilding captures and hashes.
    local valid, err = GGM.EnsureProfessionIndex(db, true)
    if not valid then return nil, err end
    local cache = getSyncCache(db)
    if not cache then return nil, "profession-index-invalid" end
    local cachedRows = cache.manifests[professionID]
    if cachedRows then
        local rows = {}
        for index, row in ipairs(cachedRows.rows) do
            checkpoint()
            rows[index] = { guid = row.guid, hash = row.hash, capturedAt = row.capturedAt }
        end
        return rows, nil
    end

    local rows, captures = {}, {}
    for localID, character in pairs(db.professionCharacters) do
        checkpoint()
        if character.active == true then
            local record, recordErr = GGM.GetProfessionRecord(db, character.key)
            if not record then return nil, recordErr end
            if record.snapshots[professionID] then
                local snapshot = record.snapshots[professionID]
                captures[localID] = { guid = character.guid, complete = true, professionID = professionID,
                    professionName = snapshot.professionName, capturedAt = snapshot.capturedAt,
                    source = snapshot.source, status = "cached", recipes = {} }
            end
        end
    end
    -- Distribute each indexed membership once. Re-scanning every recipe's
    -- entire crafter list separately for every guild character is quadratic.
    local indexedRecipes, recipeIDs = db.professionRecipeIndex[professionID] or {}, {}
    for recipeID in pairs(indexedRecipes) do checkpoint(); recipeIDs[#recipeIDs + 1] = recipeID end
    sort(recipeIDs)
    for _, recipeID in ipairs(recipeIDs) do
        checkpoint()
        local entry = indexedRecipes[recipeID]
        -- Read-only temporary descriptors are shared by all captures in this build.
        local recipe = { recipeID = recipeID, name = entry.name, outputIcon = entry.outputIcon }
        for _, localID in ipairs(entry.crafters) do
            checkpoint()
            local capture = captures[localID]
            if capture then capture.recipes[#capture.recipes + 1] = recipe end
        end
    end
    for localID, capture in pairs(captures) do
        checkpoint()
        -- Memberships were distributed in ascending recipe-ID order once for all characters.
        local complete, captureErr = GGM.ValidateProfessionCapture(capture)
        if not complete then return nil, captureErr end
        local character = db.professionCharacters[localID]
        local perCharacter = cache.contentHashes[character.guid]
        if not perCharacter then perCharacter = {}; cache.contentHashes[character.guid] = perCharacter end
        local contentHash = perCharacter[professionID]
        if not contentHash then
            local hashErr
            contentHash, hashErr = GGM.HashProfessionRecipes(professionID, capture.recipes)
            if not contentHash then return nil, hashErr end
            perCharacter[professionID] = contentHash
        end
        rows[#rows + 1] = { guid = capture.guid, hash = contentHash, capturedAt = capture.capturedAt }
    end
    sort(rows, function(a, b) return a.guid < b.guid end)
    for guid in pairs(cache.contentHashes) do
        checkpoint()
        if not db.localCharacterIDByGUID[guid] then cache.contentHashes[guid] = nil end
    end
    local digest, digestErr, count = GGM.GetProfessionSyncManifestDigest(professionID, rows)
    if not digest then return nil, digestErr end
    cache.manifests[professionID] = { rows = rows, digest = digest, count = count }
    local copies = {}
    for index, row in ipairs(rows) do copies[index] = { guid = row.guid, hash = row.hash, capturedAt = row.capturedAt } end
    return copies, nil
end

function GGM.GetProfessionSyncDigest(db, professionID, members)
    local rows, err = GGM.GetProfessionSyncManifest(db, professionID)
    if not rows then return nil, err end
    local manifest = syncCacheByDatabase[db].manifests[professionID]
    if not members then return manifest.digest, nil, manifest.count end
    local signatureParts, count = {}, 0
    for _, row in ipairs(rows) do
        checkpoint()
        local included = not not members[row.guid]
        signatureParts[#signatureParts + 1] = signatureField(row.guid) .. (included and "1" or "0")
        if included then count = count + 1 end
    end
    local memberSignature = table.concat(signatureParts, ";")
    if manifest.filteredSignature == memberSignature then
        return manifest.filteredDigest, nil, manifest.filteredCount
    end
    local includedRows = {}
    for _, row in ipairs(rows) do
        checkpoint()
        if members[row.guid] then
            includedRows[#includedRows + 1] = row
        end
    end
    manifest.filteredSignature = memberSignature
    manifest.filteredDigest, err, manifest.filteredCount = GGM.GetProfessionSyncManifestDigest(professionID, includedRows)
    if not manifest.filteredDigest then return nil, err end
    return manifest.filteredDigest, nil, manifest.filteredCount
end

function GGM.GetProfessionSyncManifestDigest(professionID, rows)
    if not GGM.IsProfessionSyncInteger(professionID, 1, 1000000) or type(rows) ~= "table" then
        return nil, "profession-sync-manifest-invalid"
    end
    local parts = { "D2:", tostring(professionID), ":" }
    local count = 0
    for _, row in ipairs(rows) do
        checkpoint()
        if type(row) ~= "table" or not GGM.IsProfessionGUID(row.guid)
            or type(row.hash) ~= "string" or not row.hash:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$")
            or type(row.capturedAt) ~= "number" or row.capturedAt < 0
            or row.capturedAt ~= math.floor(row.capturedAt) then
            return nil, "profession-sync-manifest-invalid"
        end
        parts[#parts + 1] = row.guid .. ":" .. row.hash .. ":" .. row.capturedAt .. ";"
        count = count + 1
    end
    return hashText(table.concat(parts)), nil, count
end
