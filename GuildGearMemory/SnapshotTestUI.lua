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

function GGM.FilterGuildGearBrowserOwnership(entries, db, view)
    local filtered = {}
    if type(entries) ~= "table" then return filtered end
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.key) == "string" then
            local isMine = type(GGM.IsLocalCharacter) == "function"
                and GGM.IsLocalCharacter(db, entry.key) == true
            if (view == "Mine" and isMine) or (view ~= "Mine" and not isMine) then
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
        local unavailable = savedSlot == nil or savedSlot.unavailable == true
        local empty = not unavailable and savedSlot.itemID == false
        local icon = slotTexture
        if not unavailable and not empty then icon = getItemIcon(api, savedSlot.itemID) or slotTexture end
        local layout = GGM.BROWSER_SLOT_LAYOUT[trackedSlot.key]
        local displayName = slotDisplayNames[trackedSlot.key]
        local itemID, itemLink, inventorySlotID
        if savedSlot and not unavailable then
            itemID, itemLink, inventorySlotID = savedSlot.itemID, savedSlot.itemLink, savedSlot.inventorySlotID
        end
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
        modelInput = record,
        modelState = "render-unavailable",
        slots = slots,
    }
end

function GGM.BuildSnapshotViewModel(record, formatTime)
    if not hasValidDisplayShape(record) then return missingModel() end
    local slotRows = {}
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local savedSlot = record.gear.slots[trackedSlot.key]
        local valueText
        if savedSlot == nil and GGM.OPTIONAL_TRACKED_SLOTS[trackedSlot.key] == true then
            valueText = "No data"
        elseif type(savedSlot) ~= "table" then
            return missingModel()
        elseif savedSlot.unavailable == true then
            valueText = "No data"
        elseif type(savedSlot.inventorySlotID) ~= "number" then
            return missingModel()
        elseif type(savedSlot.itemID) == "number" and type(savedSlot.itemLink) == "string" and savedSlot.itemLink ~= "" then
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

-- Presentation-only design system. Data models, storage, sync, tracking and
-- snapshot semantics deliberately remain outside this section.
local THEME = {
    -- Blizzard-inspired neutral/gold palette. Kept deliberately close to the
    -- game UI so the addon reads like another native character/guild panel.
    canvas = { 0.040, 0.032, 0.024, 0.975 },
    rail = { 0.055, 0.043, 0.030, 0.985 },
    header = { 0.070, 0.052, 0.034, 0.990 },
    panel = { 0.035, 0.030, 0.024, 0.970 },
    panelAlt = { 0.072, 0.058, 0.041, 0.965 },
    panelRaised = { 0.105, 0.082, 0.054, 0.980 },
    panelHover = { 1.000, 0.820, 0.300, 0.10 },
    input = { 0.018, 0.016, 0.013, 0.985 },
    slot = { 0.020, 0.018, 0.015, 1.000 },
    border = { 0.420, 0.335, 0.190, 0.92 },
    borderSoft = { 0.215, 0.165, 0.095, 0.78 },
    borderDark = { 0.010, 0.009, 0.007, 1.000 },
    gold = { 0.925, 0.710, 0.250, 1.000 },
    goldBright = { 1.000, 0.835, 0.390, 1.000 },
    goldDim = { 0.245, 0.160, 0.045, 0.88 },
    goldHover = { 1.000, 0.820, 0.300, 0.13 },
    cyan = { 0.370, 0.760, 1.000, 1.000 },
    success = { 0.350, 0.900, 0.450, 1.000 },
    warning = { 1.000, 0.620, 0.180, 1.000 },
    danger = { 0.950, 0.300, 0.220, 1.000 },
    text = { 1.000, 0.965, 0.830, 1.000 },
    textSoft = { 0.900, 0.835, 0.690, 1.000 },
    muted = { 0.620, 0.560, 0.455, 1.000 },
    disabled = { 0.390, 0.350, 0.290, 1.000 },
}

local UI = {
    space1 = 4,
    space2 = 8,
    space3 = 12,
    space4 = 16,
    space5 = 20,
    space6 = 24,
    borderWidth = 1,
    windowWidth = 1180,
    windowHeight = 720,
    railWidth = 184,
    headerHeight = 64,
    pageMargin = 18,
    contentTop = 100,
    contentBottom = 18,
    navigationRowHeight = 46,
    navigationIconSize = 22,
    browserColumnWidth = 286,
    detailColumnWidth = 656,
    contentGap = 16,
    ownershipButtonWidth = 94,
    controlHeightCompact = 30,
    characterRowHeight = 50,
    listScrollWidth = 258,
    listScrollHeight = 420,
    professionSidebarWidth = 244,
    professionRowHeight = 46,
}
GGM.UIStyleTokens = UI

local function space(index)
    return UI["space" .. tostring(index)]
end

local function setColor(texture, color, alphaOverride)
    if texture and type(texture.SetColorTexture) == "function" then
        texture:SetColorTexture(color[1], color[2], color[3], alphaOverride or color[4] or 1)
    end
end

local function setTextColor(text, color)
    if text and type(text.SetTextColor) == "function" then
        text:SetTextColor(color[1], color[2], color[3], color[4] or 1)
    end
end

function GGM.SetUITextTone(text, tone)
    if not text or type(text.SetTextColor) ~= "function" then return false end
    local color = tone == "success" and THEME.success
        or (tone == "warning" and THEME.warning)
        or (tone == "primary" and THEME.text)
        or (tone == "accent" and THEME.goldBright)
        or THEME.muted
    setTextColor(text, color)
    return true
end

