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

    local name, realm = sender:match("^([^-]+)%-(.+)$")
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
            identity.guid = ownerGUID
            if matchedIdentity then return nil, "profession-owner-ambiguous" end
            matchedIdentity = identity
        end
    end

    if not matchedIdentity then return nil, "profession-owner-not-in-guild" end
    return matchedIdentity, nil
end

local function accountIdentityForGUID(controller, guid)
    if type(GGM.IsLocalCharacterGUID) ~= "function"
        or not GGM.IsLocalCharacterGUID(controller.db, guid) then return nil end
    if type(GGM.BuildPlayerIdentity) == "function" then
        local ok, identity = pcall(GGM.BuildPlayerIdentity, controller.api)
        if ok and type(identity) == "table" and identity.guid == guid then return identity end
    end
    local match
    for key, record in pairs(controller.db.professions or {}) do
        local identity = type(record) == "table" and record.identity or nil
        if type(identity) == "table" and identity.guid == guid then
            if match or identity.key ~= key then return nil end
            match = identity
        end
    end
    return match
end

local function linkedOwnerIdentity(controller)
    return guildIdentityForGUID(controller.api, controller.activeOwnerGUID)
        or accountIdentityForGUID(controller, controller.activeOwnerGUID)
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

    controller.autoSaved = nil
    local source = controller.sourceByLink[link]
    local ownerGUID = professionOwnerGUID(link)
    if not ownerGUID then
        controller.activeLink = nil
        controller.activeIdentity = nil
        controller.activeOwnerGUID = nil
        controller.activeReportedBy = nil
        controller.activeSource = nil
        return "ignored"
    end

    local ownerIdentity = guildIdentityForGUID(controller.api, ownerGUID)
        or accountIdentityForGUID(controller, ownerGUID)
    controller.activeLink = link
    controller.activeIdentity = ownerIdentity
    controller.activeOwnerGUID = ownerGUID
    controller.activeReportedBy = type(source) == "table" and source.reportedBy or nil
    controller.activeSource = "guild"
    return "guild-profession-link"
end

local function isOwnProfessionView(trade)
    -- Older clients may omit these browsing modes entirely.
    if type(trade) ~= "table" then return true end
    for _, name in ipairs({ "IsTradeSkillGuild", "IsTradeSkillNPC", "IsNPCCrafting" }) do
        if type(trade[name]) == "function" then
            local ok, foreign = pcall(trade[name])
            if not ok or foreign ~= false then return false end
        end
    end
    return true
end

function GGM.SaveActiveLinkedProfession(controller)
    if type(controller) ~= "table" then
        return nil, "profession-source-unavailable"
    end

    local identity
    local snapshotSource
    local guildMembershipVerified = false
    if controller.activeSource == "guild" then
        if professionOwnerGUID(controller.activeLink) ~= controller.activeOwnerGUID then
            return nil, "profession-owner-unavailable"
        end
        local ownerIdentity, ownerErr
        if GGM.professionRosterMembershipCurrent == true then
            ownerIdentity, ownerErr = guildIdentityForGUID(controller.api, controller.activeOwnerGUID)
            guildMembershipVerified = ownerIdentity ~= nil
        else
            ownerErr = "profession-roster-incomplete"
        end
        ownerIdentity = ownerIdentity or accountIdentityForGUID(controller, controller.activeOwnerGUID)
        if not ownerIdentity then return nil, ownerErr end
        identity = ownerIdentity
        snapshotSource = GGM.PROFESSION_SOURCE_GUILD_LINK
    elseif controller.activeSource == "player" and type(controller.activeIdentity) == "table" then
        if not isOwnProfessionView(controller.api and controller.api.C_TradeSkillUI) then
            return nil, "profession-not-owned"
        end
        identity = controller.activeIdentity
        snapshotSource = GGM.PROFESSION_SOURCE_PLAYER
    else
        return nil, "profession-source-unavailable"
    end

    local prepared = controller.preparedSave
    controller.preparedSave = nil
    if prepared and (not GGM.IsCPUInputCurrent(controller.db, prepared.input)
        or prepared.snapshot.source ~= snapshotSource) then prepared = nil end
    local snapshot, captureErr
    if prepared then snapshot = prepared.snapshot
    else snapshot, captureErr = GGM.CaptureLinkedProfessionSnapshot(controller.api, snapshotSource) end
    if not snapshot then return nil, captureErr end

    local saveOptions
    if guildMembershipVerified then
        saveOptions = { guildMembershipVerified = true }
    elseif controller.activeSource == "player" and GGM.professionRosterMembershipCurrent == true then
        local playerGuildIdentity, playerGuildErr = guildIdentityForGUID(controller.api, identity.guid)
        if playerGuildIdentity then
            identity = playerGuildIdentity
            saveOptions = { guildMembershipVerified = true }
        elseif playerGuildErr ~= "profession-owner-not-in-guild" then
            return nil, playerGuildErr
        end
    end
    local beforeHash = prepared and prepared.beforeHash
    if prepared then
        saveOptions = saveOptions or {}
        saveOptions.indexValidationOperation = prepared.indexValidationOperation
    elseif GGM.professionSync and type(GGM.GetProfessionSyncDigest) == "function" then
        beforeHash = GGM.GetProfessionSyncDigest(controller.db, snapshot.professionID)
    end
    local saved, saveErr = GGM.SaveProfessionSnapshot(
        controller.db, identity, snapshot, saveOptions
    )
    if not saved then return nil, saveErr end
    if GGM.professionSync and type(GGM.PublishProfessionSyncSave) == "function" then
        local ok, _, syncErr = pcall(GGM.PublishProfessionSyncSave, GGM.professionSync, snapshot.professionID, beforeHash)
        GGM.lastProfessionSyncError = ok and syncErr or "profession-sync-save-unavailable"
    end
    if type(GGM.RefreshVisibleProfessionCatalog) == "function" then GGM.RefreshVisibleProfessionCatalog() end
    if type(GGM.RefreshVisibleProfessionLibrary) == "function" then GGM.RefreshVisibleProfessionLibrary() end
    return "saved", nil
