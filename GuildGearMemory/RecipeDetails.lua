local _, GGM = ...

local MAX_MATERIAL_GROUPS = 128
local MAX_CHOICES_PER_GROUP = 64
local MAX_TOTAL_CHOICES = 256
local MAX_NAME_BYTES = 512

local function unavailable(message)
    return {
        state = "unavailable",
        message = message or "Recipe materials are unavailable.",
        materials = {},
    }
end

local function isPositiveInteger(value)
    return type(value) == "number"
        and value > 0
        and value < math.huge
        and value == math.floor(value)
end

local function isValidIcon(icon)
    if icon == nil then return true end
    if type(icon) == "number" then return isPositiveInteger(icon) end
    return type(icon) == "string" and icon ~= "" and #icon <= MAX_NAME_BYTES
end

local function getArrayLength(value, isPublic, maximum)
    if not isPublic(value) or type(value) ~= "table" then return nil end

    local count = 0
    local highestIndex = 0
    for key, entry in pairs(value) do
        if not isPublic(key) or not isPublic(entry) then return nil end
        if not isPositiveInteger(key) or key > maximum then return nil end
        count = count + 1
        if key > highestIndex then highestIndex = key end
    end

    if count ~= highestIndex then return nil end
    return count
end

local function readItemMetadata(api, itemID, isPublic)
    local name = "Item #" .. itemID
    local icon
    local itemAPI = api.C_Item
    if itemAPI == nil then return name, icon, true end
    if type(itemAPI) ~= "table" then return nil, nil, false end

    if type(itemAPI.GetItemNameByID) == "function" then
        local ok, value = pcall(itemAPI.GetItemNameByID, itemID)
        if not ok or not isPublic(value) then return nil, nil, false end
        if value ~= nil then
            if type(value) ~= "string" or #value > MAX_NAME_BYTES then
                return nil, nil, false
            end
            if value ~= "" then name = value end
        end
    end

    if type(itemAPI.GetItemIconByID) == "function" then
        local ok, value = pcall(itemAPI.GetItemIconByID, itemID)
        if not ok or not isPublic(value) or not isValidIcon(value) then
            return nil, nil, false
        end
        icon = value
    end

    return name, icon, true
end

local function readCurrencyMetadata(api, currencyID, isPublic)
    local name = "Currency #" .. currencyID
    local icon
    local currencyAPI = api.C_CurrencyInfo
    if currencyAPI == nil then return name, icon, true end
    if type(currencyAPI) ~= "table" then return nil, nil, false end
    if type(currencyAPI.GetCurrencyInfo) ~= "function" then return name, icon, true end

    local ok, info = pcall(currencyAPI.GetCurrencyInfo, currencyID)
    if not ok or not isPublic(info) then return nil, nil, false end
    if info == nil then return name, icon, true end
    if type(info) ~= "table" then return nil, nil, false end

    local infoName = rawget(info, "name")
    local infoIcon = rawget(info, "iconFileID")
    if not isPublic(infoName) or not isPublic(infoIcon) then return nil, nil, false end
    if infoName ~= nil then
        if type(infoName) ~= "string" or #infoName > MAX_NAME_BYTES then
            return nil, nil, false
        end
        if infoName ~= "" then name = infoName end
    end
    if not isValidIcon(infoIcon) then return nil, nil, false end
    icon = infoIcon
    return name, icon, true
end

local function normalizeChoice(api, reagent, isPublic)
    if not isPublic(reagent) or type(reagent) ~= "table" then return nil end

    local itemID = rawget(reagent, "itemID")
    local currencyID = rawget(reagent, "currencyID")
    if not isPublic(itemID) or not isPublic(currencyID) then return nil end

    local hasItemID = itemID ~= nil
    local hasCurrencyID = currencyID ~= nil
    if hasItemID == hasCurrencyID then return nil end

    local choice
    if hasItemID then
        if not isPositiveInteger(itemID) then return nil end
        local name, icon, valid = readItemMetadata(api, itemID, isPublic)
        if not valid then return nil end
        choice = { itemID = itemID, name = name, icon = icon,
            metadataPending = name == "Item #" .. itemID or icon == nil }
    else
        if not isPositiveInteger(currencyID) then return nil end
        local name, icon, valid = readCurrencyMetadata(api, currencyID, isPublic)
        if not valid then return nil end
        choice = { currencyID = currencyID, name = name, icon = icon }
    end

    return choice