local function createFlatBorder(panel, color, inset)
    inset = inset or 0
    local edges = {}
    local top = panel:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT", panel, "TOPLEFT", inset, -inset)
    top:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -inset, -inset)
    top:SetHeight(UI.borderWidth)
    setColor(top, color)
    edges[#edges + 1] = top

    local bottom = panel:CreateTexture(nil, "BORDER")
    bottom:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", inset, inset)
    bottom:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -inset, inset)
    bottom:SetHeight(UI.borderWidth)
    setColor(bottom, color)
    edges[#edges + 1] = bottom

    local left = panel:CreateTexture(nil, "BORDER")
    left:SetPoint("TOPLEFT", panel, "TOPLEFT", inset, -inset)
    left:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", inset, inset)
    left:SetWidth(UI.borderWidth)
    setColor(left, color)
    edges[#edges + 1] = left

    local right = panel:CreateTexture(nil, "BORDER")
    right:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -inset, -inset)
    right:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -inset, inset)
    right:SetWidth(UI.borderWidth)
    setColor(right, color)
    edges[#edges + 1] = right
    return edges
end

local function recolorBorder(edges, color)
    for _, edge in ipairs(edges or {}) do setColor(edge, color) end
end

local function createSurface(api, parent, backgroundColor, borderColor, doubleBorder)
    local panel = api.CreateFrame("Frame", nil, parent)
    panel.background = panel:CreateTexture(nil, "BACKGROUND")
    panel.background:SetAllPoints(panel)
    panel.background:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background-Dark")
    panel.background:SetVertexColor((backgroundColor or THEME.panel)[1], (backgroundColor or THEME.panel)[2], (backgroundColor or THEME.panel)[3], 1)
    panel.background:SetAlpha((backgroundColor or THEME.panel)[4] or 1)
    panel.border = createFlatBorder(panel, borderColor or THEME.borderSoft)
    if doubleBorder then panel.innerBorder = createFlatBorder(panel, THEME.borderDark, 2) end
    return panel
end

local function createDivider(parent, leftInset, rightInset, y)
    local line = parent:CreateTexture(nil, "BORDER")
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", leftInset or 0, y or 0)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(rightInset or 0), y or 0)
    line:SetHeight(1)
    setColor(line, THEME.borderSoft)
    return line
end

local BUTTON_VARIANTS = {
    primary = { background = THEME.goldDim, border = THEME.gold, text = THEME.text, hover = THEME.goldHover },
    secondary = { background = THEME.panelRaised, border = THEME.border, text = THEME.textSoft, hover = THEME.panelHover },
    ghost = { background = THEME.panel, border = THEME.borderSoft, text = THEME.muted, hover = THEME.panelHover },
}

function GGM.SetFlatButtonState(button, state)
    if not button then return false end
    if state == "selected" then
        button.selected = true
        if button.LockHighlight then button:LockHighlight() end
        if button.label then setTextColor(button.label, THEME.goldBright) end
    elseif state == "disabled" then
        button.selected = false
        if button.UnlockHighlight then button:UnlockHighlight() end
        if button.label then setTextColor(button.label, THEME.disabled) end
    else
        if state ~= "pressed" then button.selected = false end
        if button.UnlockHighlight and not button.selected then button:UnlockHighlight() end
        if button.label then setTextColor(button.label, button.selected and THEME.goldBright or THEME.textSoft) end
    end
    button.visualState = state == "pressed" and "pressed" or (state or "idle")
    return true
end

function GGM.CreateFlatButton(api, parent, label, width, height, variant)
    if type(api) ~= "table" or type(api.CreateFrame) ~= "function" then return nil end
    -- Keep the legacy helper name because other UI modules call it, but render
    -- with Blizzard's own panel button template instead of bespoke flat chrome.
    local button = api.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button.variant = variant or "secondary"
    button:SetText(label or "")
    button.label = type(button.GetFontString) == "function" and button:GetFontString() or nil
    if not button.label then
        button.label = createText(button, "OVERLAY", "GameFontHighlightSmall")
        button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.label:SetText(label or "")
    end
    setTextColor(button.label, THEME.textSoft)
    button:RegisterForClicks("LeftButtonUp")
    button:SetScript("OnDisable", function(self) GGM.SetFlatButtonState(self, "disabled") end)
    button:SetScript("OnEnable", function(self) GGM.SetFlatButtonState(self, self.selected and "selected" or "idle") end)
    GGM.SetFlatButtonState(button, "idle")
    return button
end

local function createEyebrow(parent, text)
    local label = createText(parent, "OVERLAY", "GameFontNormalSmall")
    label:SetText(text)
    setTextColor(label, THEME.gold)
    return label
end

local function createSectionLabel(parent, text)
    local label = createText(parent, "OVERLAY", "GameFontNormalSmall")
    label:SetText(text)
    setTextColor(label, THEME.muted)
    return label
end

local function createStatusBadge(api, parent)
    local badge = createSurface(api, parent, THEME.panelRaised, THEME.borderSoft)
    badge:SetSize(126, 24)
    badge.dot = badge:CreateTexture(nil, "ARTWORK")
    badge.dot:SetSize(6, 6)
    badge.dot:SetPoint("LEFT", badge, "LEFT", 10, 0)
    badge.text = createText(badge, "OVERLAY", "GameFontHighlightSmall")
    badge.text:SetPoint("LEFT", badge.dot, "RIGHT", 7, 0)
    badge.text:SetPoint("RIGHT", badge, "RIGHT", -8, 0)
    badge.text:SetJustifyH("LEFT")
    return badge
end

local function setStatusBadge(badge, text, tone)
    if not badge then return end
    local color = tone == "success" and THEME.success or (tone == "warning" and THEME.warning) or THEME.muted
    badge.text:SetText(text or "")
    setTextColor(badge.text, color)
    setColor(badge.dot, color)
    recolorBorder(badge.border, { color[1], color[2], color[3], 0.48 })
end

local function createEmptyStateCard(api, parent, iconPath, title, body)
    local card = createSurface(api, parent, THEME.panelAlt, THEME.borderSoft, true)
    card:SetSize(390, 190)
    card.iconFrame = createSurface(api, card, THEME.slot, THEME.border)
    card.iconFrame:SetSize(52, 52)
    card.iconFrame:SetPoint("TOP", card, "TOP", 0, -24)
    card.icon = card.iconFrame:CreateTexture(nil, "ARTWORK")
    card.icon:SetPoint("TOPLEFT", card.iconFrame, "TOPLEFT", 5, -5)
    card.icon:SetPoint("BOTTOMRIGHT", card.iconFrame, "BOTTOMRIGHT", -5, 5)
    card.icon:SetTexture(iconPath)
    card.icon:SetAlpha(0.72)

    card.title = createText(card, "OVERLAY", "GameFontNormalLarge")
    card.title:SetPoint("TOP", card.iconFrame, "BOTTOM", 0, -14)
    card.title:SetText(title)
    setTextColor(card.title, THEME.text)

    card.body = createText(card, "OVERLAY", "GameFontHighlightSmall")
    card.body:SetPoint("TOP", card.title, "BOTTOM", 0, -8)
    card.body:SetWidth(326)
    card.body:SetJustifyH("CENTER")
    card.body:SetText(body)
    setTextColor(card.body, THEME.muted)
    return card
end

local function renderBrowserDetail(frame, entry, api)
    if type(GGM.ClearSavedCharacterModel) == "function" then
        GGM.ClearSavedCharacterModel(frame.characterModelView)
    elseif frame.characterModelView and frame.characterModelView.model then
        frame.characterModelView.model:Hide()
    end
    if frame.modelUnavailableLabel then frame.modelUnavailableLabel:Hide() end
    frame.detailModel = nil
    for _, control in ipairs({ frame.characterLine, frame.realmLine, frame.capturedLine, frame.completenessLine }) do
        if control then control:Hide() end
    end
    if frame.completenessBadge then frame.completenessBadge:Hide() end
    if frame.snapshotCaption then frame.snapshotCaption:Hide() end
    frame.detailEmpty:Hide()
    if frame.modelStage then frame.modelStage:Hide() end
    for _, slot in ipairs(frame.slotButtons) do slot:Hide() end

    if not entry then
        if #frame.activeEntries == 0 then
            frame.detailEmpty:SetText(frame.browserView == "Mine" and "No personal snapshots yet" or "No guild snapshots yet")
        elseif #frame.filteredEntries == 0 then
            frame.detailEmpty:SetText("No characters match your search")
        else
            frame.detailEmpty:SetText("Select a character")
        end
        frame.detailEmpty:Show()
        return
    end

    local model = GGM.BuildGuildGearBrowserDetail(entry.record, api)
    frame.detailModel = model
    if not model.hasRecord then
        frame.detailEmpty:SetText("No saved gear is available for this character")
        frame.detailEmpty:Show()
        return
    end

    if frame.modelStage then frame.modelStage:Show() end
    local renderState = type(GGM.RenderSavedCharacterModel) == "function"
        and GGM.RenderSavedCharacterModel(frame.characterModelView, model.modelInput)
        or "render-unavailable"
    model.modelState = renderState
    if renderState == "shown" then
        if frame.characterModelView.model then frame.characterModelView.model:Show() end
    else
        if frame.characterModelView.model then frame.characterModelView.model:Hide() end
        frame.modelUnavailableLabel:SetText("Saved character model unavailable")
        frame.modelUnavailableLabel:Show()
    end

    setText(frame.characterLine, model.characterName)
    setText(frame.realmLine, model.realm)
    setText(frame.capturedLine, model.capturedAtText)
    setText(frame.completenessLine, model.completenessText)
    if frame.snapshotCaption then frame.snapshotCaption:Show() end

    local statusTone = model.complete and "success" or "warning"
    setStatusBadge(frame.completenessBadge, model.completenessText, statusTone)
    frame.completenessBadge:Show()

    for index, slot in ipairs(model.slots) do
        local button = frame.slotButtons[index]
        button.key = slot.key
        button.icon:SetTexture(slot.icon)
        button.icon:SetDesaturated(slot.empty or slot.unavailable)
        button.icon:SetAlpha(slot.unavailable and 0.14 or (slot.empty and 0.32 or 1))
        setColor(button.slotBackground, slot.unavailable and THEME.input or THEME.slot)
        recolorBorder(button.borderEdges, slot.unavailable and THEME.borderSoft or (slot.empty and THEME.border or THEME.gold))
        if button.glow then
            if not slot.empty and not slot.unavailable then button.glow:Show() else button.glow:Hide() end
        end
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
                    if self.unavailable then api.GameTooltip:AddLine("No saved data", 0.55, 0.58, 0.63)
                    elseif self.empty then api.GameTooltip:AddLine("Empty", 0.55, 0.58, 0.63) end
                end
            end
            api.GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() if api.GameTooltip then api.GameTooltip:Hide() end end)
        button:Show()
    end
