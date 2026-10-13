local _, GGM = ...

function GGM.IsProfessionSyncInteger(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value == math.floor(value)
end

local function hashText(text)
    -- Two small polynomial hashes use integer-exact arithmetic in Lua 5.1.
    -- This is a versioned equality hint, never an authentication mechanism.
    local left, right = 5381, 17
    for index = 1, #text do
        local byte = text:byte(index)
        left = (left * 33 + byte) % 2147483647
        right = (right * 65599 + byte) % 2147483647
    end
    return string.format("%08x%08x", left, right)
end

function GGM.HashProfessionRecipes(professionID, recipes)
    if not GGM.IsProfessionSyncInteger(professionID, 1, 1000000) or type(recipes) ~= "table" then
        return nil, "profession-sync-membership-invalid"
    end
    local count = 0
    for key in pairs(recipes) do
        if not GGM.IsProfessionSyncInteger(key, 1, GGM.PROFESSION_MAX_RECIPES) then return nil, "profession-sync-membership-invalid" end
        count = count + 1
    end
    local parts, previous = { "P1:", tostring(professionID), ":" }, 0
    for index = 1, count do
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
        if type(entry) ~= "table" or type(entry.crafters) ~= "table" then return nil, "profession-sync-index-invalid" end
        for _, crafterID in ipairs(entry.crafters) do
            if crafterID == localID then
                recipes[#recipes + 1] = { recipeID = recipeID, name = entry.name, outputIcon = entry.outputIcon }
                break
            end
        end
    end
    table.sort(recipes, function(a, b) return a.recipeID < b.recipeID end)
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

function GGM.GetProfessionSyncManifest(db, professionID)
    if not GGM.IsProfessionSyncInteger(professionID, 1, 1000000) then return nil, "profession-sync-id-invalid" end
    local valid, err = GGM.EnsureProfessionIndex(db, true)
    if not valid then return nil, err end
    local rows, captures = {}, {}
    for localID, character in pairs(db.professionCharacters) do
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
    for recipeID, entry in pairs(db.professionRecipeIndex[professionID] or {}) do
        for _, localID in ipairs(entry.crafters) do
            local capture = captures[localID]
            if capture then capture.recipes[#capture.recipes + 1] = { recipeID = recipeID, name = entry.name, outputIcon = entry.outputIcon } end
        end
    end
    for _, capture in pairs(captures) do
        table.sort(capture.recipes, function(a, b) return a.recipeID < b.recipeID end)
        local complete, captureErr = GGM.ValidateProfessionCapture(capture)
        if not complete then return nil, captureErr end
        local contentHash, hashErr = GGM.HashProfessionRecipes(professionID, capture.recipes)
        if not contentHash then return nil, hashErr end
        rows[#rows + 1] = { guid = capture.guid, hash = contentHash, capturedAt = capture.capturedAt }
    end
    table.sort(rows, function(a, b) return a.guid < b.guid end)
    return rows, nil
end

function GGM.GetProfessionSyncDigest(db, professionID)
    local rows, err = GGM.GetProfessionSyncManifest(db, professionID)
    if not rows then return nil, err end
    local parts = { "D1:", tostring(professionID), ":" }
    for _, row in ipairs(rows) do parts[#parts + 1] = row.guid .. ":" .. row.hash .. ";" end
    return hashText(table.concat(parts)), nil, #rows
end
