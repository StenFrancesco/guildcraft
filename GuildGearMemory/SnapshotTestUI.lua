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

local slotColumns = {
    left = { "HEAD", "NECK", "SHOULDER", "BACK", "CHEST", "SHIRT", "TABARD", "WRIST" },
    right = { "HANDS", "WAIST", "LEGS", "FEET", "FINGER_1", "FINGER_2", "TRINKET_1", "TRINKET_2" },
    bottom = { "MAIN_HAND", "OFF_HAND", "RANGED" },
}
GGM.BROWSER_SLOT_LAYOUT = {}
for group, keys in pairs(slotColumns) do
    for order, key in ipairs(keys) do GGM.BROWSER_SLOT_LAYOUT[key] = { group = group, order = order } end
end

local slotDisplayNames = {
    HEAD = "Head", NECK = "Neck", SHOULDER = "Shoulder", BACK = "Back", CHEST = "Chest",
    SHIRT = "Shirt", TABARD = "Tabard", WRIST = "Wrist", HANDS = "Hands", WAIST = "Waist",
    LEGS = "Legs", FEET = "Feet", FINGER_1 = "Ring 1", FINGER_2 = "Ring 2",
    TRINKET_1 = "Trinket 1", TRINKET_2 = "Trinket 2", MAIN_HAND = "Main hand",
    OFF_HAND = "Off hand", RANGED = "Ranged",
}

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
        or type(GGM.GetCharacterRecord) ~= "function" then
        return entries
    end

    for key in pairs(db.characters) do
        local record = GGM.GetCharacterRecord(db, key)
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
    if type(record) ~= "table"
        or type(record.identity) ~= "table"
    then return false end
    local baseValid = type(record.identity.key) == "string"
        and type(record.identity.name) == "string"
        and record.identity.name ~= ""
        and type(record.identity.realm) == "string"
        and record.identity.realm ~= ""
        and record.identity.key == record.identity.name .. "-" .. record.identity.realm
        and type(record.gear) == "table"
        and type(record.gear.slots) == "table"
        and type(record.gear.capturedAt) == "number"
    if not baseValid then return false end
    if record.complete == true then
        return record.gear.complete == true and GGM.ValidateCompleteSnapshot(record.gear) == true
    end
    if record.complete ~= false or record.completeness ~= "incomplete" or record.gear.complete ~= false
        or type(GGM.GetCharacterRecord) ~= "function" then return false end
    local validated = GGM.GetCharacterRecord({
        schemaVersion = GGM.SCHEMA_VERSION,
        characters = { [record.identity.key] = record },
    }, record.identity.key)
    return validated == record
end