end

local function setBrowserContentVisible(frame, visible)
    for _, control in ipairs({ frame.searchPanel, frame.listPanel, frame.gearPanel }) do
        if control then if visible then control:Show() else control:Hide() end end
    end
    if not visible then
        if type(GGM.ClearSavedCharacterModel) == "function" then GGM.ClearSavedCharacterModel(frame.characterModelView)
        elseif frame.characterModelView and frame.characterModelView.model then frame.characterModelView.model:Hide() end
        for _, button in ipairs(frame.slotButtons) do button:Hide() end
    end
end

local PROFESSIONS = {
    { key = "Alchemy", professionID = 171, icon = "Interface\\Icons\\Trade_Alchemy" },
    { key = "Blacksmithing", professionID = 164, icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { key = "Enchanting", professionID = 333, icon = "Interface\\Icons\\Trade_Engraving" },
    { key = "Engineering", professionID = 202, icon = "Interface\\Icons\\Trade_Engineering" },
    { key = "Leatherworking", professionID = 165, icon = "Interface\\Icons\\Trade_LeatherWorking" },
    { key = "Tailoring", professionID = 197, icon = "Interface\\Icons\\Trade_Tailoring" },
}

local function professionButtonColor(button, selected)
    GGM.SetFlatButtonState(button, selected and "selected" or "idle")
    if button.icon then button.icon:SetAlpha(selected and 1 or 0.58) end
    if button.selectionBar then if selected then button.selectionBar:Show() else button.selectionBar:Hide() end end
end

local updateProfessionRecipeBrowser

function GGM.FilterProfessionRecipeBrowserEntries(entries, query)
    local filtered = {}
    if type(entries) ~= "table" then return filtered end
    local needle = type(query) == "string" and string.lower(query) or ""
    if needle == "" then
        for _, entry in ipairs(entries) do table.insert(filtered, entry) end
        return filtered
    end
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.name) == "string"
            and string.find(string.lower(entry.name), needle, 1, true) then
            table.insert(filtered, entry)
        end
    end
    return filtered
end

function GGM.SelectProfession(frame, selectedKey)
    local selectedProfession
    for _, profession in ipairs(PROFESSIONS) do if profession.key == selectedKey then selectedProfession = profession; break end end
    if not selectedProfession then return false end
    local changed = frame.selectedProfession ~= selectedKey
    frame.selectedProfession = selectedKey
    frame.professionHeading:SetText(selectedKey)
    if frame.professionHeroIcon then frame.professionHeroIcon:SetTexture(selectedProfession.icon) end
    for _, button in ipairs(frame.professionButtons) do professionButtonColor(button, button.key == selectedKey) end
    if changed and frame.professionSearchBox then frame.professionSearchBox:SetText("") end
    if frame.db and type(GGM.BuildProfessionRecipeCatalog) == "function" then
        frame.professionCatalog = GGM.BuildProfessionRecipeCatalog(frame.db, selectedProfession.professionID, selectedProfession.key, frame.api)
        if updateProfessionRecipeBrowser then updateProfessionRecipeBrowser(frame) end
    end
    return true
end

local function createProfessionButton(api, sidebar, profession, offset)
    local button = GGM.CreateFlatButton(api, sidebar, profession.key, UI.professionSidebarWidth - 24, UI.professionRowHeight, "ghost")
    button:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 12, -offset)
    button.selectionBar = button:CreateTexture(nil, "ARTWORK")
    button.selectionBar:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button.selectionBar:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    button.selectionBar:SetWidth(3)
    setColor(button.selectionBar, THEME.gold)
    button.selectionBar:Hide()

    local iconHolder = createSurface(api, button, THEME.slot, THEME.borderSoft)
    iconHolder:SetSize(30, 30)
    iconHolder:SetPoint("LEFT", button, "LEFT", 12, 0)
    local icon = iconHolder:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", iconHolder, "TOPLEFT", 4, -4)
    icon:SetPoint("BOTTOMRIGHT", iconHolder, "BOTTOMRIGHT", -4, 4)
    icon:SetTexture(profession.icon)
    button.icon = icon

    if button.label.ClearAllPoints then button.label:ClearAllPoints() end
    button.label:SetPoint("LEFT", iconHolder, "RIGHT", 10, 0)
    button.label:SetPoint("RIGHT", button, "RIGHT", -12, 0)
    button.label:SetJustifyH("LEFT")
    button.key = profession.key
    button:SetScript("OnClick", function() GGM.SelectProfession(sidebar.owner, profession.key) end)
    professionButtonColor(button, false)
    button.professionID = profession.professionID
    return button
end

local function createProfessionsPage(api, frame)
    local page = api.CreateFrame("Frame", nil, frame)
    page:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.railWidth + UI.pageMargin, -UI.contentTop)
    page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -UI.pageMargin, UI.contentBottom)
    page.owner = frame
    page:Hide()

    local sidebar = createSurface(api, page, THEME.panel, THEME.borderSoft, true)
    sidebar:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    sidebar:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
    sidebar:SetWidth(UI.professionSidebarWidth)
    sidebar.owner = frame
    frame.professionSidebar = sidebar

    local eyebrow = createEyebrow(sidebar, "PROFESSION LIBRARY")
    eyebrow:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 16, -16)
    local helper = createText(sidebar, "OVERLAY", "GameFontDisableSmall")
    helper:SetPoint("TOPLEFT", eyebrow, "BOTTOMLEFT", 0, -5)
    helper:SetWidth(UI.professionSidebarWidth - 32)
    helper:SetText("Browse cached recipe snapshots")
    setTextColor(helper, THEME.muted)
    createDivider(sidebar, 12, 12, -58)

    frame.professionButtons = {}
    for index, profession in ipairs(PROFESSIONS) do
        frame.professionButtons[index] = createProfessionButton(api, sidebar, profession, 72 + (index - 1) * (UI.professionRowHeight + 6))
    end

    local panel = createSurface(api, page, THEME.panel, THEME.borderSoft, true)
    panel:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", UI.contentGap, 0)
    panel:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    frame.professionDetailPanel = panel

    local hero = createSurface(api, panel, THEME.panelAlt, THEME.borderSoft)
    hero:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    hero:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    hero:SetHeight(94)
    local iconFrame = createSurface(api, hero, THEME.slot, THEME.gold)
    iconFrame:SetSize(54, 54)
    iconFrame:SetPoint("LEFT", hero, "LEFT", 18, 0)
    frame.professionHeroIcon = iconFrame:CreateTexture(nil, "ARTWORK")
    frame.professionHeroIcon:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 5, -5)
    frame.professionHeroIcon:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -5, 5)

    frame.professionHeading = createText(hero, "OVERLAY", "GameFontNormalHuge")
    frame.professionHeading:SetPoint("TOPLEFT", iconFrame, "TOPRIGHT", 16, -4)
    frame.professionHeading:SetPoint("RIGHT", hero, "RIGHT", -16, 0)
    frame.professionHeading:SetJustifyH("LEFT")
    setTextColor(frame.professionHeading, THEME.text)

    local subtitle = createText(hero, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", frame.professionHeading, "BOTTOMLEFT", 0, -7)
    subtitle:SetText("Last-known recipe information")
    setTextColor(subtitle, THEME.textSoft)

    local searchLabel = createSectionLabel(panel, "SEARCH RECIPES")
    searchLabel:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", 8, -16)
    frame.professionSearchBox = api.CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    frame.professionSearchBox:SetSize(300, UI.controlHeightCompact)
    frame.professionSearchBox:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -7)
    frame.professionSearchBox:SetAutoFocus(false)
    frame.professionSearchBox:SetText("")

    frame.professionCount = createText(panel, "OVERLAY", "GameFontDisableSmall")
    frame.professionCount:SetPoint("LEFT", frame.professionSearchBox, "RIGHT", 14, 0)
    setTextColor(frame.professionCount, THEME.muted)
    frame.professionStatus = createText(panel, "OVERLAY", "GameFontHighlightSmall")
    frame.professionStatus:SetPoint("TOPLEFT", frame.professionSearchBox, "BOTTOMLEFT", 0, -11)
    frame.professionStatus:SetPoint("RIGHT", panel, "RIGHT", -18, 0)
    frame.professionStatus:SetJustifyH("LEFT")
    setTextColor(frame.professionStatus, THEME.textSoft)

    frame.professionRecipeScroll = api.CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    frame.professionRecipeScroll:SetPoint("TOPLEFT", frame.professionStatus, "BOTTOMLEFT", 0, -8)
    frame.professionRecipeScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 16)
    frame.professionRecipeContent = api.CreateFrame("Frame", nil, frame.professionRecipeScroll)
    frame.professionRecipeContent:SetSize(620, 1)
    frame.professionRecipeScroll:SetScrollChild(frame.professionRecipeContent)
    frame.professionRecipeRows = {}
    frame.professionSearchBox:SetScript("OnTextChanged", function()
        if updateProfessionRecipeBrowser and frame.professionCatalog then updateProfessionRecipeBrowser(frame) end
    end)

    frame.professionsPage = page
    GGM.SelectProfession(frame, "Alchemy")
