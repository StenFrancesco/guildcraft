local _, GGM = ...

local function positiveInteger(value, maximum)
    return type(value) == "number"
        and value > 0
        and value == math.floor(value)
        and (maximum == nil or value <= maximum)
end

local function safeHide(control)
    if control and type(control.Hide) == "function" then pcall(control.Hide, control) end
end

local function safeShow(control)
    if control and type(control.Show) == "function" then pcall(control.Show, control) end
end

local function raceInfoFor(api, raceID)
    if not positiveInteger(raceID, 255) then return nil end
    local creatureInfo = type(api) == "table" and api.C_CreatureInfo or nil
    if type(creatureInfo) ~= "table" or type(creatureInfo.GetRaceInfo) ~= "function" then return nil end
    local ok, info = pcall(creatureInfo.GetRaceInfo, raceID)
    if ok and type(info) == "table" then return info end
    return nil
end

local function raceNameFor(api, raceID)
    local info = raceInfoFor(api, raceID)
    if info and type(info.raceName) == "string" and info.raceName ~= "" then
        return info.raceName
    end
    return positiveInteger(raceID, 255) and ("Race " .. tostring(raceID)) or "Race unavailable"
end

local function sexNameFor(sex)
    if sex == 2 then return "Male" end
    if sex == 3 then return "Female" end
    return "Gender unavailable"
end

-- Built-in Classic class artwork; the sheet also supports clients without atlases.
local CLASS_TCOORDS = {
    WARRIOR = {0, 0.25, 0, 0.25},
    MAGE = {0.25, 0.49609375, 0, 0.25},
    ROGUE = {0.49609375, 0.7421875, 0, 0.25},
    DRUID = {0.7421875, 0.98828125, 0, 0.25},
    HUNTER = {0, 0.25, 0.25, 0.5},
    SHAMAN = {0.25, 0.49609375, 0.25, 0.5},
    PRIEST = {0.49609375, 0.7421875, 0.25, 0.5},
    WARLOCK = {0.7421875, 0.98828125, 0.25, 0.5},
    PALADIN = {0, 0.25, 0.5, 0.75},
}

local function classicClassToken(value)
    if type(value) ~= "string" then return nil end
    value = value:upper()
    return CLASS_TCOORDS[value] and value or nil
end

local function normalizedCharacterKey(value)
    return type(value) == "string" and value:gsub("%s", ""):lower() or nil
end

local function selectedClassToken(api, identity)
    local savedToken = classicClassToken(identity.classToken)
    if savedToken then return savedToken end
    if type(api) ~= "table" then return nil end
    local guid = type(identity.guid) == "string" and identity.guid ~= "" and identity.guid or nil
    if guid and type(api.GetPlayerInfoByGUID) == "function" then
        local ok, _, classToken = pcall(api.GetPlayerInfoByGUID, guid)
        if ok and classicClassToken(classToken) then return classicClassToken(classToken) end
    end
    if guid and type(api.UnitGUID) == "function" and type(api.UnitClass) == "function" then
        local ok, playerGUID = pcall(api.UnitGUID, "player")
        if ok and playerGUID == guid then
            local classOK, _, classToken = pcall(api.UnitClass, "player")
            if classOK and classicClassToken(classToken) then return classicClassToken(classToken) end
        end
    end
    if type(api.GetNumGuildMembers) ~= "function" or type(api.GetGuildRosterInfo) ~= "function" then return nil end
    local countOK, count = pcall(api.GetNumGuildMembers, true)
    if not countOK or not positiveInteger(count, 1000) then return nil end
    local localRealm
    if type(api.GetRealmName) == "function" then
        local ok, realm = pcall(api.GetRealmName)
        if ok and type(realm) == "string" and realm ~= "" then localRealm = realm end
    end
    local selectedKey = normalizedCharacterKey(identity.key)
    for index = 1, count do
        local ok, row = pcall(function() return { api.GetGuildRosterInfo(index) } end)
        if ok then
            local rowGUID = type(row[17]) == "string" and row[17] ~= "" and row[17] or nil
            local matches = guid and rowGUID and guid == rowGUID
            -- Only use names when a GUID comparison is unavailable, and include the realm.
            if not (guid and rowGUID) and selectedKey and type(row[1]) == "string" then
                local name = row[1]
                if not name:find("-", 1, true) and localRealm then name = name .. "-" .. localRealm end
                matches = normalizedCharacterKey(name) == selectedKey
            end
            if matches and classicClassToken(row[11]) then return classicClassToken(row[11]) end
        end
    end
    return nil
end

local function clearPortraitTexture(view)
    if not view or not view.portrait then return end
    if type(view.portrait.SetTexture) == "function" then
        pcall(view.portrait.SetTexture, view.portrait, nil)
    end
    if type(view.portrait.SetTexCoord) == "function" then
        pcall(view.portrait.SetTexCoord, view.portrait, 0, 1, 0, 1)
    end
end

local function showBlankPortrait(view)
    clearPortraitTexture(view)
    if view and view.portrait and type(view.portrait.SetColorTexture) == "function" then
        pcall(view.portrait.SetColorTexture, view.portrait, 0.085, 0.085, 0.100, 1)
    end
    safeShow(view and view.questionMark)
end

local function atlasExists(api, atlas)
    local textureAPI = type(api) == "table" and api.C_Texture or nil
    if type(textureAPI) ~= "table" or type(textureAPI.GetAtlasInfo) ~= "function" then return false end
    local ok, info = pcall(textureAPI.GetAtlasInfo, atlas)
    return ok and type(info) == "table"
