local _, GGM = ...

local function nonEmptyString(value)
    return type(value) == "string" and value ~= "" and #value <= GGM.PROFESSION_MAX_NAME_BYTES
end

local function nonNegativeInteger(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function positiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function denseRecipeArrayLength(recipes)
    local count = 0
    local highestIndex = 0

    for key in pairs(recipes) do
        if not positiveInteger(key) or key > GGM.PROFESSION_MAX_RECIPES then
            return nil
        end
        count = count + 1
        if key > highestIndex then highestIndex = key end
    end

    if count ~= highestIndex then return nil end
    return count
end

local function requiredTradeSkillApi(api)
    local trade = type(api) == "table" and api.C_TradeSkillUI or nil
    if type(trade) ~= "table"
        or type(trade.IsTradeSkillLinked) ~= "function"
        or type(trade.IsTradeSkillReady) ~= "function"
        or type(trade.GetBaseProfessionInfo) ~= "function"
        or type(trade.GetAllRecipeIDs) ~= "function"
        or type(trade.GetRecipeInfo) ~= "function" then
        return nil
    end
    return trade
end

local function validateProfessionMetadata(snapshot)
    if type(snapshot) ~= "table" then return false, "profession-snapshot-invalid" end
    if snapshot.complete ~= true then return false, "profession-snapshot-incomplete" end
    if not positiveInteger(snapshot.professionID) then return false, "profession-id-invalid" end
    if not nonEmptyString(snapshot.professionName) then return false, "profession-name-invalid" end
    if not nonNegativeInteger(snapshot.capturedAt) then return false, "profession-captured-at-invalid" end
    if snapshot.source ~= GGM.PROFESSION_SOURCE_GUILD_LINK
        and snapshot.source ~= GGM.PROFESSION_SOURCE_PLAYER then
        return false, "profession-source-invalid"
    end
    if snapshot.status ~= GGM.PROFESSION_CACHE_STATUS then return false, "profession-status-invalid" end
    return true, nil
end

function GGM.ValidateProfessionSnapshot(snapshot)
    local valid, err = validateProfessionMetadata(snapshot)
    if not valid then return false, err end
    if snapshot.recipes ~= nil then
        return false, "profession-snapshot-recipes-present"
    end
    return true, nil
end

function GGM.ValidateProfessionCapture(snapshot)
    local valid, err = validateProfessionMetadata(snapshot)
    if not valid then return false, err end
    if type(snapshot.recipes) ~= "table" then
        return false, "profession-recipes-invalid"
    end
    local recipeCount = denseRecipeArrayLength(snapshot.recipes)
    if recipeCount == nil then return false, "profession-recipes-invalid" end

    local previousID = 0
    for index = 1, recipeCount do
        local recipe = snapshot.recipes[index]
        if type(recipe) ~= "table" or not positiveInteger(recipe.recipeID) then
            return false, "profession-recipe-id-invalid"
        end
        if recipe.recipeID <= previousID then return false, "profession-recipes-unsorted" end
        if not nonEmptyString(recipe.name) then return false, "profession-recipe-name-invalid" end
        previousID = recipe.recipeID
    end

    return true, nil
end

function GGM.CaptureLinkedProfessionSnapshot(api, source)
    local trade = requiredTradeSkillApi(api)
    if not trade then return nil, "profession-api-unavailable" end

    source = source or GGM.PROFESSION_SOURCE_GUILD_LINK
    if source ~= GGM.PROFESSION_SOURCE_GUILD_LINK and source ~= GGM.PROFESSION_SOURCE_PLAYER then
        return nil, "profession-source-invalid"
    end

    local linkedOk, linked = pcall(trade.IsTradeSkillLinked)
    if not linkedOk then return nil, "profession-link-state-unavailable" end
    if source == GGM.PROFESSION_SOURCE_GUILD_LINK and linked ~= true then
        return nil, "profession-not-linked"
    end
    if source == GGM.PROFESSION_SOURCE_PLAYER and linked ~= false then
        return nil, "profession-not-owned"
    end

    local readyOk, ready = pcall(trade.IsTradeSkillReady)
    if not readyOk or ready ~= true then return nil, "profession-data-unavailable" end

    local infoOk, info = pcall(trade.GetBaseProfessionInfo)
    if not infoOk or type(info) ~= "table" then return nil, "profession-info-unavailable" end

    local idsOk, recipeIDs = pcall(trade.GetAllRecipeIDs)
    if not idsOk or type(recipeIDs) ~= "table" then return nil, "profession-recipes-unavailable" end

    local recipes = {}
    for _, recipeID in ipairs(recipeIDs) do
        if not positiveInteger(recipeID) then
            return nil, "profession-recipe-id-invalid"
        end

        local recipeOk, recipeInfo = pcall(trade.GetRecipeInfo, recipeID)
        if not recipeOk or type(recipeInfo) ~= "table" then
            return nil, "profession-recipe-info-unavailable"
        end

        if recipeInfo.learned == true then
            if #recipes >= GGM.PROFESSION_MAX_RECIPES then
                return nil, "profession-recipe-limit-exceeded"
            end
            table.insert(recipes, {
                recipeID = recipeInfo.recipeID or recipeID,
                name = recipeInfo.name,
            })
        elseif recipeInfo.learned ~= false then
            return nil, "profession-recipe-learned-state-unavailable"
        end
    end

    table.sort(recipes, function(left, right) return left.recipeID < right.recipeID end)

    local capturedAt = 0
    if type(api.time) == "function" then
        local timeOk, value = pcall(api.time)
        if timeOk and nonNegativeInteger(value) then capturedAt = value end
    end

    local snapshot = {
        complete = true,
        professionID = info.professionID,
        professionName = info.professionName,
        capturedAt = capturedAt,
        source = source,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = recipes,
    }

    local valid, err = GGM.ValidateProfessionCapture(snapshot)
    if not valid then return nil, err end
    return snapshot, nil
end
