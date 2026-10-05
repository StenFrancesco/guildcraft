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
    return type(record.gear) == "table"
        and type(GGM.ValidateStoredGear) == "function"
        and GGM.ValidateStoredGear(record.gear, true) == true
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
    if not baseValid then return false end
    if record.complete == true then
        return record.gear.complete == true
            and type(GGM.ValidateStoredGear) == "function"
            and GGM.ValidateStoredGear(record.gear, true) == true
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
        local state, stateErr = GGM.GetStoredGearSlot(record.gear, trackedSlot.key)
        if not state then return { hasRecord = false, error = stateErr } end
        local slotTexture = getSlotTexture(api, trackedSlot)
        local unavailable = state.state == "unavailable"
        local empty = state.state == "empty"
        local itemID, itemLink
        if state.state == "equipped" then
            itemID = state.itemID
            itemLink = GGM.BuildItemHyperlink(api, state.itemString)
            if not itemLink then return { hasRecord = false } end
        end
        local icon = slotTexture
        if itemID then icon = getItemIcon(api, itemID) or slotTexture end
        local layout = GGM.BROWSER_SLOT_LAYOUT[trackedSlot.key]
        local displayName = slotDisplayNames[trackedSlot.key]
        table.insert(slots, {
            key = trackedSlot.key,
            inventorySlotID = state.inventorySlotID,
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

function GGM.BuildSnapshotViewModel(record, formatTime, api)
    api = type(api) == "table" and api or {}
    if not hasValidDisplayShape(record) then return missingModel() end
    local slotRows = {}
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local state = GGM.GetStoredGearSlot(record.gear, trackedSlot.key)
        if not state then return missingModel() end
        local valueText = state.state == "empty" and "Empty"
            or (state.state == "unavailable" and "No data" or nil)
        if state.state == "equipped" then
            valueText = GGM.BuildItemHyperlink(api, state.itemString)
            if not valueText then return missingModel() end
        end
        table.insert(slotRows, { key = trackedSlot.key, valueText = valueText })
    end
    local capturedAtText = tostring(record.gear.capturedAt)
    if type(formatTime) == "function" then capturedAtText = formatTime("%Y-%m-%d %H:%M:%S", record.gear.capturedAt) end
    return { hasSnapshot = true, characterName = record.identity.name, realm = record.identity.realm,
        capturedAtText = capturedAtText, completenessText = "Complete", slots = slotRows }
end

local function createText(frame, layer, fontObject)
    local object = fontObject or "GameFontHighlight"
    local text = frame:CreateFontString(nil, layer or "OVERLAY", object)
    local sizes = {
        GameFontNormalHuge = 26,
        GameFontNormalLarge = 21,
        GameFontNormal = 17,
        GameFontHighlight = 17,
        GameFontHighlightSmall = 14,
        GameFontNormalSmall = 14,
        GameFontDisableSmall = 13,
    }
    if GGM.ApplyJournalFont then
        GGM.ApplyJournalFont(text, sizes[object] or 15,
            object == "GameFontNormalHuge" or object == "GameFontNormalLarge" or object == "GameFontNormal")
    end
    return text
end

local function setText(control, value)
    control:SetText(value or "")
    if value and value ~= "" then control:Show() else control:Hide() end
end

-- Presentation-only design system. Data models, storage, sync, tracking and
-- snapshot semantics deliberately remain outside this section.
local THEME = {
    -- Warm parchment surfaces with dark ink for main content and pale text
    -- reserved for the leather navigation rail.
    canvas = { 0.940, 0.810, 0.580, 1.000 },
    rail = { 0.180, 0.105, 0.060, 1.000 },
    header = { 0.930, 0.800, 0.560, 1.000 },
    panel = { 0.965, 0.865, 0.700, 1.000 },
    panelAlt = { 0.935, 0.810, 0.615, 1.000 },
    panelRaised = { 0.900, 0.735, 0.500, 1.000 },
    panelHover = { 1.000, 0.760, 0.220, 0.16 },
    input = { 0.018, 0.016, 0.013, 0.985 },
    slot = { 0.020, 0.018, 0.015, 1.000 },
    border = { 0.440, 0.275, 0.125, 0.96 },
    borderSoft = { 0.570, 0.375, 0.205, 0.86 },
    borderDark = { 0.240, 0.135, 0.055, 1.000 },
    iconBevelOutline = { 0.035, 0.040, 0.045, 1.000 },
    iconBevelLight = { 0.520, 0.545, 0.565, 1.000 },
    iconBevelShadow = { 0.110, 0.125, 0.140, 1.000 },
    gold = { 0.475, 0.295, 0.075, 1.000 },
    goldBright = { 0.625, 0.405, 0.085, 1.000 },
    goldDim = { 0.505, 0.325, 0.085, 0.88 },
    goldHover = { 1.000, 0.755, 0.245, 0.18 },
    cyan = { 0.075, 0.345, 0.515, 1.000 },
    success = { 0.155, 0.445, 0.185, 1.000 },
    warning = { 0.665, 0.340, 0.055, 1.000 },
    danger = { 0.625, 0.145, 0.105, 1.000 },
    text = { 0.190, 0.125, 0.070, 1.000 },
    textSoft = { 0.290, 0.205, 0.125, 1.000 },
    muted = { 0.405, 0.315, 0.210, 1.000 },
    disabled = { 0.545, 0.445, 0.315, 1.000 },
    railText = { 0.970, 0.910, 0.790, 1.000 },
    railMuted = { 0.805, 0.690, 0.525, 1.000 },
    railGold = { 1.000, 0.795, 0.340, 1.000 },
}

local JOURNAL_TEXTURES = {
    parchment = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\parchment.tga",
    leather = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\leather.tga",
    button = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\profession-button.tga",
    professionButton = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\profession-button-framed.tga",
    window = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\journal-window.tga",
    armory = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\character-armory.tga",
    font = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\journal-serif.ttf",
    boldFont = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\journal-serif-bold.ttf",
    professions = {
        Alchemy = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\alchemy-page.tga",
        Blacksmithing = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\blacksmithing-page.tga",
        Enchanting = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\enchanting-page.tga",
        Engineering = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\engineering-page.tga",
        Leatherworking = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\leatherworking-page.tga",
        Tailoring = "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\tailoring-page.tga",
    },
}
GGM.UITheme = THEME
GGM.UIJournalTextures = JOURNAL_TEXTURES

function GGM.ApplyJournalFont(text, size, flags)
    if not text or type(text.SetFont) ~= "function" then return false end
    local isBold = flags == "bold" or flags == true
    local path = isBold and JOURNAL_TEXTURES.boldFont or JOURNAL_TEXTURES.font
    local ok = pcall(text.SetFont, text, path, size or 15, "")
    if ok then
        if type(text.SetShadowColor) == "function" then text:SetShadowColor(0, 0, 0, 0) end
        if type(text.SetShadowOffset) == "function" then text:SetShadowOffset(0, 0) end
        text.journalFont = path
        text.journalFontSize = size or 15
    end
    return ok
end

function GGM.ApplyJournalSurface(panel, kind)
    if not panel then return false end
    local texturePath = kind == "leather" and JOURNAL_TEXTURES.leather
        or (kind == "button" and JOURNAL_TEXTURES.button or JOURNAL_TEXTURES.parchment)
    local background = panel.background
    if not background and type(panel.CreateTexture) == "function" then
        background = panel:CreateTexture(nil, "BACKGROUND")
        panel.background = background
    end
    if not background or type(background.SetTexture) ~= "function" then return false end
    if type(background.SetAllPoints) == "function" then background:SetAllPoints(panel) end
    background:SetTexture(texturePath)
    if type(background.SetVertexColor) == "function" then background:SetVertexColor(1, 1, 1, 1) end
    if type(background.SetAlpha) == "function" then background:SetAlpha(1) end
    return true
end

local UI = {
    space1 = 4,
    space2 = 8,
    space3 = 12,
    space4 = 16,
    space5 = 20,
    space6 = 24,
    borderWidth = 1,
    windowWidth = 1400,
    windowHeight = 630,
    railWidth = 292,
    headerHeight = 72,
    pageMargin = 50,
    contentTop = 96,
    contentBottom = 24,
    navigationRowHeight = 56,
    navigationTabWidth = 238,
    navigationIconSize = 38,
    browserColumnWidth = 297,
    detailColumnWidth = 693,
    contentGap = 18,
    ownershipButtonWidth = 105,
    controlHeightCompact = 28,
    characterRowHeight = 58,
    listScrollWidth = 244,
    listScrollHeight = 326,
    professionLibraryX = 314,
    professionLibraryTop = 109,
    professionDetailX = 629,
    professionSidebarWidth = 297,
    professionRowWidth = 244,
    professionRowHeight = 48,
    professionRowPitch = 57,
    professionHeroArtWidth = 0,
    professionHeroArtHeight = 0,
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
    if backgroundColor == THEME.rail then
        GGM.ApplyJournalSurface(panel, "leather")
    elseif backgroundColor ~= THEME.slot and backgroundColor ~= THEME.input then
        GGM.ApplyJournalSurface(panel, "parchment")
    end
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
    primary = {
        tint = { 0.88, 0.76, 0.575, 1 }, selectedTint = { 0.99, 0.91, 0.735, 1 },
        border = THEME.gold, text = THEME.text,
    },
    secondary = {
        tint = { 0.96, 0.87, 0.715, 1 }, selectedTint = { 1.00, 0.94, 0.795, 1 },
        border = THEME.border, text = THEME.textSoft,
    },
    ghost = {
        tint = { 0.95, 0.86, 0.700, 1 }, selectedTint = { 1.00, 0.94, 0.805, 1 },
        border = THEME.borderSoft, text = THEME.textSoft,
    },
    profession = {
        tint = { 1.000, 1.000, 1.000, 1 }, selectedTint = { 1.000, 0.900, 0.680, 1 },
        border = THEME.border, text = THEME.textSoft,
    },
}

function GGM.SetFlatButtonState(button, state)
    if not button then return false end
    local style = BUTTON_VARIANTS[button.variant] or BUTTON_VARIANTS.secondary
    local tint = style.tint
    local borderColor = style.border
    local labelColor = style.text
    if state == "selected" then
        button.selected = true
        tint = style.selectedTint or style.tint
        borderColor = THEME.gold
        labelColor = THEME.text
    elseif state == "disabled" then
        button.selected = false
        tint = { 0.88, 0.81, 0.68, 1 }
        borderColor = THEME.borderSoft
        labelColor = THEME.disabled
    else
        if state ~= "pressed" then button.selected = false end
        if state == "pressed" then tint = style.selectedTint or style.tint end
        if button.selected then
            tint = style.selectedTint or style.tint
            borderColor = THEME.gold
            labelColor = THEME.text
        end
    end
    if button.background and button.background.SetVertexColor then
        button.background:SetVertexColor(tint[1], tint[2], tint[3], tint[4] or 1)
    end
    recolorBorder(button.borderEdges, borderColor)
    recolorBorder(button.innerBorderEdges, state == "selected" and THEME.gold or THEME.borderDark)
    if button.label then setTextColor(button.label, labelColor) end
    button.visualState = state == "pressed" and "pressed" or (state or "idle")
    return true
end

function GGM.CreateFlatButton(api, parent, label, width, height, variant)
    if type(api) ~= "table" or type(api.CreateFrame) ~= "function" then return nil end
    local button = api.CreateFrame("Button", nil, parent)
    button:SetSize(width, height)
    button.variant = variant or "secondary"
    button.background = button:CreateTexture(nil, "BACKGROUND")
    button.background:SetAllPoints(button)
    GGM.ApplyJournalSurface(button, "button")
    button.borderEdges = createFlatBorder(button, THEME.borderSoft)
    button.innerBorderEdges = createFlatBorder(button, THEME.borderDark, 2)
    button.hoverTexture = button:CreateTexture(nil, "HIGHLIGHT")
    button.hoverTexture:SetAllPoints(button)
    setColor(button.hoverTexture, THEME.goldHover)
    if button.SetHighlightTexture then button:SetHighlightTexture(button.hoverTexture) end

    button.label = createText(button, "OVERLAY", "GameFontHighlightSmall")
    button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
    function button:SetText(value)
        if self.label then self.label:SetText(value or "") end
    end
    function button:GetText()
        return self.label and self.label:GetText() or ""
    end
    button:SetText(label or "")
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
    if button.icon then button.icon:SetAlpha(selected and 1 or 0.88) end
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
    if changed and GGM.HideRecipeDetailsWindow then GGM.HideRecipeDetailsWindow(frame) end
    frame.selectedProfession = selectedKey
    frame.professionHeading:SetText(selectedKey)
    if frame.professionHeroIcon then frame.professionHeroIcon:SetTexture(selectedProfession.icon) end
    if frame.professionHeroArtwork then
        frame.professionHeroArtwork:SetTexture(JOURNAL_TEXTURES.professions[selectedKey])
        frame.professionHeroArtwork:SetVertexColor(1, 1, 1, 1)
    end
    for _, button in ipairs(frame.professionButtons) do professionButtonColor(button, button.key == selectedKey) end
    if changed and frame.professionSearchBox then frame.professionSearchBox:SetText("") end
    if frame.db and type(GGM.BuildProfessionRecipeCatalog) == "function" then
        frame.professionCatalog = GGM.BuildProfessionRecipeCatalog(frame.db, selectedProfession.professionID, selectedProfession.key, frame.api)
        if updateProfessionRecipeBrowser then updateProfessionRecipeBrowser(frame) end
    end
    return true
end

local function createProfessionButton(api, sidebar, profession, offset)
    local button = api.CreateFrame("Button", nil, sidebar)
    button:SetSize(UI.professionRowWidth, UI.professionRowHeight)
    button:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 34, -offset)
    button.variant = "profession"
    button.background = button:CreateTexture(nil, "BACKGROUND")
    button.background:SetAllPoints(button)
    button.background:SetTexture(JOURNAL_TEXTURES.professionButton)
    button.background:SetTexCoord(0.03085, 0.96961, 0.23757, 0.76520)
    button.borderEdges = createFlatBorder(button, THEME.borderSoft)
    button.hoverTexture = button:CreateTexture(nil, "HIGHLIGHT")
    button.hoverTexture:SetAllPoints(button)
    setColor(button.hoverTexture, THEME.goldHover)
    if button.SetHighlightTexture then button:SetHighlightTexture(button.hoverTexture) end

    button.selectionBar = button:CreateTexture(nil, "ARTWORK")
    button.selectionBar:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button.selectionBar:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    button.selectionBar:SetWidth(3)
    setColor(button.selectionBar, THEME.gold)
    button.selectionBar:Hide()

    local iconHolder = createSurface(api, button, THEME.slot, THEME.borderSoft)
    iconHolder:SetSize(42, 42)
    iconHolder:SetPoint("LEFT", button, "LEFT", 10, 0)
    local icon = iconHolder:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", iconHolder, "TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", iconHolder, "BOTTOMRIGHT", -3, 3)
    icon:SetTexture(profession.icon)
    button.icon = icon

    button.label = createText(button, "OVERLAY", "GameFontHighlight")
    GGM.ApplyJournalFont(button.label, 16, "bold")
    button.label:SetText(profession.key)
    if button.label.ClearAllPoints then button.label:ClearAllPoints() end
    button.label:SetPoint("LEFT", iconHolder, "RIGHT", 14, 0)
    button.label:SetPoint("RIGHT", button, "RIGHT", -10, 0)
    button.label:SetJustifyH("LEFT")
    button.key = profession.key
    button:SetScript("OnClick", function() GGM.SelectProfession(sidebar.owner, profession.key) end)
    button:RegisterForClicks("LeftButtonUp")
    professionButtonColor(button, false)
    button.professionID = profession.professionID
    return button
end

local function createProfessionsPage(api, frame)
    local page = api.CreateFrame("Frame", nil, frame)
    page:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -64)
    page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -50, 56)
    page.owner = frame
    page:Hide()

    local sidebar = api.CreateFrame("Frame", nil, page)
    sidebar:SetPoint("TOPLEFT", page, "TOPLEFT", UI.professionLibraryX, -(UI.professionLibraryTop - 64))
    sidebar:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", UI.professionLibraryX, 0)
    sidebar:SetWidth(UI.professionSidebarWidth)
    sidebar.owner = frame
    frame.professionSidebar = sidebar

    local eyebrow = createText(sidebar, "OVERLAY", "GameFontNormal")
    GGM.ApplyJournalFont(eyebrow, 16, "bold")
    eyebrow:SetText("PROFESSION LIBRARY")
    setTextColor(eyebrow, THEME.text)
    eyebrow:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 34, -10)
    local helper = createText(sidebar, "OVERLAY", "GameFontHighlight")
    GGM.ApplyJournalFont(helper, 14)
    helper:SetPoint("TOPLEFT", eyebrow, "BOTTOMLEFT", 0, -5)
    helper:SetWidth(UI.professionSidebarWidth - 56)
    helper:SetText("Browse cached recipe snapshots")
    setTextColor(helper, THEME.textSoft)
    local libraryRule = sidebar:CreateTexture(nil, "BORDER")
    libraryRule:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 34, -53)
    libraryRule:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -8, -53)
    libraryRule:SetHeight(1)
    setColor(libraryRule, THEME.borderSoft)

    frame.professionButtons = {}
    for index, profession in ipairs(PROFESSIONS) do
        frame.professionButtons[index] = createProfessionButton(api, sidebar, profession,
            62 + (index - 1) * UI.professionRowPitch)
    end

    local panel = api.CreateFrame("Frame", nil, page)
    panel:SetPoint("TOPLEFT", page, "TOPLEFT", UI.professionDetailX, 0)
    panel:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    panel.background = panel:CreateTexture(nil, "BACKGROUND")
    panel.background:SetPoint("TOPLEFT", panel, "TOPLEFT", 9, -9)
    panel.background:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -9, 9)
    panel.background:SetTexture(JOURNAL_TEXTURES.professions.Alchemy)
    panel.background:SetVertexColor(1, 1, 1, 1)
    panel.background:SetTexCoord(0, 1, 0, 1)
    frame.professionDetailPanel = panel
    frame.professionHeroArtwork = panel.background

    local hero = api.CreateFrame("Frame", nil, panel)
    hero:SetPoint("TOPLEFT", panel, "TOPLEFT", 34, -52)
    hero:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -24, -52)
    hero:SetHeight(84)
    frame.professionHeroHeader = hero
    local iconFrame = createSurface(api, hero, THEME.slot, THEME.gold)
    iconFrame:SetSize(60, 60)
    iconFrame:SetPoint("TOPLEFT", hero, "TOPLEFT", 0, 0)
    frame.professionHeroIcon = iconFrame:CreateTexture(nil, "ARTWORK")
    frame.professionHeroIcon:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 4, -4)
    frame.professionHeroIcon:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -4, 4)

    frame.professionHeading = createText(hero, "OVERLAY", "GameFontNormalHuge")
    GGM.ApplyJournalFont(frame.professionHeading, 30, "bold")
    frame.professionHeading:SetPoint("TOPLEFT", iconFrame, "TOPRIGHT", 14, -1)
    frame.professionHeading:SetWidth(360)
    frame.professionHeading:SetJustifyH("LEFT")
    setTextColor(frame.professionHeading, THEME.text)

    local subtitle = createText(hero, "OVERLAY", "GameFontHighlight")
    GGM.ApplyJournalFont(subtitle, 14)
    subtitle:SetPoint("TOPLEFT", frame.professionHeading, "BOTTOMLEFT", 0, -7)
    subtitle:SetWidth(360)
    subtitle:SetText("Last-known recipe information")
    setTextColor(subtitle, THEME.textSoft)

    local searchLabel = createText(panel, "OVERLAY", "GameFontHighlight")
    GGM.ApplyJournalFont(searchLabel, 15, "bold")
    searchLabel:SetText("Search recipes")
    setTextColor(searchLabel, THEME.text)
    searchLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 34, -156)
    frame.professionSearchBox = api.CreateFrame("EditBox", nil, panel)
    frame.professionSearchBox:SetSize(400, 27)
    frame.professionSearchBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 34, -177)
    frame.professionSearchBox:SetAutoFocus(false)
    frame.professionSearchBox:SetTextInsets(31, 8, 0, 0)
    frame.professionSearchBoxBackground = frame.professionSearchBox:CreateTexture(nil, "BACKGROUND")
    frame.professionSearchBoxBackground:SetAllPoints(frame.professionSearchBox)
    frame.professionSearchBoxBackground:SetTexture(JOURNAL_TEXTURES.parchment)
    frame.professionSearchBoxBackground:SetVertexColor(0.96, 0.83, 0.62, 1)
    frame.professionSearchBoxBorder = createFlatBorder(frame.professionSearchBox, THEME.border)
    frame.professionSearchIcon = frame.professionSearchBox:CreateTexture(nil, "ARTWORK")
    frame.professionSearchIcon:SetSize(16, 16)
    frame.professionSearchIcon:SetPoint("LEFT", frame.professionSearchBox, "LEFT", 9, 0)
    frame.professionSearchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    GGM.ApplyJournalFont(frame.professionSearchBox, 14)
    setTextColor(frame.professionSearchBox, THEME.text)
    frame.professionSearchBox:SetText("")

    frame.professionCount = createText(panel, "OVERLAY", "GameFontDisableSmall")
    frame.professionCount:SetPoint("LEFT", frame.professionSearchBox, "RIGHT", 14, 0)
    setTextColor(frame.professionCount, THEME.textSoft)
    frame.professionStatus = createText(panel, "OVERLAY", "GameFontHighlight")
    GGM.ApplyJournalFont(frame.professionStatus, 13)
    frame.professionStatus:SetPoint("TOPLEFT", frame.professionSearchBox, "BOTTOMLEFT", 0, -4)
    frame.professionStatus:SetPoint("RIGHT", panel, "RIGHT", -18, 0)
    frame.professionStatus:SetJustifyH("LEFT")
    setTextColor(frame.professionStatus, THEME.textSoft)

    frame.professionRecipeHeading = createText(panel, "OVERLAY", "GameFontNormal")
    GGM.ApplyJournalFont(frame.professionRecipeHeading, 17, "bold")
    frame.professionRecipeHeading:SetText("CACHED RECIPES")
    frame.professionRecipeHeading:SetPoint("TOPLEFT", panel, "TOPLEFT", 34, -230)
    setTextColor(frame.professionRecipeHeading, THEME.text)
    frame.professionRecipeHeading:Hide()

    frame.professionRecipeScroll = api.CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    frame.professionRecipeScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 34, -257)
    frame.professionRecipeScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 22)
    frame.professionRecipeContent = api.CreateFrame("Frame", nil, frame.professionRecipeScroll)
    frame.professionRecipeContent:SetSize(667, 1)
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
    if frame.professionRecipeHeading then
        if (catalog.state == "ready" or catalog.state == "incomplete") and #recipes > 0 then
            frame.professionRecipeHeading:SetText("CACHED RECIPES")
            frame.professionRecipeHeading:Show()
        else
            frame.professionRecipeHeading:Hide()
        end
    end
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
            row = frame.api.CreateFrame("Button", nil, frame.professionRecipeContent)
            row:RegisterForClicks("LeftButtonUp")
            row:SetScript("OnClick", function(self) GGM.ShowRecipeDetailsWindow(frame, self.recipe) end)
            if row.SetHighlightTexture then row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD") end
            row.outputIcon = row:CreateTexture(nil, "ARTWORK")
            row.outputIcon:SetSize(60, 60)
            row.outputIcon:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -7)
            row.outputIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.outputIconBevel = frame.api.CreateFrame("Frame", nil, row)
            row.outputIconBevel:SetPoint("TOPLEFT", row.outputIcon, "TOPLEFT", -3, 3)
            row.outputIconBevel:SetPoint("BOTTOMRIGHT", row.outputIcon, "BOTTOMRIGHT", 3, -3)
            local outerBevelEdges = createFlatBorder(row.outputIconBevel, THEME.iconBevelOutline)
            local innerBevelEdges = createFlatBorder(row.outputIconBevel, THEME.iconBevelOutline, 1)
            setColor(innerBevelEdges[1], THEME.iconBevelLight)
            setColor(innerBevelEdges[2], THEME.iconBevelShadow)
            setColor(innerBevelEdges[3], THEME.iconBevelLight)
            setColor(innerBevelEdges[4], THEME.iconBevelShadow)
            row.name = createText(row, "OVERLAY", "GameFontHighlight")
            GGM.ApplyJournalFont(row.name, 21, "bold")
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 82, -15)
            row.name:SetWidth(567)
            row.name:SetJustifyH("LEFT")
            setTextColor(row.name, THEME.text)
            row.knownBy = createText(row, "OVERLAY", "GameFontHighlightSmall")
            GGM.ApplyJournalFont(row.knownBy, 13)
            row.knownBy:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
            row.knownBy:SetWidth(567)
            row.knownBy:SetJustifyH("LEFT")
            setTextColor(row.knownBy, THEME.textSoft)
            row.separator = row:CreateTexture(nil, "BORDER")
            row.separator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 8, 0)
            row.separator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -18, 0)
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
        row.outputIcon:SetTexture(recipe.outputIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.name:SetText(recipe.name or "Unknown recipe")
        row.knownBy:SetText(#owners > 0 and ("Known by: " .. table.concat(owners, "\n")) or "Cached recipe snapshot")
        local rowHeight = math.max(82, 52 + #owners * 17)
        row:SetHeight(rowHeight)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.professionRecipeContent, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", frame.professionRecipeContent, "TOPRIGHT", 0, -y)
        row:Show()
        y = y + rowHeight + 1
    end
    for index = #filtered + 1, #frame.professionRecipeRows do frame.professionRecipeRows[index]:Hide() end
    frame.professionRecipeContent:SetHeight(math.max(y, 1))
    if GGM.RefreshRecipeDetailsWindow then GGM.RefreshRecipeDetailsWindow(frame) end
end

function GGM.RefreshVisibleProfessionCatalog()
    local frame = GGM.guildGearBrowserFrame
    if not frame or frame.activeTab ~= "Professions" or not frame.db
        or type(GGM.BuildProfessionRecipeCatalog) ~= "function" then
        return false
    end
    local profession
    for _, item in ipairs(PROFESSIONS) do
        if item.key == frame.selectedProfession then profession = item; break end
    end
    if not profession then return false end
    frame.professionCatalog = GGM.BuildProfessionRecipeCatalog(
        frame.db, profession.professionID, profession.key, frame.api)
    updateProfessionRecipeBrowser(frame)
    return true
end

local updateBrowserList

local function setPageHeader(frame, title, subtitle)
    frame.pageTitle:SetText(title)
    frame.pageSubtitle:SetText(subtitle)
end

function GGM.SelectGuildGearBrowserTab(frame, selectedKey)
    if selectedKey ~= "Character" and selectedKey ~= "Professions" and selectedKey ~= "Bank" then return false end
    if selectedKey ~= "Professions" and GGM.HideRecipeDetailsWindow then GGM.HideRecipeDetailsWindow(frame) end
    frame.activeTab = selectedKey
    if frame.TitleText then frame.TitleText:SetText("Guild Gear Memory") end

    if selectedKey == "Character" then setPageHeader(frame, "Characters", "Inspect last-known equipment snapshots across your guild")
    elseif selectedKey == "Professions" then setPageHeader(frame, "Professions", "Review captured profession snapshots and recipes")
    else setPageHeader(frame, "Bank", "Saved bank snapshots and shared storage") end

    for _, tab in ipairs(frame.navigationTabs) do
        local selected = tab.key == selectedKey
        local tint = selected and tab.selectedTint or tab.idleTint
        if tab.background and tab.background.SetVertexColor then
            tab.background:SetVertexColor(tint[1], tint[2], tint[3], tint[4] or 1)
        end
        if tab.label then setTextColor(tab.label, selected and THEME.railText or THEME.railMuted) end
        if tab.caption then setTextColor(tab.caption, selected and THEME.railGold or THEME.railMuted) end
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
            row.base:SetTexture(JOURNAL_TEXTURES.professionButton)
            row.base:SetTexCoord(0.03085, 0.96961, 0.23757, 0.76520)
            row.base:SetVertexColor(1, 1, 1, 1)
            row.selection = row:CreateTexture(nil, "BACKGROUND")
            row.selection:SetAllPoints(row)
            setColor(row.selection, THEME.goldDim, 0.15)
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
            GGM.ApplyJournalFont(row.label, 16, "bold")
            row.realm = createText(row, "OVERLAY", "GameFontDisableSmall")
            row.realm:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -3)
            row.realm:SetPoint("RIGHT", row, "RIGHT", -12, 0)
            row.realm:SetJustifyH("LEFT")
            GGM.ApplyJournalFont(row.realm, 13)
            row.separator = row:CreateTexture(nil, "BORDER")
            row.separator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 0)
            row.separator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 0)
            row.separator:SetHeight(1)
            row.separator:Hide()
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
    button:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", x, -62)
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
    tab:SetSize(UI.navigationTabWidth, UI.navigationRowHeight)
    tab:SetPoint("TOPLEFT", frame.navigationRail, "TOPLEFT", 33, y)

    tab.background = tab:CreateTexture(nil, "BACKGROUND")
    tab.background:SetAllPoints(tab)
    tab.background:SetColorTexture(1, 1, 1, 0)
    tab.idleTint = { 1, 1, 1, 0 }
    tab.selectedTint = { 1, 1, 1, 0 }

    tab.highlight = tab:CreateTexture(nil, "HIGHLIGHT")
    tab.highlight:SetAllPoints(tab)
    setColor(tab.highlight, { 1.000, 0.650, 0.180, 0.12 })
    if tab.SetHighlightTexture then tab:SetHighlightTexture(tab.highlight) end

    tab.accent = tab:CreateTexture(nil, "ARTWORK")
    tab.accent:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, 0)
    tab.accent:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
    tab.accent:SetWidth(3)
    setColor(tab.accent, THEME.railGold)
    tab.accent:Hide()

    tab.icon = tab:CreateTexture(nil, "ARTWORK")
    tab.icon:SetSize(UI.navigationIconSize, UI.navigationIconSize)
    tab.icon:SetPoint("LEFT", tab, "LEFT", 12, 0)
    tab.icon:SetTexture(iconPath)
    tab.icon:SetAlpha(0.88)

    tab.iconBorder = tab:CreateTexture(nil, "OVERLAY")
    tab.iconBorder:SetSize(UI.navigationIconSize + 8, UI.navigationIconSize + 8)
    tab.iconBorder:SetPoint("CENTER", tab.icon, "CENTER", 0, 0)
    tab.iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    tab.iconBorder:SetAlpha(0.82)

    tab.label = createText(tab, "OVERLAY", "GameFontHighlight")
    GGM.ApplyJournalFont(tab.label, 16, "bold")
    tab.label:SetPoint("TOPLEFT", tab.icon, "TOPRIGHT", 22, -5)
    tab.label:SetText(label)
    setTextColor(tab.label, THEME.railText)
    tab.caption = createText(tab, "OVERLAY", "GameFontDisableSmall")
    GGM.ApplyJournalFont(tab.caption, 12)
    tab.caption:SetPoint("TOPLEFT", tab.label, "BOTTOMLEFT", 0, -1)
    tab.caption:SetText(caption)
    setTextColor(tab.caption, THEME.railMuted)

    tab.key = key
    tab:RegisterForClicks("LeftButtonUp")
    tab:SetScript("OnClick", function() GGM.SelectGuildGearBrowserTab(frame, key) end)
    return tab
