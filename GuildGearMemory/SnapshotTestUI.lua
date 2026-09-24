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

local function hasValidBrowserIdentity(record, key)
    return type(key) == "string"
        and type(record) == "table"
        and type(record.identity) == "table"
        and record.identity.key == key
        and type(record.identity.name) == "string"
        and record.identity.name ~= ""
        and type(record.identity.realm) == "string"
        and record.identity.realm ~= ""
        and key == record.identity.name .. "-" .. record.identity.realm
end

function GGM.BuildGuildGearBrowserEntries(db)
    local entries = {}
    if type(db) ~= "table" or type(db.characters) ~= "table"
        or type(GGM.GetCompleteCharacterRecord) ~= "function" then
        return entries
    end

    for key in pairs(db.characters) do
        local record = GGM.GetCompleteCharacterRecord(db, key)
        if record and hasValidBrowserIdentity(record, key) then
            table.insert(entries, {
                key = key,
                name = record.identity.name,
                realm = record.identity.realm,
                record = record,
            })
        end
    end

    table.sort(entries, function(left, right)
        local leftName, rightName = string.lower(left.name), string.lower(right.name)
        if leftName ~= rightName then return leftName < rightName end
        local leftRealm, rightRealm = string.lower(left.realm), string.lower(right.realm)
        if leftRealm ~= rightRealm then return leftRealm < rightRealm end
        return left.key < right.key
    end)

    return entries
end

function GGM.FilterGuildGearBrowserEntries(entries, query)
    local filtered = {}
    if type(entries) ~= "table" then return filtered end
    if query == nil or query == "" then
        for _, entry in ipairs(entries) do table.insert(filtered, entry) end
        return filtered
    end
    if type(query) ~= "string" then return filtered end

    local needle = string.lower(query)
    for _, entry in ipairs(entries) do
        if type(entry) == "table" then
            local name = type(entry.name) == "string" and string.lower(entry.name) or ""
            local realm = type(entry.realm) == "string" and string.lower(entry.realm) or ""
            if string.find(name, needle, 1, true) or string.find(realm, needle, 1, true) then
                table.insert(filtered, entry)
            end
        end
    end
    return filtered
end

local function getItemIcon(api, itemID)
    if type(api.GetItemIcon) == "function" then
        return api.GetItemIcon(itemID)
    end
    if type(api.C_Item) == "table" and type(api.C_Item.GetItemIconByID) == "function" then
        return api.C_Item.GetItemIconByID(itemID)
    end
    return nil
end

local function getSlotTexture(api, trackedSlot)
    if type(api.GetInventorySlotInfo) ~= "function" then return nil end
    local _, texture = api.GetInventorySlotInfo(trackedSlot.inventoryName)
    return texture
end

local function hasValidBrowserDetailRecord(record)
    return type(record) == "table"
        and record.complete == true
        and type(record.identity) == "table"
        and type(record.identity.key) == "string"
        and type(record.identity.name) == "string"
        and record.identity.name ~= ""
        and type(record.identity.realm) == "string"
        and record.identity.realm ~= ""
        and record.identity.key == record.identity.name .. "-" .. record.identity.realm
        and type(record.gear) == "table"
        and type(GGM.ValidateCompleteSnapshot) == "function"
        and GGM.ValidateCompleteSnapshot(record.gear) == true
end

function GGM.BuildGuildGearBrowserDetail(record, api)
    api = type(api) == "table" and api or {}
    if not hasValidBrowserDetailRecord(record) then return { hasRecord = false } end

    local slots = {}
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local savedSlot = record.gear.slots[trackedSlot.key]
        local slotTexture = getSlotTexture(api, trackedSlot)
        local empty = savedSlot.itemID == false
        local icon = slotTexture
        if not empty then icon = getItemIcon(api, savedSlot.itemID) or slotTexture end
        table.insert(slots, {
            key = trackedSlot.key,
            inventorySlotID = savedSlot.inventorySlotID,
            itemID = savedSlot.itemID,
            itemLink = savedSlot.itemLink,
            empty = empty,
            slotTexture = slotTexture,
            icon = icon,
        })
    end

    local capturedAtText = tostring(record.gear.capturedAt)
    if type(api.date) == "function" then
        capturedAtText = api.date("%Y-%m-%d %H:%M:%S", record.gear.capturedAt)
    end
    return {
        hasRecord = true,
        key = record.identity.key,
        characterName = record.identity.name,
        name = record.identity.name,
        realm = record.identity.realm,
        capturedAtText = capturedAtText,
        slots = slots,
    }
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