end

local function setVerifiedAtlas(view, atlas)
    if not view or not view.portrait or type(view.portrait.SetAtlas) ~= "function" then return false end
    if not atlasExists(view.api, atlas) then return false end

    clearPortraitTexture(view)
    local ok, result = pcall(view.portrait.SetAtlas, view.portrait, atlas, false)
    if not ok or result == false then return false end
    safeHide(view.questionMark)
    return true
end

local function tryClassIcon(view, classToken)
    local coords = CLASS_TCOORDS[classToken]
    if not coords then return false, nil end
    local atlas = "classicon-" .. classToken:lower()
    if setVerifiedAtlas(view, atlas) then return true, atlas end
    if not view.portrait or type(view.portrait.SetTexture) ~= "function"
        or type(view.portrait.SetTexCoord) ~= "function" then return false, nil end

    clearPortraitTexture(view)
    local ok, result = pcall(
        view.portrait.SetTexture,
        view.portrait,
        "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
    )
    if not ok or result == false then return false, nil end
    local coordsOK = pcall(view.portrait.SetTexCoord, view.portrait, coords[1], coords[2], coords[3], coords[4])
    if not coordsOK then showBlankPortrait(view); return false, nil end
    safeHide(view.questionMark)
    return true, "legacy-class-sheet"
end

local function resetView(view)
    showBlankPortrait(view)
    if view.raceLabel then view.raceLabel:SetText("") end
    if view.sexLabel then view.sexLabel:SetText("") end
    if view.caption then view.caption:SetText("") end
    view.portraitRendered = false
    view.portraitSource = nil
end

function GGM.CreateSavedCharacterModel(api, parent)
    if type(api) ~= "table" or type(api.CreateFrame) ~= "function" then
        return { api = api, parent = parent, model = nil }
    end

    local ok, model = pcall(api.CreateFrame, "Frame", nil, parent)
    if not ok or not model then
        return { api = api, parent = parent, model = nil }
    end

    model.background = model:CreateTexture(nil, "BACKGROUND")
    model.background:SetAllPoints(model)
    model.background:SetColorTexture(0.035, 0.035, 0.043, 0.92)

    model.portraitBorder = model:CreateTexture(nil, "BORDER")
    model.portraitBorder:SetSize(162, 162)
    model.portraitBorder:SetPoint("TOP", model, "TOP", 0, -14)
    model.portraitBorder:SetColorTexture(0.20, 0.20, 0.23, 1)

    model.portrait = model:CreateTexture(nil, "ARTWORK")
    model.portrait:SetSize(154, 154)
    model.portrait:SetPoint("CENTER", model.portraitBorder, "CENTER")
    model.portrait:SetColorTexture(0.085, 0.085, 0.100, 1)

    model.questionMark = model:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    model.questionMark:SetPoint("CENTER", model.portrait, "CENTER")
    model.questionMark:SetText("?")
    model.questionMark:SetTextColor(0.55, 0.55, 0.60, 1)

    model.raceLabel = model:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    model.raceLabel:SetPoint("TOP", model.portraitBorder, "BOTTOM", 0, -12)
    model.raceLabel:SetWidth(200)
    model.raceLabel:SetJustifyH("CENTER")
    model.raceLabel:SetTextColor(0.92, 0.92, 0.95, 1)

    model.sexLabel = model:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    model.sexLabel:SetPoint("TOP", model.raceLabel, "BOTTOM", 0, -4)
    model.sexLabel:SetWidth(200)
    model.sexLabel:SetJustifyH("CENTER")
    model.sexLabel:SetTextColor(0.68, 0.68, 0.72, 1)

    model.caption = model:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    model.caption:SetPoint("BOTTOM", model, "BOTTOM", 0, 8)
    model.caption:SetWidth(206)
    model.caption:SetJustifyH("CENTER")
    model.caption:SetTextColor(0.50, 0.50, 0.54, 1)

    model:Hide()

    return {
        api = api,
        parent = parent,
        model = model,
        portrait = model.portrait,
        questionMark = model.questionMark,
        raceLabel = model.raceLabel,
        sexLabel = model.sexLabel,
        caption = model.caption,
        portraitRendered = false,
        portraitSource = nil,
    }
end

function GGM.ClearSavedCharacterModel(view)
    if type(view) ~= "table" or not view.model then return false end
    resetView(view)
    safeHide(view.model)
    return true
end

function GGM.RenderSavedCharacterModel(view, record)
    if type(view) ~= "table" or not view.model then return "render-unavailable" end
    if type(record) ~= "table" or type(record.identity) ~= "table" then return "identity-unavailable" end

    resetView(view)
    local identity = record.identity

    if view.raceLabel then view.raceLabel:SetText(raceNameFor(view.api, identity.raceID)) end
    if view.sexLabel then view.sexLabel:SetText(sexNameFor(identity.sex)) end

    local classToken = selectedClassToken(view.api, identity)
    -- Backfill older saved records when cached character or roster data is available.
    if classToken then identity.classToken = classToken end
    local rendered, source = tryClassIcon(view, classToken)
    if rendered then
        view.portraitRendered = true
        view.portraitSource = source
        if view.caption then view.caption:SetText("Class icon") end
    else
        if view.caption then view.caption:SetText("Class icon unavailable") end
    end

    safeShow(view.model)
    return "shown"
end