end

local function setStatus(controller, text, tone)
    if controller.status and type(controller.status.SetText) == "function" then
        controller.status:SetText(text or "")
        if type(GGM.SetUITextTone) == "function" then
            GGM.SetUITextTone(controller.status, tone or "secondary")
        end
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

local function getCreateAllButtonSize(professionFrame)
    local button = findCreateAllButton(professionFrame)
    if not button then return nil, nil end

    local width, height
    if type(button.GetWidth) == "function" then
        local ok, value = pcall(button.GetWidth, button)
        if ok and type(value) == "number" and value > 0 then width = value end
    end
    if type(button.GetHeight) == "function" then
        local ok, value = pcall(button.GetHeight, button)
        if ok and type(value) == "number" and value > 0 then height = value end
    end
    if width and height then return width, height end
    return nil, nil
end

local function establishOwnProfessionContext(controller, trade)
    if (controller.activeIdentity and controller.activeSource ~= "guild")
        or type(trade) ~= "table"
        or type(trade.IsTradeSkillLinked) ~= "function"
        or type(GGM.BuildPlayerIdentity) ~= "function" then
        return
    end

    local linkedOk, linked = pcall(trade.IsTradeSkillLinked)
    if not linkedOk or linked ~= false or not isOwnProfessionView(trade) then return end

    -- Unlinked data must never inherit the previous linked owner's identity.
    if controller.activeSource == "guild" then
        controller.activeLink = nil
        controller.activeOwnerGUID = nil
        controller.activeReportedBy = nil
    end
    local identityOk, identity = pcall(GGM.BuildPlayerIdentity, controller.api)
    if identityOk and type(identity) == "table" then
        controller.activeIdentity = identity
        controller.activeSource = "player"
    end
end