end

local function createGearPanel(api, frame)
    local panel = createSurface(api, frame, THEME.panel, THEME.borderSoft, true)
    panel:SetSize(UI.detailColumnWidth, UI.windowHeight - UI.contentTop - UI.contentBottom)
    GGM.ApplyJournalSurface(panel, "parchment")
    panel:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.railWidth + UI.pageMargin + UI.browserColumnWidth + UI.contentGap, -UI.contentTop)

    panel.header = panel:CreateTexture(nil, "BACKGROUND")
    panel.header:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -2)
    panel.header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
    panel.header:SetHeight(122)
    panel.header:Hide()
    -- Keep the vignette above the opaque parchment; same-layer texture
    -- creation order is not a reliable stacking contract in the game client.
    panel.armoryArt = panel:CreateTexture(nil, "ARTWORK")
    panel.armoryArt:SetSize(264, 122)
    panel.armoryArt:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -3, -3)
    panel.armoryArt:SetTexture(JOURNAL_TEXTURES.armory)
    panel.armoryArt:SetTexCoord(0.44, 1, 0, 0.53)
    panel.goldRule = panel:CreateTexture(nil, "ARTWORK")
    panel.goldRule:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, -124)
    panel.goldRule:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -24, -124)
    panel.goldRule:SetHeight(1)
    setColor(panel.goldRule, THEME.gold, 0.48)
    panel.sectionLabel = createEyebrow(panel, "EQUIPMENT SNAPSHOT")
    panel.sectionLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 28, -17)
    return panel
