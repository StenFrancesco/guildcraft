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

local function createText(frame, layer, fontObject)
    return frame:CreateFontString(nil, layer or "OVERLAY", fontObject or "GameFontHighlight")
end

local function setText(control, value)
    control:SetText(value or "")
    if value and value ~= "" then control:Show() else control:Hide() end
end

local function renderBrowserDetail(frame, entry, api)
    frame.detailModel = nil
    for _, control in ipairs({ frame.characterLine, frame.realmLine, frame.capturedLine }) do control:Hide() end
    frame.detailEmpty:Hide()
    for _, slot in ipairs(frame.slotButtons) do slot:Hide() end
    if not entry then
        if #frame.entries == 0 then
            frame.detailEmpty:SetText("No saved guild gear")
        elseif #frame.filteredEntries == 0 then
            frame.detailEmpty:SetText("No characters found")
        else
            frame.detailEmpty:SetText("Select a character")
        end
        frame.detailEmpty:Show()
        return
    end

    local model = GGM.BuildGuildGearBrowserDetail(entry.record, api)
    frame.detailModel = model
    if not model.hasRecord then
        frame.detailEmpty:SetText("No saved guild gear")
        frame.detailEmpty:Show()
        return
    end
    setText(frame.characterLine, model.characterName)
    setText(frame.realmLine, model.realm)
    setText(frame.capturedLine, "Saved capture: " .. model.capturedAtText)
    for index, slot in ipairs(model.slots) do
        local button = frame.slotButtons[index]
        button.key = slot.key
        button.icon:SetTexture(slot.icon)
        button.icon:SetDesaturated(slot.empty)
        button.icon:SetAlpha(slot.empty and 0.35 or 1)
        button.label:SetText(slot.empty and (slot.key .. " (empty)") or slot.key)
        button.empty = slot.empty
        button.itemID = slot.itemID
        button.itemLink = slot.itemLink
        button:SetScript("OnEnter", function(self)
            if self.itemLink and api.GameTooltip then
                api.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                api.GameTooltip:SetHyperlink(self.itemLink)
                api.GameTooltip:Show()
            end
        end)
        button:SetScript("OnLeave", function()
            if api.GameTooltip then api.GameTooltip:Hide() end
        end)
        button:Show()
    end
end