end

updateProfessionRecipeBrowser = function(frame)
    local catalog = frame.professionCatalog or { state = "unavailable", recipes = {}, message = nil }
    local recipes = type(catalog.recipes) == "table" and catalog.recipes or {}
    local filtered = GGM.FilterProfessionRecipeBrowserEntries(recipes, frame.professionSearchBox:GetText() or "")
    frame.filteredProfessionRecipes = filtered
    frame.professionCount:SetText(#filtered .. (#filtered == 1 and " recipe" or " recipes"))

    local status = catalog.message
    if (catalog.state == "ready" or catalog.state == "incomplete")
        and #recipes > 0 and #filtered == 0 then
        local noMatch = "No recipes match this search."
        status = status and (status .. " " .. noMatch) or noMatch
    elseif catalog.state == "ready" and #recipes == 0 then
        status = "No saved recipes are available."
    end
    frame.professionStatus:SetText(status or "")
    if status and status ~= "" then frame.professionStatus:Show() else frame.professionStatus:Hide() end

    local y = 0
    for index, recipe in ipairs(filtered) do
        local row = frame.professionRecipeRows[index]
        if not row then
            row = frame.api.CreateFrame("Frame", nil, frame.professionRecipeContent)
            row.name = createText(row, "OVERLAY", "GameFontHighlight")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 12, -9)
            row.name:SetPoint("RIGHT", row, "RIGHT", -12, 0)
            row.name:SetJustifyH("LEFT")
            setTextColor(row.name, THEME.text)
            row.knownBy = createText(row, "OVERLAY", "GameFontDisableSmall")
            row.knownBy:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -5)
            row.knownBy:SetPoint("RIGHT", row, "RIGHT", -12, 0)
            row.knownBy:SetJustifyH("LEFT")
            row.separator = row:CreateTexture(nil, "BORDER")
            row.separator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 0)
            row.separator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 0)
            row.separator:SetHeight(1)
            setColor(row.separator, THEME.borderSoft)
            frame.professionRecipeRows[index] = row
        end

        local owners = {}
        for _, owner in ipairs(type(recipe.knownBy) == "table" and recipe.knownBy or {}) do
            local character = (owner.name or "Unknown") .. "-" .. (owner.realm or "Unknown")
            owners[#owners + 1] = character .. " — " .. (owner.savedDate or "Date unavailable")
        end
        row.recipe = recipe
        row.name:SetText(recipe.name or "Unknown recipe")
        row.knownBy:SetText(#owners > 0 and ("Known by: " .. table.concat(owners, "\n")) or "Cached recipe snapshot")
        local rowHeight = 48 + math.max(#owners - 1, 0) * 14
        row:SetHeight(rowHeight)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.professionRecipeContent, "TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", frame.professionRecipeContent, "RIGHT", 0, 0)
        row:Show()
        y = y + rowHeight + 1
    end
    for index = #filtered + 1, #frame.professionRecipeRows do frame.professionRecipeRows[index]:Hide() end
    frame.professionRecipeContent:SetHeight(math.max(y, 1))
end

local updateBrowserList

local function setPageHeader(frame, title, subtitle)
    frame.pageTitle:SetText(title)
    frame.pageSubtitle:SetText(subtitle)
end

function GGM.SelectGuildGearBrowserTab(frame, selectedKey)
    if selectedKey ~= "Character" and selectedKey ~= "Professions" and selectedKey ~= "Bank" then return false end
    frame.activeTab = selectedKey
    if frame.TitleText then frame.TitleText:SetText("Guild Gear Memory") end

    if selectedKey == "Character" then setPageHeader(frame, "Characters", "Inspect last-known equipment snapshots across your guild")
    elseif selectedKey == "Professions" then setPageHeader(frame, "Professions", "Review captured profession snapshots and recipes")
    else setPageHeader(frame, "Bank", "Saved bank snapshots and shared storage") end

    for _, tab in ipairs(frame.navigationTabs) do
        local selected = tab.key == selectedKey
        setColor(tab.background, selected and THEME.panelRaised or THEME.rail)
        if tab.label then setTextColor(tab.label, selected and THEME.text or THEME.textSoft) end
        if tab.caption then setTextColor(tab.caption, selected and THEME.gold or THEME.muted) end
        if tab.accent then if selected then tab.accent:Show() else tab.accent:Hide() end end
        if tab.icon then tab.icon:SetAlpha(selected and 1 or 0.58) end
    end

    local showCharacter = selectedKey == "Character"
    if selectedKey == "Professions" then
        frame.professionsPage:Show()
        if frame.db and type(GGM.BuildProfessionRecipeCatalog) == "function" then
            local profession
            for _, item in ipairs(PROFESSIONS) do if item.key == frame.selectedProfession then profession = item; break end end
            if profession then
                frame.professionCatalog = GGM.BuildProfessionRecipeCatalog(frame.db, profession.professionID, profession.key, frame.api)
                updateProfessionRecipeBrowser(frame)
            end
        end
    else frame.professionsPage:Hide() end
    for pageKey, page in pairs(frame.placeholderPages) do if pageKey == selectedKey then page:Show() else page:Hide() end end

    if showCharacter then
        setBrowserContentVisible(frame, true)
        updateBrowserList(frame, frame.api)
    else
        setBrowserContentVisible(frame, false)
    end
    return true
end

local function updateSearchHint(frame)
    if not frame.searchHint then return end
    local text = frame.searchBox and frame.searchBox:GetText() or ""
    if text == "" and not frame.searchBox.hasFocus then frame.searchHint:Show() else frame.searchHint:Hide() end
end

updateBrowserList = function(frame, api)
    frame.activeEntries = GGM.FilterGuildGearBrowserOwnership(frame.entries, frame.db, frame.browserView)
    frame.filteredEntries = GGM.FilterGuildGearBrowserEntries(frame.activeEntries, frame.searchBox:GetText() or "")

    local selectedStillVisible = false
    for _, entry in ipairs(frame.filteredEntries) do
        if frame.selectedEntry and entry.key == frame.selectedEntry.key then selectedStillVisible = true; break end
    end
    if not selectedStillVisible then frame.selectedEntry = frame.filteredEntries[1] end

    if frame.characterCount then
        frame.characterCount:SetText(tostring(#frame.filteredEntries) .. (#frame.filteredEntries == 1 and " character" or " characters"))
    end

    local rows = frame.listRows
    for index, entry in ipairs(frame.filteredEntries) do
        local row = rows[index]
        if not row then
            row = api.CreateFrame("Button", nil, frame.listContent)
            row:SetSize(UI.listScrollWidth, UI.characterRowHeight)
            row:RegisterForClicks("LeftButtonUp")

            row.base = row:CreateTexture(nil, "BACKGROUND")
            row.base:SetAllPoints(row)
            setColor(row.base, THEME.panel)
            row.selection = row:CreateTexture(nil, "BACKGROUND")
            row.selection:SetAllPoints(row)
            setColor(row.selection, THEME.goldDim, 0.48)
            row.selection:Hide()
            row.selectedBar = row:CreateTexture(nil, "ARTWORK")
            row.selectedBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            row.selectedBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            row.selectedBar:SetWidth(3)
            setColor(row.selectedBar, THEME.gold)
            row.selectedBar:Hide()
            row.hover = row:CreateTexture(nil, "HIGHLIGHT")
            row.hover:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.hover:SetAllPoints(row)
            row.hover:SetBlendMode("ADD")
            row.hover:SetAlpha(0.34)
            if row.SetHighlightTexture then row:SetHighlightTexture(row.hover) end

            row.avatar = createSurface(api, row, THEME.panelRaised, THEME.borderSoft)
            row.avatar:SetSize(32, 32)
            row.avatar:SetPoint("LEFT", row, "LEFT", 10, 0)
            row.avatarRing = row:CreateTexture(nil, "OVERLAY")
            row.avatarRing:SetSize(40, 40)
            row.avatarRing:SetPoint("CENTER", row.avatar, "CENTER", 0, 0)
            row.avatarRing:SetTexture("Interface\\Buttons\\UI-Quickslot2")
            row.avatarRing:SetAlpha(0.82)
            row.avatarText = createText(row.avatar, "OVERLAY", "GameFontNormal")
            row.avatarText:SetPoint("CENTER", row.avatar, "CENTER", 0, 0)
            setTextColor(row.avatarText, THEME.goldBright)

            row.label = createText(row, "OVERLAY", "GameFontHighlight")
            row.label:SetPoint("TOPLEFT", row.avatar, "TOPRIGHT", 11, -2)
            row.label:SetPoint("RIGHT", row, "RIGHT", -12, 0)
            row.label:SetJustifyH("LEFT")
            row.realm = createText(row, "OVERLAY", "GameFontDisableSmall")
            row.realm:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -3)
            row.realm:SetPoint("RIGHT", row, "RIGHT", -12, 0)
            row.realm:SetJustifyH("LEFT")
            row.separator = row:CreateTexture(nil, "BORDER")
            row.separator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 0)
            row.separator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 0)
            row.separator:SetHeight(1)
            setColor(row.separator, THEME.borderSoft)
            rows[index] = row
        end

        row.entry = entry
        row.label:SetText(entry.name)
        row.realm:SetText(entry.realm)
        row.avatarText:SetText(type(entry.name) == "string" and entry.name:sub(1, 1):upper() or "?")
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.listContent, "TOPLEFT", 0, -(index - 1) * UI.characterRowHeight)
        row.selected = frame.selectedEntry ~= nil and frame.selectedEntry.key == entry.key
        if row.selected then
            row.selection:Show(); row.selectedBar:Show()
            setTextColor(row.label, THEME.text); setTextColor(row.realm, THEME.textSoft)
            recolorBorder(row.avatar.border, THEME.gold)
        else
            row.selection:Hide(); row.selectedBar:Hide()
            setTextColor(row.label, THEME.textSoft); setTextColor(row.realm, THEME.muted)
            recolorBorder(row.avatar.border, THEME.borderSoft)
        end
        local selectedRow = row
        row:SetScript("OnClick", function() frame.selectedEntry = selectedRow.entry; updateBrowserList(frame, api) end)
        row:Show()
    end

    for index = #frame.filteredEntries + 1, #rows do rows[index]:Hide() end
    frame.listContent:SetHeight(math.max(#frame.filteredEntries * UI.characterRowHeight, 1))

    if #frame.activeEntries == 0 then
        frame.listEmpty:SetText(frame.browserView == "Mine" and "No personal snapshots yet" or "No guild snapshots yet")
        frame.listEmpty:Show()
    elseif #frame.filteredEntries == 0 then
        frame.listEmpty:SetText("No characters match your search")
        frame.listEmpty:Show()
    else frame.listEmpty:Hide() end

    updateSearchHint(frame)
    renderBrowserDetail(frame, frame.selectedEntry, api)
    if frame.activeTab ~= "Character" then setBrowserContentVisible(frame, false) end
end

local function updateBrowserViewButtonStyles(frame)
    for _, button in ipairs({ frame.mineButton, frame.guildButton }) do
        GGM.SetFlatButtonState(button, button.key == frame.browserView and "selected" or "idle")
    end
end

local function createBrowserViewButton(api, frame, key, label, x)
    local button = GGM.CreateFlatButton(api, frame.searchPanel, label, UI.ownershipButtonWidth, UI.controlHeightCompact, "ghost")
    button:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", x, -48)
    button.key = key
    button:SetScript("OnClick", function()
        frame.browserView = key
        updateBrowserViewButtonStyles(frame)
        updateBrowserList(frame, api)
    end)
    return button
end

local function createNavigationTab(api, frame, key, label, caption, iconPath, y)
    local tab = api.CreateFrame("Button", nil, frame.navigationRail)
    tab:SetSize(UI.railWidth - 20, UI.navigationRowHeight)
    tab:SetPoint("TOPLEFT", frame.navigationRail, "TOPLEFT", 10, y)

    tab.background = tab:CreateTexture(nil, "BACKGROUND")
    tab.background:SetAllPoints(tab)
    setColor(tab.background, THEME.rail)

    tab.highlight = tab:CreateTexture(nil, "HIGHLIGHT")
    tab.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    tab.highlight:SetBlendMode("ADD")
    tab.highlight:SetAllPoints(tab)
    tab.highlight:SetAlpha(0.45)
    if tab.SetHighlightTexture then tab:SetHighlightTexture(tab.highlight) end

    tab.accent = tab:CreateTexture(nil, "ARTWORK")
    tab.accent:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, 0)
    tab.accent:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
    tab.accent:SetWidth(3)
    setColor(tab.accent, THEME.gold)
    tab.accent:Hide()

    tab.icon = tab:CreateTexture(nil, "ARTWORK")
    tab.icon:SetSize(UI.navigationIconSize, UI.navigationIconSize)
    tab.icon:SetPoint("LEFT", tab, "LEFT", 14, 0)
    tab.icon:SetTexture(iconPath)
    tab.icon:SetAlpha(0.70)

    tab.iconBorder = tab:CreateTexture(nil, "OVERLAY")
    tab.iconBorder:SetSize(UI.navigationIconSize + 10, UI.navigationIconSize + 10)
    tab.iconBorder:SetPoint("CENTER", tab.icon, "CENTER", 0, 0)
    tab.iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    tab.iconBorder:SetAlpha(0.65)

    tab.label = createText(tab, "OVERLAY", "GameFontHighlight")
    tab.label:SetPoint("TOPLEFT", tab.icon, "TOPRIGHT", 11, -1)
    tab.label:SetText(label)
    setTextColor(tab.label, THEME.textSoft)
    tab.caption = createText(tab, "OVERLAY", "GameFontDisableSmall")
    tab.caption:SetPoint("TOPLEFT", tab.label, "BOTTOMLEFT", 0, -2)
    tab.caption:SetText(caption)
    setTextColor(tab.caption, THEME.muted)

    tab.key = key
    tab:RegisterForClicks("LeftButtonUp")
    tab:SetScript("OnClick", function() GGM.SelectGuildGearBrowserTab(frame, key) end)
    return tab
end

local function createGearPanel(api, frame)
    local panel = createSurface(api, frame, THEME.panel, THEME.borderSoft, true)
    panel:SetSize(UI.detailColumnWidth, UI.windowHeight - UI.contentTop - UI.contentBottom)
    panel.background:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble")
    panel.background:SetVertexColor(0.16, 0.105, 0.055, 1)
    panel.background:SetAlpha(0.32)
    panel:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.railWidth + UI.pageMargin + UI.browserColumnWidth + UI.contentGap, -UI.contentTop)

    panel.header = panel:CreateTexture(nil, "BACKGROUND")
    panel.header:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -2)
    panel.header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
    panel.header:SetHeight(88)
    setColor(panel.header, THEME.panelAlt)
    panel.goldRule = panel:CreateTexture(nil, "ARTWORK")
    panel.goldRule:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -88)
    panel.goldRule:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -88)
    panel.goldRule:SetHeight(1)
    setColor(panel.goldRule, THEME.gold, 0.48)
    panel.sectionLabel = createEyebrow(panel, "EQUIPMENT SNAPSHOT")
    panel.sectionLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -15)
    return panel