function GGM.BuildGuildGearBrowserDetail(record, api)
    api = type(api) == "table" and api or {}
    if not hasValidBrowserDetailRecord(record) then return { hasRecord = false } end

    local slots = {}
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local savedSlot = record.gear.slots[trackedSlot.key]
        local slotTexture = getSlotTexture(api, trackedSlot)
        local unavailable = savedSlot == nil
        local empty = not unavailable and savedSlot.itemID == false
        local icon = slotTexture
        if not unavailable and not empty then icon = getItemIcon(api, savedSlot.itemID) or slotTexture end
        local layout = GGM.BROWSER_SLOT_LAYOUT[trackedSlot.key]
        local displayName = slotDisplayNames[trackedSlot.key]
        local itemID, itemLink, inventorySlotID
        if savedSlot then itemID, itemLink, inventorySlotID = savedSlot.itemID, savedSlot.itemLink, savedSlot.inventorySlotID end
        table.insert(slots, {
            key = trackedSlot.key,
            inventorySlotID = inventorySlotID,
            itemID = itemID,
            itemLink = itemLink,
            empty = empty,
            unavailable = unavailable,
            valueText = unavailable and "No data" or nil,
            displayName = displayName,
            statusText = unavailable and "No data" or (empty and "Empty" or nil),
            slotTexture = slotTexture,
            icon = icon,
            layoutGroup = layout.group,
            layoutOrder = layout.order,
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
        complete = record.complete == true,
        refreshNeeded = record.refreshNeeded == true,
        completenessText = record.complete == true and "Complete"
            or (record.refreshNeeded == true and "Refresh needed" or "Incomplete"),
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

-- A compact inset frame styled after Classic list panes.  It avoids newer
-- backdrop APIs so the browser keeps working across Classic clients.
local function createClassicInsetPanel(api, parent, width, height)
    local panel = api.CreateFrame("Frame", nil, parent)
    panel:SetSize(width, height)

    panel.background = panel:CreateTexture(nil, "BACKGROUND")
    panel.background:SetAllPoints(panel)
    panel.background:SetColorTexture(0.018, 0.016, 0.015, 0.96)

    panel.leather = panel:CreateTexture(nil, "BACKGROUND")
    panel.leather:SetAllPoints(panel)
    panel.leather:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background")
    panel.leather:SetAlpha(0.20)

    -- Soft black outer edge and pale raised trim approximate the old Classic
    -- inset boxes used by guild, friends and character-list panels.
    local edge = 2
    local top = panel:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    top:SetHeight(edge)
    top:SetColorTexture(0.66, 0.66, 0.64, 0.95)

    local left = panel:CreateTexture(nil, "BORDER")
    left:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
    left:SetWidth(edge)
    left:SetColorTexture(0.60, 0.60, 0.58, 0.95)

    local bottom = panel:CreateTexture(nil, "BORDER")
    bottom:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    bottom:SetHeight(edge)
    bottom:SetColorTexture(0.20, 0.20, 0.20, 1)

    local right = panel:CreateTexture(nil, "BORDER")
    right:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(edge)
    right:SetColorTexture(0.20, 0.20, 0.20, 1)

    local inner = panel:CreateTexture(nil, "BORDER")
    inner:SetPoint("TOPLEFT", panel, "TOPLEFT", 3, -3)
    inner:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -3, 3)
    inner:SetColorTexture(0.025, 0.022, 0.020, 0.75)

    return panel
end

-- Build the equipment area from simple Blizzard-native pieces instead of relying on
-- a retail-only paper-doll template.  The dark leather, brass trim and quick-slot
-- borders keep the panel at home in the Classic UI while remaining safe on clients
-- where some optional art assets are unavailable.
local function createClassicGearPanel(api, parent)
    local panel = api.CreateFrame("Frame", nil, parent)
    panel:SetSize(570, 438)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 292, -128)

    panel.background = panel:CreateTexture(nil, "BACKGROUND")
    panel.background:SetAllPoints(panel)
    panel.background:SetColorTexture(0.035, 0.026, 0.017, 0.98)

    panel.leather = panel:CreateTexture(nil, "BACKGROUND")
    panel.leather:SetAllPoints(panel)
    panel.leather:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background")
    panel.leather:SetAlpha(0.28)

    panel.headerBackground = panel:CreateTexture(nil, "BORDER")
    panel.headerBackground:SetSize(566, 34)
    panel.headerBackground:SetPoint("TOP", panel, "TOP", 0, -2)
    panel.headerBackground:SetColorTexture(0.105, 0.070, 0.026, 0.98)

    panel.headerLine = panel:CreateTexture(nil, "BORDER")
    panel.headerLine:SetSize(548, 1)
    panel.headerLine:SetPoint("TOP", panel.headerBackground, "BOTTOM", 0, 0)
    panel.headerLine:SetColorTexture(0.55, 0.39, 0.11, 0.90)

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.title:SetPoint("CENTER", panel.headerBackground, "CENTER", 0, 0)
    panel.title:SetText("Equipment")
    panel.title:SetTextColor(1.0, 0.82, 0.0)

    -- Keep the center open. The slot columns and weapon row frame the equipment
    -- naturally, without an extra inset box or instructional text.

    -- Outer double-line trim: dark outer edge + warm brass inner edge.
    local outerTop = panel:CreateTexture(nil, "BORDER")
    outerTop:SetSize(570, 2)
    outerTop:SetPoint("TOP", panel, "TOP", 0, 0)
    outerTop:SetColorTexture(0.16, 0.105, 0.035, 1)
    local outerBottom = panel:CreateTexture(nil, "BORDER")
    outerBottom:SetSize(570, 2)
    outerBottom:SetPoint("BOTTOM", panel, "BOTTOM", 0, 0)
    outerBottom:SetColorTexture(0.16, 0.105, 0.035, 1)
    local outerLeft = panel:CreateTexture(nil, "BORDER")
    outerLeft:SetSize(2, 438)
    outerLeft:SetPoint("LEFT", panel, "LEFT", 0, 0)
    outerLeft:SetColorTexture(0.16, 0.105, 0.035, 1)
    local outerRight = panel:CreateTexture(nil, "BORDER")
    outerRight:SetSize(2, 438)
    outerRight:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    outerRight:SetColorTexture(0.16, 0.105, 0.035, 1)

    local innerTop = panel:CreateTexture(nil, "BORDER")
    innerTop:SetSize(564, 1)
    innerTop:SetPoint("TOP", panel, "TOP", 0, -3)
    innerTop:SetColorTexture(0.58, 0.42, 0.12, 0.94)
    local innerBottom = panel:CreateTexture(nil, "BORDER")
    innerBottom:SetSize(564, 1)
    innerBottom:SetPoint("BOTTOM", panel, "BOTTOM", 0, 3)
    innerBottom:SetColorTexture(0.58, 0.42, 0.12, 0.94)
    local innerLeft = panel:CreateTexture(nil, "BORDER")
    innerLeft:SetSize(1, 432)
    innerLeft:SetPoint("LEFT", panel, "LEFT", 3, 0)
    innerLeft:SetColorTexture(0.58, 0.42, 0.12, 0.94)
    local innerRight = panel:CreateTexture(nil, "BORDER")
    innerRight:SetSize(1, 432)
    innerRight:SetPoint("RIGHT", panel, "RIGHT", -3, 0)
    innerRight:SetColorTexture(0.58, 0.42, 0.12, 0.94)

    return panel
