local _, GGM = ...

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function positiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

function GGM.InitializeProfessionIndexState(db)
    if type(db) ~= "table" or type(db.professions) ~= "table" then
        return false, "database-professions-invalid"
    end

    local registryMissing = type(db.professionCharacters) ~= "table"
        or type(db.localCharacterIDByGUID) ~= "table"
    local indexMissing = type(db.professionRecipeIndex) ~= "table"

    db.nextLocalCharacterID = positiveInteger(db.nextLocalCharacterID)
        and db.nextLocalCharacterID or 1
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