end

local function createSlotButton(api, frame, trackedSlot, layout, x, y)
    local button = api.CreateFrame("Button", nil, frame.gearPanel)
    button:SetSize(48, 48)
    button:SetPoint("CENTER", frame.gearPanel, "TOPLEFT", x, y)
    button.paperDollGroup, button.paperDollOrder = layout.group, layout.order

    button.slotBackground = button:CreateTexture(nil, "BACKGROUND")
    button.slotBackground:SetPoint("TOPLEFT", button, "TOPLEFT", 4, -4)
    button.slotBackground:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 4)
    setColor(button.slotBackground, THEME.slot)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 5, -5)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -5, 5)

    button.quickslot = button:CreateTexture(nil, "OVERLAY")
    button.quickslot:SetAllPoints(button)
    button.quickslot:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    button.quickslot:SetAlpha(0.92)
    button.borderEdges = createFlatBorder(button, THEME.borderSoft, 3)

    button.glow = button:CreateTexture(nil, "BACKGROUND")
    button.glow:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
    button.glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
    button.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    button.glow:SetBlendMode("ADD")
    button.glow:SetAlpha(0.45)
    button.glow:Hide()

    button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
    button.highlight:SetAllPoints(button)
    button.highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    button.highlight:SetBlendMode("ADD")
    if button.SetHighlightTexture then button:SetHighlightTexture(button.highlight) end

    button.label = createText(button, "OVERLAY", "GameFontHighlightSmall")
    button.label:SetText(slotDisplayNames[trackedSlot.key])
    setTextColor(button.label, THEME.textSoft)
    button.status = createText(button, "OVERLAY", "GameFontDisableSmall")
    setTextColor(button.status, THEME.muted)

    if layout.group == "left" then
        button.label:SetWidth(98); button.label:SetJustifyH("LEFT"); button.label:SetPoint("LEFT", button, "RIGHT", 9, 5)
        button.status:SetWidth(98); button.status:SetJustifyH("LEFT"); button.status:SetPoint("TOPLEFT", button.label, "BOTTOMLEFT", 0, -2)
    elseif layout.group == "right" then
        button.label:SetWidth(98); button.label:SetJustifyH("RIGHT"); button.label:SetPoint("RIGHT", button, "LEFT", -9, 5)
        button.status:SetWidth(98); button.status:SetJustifyH("RIGHT"); button.status:SetPoint("TOPRIGHT", button.label, "BOTTOMRIGHT", 0, -2)
    else
        button.label:SetWidth(92); button.label:SetJustifyH("CENTER"); button.label:SetPoint("TOP", button, "BOTTOM", 0, -5)
        button.status:SetWidth(92); button.status:SetJustifyH("CENTER"); button.status:SetPoint("TOP", button.label, "BOTTOM", 0, -1)
    end
    button:Hide()
    return button