end

local function renderBrowserDetail(frame, entry, api)
    frame.detailModel = nil
    for _, control in ipairs({ frame.characterLine, frame.realmLine, frame.capturedLine, frame.completenessLine }) do control:Hide() end
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
    setText(frame.completenessLine, model.completenessText)
    for index, slot in ipairs(model.slots) do
        local button = frame.slotButtons[index]
        button.key = slot.key
        button.icon:SetTexture(slot.icon)
        button.icon:SetDesaturated(slot.empty or slot.unavailable)
        button.icon:SetAlpha(slot.unavailable and 0.18 or (slot.empty and 0.42 or 1))
        if button.border then button.border:SetAlpha(slot.unavailable and 0.45 or (slot.empty and 0.72 or 1)) end
        button.label:SetText(slot.displayName)
        setText(button.status, slot.statusText)
        button.empty = slot.empty
        button.unavailable = slot.unavailable
        button.itemID = slot.itemID
        button.itemLink = slot.itemLink
        button.slotDisplayName = slot.displayName
        button:SetScript("OnEnter", function(self)
            if not api.GameTooltip then return end
            local anchor = self.paperDollGroup == "right" and "ANCHOR_LEFT" or "ANCHOR_RIGHT"
            api.GameTooltip:SetOwner(self, anchor)
            if self.itemLink then
                api.GameTooltip:SetHyperlink(self.itemLink)
            elseif type(api.GameTooltip.SetText) == "function" then
                api.GameTooltip:SetText(self.slotDisplayName or self.key or "Equipment")
                if type(api.GameTooltip.AddLine) == "function" then
                    if self.unavailable then
                        api.GameTooltip:AddLine("No saved data", 0.65, 0.65, 0.65)
                    elseif self.empty then
                        api.GameTooltip:AddLine("Empty", 0.65, 0.65, 0.65)
                    end
                end
            end
            api.GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function()
            if api.GameTooltip then api.GameTooltip:Hide() end
        end)
        button:Show()
    end
end

local function setBrowserContentVisible(frame, visible)
    local alwaysCharacterControls = {
        frame.searchPanel,
        frame.searchLabel,
        frame.searchBox,
        frame.listPanel,
        frame.listScroll,
    }
    for _, control in ipairs(alwaysCharacterControls) do
        if control then
            if visible then control:Show() else control:Hide() end
        end
    end

    local conditionalControls = {
        frame.listEmpty,
        frame.characterLine,
        frame.realmLine,
        frame.capturedLine,
        frame.completenessLine,
        frame.detailEmpty,
    }
    if not visible then
        for _, control in ipairs(conditionalControls) do
            if control then control:Hide() end
        end
    end

    if frame.gearPanel then
        if visible then frame.gearPanel:Show() else frame.gearPanel:Hide() end
    end
    for _, button in ipairs(frame.slotButtons) do
        if not visible then button:Hide() end
    end
end

local updateBrowserList

