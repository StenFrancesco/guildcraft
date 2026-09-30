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