end

local function createSlotButton(api, frame, trackedSlot, layout, x, y)
    local button = api.CreateFrame("Button", nil, frame.gearPanel)
    button:SetSize(40, 40)
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
    local button = api.CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    button:SetSize(32, 32)
    button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
    button:SetScript("OnClick", function() frame:Hide() end)
    frame.proCloseButton = button
end

function GGM.CreateGuildGearBrowserWindow(api)
    api.UISpecialFrames = api.UISpecialFrames or {}
    local frameName = "GuildGearMemoryBrowserFrame"
    local isRegistered = false
    for _, registeredName in ipairs(api.UISpecialFrames) do if registeredName == frameName then isRegistered = true; break end end
    if not isRegistered then table.insert(api.UISpecialFrames, frameName) end

    local frame = api.CreateFrame("Frame", frameName, api.UIParent)
    frame:SetSize(UI.windowWidth, UI.windowHeight)
    local screen = api.UIParent
    if frame.SetScale and screen and type(screen.GetWidth) == "function" and type(screen.GetHeight) == "function" then
        local screenWidth, screenHeight = screen:GetWidth(), screen:GetHeight()
        if screenWidth > 0 and screenHeight > 0 then
            local fitScale = math.min(1, (screenWidth - 24) / UI.windowWidth, (screenHeight - 24) / UI.windowHeight)
            frame:SetScale(math.max(0.25, fitScale))
        end
    end
    frame:SetPoint("CENTER")
    frame:SetClampedToScreen(true)
    frame:Hide()
    frame.api = api
    frame:SetScript("OnHide", function(self)
        if GGM.HideRecipeDetailsWindow then GGM.HideRecipeDetailsWindow(self) end
    end)
    frame.entries, frame.filteredEntries, frame.listRows, frame.slotButtons = {}, {}, {}, {}
    frame.browserView = "Guild"

    if frame.SetMovable then frame:SetMovable(true) end
    if frame.EnableMouse then frame:EnableMouse(true) end
    if frame.RegisterForDrag then frame:RegisterForDrag("LeftButton") end
    frame:SetScript("OnDragStart", function(self) if self.StartMoving then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self) if self.StopMovingOrSizing then self:StopMovingOrSizing() end end)

    frame.background = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    frame.background:SetAllPoints(frame)
    frame.background:SetTexture(JOURNAL_TEXTURES.window)
    frame.background:SetVertexColor(1, 1, 1, 1)
    frame.background:SetAlpha(1)

    frame.navigationRail = api.CreateFrame("Frame", nil, frame)
    frame.navigationRail:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -28)
    frame.navigationRail:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 22)
    frame.navigationRail:SetWidth(UI.railWidth)

    frame.brandIconFrame = createSurface(api, frame.navigationRail, THEME.slot, THEME.gold)
    frame.brandIconFrame:SetSize(48, 48)
    frame.brandIconFrame:SetPoint("TOPLEFT", frame.navigationRail, "TOPLEFT", 38, -21)
    frame.brandIcon = frame.brandIconFrame:CreateTexture(nil, "ARTWORK")
    frame.brandIcon:SetPoint("TOPLEFT", frame.brandIconFrame, "TOPLEFT", 5, -5)
    frame.brandIcon:SetPoint("BOTTOMRIGHT", frame.brandIconFrame, "BOTTOMRIGHT", -5, 5)
    frame.brandIcon:SetTexture("Interface\\Icons\\INV_Chest_Chain_05")

    frame.brandTitle = createText(frame.navigationRail, "OVERLAY", "GameFontNormalLarge")
    GGM.ApplyJournalFont(frame.brandTitle, 20, "bold")
    frame.brandTitle:SetPoint("TOPLEFT", frame.brandIconFrame, "TOPRIGHT", 10, -5)
    frame.brandTitle:SetText("Guild Gear Memory")
    setTextColor(frame.brandTitle, THEME.railGold)
    frame.brandSubtitle = createText(frame.navigationRail, "OVERLAY", "GameFontHighlightSmall")
    GGM.ApplyJournalFont(frame.brandSubtitle, 13)
    frame.brandSubtitle:SetPoint("TOPLEFT", frame.brandTitle, "BOTTOMLEFT", 0, -5)
    frame.brandSubtitle:SetText("Gear memory and recipe snapshots")
    setTextColor(frame.brandSubtitle, THEME.railMuted)

    local navLabel = createSectionLabel(frame.navigationRail, "LIBRARY")
    GGM.ApplyJournalFont(navLabel, 15)
    navLabel:SetPoint("TOPLEFT", frame.navigationRail, "TOPLEFT", 38, -100)
    setTextColor(navLabel, THEME.railMuted)
    frame.navigationTabs = {
        createNavigationTab(api, frame, "Character", "Characters", "Gear snapshots", "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest", -122),
        createNavigationTab(api, frame, "Professions", "Professions", "Recipe memory", "Interface\\Icons\\Trade_BlackSmithing", -185),
        createNavigationTab(api, frame, "Bank", "Bank", "Shared storage", "Interface\\Icons\\INV_Misc_Bag_10", -248),
    }

    if frame.TitleText then frame.TitleText:SetText(""); frame.TitleText:Hide() end
    frame.pageTitle = createText(frame, "OVERLAY", "GameFontNormalHuge")
    GGM.ApplyJournalFont(frame.pageTitle, 26, "bold")
    frame.pageTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 342, -49)
    setTextColor(frame.pageTitle, THEME.text)
    frame.pageSubtitle = createText(frame, "OVERLAY", "GameFontHighlightSmall")
    GGM.ApplyJournalFont(frame.pageSubtitle, 13)
    frame.pageSubtitle:SetPoint("TOPLEFT", frame.pageTitle, "BOTTOMLEFT", 0, -4)
    setTextColor(frame.pageSubtitle, THEME.muted)
    createCloseButton(api, frame)

    frame.searchPanel = createSurface(api, frame, THEME.panel, THEME.borderSoft, true)
    frame.searchPanel:SetSize(UI.browserColumnWidth, 148)
    frame.searchPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.railWidth + UI.pageMargin, -UI.contentTop)
    frame.searchPanel.background:Hide()
    for _, edge in ipairs(frame.searchPanel.border) do edge:Hide() end
    for _, edge in ipairs(frame.searchPanel.innerBorder or {}) do edge:Hide() end
    frame.charactersHeading = createEyebrow(frame.searchPanel, "CHARACTER LIBRARY")
    GGM.ApplyJournalFont(frame.charactersHeading, 16, "bold")
    frame.charactersHeading:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", 14, -17)
    local libraryHelper = createText(frame.searchPanel, "OVERLAY", "GameFontHighlightSmall")
    libraryHelper:SetPoint("TOPLEFT", frame.charactersHeading, "BOTTOMLEFT", 0, -5)
    libraryHelper:SetText("Browse last-known equipment")
    setTextColor(libraryHelper, THEME.textSoft)
    frame.mineButton = createBrowserViewButton(api, frame, "Mine", "My Characters", 14)
    frame.guildButton = createBrowserViewButton(api, frame, "Guild", "Guild", 123)
    updateBrowserViewButtonStyles(frame)

    frame.searchLabel = createSectionLabel(frame.searchPanel, "")
    frame.searchLabel:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", 14, -92)
    frame.searchBox = api.CreateFrame("EditBox", nil, frame.searchPanel)
    frame.searchBox:SetSize(244, 27)
    frame.searchBox:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", 14, -102)
    frame.searchBox:SetAutoFocus(false)
    if frame.searchBox.SetTextInsets then frame.searchBox:SetTextInsets(31, 8, 0, 0) end
    GGM.ApplyJournalFont(frame.searchBox, 14)
    setTextColor(frame.searchBox, THEME.text)
    frame.searchBoxBackground = frame.searchBox:CreateTexture(nil, "BACKGROUND")
    frame.searchBoxBackground:SetPoint("TOPLEFT", frame.searchBox, "TOPLEFT", -2, 2)
    frame.searchBoxBackground:SetPoint("BOTTOMRIGHT", frame.searchBox, "BOTTOMRIGHT", 2, -2)
    frame.searchBoxBackground:SetTexture(JOURNAL_TEXTURES.parchment)
    frame.searchBoxBackground:SetVertexColor(0.96, 0.83, 0.62, 1)
    frame.searchBoxBorder = createFlatBorder(frame.searchBox, THEME.border)
    local searchIcon = frame.searchBox:CreateTexture(nil, "ARTWORK")
    searchIcon:SetSize(16, 16)
    searchIcon:SetPoint("LEFT", frame.searchBox, "LEFT", 9, 0)
    searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    frame.searchHint = createText(frame.searchBox, "OVERLAY", "GameFontDisableSmall")
    frame.searchHint:SetPoint("LEFT", frame.searchBox, "LEFT", 31, 0)
    frame.searchHint:SetText("Name or realm")
    setTextColor(frame.searchHint, THEME.muted)
    frame.searchBox:SetScript("OnEditFocusGained", function(self)
        self.hasFocus = true; recolorBorder(frame.searchBoxBorder, THEME.gold); updateSearchHint(frame)
    end)
    frame.searchBox:SetScript("OnEditFocusLost", function(self)
        self.hasFocus = false; recolorBorder(frame.searchBoxBorder, THEME.border); updateSearchHint(frame)
    end)
    frame.searchBox:SetScript("OnTextChanged", function() updateBrowserList(frame, api) end)

    frame.listPanel = createSurface(api, frame, THEME.panel, THEME.borderSoft, true)
    frame.listPanel:SetSize(UI.browserColumnWidth,
        UI.windowHeight - UI.contentTop - UI.contentBottom - 148)
    frame.listPanel:SetPoint("TOPLEFT", frame.searchPanel, "BOTTOMLEFT", 0, 0)
    frame.listPanel.background:Hide()
    for _, edge in ipairs(frame.listPanel.border) do edge:Hide() end
    for _, edge in ipairs(frame.listPanel.innerBorder or {}) do edge:Hide() end
    frame.characterCount = createSectionLabel(frame.listPanel, "0 characters")
    frame.characterCount:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 14, -13)
    local listHint = createText(frame.listPanel, "OVERLAY", "GameFontDisableSmall")
    listHint:SetPoint("TOPRIGHT", frame.listPanel, "TOPRIGHT", -14, -13)
    listHint:SetText("")
    setTextColor(listHint, THEME.muted)
    createDivider(frame.listPanel, 12, 12, -34)

    frame.listScroll = api.CreateFrame("ScrollFrame", nil, frame.listPanel, "UIPanelScrollFrameTemplate")
    frame.listScroll:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 12, -42)
    frame.listScroll:SetSize(UI.listScrollWidth, frame.listPanel:GetHeight() - 64)
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
    GGM.ApplyJournalFont(frame.characterLine, 30, "bold")
    frame.characterLine:SetPoint("TOPLEFT", frame.gearPanel, "TOPLEFT", 28, -37)
    frame.characterLine:SetWidth(385)
    frame.characterLine:SetJustifyH("LEFT")
    setTextColor(frame.characterLine, THEME.text)
    frame.realmLine = createText(frame.gearPanel, "OVERLAY", "GameFontHighlightSmall")
    frame.realmLine:SetPoint("TOPLEFT", frame.characterLine, "BOTTOMLEFT", 1, -4)
    setTextColor(frame.realmLine, THEME.muted)
    frame.snapshotCaption = createSectionLabel(frame.gearPanel, "LAST CAPTURED")
    GGM.ApplyJournalFont(frame.snapshotCaption, 11, "bold")
    frame.snapshotCaption:SetPoint("TOPLEFT", frame.gearPanel, "TOPLEFT", 28, -95)
    frame.capturedLine = createText(frame.gearPanel, "OVERLAY", "GameFontHighlightSmall")
    -- A bounded region avoids relying on a hidden caption's auto-sized bounds
    -- while selection changes hide and repopulate the header.
    frame.capturedLine:SetSize(152, 16)
    frame.capturedLine:SetPoint("TOPLEFT", frame.gearPanel, "TOPLEFT", 138, -95)
    GGM.ApplyJournalFont(frame.capturedLine, 12)
    frame.capturedLine:SetJustifyH("LEFT")
    setTextColor(frame.capturedLine, THEME.textSoft)
    frame.completenessBadge = createStatusBadge(api, frame.gearPanel)
    frame.completenessBadge:SetPoint("TOPLEFT", frame.gearPanel, "TOPLEFT", 302, -89)
    frame.completenessBadge:Hide()
    frame.completenessLine = frame.completenessBadge.text

    frame.modelStage = createSurface(api, frame.gearPanel, THEME.panel, THEME.borderSoft)
    frame.modelStage:SetSize(208, 226)
    frame.modelStage:SetPoint("TOP", frame.gearPanel, "TOP", 0, -146)
    frame.modelStage.background:Hide()
    for _, edge in ipairs(frame.modelStage.border) do edge:Hide() end
    frame.stageLabel = createSectionLabel(frame.modelStage, "SAVED PORTRAIT")
    frame.stageLabel:SetPoint("TOP", frame.modelStage, "TOP", 0, -3)
    frame.stageRule = createDivider(frame.modelStage, 30, 30, -24)

    frame.characterModelView = GGM.CreateSavedCharacterModel(api, frame.modelStage)
    if frame.characterModelView.model then
        local view = frame.characterModelView
        view.model:SetSize(208, 192)
        view.model:SetPoint("BOTTOM", frame.modelStage, "BOTTOM", 0, 0)
        view.model.background:Hide()
        view.model.portraitBorder:SetSize(126, 126)
        view.model.portraitBorder:ClearAllPoints()
        view.model.portraitBorder:SetPoint("TOP", view.model, "TOP", 0, 0)
        setColor(view.model.portraitBorder, THEME.gold)
        view.portrait:SetSize(118, 118)
        GGM.ApplyJournalFont(view.raceLabel, 16, "bold")
        GGM.ApplyJournalFont(view.sexLabel, 13)
        GGM.ApplyJournalFont(view.caption, 11)
        setTextColor(view.raceLabel, THEME.text)
        setTextColor(view.sexLabel, THEME.textSoft)
        setTextColor(view.caption, THEME.muted)
        view.raceLabel:ClearAllPoints()
        view.raceLabel:SetPoint("TOP", view.model.portraitBorder, "BOTTOM", 0, -9)
        view.caption:SetWidth(208)
        view.caption:ClearAllPoints()
        view.caption:SetPoint("BOTTOM", view.model, "BOTTOM", 0, 0)
        view.model:Hide()
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
    local sideStartY, sidePitch = -144, 41
    local bottomX = { 250, 346, 442 }
    local bottomY = -400
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
    frame.detailFooter.background:Hide()
    for _, edge in ipairs(frame.detailFooter.border) do edge:Hide() end
    local footerText = createText(frame.detailFooter, "OVERLAY", "GameFontDisableSmall")
    footerText:SetPoint("CENTER", frame.detailFooter, "CENTER", 0, 0)
    GGM.ApplyJournalFont(footerText, 12)
    footerText:SetText("Last-known equipment · Hover a slot to view the saved item")
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
        if type(GGM.startupError) == "string"
            and GGM.startupError:match("^unsupported%-schema%-version:%d+$") then
            emit("No automatic migration is available. Close WoW, back up and remove WTF/Account/<account>/SavedVariables/GuildGearMemory.lua (or remove only its GuildGearMemoryDB global), then relaunch.")
            emit("This clears cached gear, profession snapshots/index data, and local-character metadata.")
        end
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
