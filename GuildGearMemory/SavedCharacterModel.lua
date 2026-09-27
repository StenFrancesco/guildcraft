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

local RACE_ATLAS_NAME_FIXES = {
    highmountaintauren = "highmountain",
    lightforgeddraenei = "lightforged",
    scourge = "undead",
    zandalaritroll = "zandalari",
}

local RACE_ID_FALLBACK = {
    [1] = "human", [2] = "orc", [3] = "dwarf", [4] = "nightelf",
    [5] = "undead", [6] = "tauren", [7] = "gnome", [8] = "troll",
    [9] = "goblin", [10] = "bloodelf", [11] = "draenei", [22] = "worgen",
    [24] = "pandaren", [25] = "pandaren", [26] = "pandaren",
}

local LEGACY_RACE_TCOORDS = {
    human = { male={0,0.125,0,0.25}, female={0,0.125,0.5,0.75} },
    dwarf = { male={0.125,0.25,0,0.25}, female={0.125,0.25,0.5,0.75} },
    gnome = { male={0.25,0.375,0,0.25}, female={0.25,0.375,0.5,0.75} },
    nightelf = { male={0.375,0.5,0,0.25}, female={0.375,0.5,0.5,0.75} },
    draenei = { male={0.5,0.625,0,0.25}, female={0.5,0.625,0.5,0.75} },
    worgen = { male={0.625,0.75,0,0.25}, female={0.625,0.75,0.5,0.75} },
    pandaren = { male={0.75,0.875,0,0.25}, female={0.75,0.875,0.5,0.75} },
    tauren = { male={0,0.125,0.25,0.5}, female={0,0.125,0.75,1} },
    undead = { male={0.125,0.25,0.25,0.5}, female={0.125,0.25,0.75,1} },
    troll = { male={0.25,0.375,0.25,0.5}, female={0.25,0.375,0.75,1} },
    orc = { male={0.375,0.5,0.25,0.5}, female={0.375,0.5,0.75,1} },
    bloodelf = { male={0.5,0.625,0.25,0.5}, female={0.5,0.625,0.75,1} },
    goblin = { male={0.625,0.75,0.25,0.5}, female={0.625,0.75,0.75,1} },
}

local function addUnique(list, value)
    if type(value) ~= "string" or value == "" then return end
    value = string.lower(value):gsub("[^a-z]", "")
    if value == "" then return end
    for _, existing in ipairs(list) do
        if existing == value then return end
    end
    table.insert(list, value)
end

local function normalizedRaceNames(api, raceID)
    local names = {}
    local info = raceInfoFor(api, raceID)
    if info then
        addUnique(names, info.clientFileString)
        addUnique(names, info.raceName)
    end
    addUnique(names, RACE_ID_FALLBACK[raceID])

    local original = {}
    for _, name in ipairs(names) do table.insert(original, name) end
    for _, name in ipairs(original) do
        addUnique(names, RACE_ATLAS_NAME_FIXES[name])
    end
    return names
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

local function tryRaceAtlas(view, raceID, sex)
    local gender = sex == 2 and "male" or sex == 3 and "female" or nil
    if not gender then return false, nil end

    for _, prefix in ipairs({ "raceicon128", "raceicon" }) do
        for _, raceName in ipairs(normalizedRaceNames(view.api, raceID)) do
            local atlas = prefix .. "-" .. raceName .. "-" .. gender
            if setVerifiedAtlas(view, atlas) then return true, atlas end
        end
    end
    return false, nil
end

local function tryLegacyRaceSheet(view, raceID, sex)
    if not view or not view.portrait or type(view.portrait.SetTexture) ~= "function" then return false end
    local gender = sex == 2 and "male" or sex == 3 and "female" or nil
    if not gender then return false end

    local coords
    for _, raceName in ipairs(normalizedRaceNames(view.api, raceID)) do
        local fixed = RACE_ATLAS_NAME_FIXES[raceName] or raceName
        if LEGACY_RACE_TCOORDS[fixed] then
            coords = LEGACY_RACE_TCOORDS[fixed][gender]
            if coords then break end
        end
    end
    if not coords then return false end

    clearPortraitTexture(view)
    local ok = pcall(
        view.portrait.SetTexture,
        view.portrait,
        "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Races"
    )
    if not ok then return false end
    if type(view.portrait.SetTexCoord) == "function" then
        pcall(view.portrait.SetTexCoord, view.portrait, coords[1], coords[2], coords[3], coords[4])
    end
    safeHide(view.questionMark)
    return true
end

local function tryDisplayIDPortrait(view, displayID)
    if not view or not view.portrait or not positiveInteger(displayID, 2147483647) then return false end
    local api = view.api
    if type(api) ~= "table" or type(api.SetPortraitTextureFromCreatureDisplayID) ~= "function" then return false end

    clearPortraitTexture(view)
    local ok = pcall(api.SetPortraitTextureFromCreatureDisplayID, view.portrait, displayID)
    if not ok then return false end
    safeHide(view.questionMark)
    return true
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

    local rendered, source = tryRaceAtlas(view, identity.raceID, identity.sex)
    if rendered then
        view.portraitRendered = true
        view.portraitSource = source
        if view.caption then view.caption:SetText("Saved race portrait") end
    elseif tryLegacyRaceSheet(view, identity.raceID, identity.sex) then
        view.portraitRendered = true
        view.portraitSource = "legacy-race-sheet"
        if view.caption then view.caption:SetText("Saved race portrait") end
    elseif tryDisplayIDPortrait(view, identity.displayID) then
        view.portraitRendered = true
        view.portraitSource = "display-id"
        if view.caption then view.caption:SetText("Saved 2D portrait") end
    else
        if view.caption then view.caption:SetText("Saved gear - portrait not available") end
    end

    safeShow(view.model)
    return "shown"
end