local function setSnapshotContentVisible(frame, visible)
    if visible and frame.snapshotModel and frame.snapshotModel.hasSnapshot then
        frame.emptyState:Hide()
        setMetadataVisible(frame, true)
        for _, row in ipairs(frame.slotRows) do row:Show() end
    elseif visible and frame.snapshotModel then
        frame.emptyState:Show()
        setMetadataVisible(frame, false)
        for _, row in ipairs(frame.slotRows) do row:Hide() end
    else
        frame.emptyState:Hide()
        setMetadataVisible(frame, false)
        for _, row in ipairs(frame.slotRows) do row:Hide() end
    end
end

function GGM.SelectSnapshotTab(frame, selectedKey)
    if selectedKey ~= "Character" and selectedKey ~= "Professions" and selectedKey ~= "Bank" then return false end
    frame.activeTab = selectedKey
    frame.TitleText:SetText(selectedKey == "Character" and "Guild Gear Memory - Saved Snapshot" or "Guild Gear Memory - " .. selectedKey)

    for _, tab in ipairs(frame.navigationTabs) do
        local selected = tab.key == selectedKey
        tab.background:SetColorTexture(selected and 0.20 or 0.055, selected and 0.16 or 0.055, selected and 0.025 or 0.065, 0.96)
        if selected then tab.label:SetTextColor(1, 0.82, 0) else tab.label:SetTextColor(0.9, 0.9, 0.9) end
    end

    local showSnapshot = selectedKey == "Character"
    setSnapshotContentVisible(frame, showSnapshot)
    for pageKey, page in pairs(frame.placeholderPages) do
        if pageKey == selectedKey then page:Show() else page:Hide() end
    end
    return true
end

local function createNavigationTab(api, frame, key, label, iconPath, offset)
    local tab = api.CreateFrame("Button", nil, frame)
    tab:SetSize(72, 82)
    tab:SetPoint("TOPRIGHT", frame, "TOPLEFT", -3, -72 - offset)

    local background = tab:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(tab)
    background:SetColorTexture(0.055, 0.055, 0.065, 0.96)

    local icon = tab:CreateTexture(nil, "ARTWORK")
    icon:SetSize(34, 34)
    icon:SetPoint("TOP", tab, "TOP", 0, -8)
    icon:SetTexture(iconPath)

    local text = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOP", icon, "BOTTOM", 0, -3)
    text:SetText(label)
    text:SetJustifyH("CENTER")

    tab.key = key
    tab.background = background
    tab.label = text
    tab:RegisterForClicks("LeftButtonUp")
    tab:SetScript("OnClick", function() GGM.SelectSnapshotTab(frame, key) end)
    return tab
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
    frame.snapshotModel = nil
    frame.placeholderPages = {}
    for _, pageKey in ipairs({ "Professions", "Bank" }) do
        local page = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        page:SetPoint("CENTER", frame, "CENTER", 0, 0)
        page:SetText(pageKey .. " content will be added later.")
        page:Hide()
        frame.placeholderPages[pageKey] = page
    end
    frame.navigationTabs = {
        createNavigationTab(api, frame, "Character", "Character", "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest", 0),
        createNavigationTab(api, frame, "Professions", "Professions", "Interface\\Icons\\Trade_BlackSmithing", 86),
        createNavigationTab(api, frame, "Bank", "Bank", "Interface\\Icons\\INV_Misc_Bag_10", 172),
    }
    GGM.SelectSnapshotTab(frame, "Character")
    return frame
end

function GGM.ShowSnapshotTestWindow(api, db)
    local record
    if db ~= nil then record = select(1, GGM.GetLocalPlayerRecord(api, db)) end
    local model = GGM.BuildSnapshotViewModel(record, api.date)
    if not GGM.snapshotTestFrame then GGM.snapshotTestFrame = GGM.CreateSnapshotTestWindow(api) end
    GGM.snapshotTestFrame.snapshotModel = model
    GGM.RenderSnapshotViewModel(GGM.snapshotTestFrame, model)
    GGM.SelectSnapshotTab(GGM.snapshotTestFrame, GGM.snapshotTestFrame.activeTab or "Character")
    GGM.snapshotTestFrame:Show()
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