local function updateBrowserList(frame, api)
    frame.filteredEntries = GGM.FilterGuildGearBrowserEntries(frame.entries, frame.searchBox:GetText() or "")
    local selectedStillVisible = false
    for _, entry in ipairs(frame.filteredEntries) do
        if frame.selectedEntry and entry.key == frame.selectedEntry.key then selectedStillVisible = true end
    end
    if not selectedStillVisible then frame.selectedEntry = frame.filteredEntries[1] end

    local rows = frame.listRows
    for index, entry in ipairs(frame.filteredEntries) do
        local row = rows[index]
        if not row then
            row = api.CreateFrame("Button", nil, frame.listContent)
            row:SetSize(220, 28)
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
            row.label:SetJustifyH("LEFT")
            row:RegisterForClicks("LeftButtonUp")
            rows[index] = row
        end
        row.entry = entry
        row.label:SetText(entry.name .. " - " .. entry.realm)
        row:SetPoint("TOPLEFT", frame.listContent, "TOPLEFT", 0, -(index - 1) * 28)
        row.selected = frame.selectedEntry ~= nil and frame.selectedEntry.key == entry.key
        if row.label.SetTextColor then
            if row.selected then row.label:SetTextColor(1, 0.82, 0) else row.label:SetTextColor(1, 1, 1) end
        end
        local selectedRow = row
        row:SetScript("OnClick", function()
            frame.selectedEntry = selectedRow.entry
            updateBrowserList(frame, api)
            renderBrowserDetail(frame, frame.selectedEntry, api)
        end)
        row:Show()
    end
    for index = #frame.filteredEntries + 1, #rows do rows[index]:Hide() end
    frame.listContent:SetHeight(math.max(#frame.filteredEntries * 28, 1))

    if #frame.entries == 0 then
        frame.listEmpty:SetText("No saved guild gear")
        frame.listEmpty:Show()
    elseif #frame.filteredEntries == 0 then
        frame.listEmpty:SetText("No characters found")
        frame.listEmpty:Show()
    else
        frame.listEmpty:Hide()
    end
    renderBrowserDetail(frame, frame.selectedEntry, api)
end

function GGM.CreateGuildGearBrowserWindow(api)
    local frame = api.CreateFrame("Frame", "GuildGearMemoryBrowserFrame", api.UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(900, 610)
    frame:SetPoint("CENTER")
    frame:SetClampedToScreen(true)
    frame:Hide()
    frame.TitleText:SetText("Guild Gear Memory - Saved Gear")
    frame.entries, frame.filteredEntries, frame.listRows, frame.slotButtons = {}, {}, {}, {}

    frame.searchLabel = createText(frame, "OVERLAY", "GameFontNormal")
    frame.searchLabel:SetText("Search characters")
    frame.searchLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -40)
    frame.searchBox = api.CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.searchBox:SetSize(230, 28)
    frame.searchBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -60)
    frame.searchBox:SetAutoFocus(false)
    frame.searchBox:SetScript("OnTextChanged", function()
        updateBrowserList(frame, api)
    end)

    frame.listScroll = api.CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.listScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -98)
    frame.listScroll:SetSize(250, 480)
    frame.listContent = api.CreateFrame("Frame", nil, frame.listScroll)
    frame.listContent:SetSize(230, 1)
    frame.listScroll:SetScrollChild(frame.listContent)
    frame.listEmpty = createText(frame, "OVERLAY", "GameFontNormal")
    frame.listEmpty:SetPoint("TOPLEFT", frame, "TOPLEFT", 28, -112)
    frame.listEmpty:Hide()

    frame.characterLine = createText(frame, "OVERLAY", "GameFontNormalLarge")
    frame.characterLine:SetPoint("TOPLEFT", frame, "TOPLEFT", 300, -48)
    frame.realmLine = createText(frame, "OVERLAY", "GameFontHighlight")
    frame.realmLine:SetPoint("TOPLEFT", frame.characterLine, "BOTTOMLEFT", 0, -6)
    frame.capturedLine = createText(frame, "OVERLAY", "GameFontHighlightSmall")
    frame.capturedLine:SetPoint("TOPLEFT", frame.realmLine, "BOTTOMLEFT", 0, -6)
    frame.detailEmpty = createText(frame, "OVERLAY", "GameFontNormalLarge")
    frame.detailEmpty:SetPoint("CENTER", frame, "CENTER", 120, -20)
    frame.detailEmpty:Hide()

    -- Keep the full 62px slot buttons inside the right detail panel while
    -- leaving a clear gutter after the character list (which ends at x=270).
    local centerX, centerY, radiusX, radiusY = 590, -365, 250, 174
    for index, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local angle = ((index - 1) / #GGM.TRACKED_SLOTS) * (2 * math.pi) - (math.pi / 2)
        local button = api.CreateFrame("Button", nil, frame)
        button:SetSize(62, 64)
        button:SetPoint("CENTER", frame, "TOPLEFT", centerX + math.cos(angle) * radiusX, centerY + math.sin(angle) * radiusY)
        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetSize(42, 42)
        button.icon:SetPoint("TOP", button, "TOP", 0, -1)
        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.label:SetPoint("TOP", button.icon, "BOTTOM", 0, -2)
        button.label:SetText(trackedSlot.key)
        button:Hide()
        frame.slotButtons[index] = button
    end
    return frame
end

function GGM.ShowGuildGearBrowserWindow(api, db)
    if not GGM.guildGearBrowserFrame then GGM.guildGearBrowserFrame = GGM.CreateGuildGearBrowserWindow(api) end
    local frame = GGM.guildGearBrowserFrame
    local query = frame.searchBox:GetText() or ""
    local selectedKey = frame.selectedEntry and frame.selectedEntry.key or nil
    frame.entries = GGM.BuildGuildGearBrowserEntries(db)
    frame.searchBox:SetText(query)
    frame.filteredEntries = GGM.FilterGuildGearBrowserEntries(frame.entries, query)
    frame.selectedEntry = nil
    for _, entry in ipairs(frame.filteredEntries) do
        if entry.key == selectedKey then frame.selectedEntry = entry; break end
    end
    if not frame.selectedEntry then frame.selectedEntry = frame.filteredEntries[1] end
    updateBrowserList(frame, api)
    frame:Show()
    return frame.detailModel
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

        GGM.ShowGuildGearBrowserWindow(api, GGM.db)
    end
end
