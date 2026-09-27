local _, GGM = ...

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function senderIdentity(api, sender)
    if not nonEmptyString(sender) then return nil, "profession-sender-invalid" end

    local name, realm = sender:match("^(.+)%-(.+)$")
    if not name then
        name = sender
        if type(api) == "table" and type(api.GetRealmName) == "function" then
            local ok, currentRealm = pcall(api.GetRealmName)
            if ok then realm = currentRealm end
        end
    end

    if not nonEmptyString(name) or not nonEmptyString(realm) then
        return nil, "profession-sender-identity-unavailable"
    end

    return {
        key = name .. "-" .. realm,
        name = name,
        realm = realm,
    }, nil
end

function GGM.ExtractProfessionTradeLinks(message)
    local links = {}
    if type(message) ~= "string" then return links end

    for link in message:gmatch("|H(trade:[^|]+)|h") do
        table.insert(links, link)
    end
    return links
end

function GGM.CreateProfessionLinkSaveController(api, db)
    return {
        api = api,
        db = db,
        sourceByLink = {},
        activeLink = nil,
        activeIdentity = nil,
        button = nil,
        status = nil,
    }
end

function GGM.ObserveGuildProfessionMessage(controller, message, sender)
    if type(controller) ~= "table" then return nil, "profession-controller-invalid" end
    local links = GGM.ExtractProfessionTradeLinks(message)
    if #links == 0 then return "ignored", nil end

    local identity, identityErr = senderIdentity(controller.api, sender)
    if not identity then return nil, identityErr end

    for _, link in ipairs(links) do
        controller.sourceByLink[link] = { identity = identity }
    end
    return "observed", nil
end

function GGM.HandleProfessionHyperlinkOpened(controller, link)
    if type(controller) ~= "table" or type(link) ~= "string" then return "ignored" end
    if not link:match("^trade:") then return "ignored" end

    local source = controller.sourceByLink[link]
    if type(source) ~= "table" or type(source.identity) ~= "table" then
        controller.activeLink = nil
        controller.activeIdentity = nil
        return "ignored"
    end

    controller.activeLink = link
    controller.activeIdentity = source.identity
    return "guild-profession-link"
end

function GGM.SaveActiveLinkedProfession(controller)
    if type(controller) ~= "table" or type(controller.activeIdentity) ~= "table" then
        return nil, "profession-source-unavailable"
    end

    local snapshot, captureErr = GGM.CaptureLinkedProfessionSnapshot(controller.api)
    if not snapshot then return nil, captureErr end

    local saved, saveErr = GGM.SaveProfessionSnapshot(controller.db, controller.activeIdentity, snapshot)
    if not saved then return nil, saveErr end
    return "saved", nil
end

local function setStatus(controller, text)
    if controller.status and type(controller.status.SetText) == "function" then
        controller.status:SetText(text or "")
    end
end

function GGM.CreateProfessionSaveButton(controller)
    local api = controller and controller.api
    if type(api) ~= "table" or type(api.CreateFrame) ~= "function" then
        return false, "profession-ui-unavailable"
    end

    local button = api.CreateFrame("Button", nil, api.UIParent, "UIPanelButtonTemplate")
    button:SetSize(150, 24)
    button:SetPoint("TOP", api.UIParent, "TOP", 0, -120)
    button:SetText("Save to Variables")
    button:Hide()

    local status = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOP", button, "BOTTOM", 0, -4)
    status:SetText("")

    button:SetScript("OnClick", function()
        local result, err = GGM.SaveActiveLinkedProfession(controller)
        if result == "saved" then
            setStatus(controller, "Saved as cached profession data")
        else
            setStatus(controller, "Not saved: " .. tostring(err or "unavailable"))
        end
    end)

    controller.button = button
    controller.status = status
    return true, nil
end

function GGM.RefreshProfessionSaveButton(controller)
    if type(controller) ~= "table" or not controller.button then return "unavailable" end
    local trade = type(controller.api) == "table" and controller.api.C_TradeSkillUI or nil

    if type(controller.activeIdentity) ~= "table"
        or type(trade) ~= "table"
        or type(trade.IsTradeSkillLinked) ~= "function"
        or type(trade.IsTradeSkillReady) ~= "function" then
        controller.button:Hide()
        return "hidden"
    end

    local linkedOk, linked = pcall(trade.IsTradeSkillLinked)
    local readyOk, ready = pcall(trade.IsTradeSkillReady)
    if linkedOk and linked == true and readyOk and ready == true then
        setStatus(controller, "Guild link — saved data will be cached/last-known")
        controller.button:Show()
        return "shown"
    end

    controller.button:Hide()
    return "hidden"
end

function GGM.ClearProfessionSaveContext(controller)
    if type(controller) ~= "table" then return end
    controller.activeLink = nil
    controller.activeIdentity = nil
    if controller.button then controller.button:Hide() end
    setStatus(controller, "")
end

function GGM.RegisterProfessionLinkSaveController(controller)
    if type(controller) ~= "table" or type(controller.api) ~= "table" then
        return false, "profession-controller-invalid"
    end

    local api = controller.api
    if type(api.hooksecurefunc) ~= "function" or type(api.SetItemRef) ~= "function" then
        return false, "profession-hyperlink-hook-unavailable"
    end

    local created, createErr = GGM.CreateProfessionSaveButton(controller)
    if not created then return false, createErr end

    api.hooksecurefunc("SetItemRef", function(link)
        local result = GGM.HandleProfessionHyperlinkOpened(controller, link)
        if result == "guild-profession-link" then
            GGM.RefreshProfessionSaveButton(controller)
        end
    end)

    return true, nil
end
