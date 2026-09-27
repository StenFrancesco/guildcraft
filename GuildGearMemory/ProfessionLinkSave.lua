local _, GGM = ...

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function professionOwnerGUID(link)
    if type(link) ~= "string" then return nil end
    return link:match("^trade:([^:|]+):")
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

local function guildIdentityForGUID(api, ownerGUID)
    if not nonEmptyString(ownerGUID)
        or type(api) ~= "table"
        or type(api.GetNumGuildMembers) ~= "function"
        or type(api.GetGuildRosterInfo) ~= "function" then
        return nil, "profession-owner-unavailable"
    end

    local countOk, count = pcall(api.GetNumGuildMembers, true)
    if not countOk or type(count) ~= "number" or count < 0 then
        return nil, "profession-roster-unavailable"
    end

    local matchedIdentity
    for index = 1, count do
        local infoOk, info = pcall(function()
            return { api.GetGuildRosterInfo(index) }
        end)
        if not infoOk then return nil, "profession-roster-unavailable" end

        if info[17] == ownerGUID then
            local identity, identityErr = senderIdentity(api, info[1])
            if not identity then return nil, identityErr end
            if matchedIdentity then return nil, "profession-owner-ambiguous" end
            matchedIdentity = identity
        end
    end

    if not matchedIdentity then return nil, "profession-owner-not-in-guild" end
    return matchedIdentity, nil
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
        activeOwnerGUID = nil,
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
        controller.sourceByLink[link] = {
            reportedBy = identity,
            ownerGUID = professionOwnerGUID(link),
        }
    end
    return "observed", nil
end

function GGM.HandleProfessionHyperlinkOpened(controller, link)
    if type(controller) ~= "table" or type(link) ~= "string" then return "ignored" end
    if not link:match("^trade:") then return "ignored" end

    local source = controller.sourceByLink[link]
    if type(source) ~= "table" or type(source.reportedBy) ~= "table" then
        controller.activeLink = nil
        controller.activeIdentity = nil
        controller.activeOwnerGUID = nil
        controller.activeReportedBy = nil
        controller.activeSource = nil
        return "ignored"
    end

    local ownerIdentity = guildIdentityForGUID(controller.api, source.ownerGUID)
    controller.activeLink = link
    controller.activeIdentity = ownerIdentity
    controller.activeOwnerGUID = source.ownerGUID
    controller.activeReportedBy = source.reportedBy
    controller.activeSource = "guild"
    return "guild-profession-link"
end

function GGM.SaveActiveLinkedProfession(controller)
    if type(controller) ~= "table" then
        return nil, "profession-source-unavailable"
    end

    local identity
    local snapshotSource
    if controller.activeSource == "guild" then
        if professionOwnerGUID(controller.activeLink) ~= controller.activeOwnerGUID then
            return nil, "profession-owner-unavailable"
        end
        local ownerIdentity, ownerErr = guildIdentityForGUID(controller.api, controller.activeOwnerGUID)
        if not ownerIdentity then return nil, ownerErr end
        identity = ownerIdentity
        snapshotSource = GGM.PROFESSION_SOURCE_GUILD_LINK
    elseif controller.activeSource == "player" and type(controller.activeIdentity) == "table" then
        identity = controller.activeIdentity
        snapshotSource = GGM.PROFESSION_SOURCE_PLAYER
    else
        return nil, "profession-source-unavailable"
    end

    local snapshot, captureErr = GGM.CaptureLinkedProfessionSnapshot(
        controller.api,
        snapshotSource
    )
    if not snapshot then return nil, captureErr end

    local saved, saveErr = GGM.SaveProfessionSnapshot(controller.db, identity, snapshot)
    if not saved then return nil, saveErr end
    return "saved", nil
end

local function setStatus(controller, text)
    if controller.status and type(controller.status.SetText) == "function" then
        controller.status:SetText(text or "")
    end
end

local function findProfessionFrame(api)
    if type(api) ~= "table" then return nil end
    return api.ProfessionsFrame or api.TradeSkillFrame
end

local function findCreateAllButton(professionFrame)
    local craftingPage = professionFrame and professionFrame.CraftingPage
    local schematicForm = craftingPage and craftingPage.SchematicForm
    return (schematicForm and schematicForm.CreateAllButton)
        or (craftingPage and craftingPage.CreateAllButton)
end

local function establishOwnProfessionContext(controller, trade)
    if controller.activeSource == "guild"
        or controller.activeIdentity
        or type(trade) ~= "table"
        or type(trade.IsTradeSkillLinked) ~= "function"
        or type(GGM.BuildPlayerIdentity) ~= "function" then
        return
    end

    local linkedOk, linked = pcall(trade.IsTradeSkillLinked)
    if not linkedOk or linked ~= false then return end

    local identityOk, identity = pcall(GGM.BuildPlayerIdentity, controller.api)
    if identityOk and type(identity) == "table" then
        controller.activeIdentity = identity
        controller.activeSource = "player"
    end
end

function GGM.CreateProfessionSaveButton(controller)
    if controller and controller.button then
        return true, nil
    end

    local api = controller and controller.api
    if type(api) ~= "table" or type(api.CreateFrame) ~= "function" then
        return false, "profession-ui-unavailable"
    end

    local professionFrame = findProfessionFrame(api)
    if not professionFrame then
        return false, "profession-frame-unavailable"
    end

    local button = api.CreateFrame("Button", nil, professionFrame, "UIPanelButtonTemplate")
    button:SetSize(150, 24)
    local createAllButton = findCreateAllButton(professionFrame)
    if createAllButton then
        button:SetPoint("RIGHT", createAllButton, "LEFT", -8, 0)
    else
        button:SetPoint("BOTTOMRIGHT", professionFrame, "BOTTOMRIGHT", -440, 22)
    end
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
    if type(controller) ~= "table" then return "unavailable" end
    if not controller.button then
        local created = GGM.CreateProfessionSaveButton(controller)
        if not created then return "unavailable" end
    end

    local trade = type(controller.api) == "table" and controller.api.C_TradeSkillUI or nil

    establishOwnProfessionContext(controller, trade)

    if controller.activeSource == "guild" then
        controller.activeIdentity = guildIdentityForGUID(controller.api, controller.activeOwnerGUID)
    end

    if type(controller.activeIdentity) ~= "table"
        or type(trade) ~= "table"
        or type(trade.IsTradeSkillLinked) ~= "function"
        or type(trade.IsTradeSkillReady) ~= "function" then
        controller.button:Hide()
        return "hidden"
    end

    local linkedOk, linked = pcall(trade.IsTradeSkillLinked)
    local readyOk, ready = pcall(trade.IsTradeSkillReady)
    local validContext = linked == true or (linked == false and controller.activeSource == "player")
    if linkedOk and validContext and readyOk and ready == true then
        if controller.activeSource == "player" then
            setStatus(controller, "Your profession — saved data will be cached")
        else
            setStatus(controller, "Guild link — saved data will be cached/last-known")
        end
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
    controller.activeOwnerGUID = nil
    controller.activeReportedBy = nil
    controller.activeSource = nil
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
    if not created and createErr ~= "profession-frame-unavailable" then
        return false, createErr
    end

    api.hooksecurefunc("SetItemRef", function(link)
        local result = GGM.HandleProfessionHyperlinkOpened(controller, link)
        if result == "guild-profession-link" or (type(link) == "string" and link:match("^trade:")) then
            GGM.RefreshProfessionSaveButton(controller)
        end
    end)

    return true, nil
end