function GGM.TryAutoSaveProfession(controller)
    if type(controller) ~= "table" or controller.panelOpen ~= true then return "ignored" end
    local trade = type(controller.api) == "table" and controller.api.C_TradeSkillUI or nil
    if type(trade) ~= "table" or type(trade.IsTradeSkillLinked) ~= "function"
        or type(trade.IsTradeSkillReady) ~= "function"
        or type(trade.GetBaseProfessionInfo) ~= "function" then
        return nil, "profession-api-unavailable"
    end
    local linkedOk, linked = pcall(trade.IsTradeSkillLinked)
    local readyOk, ready = pcall(trade.IsTradeSkillReady)
    if not linkedOk or not readyOk or ready ~= true then
        return nil, "profession-data-unavailable"
    end
    if linked == false then
        if not isOwnProfessionView(trade) then return nil, "profession-not-owned" end
        establishOwnProfessionContext(controller, trade)
    elseif linked ~= true or controller.activeSource ~= "guild" then
        return nil, "profession-source-unavailable"
    end
    local identity = controller.activeIdentity
    if controller.activeSource == "guild" then
        identity = linkedOwnerIdentity(controller)
    end
    if type(identity) ~= "table" or not nonEmptyString(identity.guid) then
        return nil, "profession-owner-unavailable"
    end
    local infoOk, info = pcall(trade.GetBaseProfessionInfo)
    if not infoOk or type(info) ~= "table" or type(info.professionID) ~= "number" then
        return nil, "profession-info-unavailable"
    end
    local key = identity.guid .. ":" .. tostring(info.professionID)
    if controller.autoSaved and controller.autoSaved[key] then return "unchanged" end
    local result, err = GGM.SaveActiveLinkedProfession(controller)
    if result == "saved" then
        controller.autoSaved = controller.autoSaved or {}
        controller.autoSaved[key] = true
        setStatus(controller, "The Guild Book  •  snapshot saved automatically", "success")
    end
    return result, err
end

