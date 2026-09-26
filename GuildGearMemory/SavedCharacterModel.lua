local _, GGM = ...

local VISUAL_SLOTS = {
    { key = "HEAD", id = 1 },
    { key = "SHOULDER", id = 3 },
    { key = "CHEST", id = 5 },
    { key = "WAIST", id = 6 },
    { key = "LEGS", id = 7 },
    { key = "FEET", id = 8 },
    { key = "WRIST", id = 9 },
    { key = "HANDS", id = 10 },
    { key = "BACK", id = 15 },
    { key = "MAIN_HAND", id = 16, handGlobal = "MAINHANDSLOT" },
    { key = "OFF_HAND", id = 17, handGlobal = "SECONDARYHANDSLOT" },
    { key = "TABARD", id = 19 },
}

local function positiveInteger(value, maximum)
    return type(value) == "number"
        and value > 0
        and value == math.floor(value)
        and (maximum == nil or value <= maximum)
end

local function hide(model)
    if type(model) ~= "table" and type(model) ~= "userdata" then return false end
    if type(model.Hide) ~= "function" then return false end
    return pcall(model.Hide, model)
end

local function undress(model)
    if type(model.Undress) ~= "function" then return false end
    local ok, result = pcall(model.Undress, model)
    return ok and result ~= false
end

local function callSucceeded(target, methodName, ...)
    if type(target[methodName]) ~= "function" then return false end
    local ok, result = pcall(target[methodName], target, ...)
    return ok and result ~= false
end

local function tryOnSucceeded(api, result)
    local enum = type(api) == "table" and api.Enum or nil
    local reasons = type(enum) == "table" and enum.ItemTryOnReason or nil
    return type(reasons) == "table" and reasons.Success ~= nil and result == reasons.Success
end

local function renderUnavailable(view)
    if type(view) == "table" and view.model then
        hide(view.model)
        undress(view.model)
    end
    return "render-unavailable"
end

function GGM.CreateSavedCharacterModel(api, parent)
    local model
    if type(api) == "table" and type(api.CreateFrame) == "function" then
        local ok, created = pcall(api.CreateFrame, "DressUpModel", nil, parent)
        if ok then model = created end
    end

    return {
        api = api,
        parent = parent,
        model = model,
    }
end

function GGM.ClearSavedCharacterModel(view)
    if type(view) ~= "table" or not view.model then return false end
    local hidden = hide(view.model)
    local cleared = undress(view.model)
    return hidden and cleared
end

function GGM.RenderSavedCharacterModel(view, record)
    if type(view) ~= "table" or not view.model then return "render-unavailable" end
    local model = view.model
    local api = view.api
    local cleared = GGM.ClearSavedCharacterModel(view)

    if type(record) ~= "table" or type(record.identity) ~= "table" then
        return "identity-unavailable"
    end
    local identity = record.identity
    if not positiveInteger(identity.raceID, 255)
        or (identity.sex ~= 2 and identity.sex ~= 3)
        or not positiveInteger(identity.displayID, 2147483647) then
        return "identity-unavailable"
    end
    if not cleared then return renderUnavailable(view) end
    if not callSucceeded(model, "SetDisplayInfo", identity.displayID) then
        return renderUnavailable(view)
    end

    local gear = record.gear
    local slots = type(gear) == "table" and gear.slots or nil
    if type(slots) ~= "table" then return renderUnavailable(view) end
    for _, visualSlot in ipairs(VISUAL_SLOTS) do
        local saved = slots[visualSlot.key]
        if type(saved) ~= "table" or saved.unavailable == true
            or saved.inventorySlotID ~= visualSlot.id then
            return renderUnavailable(view)
        end

        if saved.itemID == false and saved.itemLink == false then
            if not callSucceeded(model, "UndressSlot", visualSlot.id) then
                return renderUnavailable(view)
            end
        elseif positiveInteger(saved.itemID) and type(saved.itemLink) == "string" and saved.itemLink ~= "" then
            if type(api) ~= "table" or type(api.GetItemInfo) ~= "function" then
                return renderUnavailable(view)
            end
            local infoOK, itemName = pcall(api.GetItemInfo, saved.itemLink)
            if not infoOK or type(itemName) ~= "string" or itemName == "" then
                return renderUnavailable(view)
            end
            if type(model.TryOn) ~= "function" then return renderUnavailable(view) end
            local handSlotName
            if visualSlot.handGlobal then
                handSlotName = api[visualSlot.handGlobal]
                if type(handSlotName) ~= "string" or handSlotName == "" then
                    return renderUnavailable(view)
                end
            end
            local tryOK, tryResult
            if handSlotName then
                tryOK, tryResult = pcall(model.TryOn, model, saved.itemLink, handSlotName)
            else
                tryOK, tryResult = pcall(model.TryOn, model, saved.itemLink)
            end
            if not tryOK or not tryOnSucceeded(api, tryResult) then return renderUnavailable(view) end
        else
            return renderUnavailable(view)
        end
    end

    local showOK = pcall(model.Show, model)
    if not showOK then
        hide(model)
        undress(model)
        return renderUnavailable(view)
    end
    return "shown"
end