end

local function createCloseButton(api, frame)
    -- BasicFrameTemplateWithInset already supplies Blizzard's standard close
    -- button. Reuse it instead of drawing an addon-specific replacement.
    if frame.CloseButton then
        frame.CloseButton:Show()
        frame.proCloseButton = frame.CloseButton
        return
    end
    local button = api.CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    frame.proCloseButton = button
end

function GGM.CreateGuildGearBrowserWindow(api)
    api.UISpecialFrames = api.UISpecialFrames or {}
    local frameName = "GuildGearMemoryBrowserFrame"
    local isRegistered = false
    for _, registeredName in ipairs(api.UISpecialFrames) do if registeredName == frameName then isRegistered = true; break end end
    if not isRegistered then table.insert(api.UISpecialFrames, frameName) end

    local frame = api.CreateFrame("Frame", frameName, api.UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(UI.windowWidth, UI.windowHeight)
    frame:SetPoint("CENTER")
    frame:SetClampedToScreen(true)
    frame:Hide()
    frame.api = api
    frame.entries, frame.filteredEntries, frame.listRows, frame.slotButtons = {}, {}, {}, {}
    frame.browserView = "Guild"

    if frame.SetMovable then frame:SetMovable(true) end
    if frame.EnableMouse then frame:EnableMouse(true) end
    if frame.RegisterForDrag then frame:RegisterForDrag("LeftButton") end
    frame:SetScript("OnDragStart", function(self) if self.StartMoving then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self) if self.StopMovingOrSizing then self:StopMovingOrSizing() end end)

    -- Keep Blizzard's BasicFrameTemplate chrome visible. The only custom shell
    -- is the content fill inside it, which prevents the UI from feeling like a
    -- freestanding addon dashboard.
    if frame.Inset and frame.Inset.Hide then frame.Inset:Hide() end
    frame.shell = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    frame.shell:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -25)
    frame.shell:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    frame.shell:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background-Dark")
    frame.shell:SetVertexColor(THEME.canvas[1], THEME.canvas[2], THEME.canvas[3], 1)
    frame.shell:SetAlpha(THEME.canvas[4])

    frame.navigationRail = createSurface(api, frame, THEME.rail, THEME.borderSoft)
    frame.navigationRail:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -28)
    frame.navigationRail:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 5)
    frame.navigationRail:SetWidth(UI.railWidth - 3)
    frame.navigationRail.background:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble")
    frame.navigationRail.background:SetVertexColor(0.18, 0.12, 0.07, 1)
    frame.navigationRail.background:SetAlpha(0.82)

    frame.brandIconFrame = createSurface(api, frame.navigationRail, THEME.slot, THEME.gold)
    frame.brandIconFrame:SetSize(44, 44)
    frame.brandIconFrame:SetPoint("TOPLEFT", frame.navigationRail, "TOPLEFT", 16, -18)
    frame.brandIcon = frame.brandIconFrame:CreateTexture(nil, "ARTWORK")
    frame.brandIcon:SetPoint("TOPLEFT", frame.brandIconFrame, "TOPLEFT", 5, -5)
    frame.brandIcon:SetPoint("BOTTOMRIGHT", frame.brandIconFrame, "BOTTOMRIGHT", -5, 5)
    frame.brandIcon:SetTexture("Interface\\Icons\\INV_Chest_Chain_05")

    frame.brandTitle = createText(frame.navigationRail, "OVERLAY", "GameFontNormalLarge")
    frame.brandTitle:SetPoint("TOPLEFT", frame.brandIconFrame, "TOPRIGHT", 11, -2)
    frame.brandTitle:SetText("Guild Ledger")
    setTextColor(frame.brandTitle, THEME.text)
    frame.brandSubtitle = createText(frame.navigationRail, "OVERLAY", "GameFontDisableSmall")
    frame.brandSubtitle:SetPoint("TOPLEFT", frame.brandTitle, "BOTTOMLEFT", 0, -3)
    frame.brandSubtitle:SetText("GEAR MEMORY")
    setTextColor(frame.brandSubtitle, THEME.gold)
    createDivider(frame.navigationRail, 12, 12, -80)

    local navLabel = createSectionLabel(frame.navigationRail, "LIBRARY")
    navLabel:SetPoint("TOPLEFT", frame.navigationRail, "TOPLEFT", 16, -100)
    frame.navigationTabs = {
        createNavigationTab(api, frame, "Character", "Characters", "Gear snapshots", "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest", -122),
        createNavigationTab(api, frame, "Professions", "Professions", "Recipe memory", "Interface\\Icons\\Trade_BlackSmithing", -174),
        createNavigationTab(api, frame, "Bank", "Bank", "Shared storage", "Interface\\Icons\\INV_Misc_Bag_10", -226),
    }

    frame.railFooter = createText(frame.navigationRail, "OVERLAY", "GameFontDisableSmall")
    frame.railFooter:SetPoint("BOTTOMLEFT", frame.navigationRail, "BOTTOMLEFT", 16, 18)
    frame.railFooter:SetText("LAST-KNOWN GUILD DATA")
    setTextColor(frame.railFooter, THEME.muted)

    frame.headerBackground = frame:CreateTexture(nil, "BACKGROUND")
    frame.headerBackground:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.railWidth, -28)
    frame.headerBackground:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -28)
    frame.headerBackground:SetHeight(UI.headerHeight)
    setColor(frame.headerBackground, THEME.header)
    frame.headerRule = frame:CreateTexture(nil, "BORDER")
    frame.headerRule:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.railWidth, -(UI.headerHeight + 28))
    frame.headerRule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -(UI.headerHeight + 28))
    frame.headerRule:SetHeight(1)
    setColor(frame.headerRule, THEME.gold, 0.35)

    if frame.TitleText then frame.TitleText:SetText("Guild Gear Memory"); frame.TitleText:Show() end
    frame.pageEyebrow = createEyebrow(frame, "SAVED GUILD RECORDS")
    frame.pageEyebrow:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.railWidth + UI.pageMargin, -38)
    frame.pageTitle = createText(frame, "OVERLAY", "GameFontNormalHuge")
    frame.pageTitle:SetPoint("TOPLEFT", frame.pageEyebrow, "BOTTOMLEFT", 0, -5)
    setTextColor(frame.pageTitle, THEME.text)
    frame.pageSubtitle = createText(frame, "OVERLAY", "GameFontHighlightSmall")
    frame.pageSubtitle:SetPoint("TOPLEFT", frame.pageTitle, "BOTTOMLEFT", 0, -5)
    setTextColor(frame.pageSubtitle, THEME.muted)
    createCloseButton(api, frame)

    frame.searchPanel = createSurface(api, frame, THEME.panel, THEME.borderSoft, true)
    frame.searchPanel:SetSize(UI.browserColumnWidth, 138)
    frame.searchPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.railWidth + UI.pageMargin, -UI.contentTop)
    frame.charactersHeading = createEyebrow(frame.searchPanel, "CHARACTER SOURCE")
    frame.charactersHeading:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", 14, -14)
    frame.mineButton = createBrowserViewButton(api, frame, "Mine", "My Characters", 14)
    frame.guildButton = createBrowserViewButton(api, frame, "Guild", "Guild", 112)
    updateBrowserViewButtonStyles(frame)

    frame.searchLabel = createSectionLabel(frame.searchPanel, "SEARCH")
    frame.searchLabel:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", 14, -92)
    frame.searchBox = api.CreateFrame("EditBox", nil, frame.searchPanel, "InputBoxTemplate")
    frame.searchBox:SetSize(196, UI.controlHeightCompact)
    frame.searchBox:SetPoint("TOPRIGHT", frame.searchPanel, "TOPRIGHT", -14, -88)
    frame.searchBox:SetAutoFocus(false)
    if frame.searchBox.SetTextInsets then frame.searchBox:SetTextInsets(10, 8, 0, 0) end
    frame.searchBoxBackground = frame.searchBox:CreateTexture(nil, "BACKGROUND")
    frame.searchBoxBackground:SetPoint("TOPLEFT", frame.searchBox, "TOPLEFT", -2, 2)
    frame.searchBoxBackground:SetPoint("BOTTOMRIGHT", frame.searchBox, "BOTTOMRIGHT", 2, -2)
    setColor(frame.searchBoxBackground, THEME.input)
    frame.searchBoxBorder = {}
    frame.searchHint = createText(frame.searchBox, "OVERLAY", "GameFontDisableSmall")
    frame.searchHint:SetPoint("LEFT", frame.searchBox, "LEFT", 10, 0)
    frame.searchHint:SetText("Name or realm")
    setTextColor(frame.searchHint, THEME.muted)
    frame.searchBox:SetScript("OnEditFocusGained", function(self)
        self.hasFocus = true; setColor(frame.searchBoxBackground, THEME.panelRaised); recolorBorder(frame.searchBoxBorder, THEME.gold); updateSearchHint(frame)
    end)
    frame.searchBox:SetScript("OnEditFocusLost", function(self)
        self.hasFocus = false; setColor(frame.searchBoxBackground, THEME.input); recolorBorder(frame.searchBoxBorder, THEME.border); updateSearchHint(frame)
    end)
    frame.searchBox:SetScript("OnTextChanged", function() updateBrowserList(frame, api) end)

    frame.listPanel = createSurface(api, frame, THEME.panel, THEME.borderSoft, true)
    frame.listPanel:SetSize(UI.browserColumnWidth, 446)
    frame.listPanel:SetPoint("TOPLEFT", frame.searchPanel, "BOTTOMLEFT", 0, -UI.contentGap)
    frame.characterCount = createSectionLabel(frame.listPanel, "0 characters")
    frame.characterCount:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 14, -13)
    local listHint = createText(frame.listPanel, "OVERLAY", "GameFontDisableSmall")
    listHint:SetPoint("TOPRIGHT", frame.listPanel, "TOPRIGHT", -14, -13)
    listHint:SetText("SELECT TO INSPECT")
    setTextColor(listHint, THEME.muted)
    createDivider(frame.listPanel, 12, 12, -34)

    frame.listScroll = api.CreateFrame("ScrollFrame", nil, frame.listPanel, "UIPanelScrollFrameTemplate")
    frame.listScroll:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 12, -42)
    frame.listScroll:SetSize(UI.listScrollWidth, UI.listScrollHeight - 22)
    frame.listContent = api.CreateFrame("Frame", nil, frame.listScroll)
    frame.listContent:SetSize(UI.listScrollWidth, 1)
    frame.listScroll:SetScrollChild(frame.listContent)
    frame.listEmpty = createText(frame.listPanel, "OVERLAY", "GameFontHighlightSmall")
    frame.listEmpty:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 16, -58)
    frame.listEmpty:SetWidth(238)
    frame.listEmpty:SetJustifyH("LEFT")
    setTextColor(frame.listEmpty, THEME.muted)
    frame.listEmpty:Hide()

    frame.gearPanel = createGearPanel(api, frame)
    frame.characterLine = createText(frame.gearPanel, "OVERLAY", "GameFontNormalHuge")
    frame.characterLine:SetPoint("TOPLEFT", frame.gearPanel, "TOPLEFT", 18, -36)
    setTextColor(frame.characterLine, THEME.text)
    frame.realmLine = createText(frame.gearPanel, "OVERLAY", "GameFontHighlightSmall")
    frame.realmLine:SetPoint("TOPLEFT", frame.characterLine, "BOTTOMLEFT", 1, -4)
    setTextColor(frame.realmLine, THEME.muted)
    frame.snapshotCaption = createSectionLabel(frame.gearPanel, "CAPTURED")
    frame.snapshotCaption:SetPoint("TOPRIGHT", frame.gearPanel, "TOPRIGHT", -18, -18)
    frame.capturedLine = createText(frame.gearPanel, "OVERLAY", "GameFontHighlightSmall")
    frame.capturedLine:SetPoint("TOPRIGHT", frame.gearPanel, "TOPRIGHT", -18, -36)
    frame.capturedLine:SetJustifyH("RIGHT")
    setTextColor(frame.capturedLine, THEME.textSoft)
    frame.completenessBadge = createStatusBadge(api, frame.gearPanel)
    frame.completenessBadge:SetPoint("TOPRIGHT", frame.gearPanel, "TOPRIGHT", -18, -58)
    frame.completenessBadge:Hide()
    frame.completenessLine = frame.completenessBadge.text

    frame.modelStage = createSurface(api, frame.gearPanel, THEME.input, THEME.borderSoft, true)
    frame.modelStage:SetSize(238, 336)
    frame.modelStage:SetPoint("TOP", frame.gearPanel, "TOP", 0, -116)
    frame.stageLabel = createSectionLabel(frame.modelStage, "SAVED APPEARANCE")
    frame.stageLabel:SetPoint("TOPLEFT", frame.modelStage, "TOPLEFT", 12, -11)
    frame.stageRule = createDivider(frame.modelStage, 10, 10, -30)

    frame.characterModelView = GGM.CreateSavedCharacterModel(api, frame.modelStage)
    if frame.characterModelView.model then
        frame.characterModelView.model:SetSize(222, 292)
        frame.characterModelView.model:SetPoint("BOTTOM", frame.modelStage, "BOTTOM", 0, 8)
        if frame.characterModelView.model.background then setColor(frame.characterModelView.model.background, THEME.input, 0.35) end
        frame.characterModelView.model:Hide()
    end
    frame.modelUnavailableLabel = createText(frame.modelStage, "OVERLAY", "GameFontDisableSmall")
    frame.modelUnavailableLabel:SetSize(190, 50)
    frame.modelUnavailableLabel:SetPoint("CENTER", frame.modelStage, "CENTER", 0, -4)
    frame.modelUnavailableLabel:SetJustifyH("CENTER")
    setTextColor(frame.modelUnavailableLabel, THEME.muted)
    frame.modelUnavailableLabel:Hide()

    frame.detailEmpty = createText(frame.gearPanel, "OVERLAY", "GameFontNormalLarge")
    frame.detailEmpty:SetPoint("CENTER", frame.gearPanel, "CENTER", 0, -16)
    frame.detailEmpty:SetWidth(380)
    frame.detailEmpty:SetJustifyH("CENTER")
    setTextColor(frame.detailEmpty, THEME.muted)
    frame.detailEmpty:Hide()

    local sideX = { left = 42, right = UI.detailColumnWidth - 42 }
    local sideStartY, sidePitch = -138, 52
    local bottomX = { 250, 328, 406 }
    local bottomY = -482
    for index, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local layout = GGM.BROWSER_SLOT_LAYOUT[trackedSlot.key]
        local x, y
        if layout.group == "bottom" then x, y = bottomX[layout.order], bottomY
        else x = sideX[layout.group]; y = sideStartY - (layout.order - 1) * sidePitch end
        frame.slotButtons[index] = createSlotButton(api, frame, trackedSlot, layout, x, y)
    end

    frame.detailFooter = createSurface(api, frame.gearPanel, THEME.panelAlt, THEME.borderSoft)
    frame.detailFooter:SetPoint("BOTTOMLEFT", frame.gearPanel, "BOTTOMLEFT", 14, 14)
    frame.detailFooter:SetPoint("BOTTOMRIGHT", frame.gearPanel, "BOTTOMRIGHT", -14, 14)
    frame.detailFooter:SetHeight(32)
    local footerText = createText(frame.detailFooter, "OVERLAY", "GameFontDisableSmall")
    footerText:SetPoint("CENTER", frame.detailFooter, "CENTER", 0, 0)
    footerText:SetText("Mouse over an equipment slot to view the saved item")
    setTextColor(footerText, THEME.muted)

    frame.placeholderPages = {}
    do
        local page = createSurface(api, frame, THEME.panel, THEME.borderSoft, true)
        page:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.railWidth + UI.pageMargin, -UI.contentTop)
        page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -UI.pageMargin, UI.contentBottom)
        page.emptyCard = createEmptyStateCard(api, page, "Interface\\Icons\\INV_Misc_Bag_10",
            "Bank snapshots", "This section is prepared for the existing bank feature when its data layer is available. No storage or synchronization behavior has been changed.")
        page.emptyCard:SetPoint("CENTER", page, "CENTER", 0, -8)
        page:Hide()
        frame.placeholderPages.Bank = page
    end

    createProfessionsPage(api, frame)
    GGM.SelectGuildGearBrowserTab(frame, "Character")
    return frame