end

function GGM.BuildRecipeMaterialDetails(api, recipeID)
    if type(api) ~= "table" then return unavailable("Recipe material APIs are unavailable.") end

    local secretCheck = api.issecretvalue
    if type(secretCheck) ~= "function" then
        return unavailable("Recipe material safety checks are unavailable.")
    end

    local function isPublic(value)
        local ok, secret = pcall(secretCheck, value)
        return ok and secret == false
    end

    if not isPublic(recipeID) or not isPositiveInteger(recipeID) then
        return unavailable("Recipe materials are unavailable.")
    end

    if type(api.InCombatLockdown) ~= "function" then
        return unavailable("Recipe materials are unavailable during combat.")
    end
    local combatOK, inCombat = pcall(api.InCombatLockdown)
    if not combatOK or not isPublic(inCombat) or inCombat ~= false then
        return unavailable("Recipe materials are unavailable during combat.")
    end

    local tradeAPI = api.C_TradeSkillUI
    if type(tradeAPI) ~= "table" or type(tradeAPI.GetRecipeSchematic) ~= "function" then
        return unavailable("Recipe material APIs are unavailable.")
    end

    local schematicOK, schematic = pcall(tradeAPI.GetRecipeSchematic, recipeID, false)
    if not schematicOK or not isPublic(schematic) or type(schematic) ~= "table" then
        return unavailable("Recipe materials are unavailable.")
    end

    local slotSchematics = rawget(schematic, "reagentSlotSchematics")
    local slotCount = getArrayLength(slotSchematics, isPublic, MAX_MATERIAL_GROUPS)
    if slotCount == nil then return unavailable("Recipe materials are unavailable.") end

    local materials = {}
    local totalChoices = 0
    for slotIndex = 1, slotCount do
        local slot = rawget(slotSchematics, slotIndex)
        if not isPublic(slot) or type(slot) ~= "table" then
            return unavailable("Recipe materials are unavailable.")
        end

        local required = rawget(slot, "required")
        local quantity = rawget(slot, "quantityRequired")
        local reagents = rawget(slot, "reagents")
        if not isPublic(required) or not isPublic(quantity) or not isPublic(reagents) then
            return unavailable("Recipe materials are unavailable.")
        end
        if type(required) ~= "boolean" or not isPositiveInteger(quantity) then
            return unavailable("Recipe materials are unavailable.")
        end

        local choiceCount = getArrayLength(reagents, isPublic, MAX_CHOICES_PER_GROUP)
        if choiceCount == nil or choiceCount == 0 then
            return unavailable("Recipe materials are unavailable.")
        end
        totalChoices = totalChoices + choiceCount
        if totalChoices > MAX_TOTAL_CHOICES then
            return unavailable("Recipe materials are unavailable.")
        end

        local choices = {}
        for choiceIndex = 1, choiceCount do
            local choice = normalizeChoice(api, rawget(reagents, choiceIndex), isPublic)
            if not choice then return unavailable("Recipe materials are unavailable.") end
            choices[#choices + 1] = choice
        end

        local groupName = choices[1].name
        local slotInfo = rawget(slot, "slotInfo")
        if not isPublic(slotInfo) then return unavailable("Recipe materials are unavailable.") end
        if slotInfo ~= nil then
            if type(slotInfo) ~= "table" then return unavailable("Recipe materials are unavailable.") end
            local slotText = rawget(slotInfo, "slotText")
            if not isPublic(slotText) then return unavailable("Recipe materials are unavailable.") end
            if slotText ~= nil then
                if type(slotText) ~= "string" or #slotText > MAX_NAME_BYTES then
                    return unavailable("Recipe materials are unavailable.")
                end
                if slotText ~= "" then groupName = slotText end
            end
        end

        materials[#materials + 1] = {
            quantity = quantity,
            optional = not required,
            name = groupName,
            choices = choices,
        }
    end

    return {
        state = "ready",
        message = nil,
        materials = materials,
    }
end