function GGM.SelectGuildGearBrowserTab(frame, selectedKey)
    if selectedKey ~= "Character" and selectedKey ~= "Professions" and selectedKey ~= "Bank" then
        return false
    end

    frame.activeTab = selectedKey
    frame.TitleText:SetText(selectedKey == "Character"
        and "Guild Gear Memory - Saved Gear"
        or "Guild Gear Memory - " .. selectedKey)

    for _, tab in ipairs(frame.navigationTabs) do
        local selected = tab.key == selectedKey
        tab.background:SetColorTexture(selected and 0.20 or 0.055, selected and 0.16 or 0.055,
            selected and 0.025 or 0.065, 0.96)
        if selected then tab.label:SetTextColor(1, 0.82, 0) else tab.label:SetTextColor(0.9, 0.9, 0.9) end
    end

    local showCharacter = selectedKey == "Character"
    for pageKey, page in pairs(frame.placeholderPages) do
        if pageKey == selectedKey then page:Show() else page:Hide() end
    end
    if showCharacter then
        setBrowserContentVisible(frame, true)
        updateBrowserList(frame, frame.api)
    else
        setBrowserContentVisible(frame, false)
    end
    return true
end

updateBrowserList = function(frame, api)
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
            row:SetSize(224, 24)

            row.selection = row:CreateTexture(nil, "BACKGROUND")
            row.selection:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
            row.selection:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
            row.selection:SetColorTexture(0.56, 0.48, 0.00, 0.66)
            row.selection:Hide()

            row.hover = row:CreateTexture(nil, "HIGHLIGHT")
            row.hover:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
            row.hover:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
            row.hover:SetColorTexture(0.34, 0.29, 0.05, 0.35)

            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.label:SetPoint("LEFT", row, "LEFT", 5, 0)
            row.label:SetWidth(214)
            row.label:SetJustifyH("LEFT")
            row:RegisterForClicks("LeftButtonUp")
            rows[index] = row
        end
        row.entry = entry
        row.label:SetText(entry.name .. " - " .. entry.realm)
        row:SetPoint("TOPLEFT", frame.listContent, "TOPLEFT", 0, -(index - 1) * 24)
        row.selected = frame.selectedEntry ~= nil and frame.selectedEntry.key == entry.key
        if row.selected then row.selection:Show() else row.selection:Hide() end
        if row.label.SetTextColor then
            if row.selected then row.label:SetTextColor(1, 0.92, 0.05) else row.label:SetTextColor(0.95, 0.95, 0.92) end
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
    frame.listContent:SetHeight(math.max(#frame.filteredEntries * 24, 1))

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
    if frame.activeTab ~= "Character" then
        setBrowserContentVisible(frame, false)
    end
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
    tab:SetScript("OnClick", function() GGM.SelectGuildGearBrowserTab(frame, key) end)
    return tab
end

function GGM.CreateGuildGearBrowserWindow(api)
    local frame = api.CreateFrame("Frame", "GuildGearMemoryBrowserFrame", api.UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(900, 610)
    frame:SetPoint("CENTER")
    frame:SetClampedToScreen(true)
    frame:Hide()
    frame.api = api
    frame.TitleText:SetText("Guild Gear Memory - Saved Gear")
    frame.entries, frame.filteredEntries, frame.listRows, frame.slotButtons = {}, {}, {}, {}

    -- Left browser column: separate inset search and character-list panes, styled
    -- after the compact black/silver list frames used throughout the Classic UI.
    frame.searchPanel = createClassicInsetPanel(api, frame, 258, 74)
    frame.searchPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -42)

    frame.searchLabel = createText(frame.searchPanel, "OVERLAY", "GameFontNormal")
    frame.searchLabel:SetText("Search characters")
    frame.searchLabel:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", 10, -9)
    frame.searchLabel:SetTextColor(1, 0.82, 0)

    frame.searchBox = api.CreateFrame("EditBox", nil, frame.searchPanel, "InputBoxTemplate")
    frame.searchBox:SetSize(232, 26)
    frame.searchBox:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", 11, -34)
    frame.searchBox:SetAutoFocus(false)
    frame.searchBox:SetScript("OnTextChanged", function()
        updateBrowserList(frame, api)
    end)

    frame.listPanel = createClassicInsetPanel(api, frame, 258, 458)
    frame.listPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -126)

    frame.listScroll = api.CreateFrame("ScrollFrame", nil, frame.listPanel, "UIPanelScrollFrameTemplate")
    frame.listScroll:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 7, -7)
    frame.listScroll:SetSize(242, 444)
    frame.listContent = api.CreateFrame("Frame", nil, frame.listScroll)
    frame.listContent:SetSize(224, 1)
    frame.listScroll:SetScrollChild(frame.listContent)
    frame.listEmpty = createText(frame.listPanel, "OVERLAY", "GameFontNormal")
    frame.listEmpty:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 14, -14)
    frame.listEmpty:Hide()

    frame.characterLine = createText(frame, "OVERLAY", "GameFontNormalLarge")
    frame.characterLine:SetPoint("TOPLEFT", frame, "TOPLEFT", 300, -48)
    frame.realmLine = createText(frame, "OVERLAY", "GameFontHighlight")
    frame.realmLine:SetPoint("TOPLEFT", frame.characterLine, "BOTTOMLEFT", 0, -6)
    frame.capturedLine = createText(frame, "OVERLAY", "GameFontHighlightSmall")
    frame.capturedLine:SetPoint("TOPLEFT", frame.realmLine, "BOTTOMLEFT", 0, -6)
    frame.completenessLine = createText(frame, "OVERLAY", "GameFontHighlightSmall")
    frame.completenessLine:SetPoint("TOPLEFT", frame.capturedLine, "BOTTOMLEFT", 0, -4)
    frame.gearPanel = createClassicGearPanel(api, frame)

    frame.detailEmpty = createText(frame.gearPanel, "OVERLAY", "GameFontNormalLarge")
    frame.detailEmpty:SetPoint("CENTER", frame.gearPanel, "CENTER", 0, -12)
    frame.detailEmpty:Hide()

    -- Classic paper-doll arrangement: eight slots on each side and weapons along
    -- the bottom.  Slot names sit beside the icons instead of underneath them,
    -- which leaves the center uncluttered and makes the silhouette easier to read.
    local sideX = { left = 32, right = 538 }
    local sideStartY, sidePitch = -68, 46
    local bottomX = { 210, 285, 360 }
    local bottomY = -374
    for index, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local layout = GGM.BROWSER_SLOT_LAYOUT[trackedSlot.key]
        local x, y
        if layout.group == "bottom" then
            x, y = bottomX[layout.order], bottomY
        else
            x = sideX[layout.group]
            y = sideStartY - (layout.order - 1) * sidePitch
        end

        local button = api.CreateFrame("Button", nil, frame.gearPanel)
        button:SetSize(46, 46)
        button:SetPoint("CENTER", frame.gearPanel, "TOPLEFT", x, y)
        button.paperDollGroup, button.paperDollOrder = layout.group, layout.order

        button.slotBackground = button:CreateTexture(nil, "BACKGROUND")
        button.slotBackground:SetSize(38, 38)
        button.slotBackground:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.slotBackground:SetColorTexture(0.015, 0.015, 0.015, 0.96)

        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetSize(36, 36)
        button.icon:SetPoint("CENTER", button, "CENTER", 0, 0)

        button.border = button:CreateTexture(nil, "OVERLAY")
        button.border:SetSize(54, 54)
        button.border:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")

        button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
        button.highlight:SetSize(42, 42)
        button.highlight:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")

        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.label:SetText(slotDisplayNames[trackedSlot.key])
        button.label:SetTextColor(0.88, 0.78, 0.56)

        button.status = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")

        if layout.group == "left" then
            button.label:SetWidth(92)
            button.label:SetJustifyH("LEFT")
            button.label:SetPoint("LEFT", button, "RIGHT", 7, 6)
            button.status:SetWidth(92)
            button.status:SetJustifyH("LEFT")
            button.status:SetPoint("TOPLEFT", button.label, "BOTTOMLEFT", 0, -1)
        elseif layout.group == "right" then
            button.label:SetWidth(92)
            button.label:SetJustifyH("RIGHT")
            button.label:SetPoint("RIGHT", button, "LEFT", -7, 6)
            button.status:SetWidth(92)
            button.status:SetJustifyH("RIGHT")
            button.status:SetPoint("TOPRIGHT", button.label, "BOTTOMRIGHT", 0, -1)
        else
            button.label:SetWidth(70)
            button.label:SetJustifyH("CENTER")
            button.label:SetPoint("TOP", button, "BOTTOM", 0, -2)
            button.status:SetWidth(70)
            button.status:SetJustifyH("CENTER")
            button.status:SetPoint("TOP", button.label, "BOTTOM", 0, -1)
        end

        button:Hide()
        frame.slotButtons[index] = button
    end

    frame.placeholderPages = {}
    for _, pageKey in ipairs({ "Professions", "Bank" }) do
        local page = createText(frame, "OVERLAY", "GameFontNormalLarge")
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
    GGM.SelectGuildGearBrowserTab(frame, "Character")
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
    GGM.SelectGuildGearBrowserTab(frame, frame.activeTab or "Character")
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