end

function GGM.ShowGuildGearBrowserWindow(api, db)
    if not GGM.guildGearBrowserFrame then GGM.guildGearBrowserFrame = GGM.CreateGuildGearBrowserWindow(api) end
    local frame = GGM.guildGearBrowserFrame
    local query = frame.searchBox:GetText() or ""
    local selectedKey = frame.selectedEntry and frame.selectedEntry.key or nil
    frame.entries = GGM.BuildGuildGearBrowserEntries(db)
    frame.db = db
    GGM.SelectProfession(frame, frame.selectedProfession or "Alchemy")
    frame.searchBox:SetText(query)
    frame.filteredEntries = GGM.FilterGuildGearBrowserEntries(frame.entries, query)
    frame.selectedEntry = nil
    for _, entry in ipairs(frame.filteredEntries) do if entry.key == selectedKey then frame.selectedEntry = entry; break end end
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

local function printAddonStatus(api)
    local chatFrame = api.DEFAULT_CHAT_FRAME
    local emit
    if chatFrame and type(chatFrame.AddMessage) == "function" then
        emit = function(message) chatFrame:AddMessage(message) end
    elseif type(api.print) == "function" then
        emit = function(message) api.print(message) end
    end

    if not emit then return end

    emit("Guild Gear Memory status:")
    if GGM.startupError then
        emit("Database: unavailable (" .. tostring(GGM.startupError) .. ")")
        return
    end
    if type(GGM.db) ~= "table" then
        emit("Database: unavailable")
        return
    end

    local identity, identityErr = GGM.BuildPlayerIdentity(api)
    if not identity then
        emit("Current character: unavailable (" .. tostring(identityErr) .. ")")
        return
    end

    emit("Current character: " .. identity.key)
    local record, recordErr = GGM.GetCharacterRecord(GGM.db, identity.key)
    if record then
        emit("Saved gear: " .. (record.complete == true and "complete" or "incomplete"))
    else
        emit("Saved gear: no (" .. tostring(recordErr) .. ")")
    end
    emit("Ownership: " .. (GGM.IsLocalCharacter(GGM.db, identity.key) and "Mine" or "not marked Mine"))
    local trackerActive = type(GGM.gearTracker) == "table"
        and GGM.gearTracker.characterKey == identity.key
    emit("Tracking: " .. (trackerActive and "active" or "not active"))

    local trackingErr = GGM.lastGearTrackingError or GGM.lastCaptureError
    if trackingErr then
        emit("Login capture/tracking error: " .. tostring(trackingErr))
    elseif not record then
        emit("Login capture/tracking error: no error was recorded")
    else
        emit("Login capture/tracking error: none")
    end
end

function GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList = api.SlashCmdList or {}
    api.SLASH_GUILDGEARMEMORY1 = "/ggm"
    api.SlashCmdList.GUILDGEARMEMORY = function(message)
        if type(message) == "string" and message:match("^%s*status%s*$") then
            printAddonStatus(api)
            return
        end

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