-- UI/events prepare data before calling the unchanged synchronous save API.
-- Closing/replacing the trade context cancels work without retrying in the background.
function GGM.QueueProfessionSave(controller, automatic)
    if not GGM.StartCPUJob then
        local result, err
        if automatic then result, err = GGM.TryAutoSaveProfession(controller)
        else result, err = GGM.SaveActiveLinkedProfession(controller) end
        return result == "saved" or result == "unchanged", err
    end
    local api, db = controller.api, controller.db
    local trade = api and api.C_TradeSkillUI
    establishOwnProfessionContext(controller, trade)
    if controller.activeSource == "guild" then
        -- A link can open before the roster resolves its owner. Retry through
        -- the same trusted GUID lookup used by the synchronous save boundary.
        controller.activeIdentity = linkedOwnerIdentity(controller)
    end
    local ownerGUID, ownerLink = controller.activeOwnerGUID, controller.activeLink
    local infoOK, info = pcall(function() return trade.GetBaseProfessionInfo() end)
    if not infoOK or type(info) ~= "table" or type(info.professionID) ~= "number" then
        return false, "profession-info-unavailable"
    end
    local identity, source, professionID = controller.activeIdentity, controller.activeSource, info.professionID
    if type(identity) ~= "table" then return false, "profession-owner-unavailable" end
    if automatic and controller.autoSaved and controller.autoSaved[identity.guid .. ":" .. professionID] then return true end
    local input, membership = GGM.CaptureCPUInput(db), GGM.professionRosterMembershipCurrent
    local authoritative = GGM.db == db
    controller.saveCPUOwner = controller.saveCPUOwner or {}
    local owner = controller.saveCPUOwner
    local function current()
        return controller.db == db and (not authoritative or GGM.db == db)
            and controller.panelOpen ~= false and controller.activeIdentity == identity
            and controller.activeSource == source and controller.activeOwnerGUID == ownerGUID
            and controller.activeLink == ownerLink and GGM.professionRosterMembershipCurrent == membership
            and GGM.IsCPUInputCurrent(db, input)
    end
    local job, err = GGM.StartCPUJob(owner, function()
        local snapshot, captureErr = GGM.CaptureLinkedProfessionSnapshot(api,
            source == "player" and GGM.PROFESSION_SOURCE_PLAYER or GGM.PROFESSION_SOURCE_GUILD_LINK)
        if not snapshot or snapshot.professionID ~= professionID then return nil, captureErr or "profession-context-changed" end
        local beforeHash
        if GGM.professionSync and GGM.GetProfessionSyncDigest then beforeHash = GGM.GetProfessionSyncDigest(db, professionID) end
        local token, validationErr
        if GGM.PrepareProfessionValidationOperation then token, validationErr = GGM.PrepareProfessionValidationOperation(db, identity) end
        -- Unsupported rename/repair paths use the original full validation at save time.
        return {snapshot = snapshot, input = input, beforeHash = beforeHash, indexValidationOperation = token}
    end, function(prepared, prepareErr)
        local infoOK, nowInfo = pcall(trade.GetBaseProfessionInfo)
        if not infoOK or type(nowInfo) ~= "table" or nowInfo.professionID ~= professionID then return end
        if not prepared then
            GGM.lastProfessionSaveError = prepareErr
            setStatus(controller, "Save failed: " .. tostring(prepareErr or "unavailable"), "warning")
            return
        end
        controller.preparedSave = prepared
        local result, saveErr
        if automatic then result, saveErr = GGM.TryAutoSaveProfession(controller)
        else result, saveErr = GGM.SaveActiveLinkedProfession(controller) end
        controller.preparedSave = nil
        GGM.lastProfessionSaveError = saveErr
        if result == "saved" then setStatus(controller, "The Guild Book  •  snapshot saved", "success")
        elseif result ~= "unchanged" then setStatus(controller, "Save failed: " .. tostring(saveErr or "unavailable"), "warning") end
    end, { api = api, current = current, onCancel = function()
        controller.preparedSave = nil
    end })
    return job ~= nil, err
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

    local createAllButton = findCreateAllButton(professionFrame)
    local buttonWidth, buttonHeight = getCreateAllButtonSize(professionFrame)

    local button = api.CreateFrame("Button", nil, professionFrame, "UIPanelButtonTemplate")
    button:SetSize(buttonWidth or 172, buttonHeight or 26)
    button:SetText("Save Snapshot")

    local buttonGap = GGM.UIStyleTokens and GGM.UIStyleTokens.space2 or 8
    if createAllButton then
        button:SetPoint("RIGHT", createAllButton, "LEFT", -buttonGap, 0)
    else
        button:SetPoint("BOTTOMRIGHT", professionFrame, "BOTTOMRIGHT", -184, 34)
    end
    button:Hide()

    local status = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("BOTTOMRIGHT", button, "TOPRIGHT", 0, 7)
    status:SetWidth(340)
    status:SetJustifyH("RIGHT")
    status:SetText("")
    if type(GGM.SetUITextTone) == "function" then GGM.SetUITextTone(status, "secondary") end

    button:SetScript("OnEnter", function(self)
        if not api.GameTooltip then return end
        api.GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if type(api.GameTooltip.SetText) == "function" then
            api.GameTooltip:SetText("Save to The Guild Book")
            if type(api.GameTooltip.AddLine) == "function" then
                api.GameTooltip:AddLine("Stores the currently visible recipes as a last-known profession snapshot.", 0.72, 0.74, 0.78, true)
            end
        end
        api.GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        if api.GameTooltip then api.GameTooltip:Hide() end
    end)

    button:SetScript("OnClick", function()
        if GGM.StartCPUJob then GGM.QueueProfessionSave(controller, false); return end
        local result, err = GGM.SaveActiveLinkedProfession(controller)
        if result == "saved" then
            setStatus(controller, "The Guild Book  •  snapshot saved", "success")
        else
            setStatus(controller, "Save failed: " .. tostring(err or "unavailable"), "warning")
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
        controller.activeIdentity = linkedOwnerIdentity(controller)
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
    local validContext = (linked == true and controller.activeSource == "guild")
        or (linked == false and controller.activeSource == "player" and isOwnProfessionView(trade))
    if linkedOk and validContext and readyOk and ready == true then
        local infoOk, info = false, nil
        if type(trade.GetBaseProfessionInfo) == "function" then infoOk, info = pcall(trade.GetBaseProfessionInfo) end
        local savedKey = infoOk and type(info) == "table" and controller.activeIdentity.guid
            and (controller.activeIdentity.guid .. ":" .. tostring(info.professionID))
        if savedKey and controller.autoSaved and controller.autoSaved[savedKey] then
            setStatus(controller, "The Guild Book  •  snapshot saved automatically", "success")
        elseif controller.activeSource == "player" then
            setStatus(controller, "The Guild Book  •  personal profession  •  last-known recipes")
        else
            setStatus(controller, "The Guild Book  •  guild profession  •  last-known recipes")
        end
        local professionFrame = findProfessionFrame(controller.api)
        local width, height = getCreateAllButtonSize(professionFrame)
        if width and height then controller.button:SetSize(width, height) end
        controller.button:Show()
        return "shown"
    end

    controller.button:Hide()
    return "hidden"
end

function GGM.ClearProfessionSaveContext(controller)
    if type(controller) ~= "table" then return end
    controller.panelOpen = false
    if GGM.CancelCPUJob and controller.saveCPUOwner then GGM.CancelCPUJob(controller.saveCPUOwner) end
    controller.preparedSave = nil
    controller.autoSaveRequest = nil
    controller.autoSaved = nil
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
