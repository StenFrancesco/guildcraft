local _, GGM = ...

local function missingModel()
    return { hasSnapshot = false, emptyStateText = "No saved snapshot", slots = {} }
end

local function hasValidDisplayShape(record)
    if type(record) ~= "table" or record.complete ~= true then return false end
    if type(record.identity) ~= "table" then return false end
    if type(record.identity.key) ~= "string" or record.identity.key == "" then return false end
    if type(record.identity.name) ~= "string" or record.identity.name == "" then return false end
    if type(record.identity.realm) ~= "string" or record.identity.realm == "" then return false end
    if record.identity.key ~= record.identity.name .. "-" .. record.identity.realm then return false end
    if type(record.gear) ~= "table" or record.gear.complete ~= true then return false end
    if type(record.gear.capturedAt) ~= "number" then return false end
    if type(record.gear.slots) ~= "table" then return false end
    return true
end

function GGM.BuildSnapshotViewModel(record, formatTime)
    if not hasValidDisplayShape(record) then return missingModel() end
    local slotRows = {}
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local savedSlot = record.gear.slots[trackedSlot.key]
        if type(savedSlot) ~= "table" then return missingModel() end
        if type(savedSlot.inventorySlotID) ~= "number" then return missingModel() end
        local valueText
        if type(savedSlot.itemID) == "number" and type(savedSlot.itemLink) == "string" and savedSlot.itemLink ~= "" then
            valueText = savedSlot.itemLink
        elseif savedSlot.itemID == false and savedSlot.itemLink == false then
            valueText = "Empty"
        else return missingModel() end
        table.insert(slotRows, { key = trackedSlot.key, valueText = valueText })
    end
    local capturedAtText = tostring(record.gear.capturedAt)
    if type(formatTime) == "function" then capturedAtText = formatTime("%Y-%m-%d %H:%M:%S", record.gear.capturedAt) end
    return { hasSnapshot = true, characterName = record.identity.name, realm = record.identity.realm,
        capturedAtText = capturedAtText, completenessText = "Complete", slots = slotRows }
end

local function setMetadataVisible(frame, visible)
    local controls = { frame.characterLine, frame.realmLine, frame.capturedLine, frame.completenessLine }
    for _, control in ipairs(controls) do if visible then control:Show() else control:Hide() end end
end

function GGM.RenderSnapshotViewModel(frame, model)
    if not model.hasSnapshot then
        frame.emptyState:SetText(model.emptyStateText); frame.emptyState:Show(); setMetadataVisible(frame, false)
        for _, row in ipairs(frame.slotRows) do row:Hide() end
        return
    end
    frame.emptyState:Hide(); setMetadataVisible(frame, true)
    frame.characterLine:SetText("Character: " .. model.characterName)
    frame.realmLine:SetText("Realm: " .. model.realm)
    frame.capturedLine:SetText("Captured: " .. model.capturedAtText)
    frame.completenessLine:SetText("Completeness: " .. model.completenessText)
    for index, slot in ipairs(model.slots) do
        local row = frame.slotRows[index]; row:SetText(slot.key .. ": " .. slot.valueText); row:Show()
    end
    for index = #model.slots + 1, #frame.slotRows do frame.slotRows[index]:Hide() end
end

local function createLine(frame, yOffset, fontObject)
    local line = frame:CreateFontString(nil, "OVERLAY", fontObject)
    line:SetPoint("TOPLEFT", 24, yOffset); line:SetPoint("RIGHT", frame, "RIGHT", -24, 0); line:SetJustifyH("LEFT")
    return line
end

function GGM.CreateSnapshotTestWindow(api)
    local frame = api.CreateFrame("Frame", "GuildGearMemorySnapshotTestFrame", api.UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(660, 500); frame:SetPoint("CENTER"); frame:SetClampedToScreen(true); frame:Hide()
    frame.TitleText:SetText("Guild Gear Memory - Saved Snapshot")
    frame.characterLine = createLine(frame, -62, "GameFontNormal")
    frame.realmLine = createLine(frame, -84, "GameFontNormal")
    frame.capturedLine = createLine(frame, -106, "GameFontHighlight")
    frame.completenessLine = createLine(frame, -128, "GameFontHighlight")
    frame.emptyState = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.emptyState:SetPoint("CENTER", frame, "CENTER", 0, 0); frame.emptyState:Hide()
    frame.slotRows = {}
    for index = 1, #GGM.TRACKED_SLOTS do table.insert(frame.slotRows, createLine(frame, -158 - ((index - 1) * 19), "GameFontHighlightSmall")) end
    return frame
end

function GGM.ShowSnapshotTestWindow(api, db)
    local record
    if db ~= nil then record = select(1, GGM.GetLocalPlayerRecord(api, db)) end
    local model = GGM.BuildSnapshotViewModel(record, api.date)
    if not GGM.snapshotTestFrame then GGM.snapshotTestFrame = GGM.CreateSnapshotTestWindow(api) end
    GGM.RenderSnapshotViewModel(GGM.snapshotTestFrame, model); GGM.snapshotTestFrame:Show()
    return model
end

local function parseRequestedIdentity(message)
    if type(message) ~= "string" then
        return nil, nil
    end

    local targetKey = message:match("^%s*request%s+([^%s]+)%s*$")
    if not targetKey then
        if message:match("^%s*request") then
            return nil, "request-target-invalid"
        end
        return nil, nil
    end

    local name, realm = targetKey:match("^([^-]+)%-(.+)$")
    if not name or name == "" or not realm or realm == "" then
        return nil, "request-target-invalid"
    end

    return {
        key = targetKey,
        name = name,
        realm = realm,
        guid = nil,
    }, nil
end

function GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList = api.SlashCmdList or {}
    api.SLASH_GUILDGEARMEMORY1 = "/ggm"
    api.SlashCmdList.GUILDGEARMEMORY = function(message)
        local target, requestErr = parseRequestedIdentity(message)
        if target then
            if not GGM.guildSync then
                GGM.lastSyncError = "sync-unavailable"
                return
            end

            local queued, queueErr = GGM.RequestCompleteSnapshot(GGM.guildSync, target)
            if queued then
                GGM.lastSyncError = nil
            else
                GGM.lastSyncError = queueErr
            end
            return
        end

        if requestErr then
            GGM.lastSyncError = requestErr
            return
        end

        GGM.ShowSnapshotTestWindow(api, GGM.db)
    end
end
