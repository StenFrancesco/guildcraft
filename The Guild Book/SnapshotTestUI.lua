local _, GGM = ...
local REQUEST_ERRORS
local function cpuCheckpoint()
    if GGM.CPUCheckpoint then GGM.CPUCheckpoint() end
end
local function cpuSort(rows, less)
    if GGM.CPUSort then return GGM.CPUSort(rows, less) end
    return table.sort(rows, less)
end

local function gearUnavailableMessage(db)
    local reason = type(db) == "table" and db.gearUnavailableReason or nil
    if not reason then return nil end
    if reason == "gear-companion-missing" then
        return "Install and enable The Guild Book gear beside The Guild Book to save and view gear."
    end
    if type(reason) == "string" and reason:match("^gear%-backend%-") then
        return "Gear backend unavailable. Check /ggm status for details."
    end
    return "Gear storage is unavailable. Check /ggm status for details."
end

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
        cpuCheckpoint()
        local record = GGM.GetCharacterRecord(db, key)
        if record and hasValidBrowserIdentity(record, key) then
            table.insert(entries, {
                key = key,
                name = record.identity.name,
                realm = record.identity.realm,
                searchName = string.lower(record.identity.name),
                searchRealm = string.lower(record.identity.realm),
                record = record,
            })
        end
    end

    cpuSort(entries, function(left, right)
        local leftName, rightName = left.searchName, right.searchName
        if leftName ~= rightName then return leftName < rightName end
        local leftRealm, rightRealm = left.searchRealm, right.searchRealm
        if leftRealm ~= rightRealm then return leftRealm < rightRealm end
        return left.key < right.key
    end)

    return entries
end

function GGM.FilterGuildGearBrowserEntries(entries, query)
    local filtered = {}
    if type(entries) ~= "table" then return filtered end
    if query == nil or query == "" then
        for _, entry in ipairs(entries) do cpuCheckpoint(); table.insert(filtered, entry) end
        return filtered
    end
    if type(query) ~= "string" then return filtered end

    local needle = string.lower(query)
    for _, entry in ipairs(entries) do
        cpuCheckpoint()
        if type(entry) == "table" then
            local name = entry.searchName or (type(entry.name) == "string" and string.lower(entry.name) or "")
            local realm = entry.searchRealm or (type(entry.realm) == "string" and string.lower(entry.realm) or "")
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
        cpuCheckpoint()
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
        local displayName = itemLink and itemLink:match("|h%[(.-)%]|h") or slotDisplayNames[trackedSlot.key]
        table.insert(slots, {
            key = trackedSlot.key,
            inventorySlotID = state.inventorySlotID,
            itemID = itemID,
            itemLink = itemLink,
            itemString = state.itemString,
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
    parchment = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\parchment.tga",
    leather = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\leather.tga",
    button = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\profession-button.tga",
    professionButton = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\profession-button-framed.tga",
    window = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\journal-window.blp",
    professionMask = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\profession-page-mask.tga",
    gearPage = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\gear-journal-page.blp",
    font = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\journal-serif.ttf",
    boldFont = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\journal-serif-bold.ttf",
    italicFont = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\journal-serif-italic.ttf",
    professions = {
        Alchemy = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\alchemy-page.blp",
        Blacksmithing = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\blacksmithing-page.blp",
        Cooking = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\cooking-page.tga",
        Enchanting = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\enchanting-page.blp",
        Engineering = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\engineering-page.blp",
        ["First Aid"] = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\first-aid-page.tga",
        Fishing = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\fishing-page.tga",
        Leatherworking = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\leatherworking-page.blp",
        Tailoring = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\tailoring-page.blp",
    },
    professionFallback = "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\parchment.tga",
}
GGM.UITheme = THEME
GGM.UIJournalTextures = JOURNAL_TEXTURES

function GGM.ApplyJournalFont(text, size, flags)
    if not text or type(text.SetFont) ~= "function" then return false end
    local isBold = flags == "bold" or flags == true
    local isItalic = flags == "italic"
    local path = isBold and JOURNAL_TEXTURES.boldFont
        or (isItalic and JOURNAL_TEXTURES.italicFont or JOURNAL_TEXTURES.font)
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
    windowHeight = 694,
    railWidth = 292,
    headerHeight = 72,
    pageMargin = 50,
    contentTop = 96,
    contentBottom = 24,
    navigationRowHeight = 56,
    navigationTabWidth = 238,
    navigationIconSize = 38,
    browserColumnWidth = 297,
    detailColumnWidth = 702,
    contentGap = 18,
    ownershipButtonWidth = 105,
    controlHeightCompact = 28,
    characterRowHeight = 58,
    listScrollWidth = 244,
    listScrollHeight = 326,
    -- Bounds inside the painted journal window, independent of the generic
    -- page margins used by placeholder content.
    characterLibraryX = 334,
    characterLibraryWidth = 280,
    characterLibraryBottom = 574,
    characterDetailX = 629,
    characterDetailTop = 64,
    characterDetailHeight = 574,
    characterDetailWidth = 721,
    professionLibraryX = 314,
    professionLibraryTop = 145,
    professionDetailX = 629,
    professionSidebarWidth = 297,
    professionScrollLeft = 30,
    professionScrollWidth = 239,
    professionScrollHeight = 350,
    professionRowWidth = 231,
    professionRowHeight = 48,
    professionRowPitch = 57,
    professionRowInset = 4,
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

local function refreshGearSyncControls(frame)
    if not frame.gearSyncButton then return end
    local entry = frame.selectedEntry
    local visible = frame.activeTab == "Character" and entry ~= nil
    if not visible then
        frame.gearSyncButton:Hide()
        if frame.activeTab == "Character" then GGM.SetSharedStatus(frame, "") end
        return
    end
    frame.gearSyncButton:Show()
    local status, busy, err = "", false, nil
    if type(GGM.GetGearSyncStatus) == "function" then
        status, busy, err = GGM.GetGearSyncStatus(GGM.guildSync, entry.key)
    end
    local localError = frame.gearSyncError
    if localError and localError.targetKey == entry.key then
        err = localError.error
        if busy then frame.gearSyncError = nil; err = nil end
    end
    if err then status = REQUEST_ERRORS[err] or "Gear sync failed. Try again." end
    GGM.SetSharedStatus(frame, status)
    if frame.gearSyncButton.SetEnabled then frame.gearSyncButton:SetEnabled(not busy) end
end

function GGM.SyncSelectedGear(frame)
    local entry = frame and frame.selectedEntry
    if not entry or frame.activeTab ~= "Character" then return false end
    local ok, err = false, "sync-unavailable"
    if GGM.guildSync and type(GGM.RequestCompleteSnapshot) == "function" then
        ok, err = GGM.RequestCompleteSnapshot(GGM.guildSync, entry.record.identity)
    end
    frame.gearSyncError = not ok and { targetKey = entry.key, error = err } or nil
    GGM.lastSyncError = err
    refreshGearSyncControls(frame)
    return ok, err
end

function GGM.RefreshVisibleGearSyncStatus(dataChanged)
    local frame = GGM.guildGearBrowserFrame
    if frame and dataChanged == true then frame.gearSyncError = nil end
    if frame and frame:IsShown() then refreshGearSyncControls(frame) end
end

local function renderBrowserDetail(frame, entry, api)
    if type(GGM.ClearSavedCharacterModel) == "function" then
        GGM.ClearSavedCharacterModel(frame.characterModelView)
    elseif frame.characterModelView and frame.characterModelView.model then
        frame.characterModelView.model:Hide()
    end
    if frame.modelUnavailableLabel then frame.modelUnavailableLabel:Hide() end
    frame.detailModel = nil
    refreshGearSyncControls(frame)
    for _, control in ipairs({ frame.characterLine, frame.realmLine, frame.capturedLine }) do
        if control then control:Hide() end
    end
    if frame.snapshotCaption then frame.snapshotCaption:Hide() end
    frame.detailEmpty:Hide()
    if frame.modelStage then frame.modelStage:Hide() end
    for _, slot in ipairs(frame.slotButtons) do slot:Hide() end

    if not entry then
        local unavailable = gearUnavailableMessage(frame.db)
        if unavailable then
            frame.detailEmpty:SetText(unavailable)
        elseif #frame.activeEntries == 0 then
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
    if frame.snapshotCaption then frame.snapshotCaption:Show() end

    for index, slot in ipairs(model.slots) do
        local button = frame.slotButtons[index]
        button.key = slot.key
        button.icon:SetTexture(slot.icon)
        button.icon:SetDesaturated(slot.empty or slot.unavailable)
        button.icon:SetAlpha(slot.unavailable and 0.25 or (slot.empty and 0.7 or 1))
        setColor(button.slotBackground, slot.unavailable and THEME.input or THEME.slot)
        recolorBorder(button.borderEdges, slot.unavailable and THEME.borderSoft or (slot.empty and THEME.border or THEME.gold))
        if button.glow then
            if not slot.empty and not slot.unavailable then button.glow:Show() else button.glow:Hide() end
        end
        button.label:SetText(slot.displayName)
        local labelHeight = slot.itemID and 32 or 14
        if slot.itemID and button.paperDollGroup == "bottom" then labelHeight = 44 end
        button.label:SetHeight(labelHeight)
        button.pendingItemString = slot.itemID and slot.displayName == "Item " .. tostring(slot.itemID) and slot.itemString or nil
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
    refreshGearSyncControls(frame)
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
    { key = "Cooking", professionID = 185, icon = "Interface\\Icons\\INV_Misc_Food_15" },
    { key = "Enchanting", professionID = 333, icon = "Interface\\Icons\\Trade_Engraving" },
    { key = "Engineering", professionID = 202, icon = "Interface\\Icons\\Trade_Engineering" },
    { key = "First Aid", professionID = 129, icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice" },
    { key = "Fishing", professionID = 356, icon = "Interface\\Icons\\Trade_Fishing" },
    { key = "Leatherworking", professionID = 165, icon = "Interface\\Icons\\INV_Misc_ArmorKit_17" },
    { key = "Tailoring", professionID = 197, icon = "Interface\\Icons\\Trade_Tailoring" },
}

local PROFESSION_SUBTITLES = {
    Alchemy = "Definitely safe. Probably drinkable.",
    Blacksmithing = "Hit it until it becomes useful.",
    Enchanting = "Now with magically inflated confidence.",
    Engineering = "Safety third.",
    ["First Aid"] = "Patch up and get back to it.",
    Leatherworking = "Armor that remembers being angry.",
    Tailoring = "Sew much responsibility.",
    Cooking = "Raid fuel with extra seasoning.",
    Fishing = "Gone fishing. Guild can wait.",
    Herbalism = "Touching grass. Collecting it too.",
    Mining = "Ore else.",
    Skinning = "Fur a good cause.",
}

local function updateProfessionSubtitle(frame, selectedKey)
    local subtitle = frame.professionSubtitle
    if not subtitle then return end

    local subtitleText = PROFESSION_SUBTITLES[selectedKey]
    subtitle:SetText(subtitleText and ('"' .. subtitleText .. '"') or "")
    subtitle:SetWidth(280)
    if type(subtitle.SetWordWrap) == "function" then subtitle:SetWordWrap(true) end
    subtitle:ClearAllPoints()
    subtitle:SetJustifyH("LEFT")
    subtitle:SetPoint("TOPLEFT", frame.professionHeroIconFrame, "BOTTOMLEFT", 0, -6)
end

local function professionButtonColor(button, selected)
    GGM.SetFlatButtonState(button, selected and "selected" or "idle")
    if button.icon then button.icon:SetAlpha(selected and 1 or 0.88) end
    if button.selectionBar then if selected then button.selectionBar:Show() else button.selectionBar:Hide() end end
end

local updateProfessionRecipeBrowser, renderProfessionRows, renderCharacterRows

function GGM.FilterProfessionRecipeBrowserEntries(entries, query)
    local filtered = {}
    if type(entries) ~= "table" then return filtered end
    local needle = type(query) == "string" and string.lower(query) or ""
    if needle == "" then
        for _, entry in ipairs(entries) do cpuCheckpoint(); table.insert(filtered, entry) end
        return filtered
    end
    for _, entry in ipairs(entries) do cpuCheckpoint();
        if type(entry) == "table" and type(entry.name) == "string"
            and string.find(entry.searchName or string.lower(entry.name), needle, 1, true) then
            table.insert(filtered, entry)
        end
    end
    return filtered
end

function GGM.HideBlizzardProfessionPanel(api, professionFrame)
    if type(api) ~= "table" or not professionFrame then return false end
    if type(api.HideUIPanel) ~= "function" then return false end

    local getScript = professionFrame.GetScript
    local setScript = professionFrame.SetScript
    local originalOnHide
    local canTemporarilySuppress = type(getScript) == "function" and type(setScript) == "function"
    if canTemporarilySuppress then
        local scriptOK, script = pcall(getScript, professionFrame, "OnHide")
        if not scriptOK then return false end
        originalOnHide = script
        local clearOK = pcall(setScript, professionFrame, "OnHide", nil)
        if not clearOK then return false end
    end

    local hideOK = pcall(api.HideUIPanel, professionFrame)
    if canTemporarilySuppress then
        pcall(setScript, professionFrame, "OnHide", originalOnHide)
    end
    return hideOK
end

function GGM.CloseBlizzardProfessionPanel(api, professionFrame)
    if type(api) ~= "table" then return false end
    local trade = api.C_TradeSkillUI
    local closedContext = false
    if type(trade) == "table" and type(trade.CloseTradeSkill) == "function" then
        closedContext = pcall(trade.CloseTradeSkill)
    end
    local hiddenFrame = false
    if professionFrame and type(professionFrame.Hide) == "function" then
        hiddenFrame = pcall(professionFrame.Hide, professionFrame)
    end
    return closedContext or hiddenFrame
end

local function openSelectedProfessionContext(frame, skillLineID)
    if frame.professionLibraryMode ~= "Own" then return false end
    local trade = frame.api and frame.api.C_TradeSkillUI
    if type(trade) ~= "table" or type(trade.OpenTradeSkill) ~= "function" then return false end
    local professionFrame = frame.api.ProfessionsFrame or frame.api.TradeSkillFrame
    local frameWasShown = false
    if professionFrame and type(professionFrame.IsShown) == "function" then
        local shownOK, wasShown = pcall(professionFrame.IsShown, professionFrame)
        frameWasShown = not shownOK or wasShown == true
    end
    local openOK, opened = pcall(trade.OpenTradeSkill, skillLineID)
    if not openOK or opened == false then return false end
    frame.craftingContextSkillLineID = skillLineID
    frame.craftingContextOpenedByGuildBook = not frameWasShown
    if professionFrame then
        if type(GGM.HideBlizzardProfessionPanel) == "function" then
            GGM.HideBlizzardProfessionPanel(frame.api, professionFrame)
        elseif type(professionFrame.Hide) == "function" then
            pcall(professionFrame.Hide, professionFrame)
        end
        if type(professionFrame.SetFrameStrata) == "function" then
            pcall(professionFrame.SetFrameStrata, professionFrame, "MEDIUM")
        end
        if type(professionFrame.SetFrameLevel) == "function" then
            pcall(professionFrame.SetFrameLevel, professionFrame, 1)
        end
    end
    return true
end

-- Fixed-height virtual lists retain their full logical height while binding only
-- enough buttons for the viewport and two buffered rows on either side.
local function viewportRange(scroll, count, stride, fallbackHeight)
    local height = scroll:GetHeight()
    if height <= 0 then height = fallbackHeight end
    local capacity = math.ceil(height / stride) + 4
    local offset = math.max(0, math.min(scroll:GetVerticalScroll(), math.max(0, count * stride - height)))
    if offset ~= scroll:GetVerticalScroll() then scroll:SetVerticalScroll(offset) end
    local first = math.max(1, math.min(math.floor(offset / stride) - 1, count - capacity + 1))
    return first, math.min(count, first + capacity - 1)
end

local function hookListScroll(scroll, render)
    local function hook(event, callback)
        if scroll.HookScript then scroll:HookScript(event, callback)
        else
            local previous = scroll.GetScript and scroll:GetScript(event)
            scroll:SetScript(event, function(...)
                if previous then previous(...) end
                callback(...)
            end)
        end
    end
    hook("OnVerticalScroll", render)
    hook("OnSizeChanged", render)
end

local browserVisible
local function debounceSearch(frame, key, tab, refresh)
    local generation = (frame[key] or 0) + 1
    frame[key] = generation
    local function apply()
        if frame[key] ~= generation then return end
        if browserVisible(frame) and frame.activeTab == tab then refresh()
        elseif tab == "Professions" then frame.professionDirty = true
        else frame.charactersDirty = true end
    end
    local timer = frame.api and frame.api.C_Timer
    if timer and type(timer.After) == "function" then timer.After(0.125, apply)
    else apply() end
end

-- Dirty state belongs to the runtime browser, never SavedVariables.
local flushProfessionCatalog, refreshCharacterBrowser

browserVisible = function(frame)
    if not frame then return false end
    if type(frame.IsVisible) == "function" then return frame:IsVisible() end
    return type(frame.IsShown) == "function" and frame:IsShown()
end

-- Queue a read with a bounded lifetime tied to this visible view and input revision.
-- Callbacks receive complete models; no partial list or catalog escapes a job.
local function browserRead(frame, key, tab, build, complete, cancelled)
    if not GGM.StartCPUJob then complete(build()); return true end
    frame.cpuOwners = frame.cpuOwners or {}
    frame.cpuOwners[key] = frame.cpuOwners[key] or {}
    local owner = frame.cpuOwners[key]
    local db, selected = frame.db, frame.selectedProfession
    local input = GGM.CaptureCPUInput(db)
    local authoritative = GGM.db == db
    local membership = GGM.professionRosterMembershipCurrent
    local generation = (frame[key .. "Generation"] or 0) + 1
    frame[key .. "Generation"] = generation
    local function current()
        return browserVisible(frame) and frame.activeTab == tab and frame.db == db
            and frame[key .. "Generation"] == generation
            and (tab ~= "Professions" or frame.selectedProfession == selected)
            and (not authoritative or GGM.db == db) and GGM.IsCPUInputCurrent(db, input)
            and GGM.professionRosterMembershipCurrent == membership
    end
    local job = GGM.StartCPUJob(owner, build, complete, {
        api = frame.api, current = current,
        onCancel = function() if cancelled then cancelled() end end,
    })
    if not job and cancelled then cancelled() end
    return job ~= nil
end
local function cancelBrowserReads(frame)
    if not GGM.CancelCPUJob or not frame.cpuOwners then return end
    for _, owner in pairs(frame.cpuOwners) do GGM.CancelCPUJob(owner) end
end

local function flushBrowserRefresh(frame)
    if not browserVisible(frame) then return false end
    if frame.activeTab == "Professions" then return flushProfessionCatalog(frame) end
    if frame.activeTab == "Character" and frame.charactersDirty then return refreshCharacterBrowser(frame) end
    return false
end

local function queueBrowserRefresh(frame)
    if not browserVisible(frame) then return false end
    if frame.activeTab ~= "Professions" and frame.activeTab ~= "Character" then return false end
    if frame.browserRefreshPending then return true end
    local timer = frame.api and frame.api.C_Timer
    if timer and type(timer.After) == "function" then
        frame.browserRefreshPending = true
        timer.After(0, function()
            frame.browserRefreshPending = nil
            if GGM.guildGearBrowserFrame == frame then flushBrowserRefresh(frame) end
        end)
    else
        -- Older clients and synchronous callers without a timer still flush safely.
        flushBrowserRefresh(frame)
    end
    return true
end

function GGM.SelectProfession(frame, selectedKey)
    if selectedKey == nil then
        if GGM.HideRecipeDetailsWindow then GGM.HideRecipeDetailsWindow(frame) end
        frame.selectedProfession = nil
        frame.selectedProfessionID = nil
        frame.professionCatalog = { state = "unavailable", recipes = {} }
        if updateProfessionRecipeBrowser then updateProfessionRecipeBrowser(frame) end
        frame.professionSearchBox:SetText("")
        frame.professionDetailPanel:Hide()
        for _, button in ipairs(frame.professionButtons) do professionButtonColor(button, false) end
        if frame.activeTab == "Professions" then GGM.SetSharedStatus(frame, "") end
        return true
    end
    local selectedProfession
    for _, profession in ipairs(PROFESSIONS) do if profession.key == selectedKey then selectedProfession = profession; break end end
    if not selectedProfession then return false end
    frame.professionDetailPanel:Show()
    local changed = frame.selectedProfession ~= selectedKey
    if changed and GGM.HideRecipeDetailsWindow then GGM.HideRecipeDetailsWindow(frame) end
    frame.selectedProfession = selectedKey
    frame.selectedProfessionID = selectedProfession.professionID
    frame.professionHeading:SetText(selectedKey)
    updateProfessionSubtitle(frame, selectedKey)
    if frame.professionHeroIcon then frame.professionHeroIcon:SetTexture(selectedProfession.icon) end
    if frame.professionHeroArtwork then
        frame.professionHeroArtwork:SetTexture(JOURNAL_TEXTURES.professions[selectedKey] or JOURNAL_TEXTURES.professionFallback)
        frame.professionHeroArtwork:SetVertexColor(1, 1, 1, 1)
    end
    for _, button in ipairs(frame.professionButtons) do professionButtonColor(button, button.key == selectedKey) end
    if changed then
        frame.professionCatalog = nil
        frame.filteredProfessionRecipes = {}
        if frame.cpuOwners and GGM.CancelCPUJob then
            GGM.CancelCPUJob(frame.cpuOwners.catalogBuild)
            GGM.CancelCPUJob(frame.cpuOwners.recipeFilter)
        end
        renderProfessionRows(frame)
    end
    if changed and frame.professionSearchBox then frame.professionSearchBox:SetText("") end
    frame.professionDirty = true
    if flushProfessionCatalog then flushProfessionCatalog(frame) end
    if browserVisible(frame) and frame.professionLibraryMode == "Own" and frame.db and frame.activeTab == "Professions" then
        frame.craftingContextSkillLineID = nil
        frame.craftingContextOpenedByGuildBook = nil
        openSelectedProfessionContext(frame, selectedProfession.professionID)
    end
    if browserVisible(frame) and frame.activeTab == "Professions" then GGM.SyncSelectedProfession(frame, false) end
    return true
end

function GGM.RefreshVisibleProfessionLibrary(frame)
    if not frame then
        frame = GGM.guildGearBrowserFrame
        if not frame then return false end
        frame.professionLibraryDirty = true
        if frame.activeTab ~= "Professions" then return false end
        return queueBrowserRefresh(frame)
    end
    if type(frame.professionButtons) ~= "table" then return false end
    if not browserVisible(frame) or frame.activeTab ~= "Professions" then
        frame.professionLibraryDirty = true
        return false
    end

    local visibleEntries = {}
    if frame.professionLibraryMode == "Own" then
        local identity = nil
        if type(GGM.BuildPlayerIdentity) == "function" then
            local identityOk, playerIdentity = pcall(GGM.BuildPlayerIdentity, frame.api)
            if identityOk then identity = playerIdentity end
        end
        local characterKey = identity and identity.key or nil
        local characterGUID = identity and identity.guid or nil
        visibleEntries = GGM.FilterProfessionLibraryEntries(
            frame.professionButtons, frame.db, characterKey, characterGUID)
    else
        for _, button in ipairs(frame.professionButtons) do visibleEntries[#visibleEntries + 1] = button end
    end

    local visibleByKey = {}
    local contentHeight = #visibleEntries == 0 and 1
        or (UI.professionRowInset + (#visibleEntries - 1) * UI.professionRowPitch + UI.professionRowHeight)
    frame.professionLibraryContent:SetSize(UI.professionScrollWidth, contentHeight)
    for index, button in ipairs(visibleEntries) do
        visibleByKey[button.key] = true
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", frame.professionLibraryContent, "TOPLEFT", UI.professionRowInset,
            -(UI.professionRowInset + (index - 1) * UI.professionRowPitch))
        button:Show()
    end
    for _, button in ipairs(frame.professionButtons) do
        if not visibleByKey[button.key] then button:Hide() end
    end

    frame.visibleProfessionEntries = visibleEntries
    local maxScroll = math.max(0, contentHeight - frame.professionLibraryScroll:GetHeight())
    local scrollBar = frame.professionLibraryScroll.ScrollBar
    local scrollOffset = frame.professionLibraryScroll:GetVerticalScroll() or 0
    if frame.professionLibraryResetScroll then
        scrollOffset = 0
        frame.professionLibraryResetScroll = nil
    end
    scrollOffset = math.min(scrollOffset, maxScroll)
    if scrollBar then
        scrollBar:SetMinMaxValues(0, maxScroll)
        if scrollBar.SetValueStep then scrollBar:SetValueStep(UI.professionRowPitch) end
        if scrollBar.SetObeyStepOnDrag then scrollBar:SetObeyStepOnDrag(true) end
        scrollBar:SetValue(scrollOffset)
        if maxScroll > 0 then scrollBar:Show() else scrollBar:Hide() end
    else
        frame.professionLibraryScroll:SetVerticalScroll(scrollOffset)
    end
    if frame.professionLibraryEmpty then
        if frame.professionLibraryMode == "Own" and #visibleEntries == 0 then
            frame.professionLibraryEmpty:Show()
        else
            frame.professionLibraryEmpty:Hide()
        end
    end
    if frame.professionLibraryToggle then
        local own = frame.professionLibraryMode == "Own"
        frame.professionLibraryToggle.allRadio:SetChecked(not own)
        frame.professionLibraryToggle.ownRadio:SetChecked(own)
        setTextColor(frame.professionLibraryToggle.allRadio.label, own and THEME.muted or THEME.text)
        setTextColor(frame.professionLibraryToggle.ownRadio.label, own and THEME.text or THEME.muted)
    end
    -- The detail selection must belong to the same list as the visible buttons.
    if frame.db and frame.professionDetailPanel then
        local selectionVisible = false
        for _, entry in ipairs(visibleEntries) do
            if entry.key == frame.selectedProfession then selectionVisible = true; break end
        end
        if not selectionVisible then
            GGM.SelectProfession(frame, visibleEntries[1] and visibleEntries[1].key or nil)
        end
    end
    return true
end

function GGM.SyncSelectedProfession(frame, manual)
    if not frame or frame.activeTab ~= "Professions" then return false end
    local professionID
    for _, profession in ipairs(PROFESSIONS) do
        if profession.key == frame.selectedProfession then professionID = profession.professionID; break end
    end
    if not professionID then return false end
    frame.professionSyncSelections = frame.professionSyncSelections or {}
    if not manual and frame.professionSyncSelections[professionID] then return false end
    local ok, err = false, "profession-sync-unavailable"
    if GGM.professionSync and type(GGM.RequestProfessionSync) == "function" then
        if manual and type(GGM.RequestProfessionSyncFromButton) == "function" then
            ok, err = GGM.RequestProfessionSyncFromButton(GGM.professionSync, professionID)
        else
            ok, err = GGM.RequestProfessionSync(GGM.professionSync, professionID, manual and "manual" or "selection")
        end
    end
    if ok and not manual then frame.professionSyncSelections[professionID] = true end
    local status = GGM.GetProfessionSyncStatus and GGM.GetProfessionSyncStatus(GGM.professionSync, professionID) or "Sync unavailable"
    if manual and not ok and (err == "profession-sync-cooldown" or err == "profession-sync-busy") then
        status = "Comparison pending or on cooldown"
    end
    GGM.SetSharedStatus(frame, status)
    return ok, err
end

function GGM.RefreshVisibleProfessionSyncStatus()
    local frame = GGM.guildGearBrowserFrame
    if not frame or frame.activeTab ~= "Professions" or not frame.professionSyncStatus then return end
    for _, profession in ipairs(PROFESSIONS) do
        if profession.key == frame.selectedProfession then
            GGM.SetSharedStatus(frame,
                GGM.GetProfessionSyncStatus and GGM.GetProfessionSyncStatus(GGM.professionSync, profession.professionID)
                    or "Sync unavailable")
            return
        end
    end
end

local function createProfessionButton(api, content, profession)
    local button = api.CreateFrame("Button", nil, content)
    button:SetSize(UI.professionRowWidth, UI.professionRowHeight)
    button:SetPoint("TOPLEFT", content, "TOPLEFT", UI.professionRowInset, -UI.professionRowInset)
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
    button:SetScript("OnClick", function() GGM.SelectProfession(content.owner, profession.key) end)
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

    frame.professionLibraryScroll = api.CreateFrame("ScrollFrame", nil, sidebar, "UIPanelScrollFrameTemplate")
    frame.professionLibraryScroll:SetPoint("TOPLEFT", sidebar, "TOPLEFT", UI.professionScrollLeft, -58)
    frame.professionLibraryScroll:SetSize(UI.professionScrollWidth, UI.professionScrollHeight)
    frame.professionLibraryScroll:EnableMouseWheel(true)
    frame.professionLibraryContent = api.CreateFrame("Frame", nil, frame.professionLibraryScroll)
    frame.professionLibraryContent:SetSize(UI.professionScrollWidth, 1)
    frame.professionLibraryContent.owner = frame
    frame.professionLibraryScroll:SetScrollChild(frame.professionLibraryContent)

    local scrollBar = frame.professionLibraryScroll.ScrollBar
    if scrollBar then
        scrollBar:SetMinMaxValues(0, 0)
        if scrollBar.SetValueStep then scrollBar:SetValueStep(UI.professionRowPitch) end
        if scrollBar.SetObeyStepOnDrag then scrollBar:SetObeyStepOnDrag(true) end
        scrollBar:SetScript("OnValueChanged", function(_, offset)
            frame.professionLibraryScroll:SetVerticalScroll(offset)
        end)
    end
    frame.professionLibraryScroll:SetScript("OnVerticalScroll", function(_, offset)
        if scrollBar and math.abs((scrollBar:GetValue() or 0) - offset) > 0.5 then
            scrollBar:SetValue(offset)
        end
    end)
    frame.professionLibraryScroll:SetScript("OnMouseWheel", function(scroll, delta)
        local current = scroll:GetVerticalScroll() or 0
        local maximum = math.max(0, frame.professionLibraryContent:GetHeight() - scroll:GetHeight())
        scroll:SetVerticalScroll(math.max(0, math.min(maximum, current - delta * UI.professionRowPitch)))
    end)
    frame.professionLibraryScroll:SetScript("OnSizeChanged", function()
        GGM.RefreshVisibleProfessionLibrary(frame)
    end)

    frame.professionLibraryMode = "Own"
    local toggle = api.CreateFrame("Button", nil, page)
    toggle:SetSize(170, 28)
    local function createProfessionRadio(label, x)
        local radio = api.CreateFrame("CheckButton", nil, toggle)
        radio:SetSize(82, 28)
        radio:SetPoint("TOPLEFT", toggle, "TOPLEFT", x, 0)
        radio.checkedTexture = radio:CreateTexture(nil, "ARTWORK")
        radio.checkedTexture:SetSize(32, 32)
        radio.checkedTexture:SetPoint("LEFT", radio, "LEFT", 0, 0)
        radio.checkedTexture:SetTexture("Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\profession-radio-checked")
        radio.uncheckedTexture = radio:CreateTexture(nil, "ARTWORK")
        radio.uncheckedTexture:SetSize(32, 32)
        radio.uncheckedTexture:SetPoint("LEFT", radio, "LEFT", 0, 0)
        radio.uncheckedTexture:SetTexture("Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\profession-radio-unchecked")
        radio:SetCheckedTexture(radio.checkedTexture)
        radio:SetNormalTexture(radio.uncheckedTexture)
        radio.label = createText(radio, "OVERLAY", "GameFontHighlight")
        GGM.ApplyJournalFont(radio.label, 16, "bold")
        radio.label:SetText(label)
        radio.label:SetPoint("LEFT", radio, "LEFT", 30, 0)
        radio.label:SetWidth(52)
        radio:RegisterForClicks("LeftButtonUp")
        return radio
    end
    toggle.ownRadio = createProfessionRadio("OWN", 0)
    toggle.allRadio = createProfessionRadio("ALL", 88)
    frame.professionLibraryToggle = toggle
    frame.professionLibraryToggle:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 34, 34)
    local function selectProfessionLibraryMode(mode)
        local changed = frame.professionLibraryMode ~= mode
        if changed and GGM.HideRecipeDetailsWindow then GGM.HideRecipeDetailsWindow(frame) end
        if changed then frame.professionLibraryResetScroll = true end
        frame.professionLibraryMode = mode
        GGM.RefreshVisibleProfessionLibrary(frame)
        if changed and mode == "Own" then
            for _, profession in ipairs(frame.visibleProfessionEntries or {}) do
                if profession.key == frame.selectedProfession then
                    GGM.SelectProfession(frame, frame.selectedProfession)
                    break
                end
            end
        end
    end
    toggle.allRadio:SetScript("OnClick", function() selectProfessionLibraryMode("All") end)
    toggle.ownRadio:SetScript("OnClick", function() selectProfessionLibraryMode("Own") end)
    toggle.ownRadio:SetChecked(true)
    toggle.allRadio:SetChecked(false)
    frame.professionLibraryEmpty = createText(sidebar, "OVERLAY", "GameFontHighlight")
    frame.professionLibraryEmpty:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 34, -62)
    frame.professionLibraryEmpty:SetWidth(UI.professionRowWidth)
    frame.professionLibraryEmpty:SetJustifyH("CENTER")
    frame.professionLibraryEmpty:SetText("No captured professions for this character.")
    setTextColor(frame.professionLibraryEmpty, THEME.muted)
    frame.professionLibraryEmpty:Hide()

    local eyebrow = createText(sidebar, "OVERLAY", "GameFontNormal")
    frame.professionLibraryHeading = eyebrow
    GGM.ApplyJournalFont(eyebrow, 16, "bold")
    eyebrow:SetText("PROFESSION LIBRARY")
    setTextColor(eyebrow, THEME.text)
    eyebrow:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 34, -10)

    frame.professionButtons = {}
    for index, profession in ipairs(PROFESSIONS) do
        frame.professionButtons[index] = createProfessionButton(api, frame.professionLibraryContent, profession)
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
    -- Shared edge treatment preserves each profession's artwork and all controls.
    panel.backgroundMask = panel:CreateMaskTexture()
    panel.backgroundMask:SetTexture(JOURNAL_TEXTURES.professionMask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    panel.backgroundMask:SetAllPoints(panel.background)
    panel.background:AddMaskTexture(panel.backgroundMask)
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
    frame.professionHeroIconFrame = iconFrame
    frame.professionHeroIcon = iconFrame:CreateTexture(nil, "ARTWORK")
    frame.professionHeroIcon:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 4, -4)
    frame.professionHeroIcon:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -4, 4)

    frame.professionHeading = createText(hero, "OVERLAY", "GameFontNormalHuge")
    GGM.ApplyJournalFont(frame.professionHeading, 30, "bold")
    frame.professionHeading:SetPoint("TOPLEFT", iconFrame, "TOPRIGHT", 14, -1)
    frame.professionHeading:SetWidth(360)
    frame.professionHeading:SetJustifyH("LEFT")
    setTextColor(frame.professionHeading, THEME.text)

    frame.professionSubtitle = createText(hero, "OVERLAY", "GameFontHighlight")
    GGM.ApplyJournalFont(frame.professionSubtitle, 15, "italic")
    setTextColor(frame.professionSubtitle, THEME.text)
    frame.professionSubtitle:SetShadowColor(
        THEME.panel[1], THEME.panel[2], THEME.panel[3], 0.78)
    frame.professionSubtitle:SetShadowOffset(1, -1)

    local searchLabel = createText(panel, "OVERLAY", "GameFontHighlight")
    GGM.ApplyJournalFont(searchLabel, 15, "bold")
    searchLabel:SetText("Search recipes")
    setTextColor(searchLabel, THEME.text)
    searchLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 34, -156)
    frame.professionSearchBox = api.CreateFrame("EditBox", nil, panel)
    frame.professionSearchBox:SetSize(310, 27)
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
    frame.professionCount:SetWidth(130)
    setTextColor(frame.professionCount, THEME.textSoft)
    frame.professionStatus = createText(panel, "OVERLAY", "GameFontHighlight")
    GGM.ApplyJournalFont(frame.professionStatus, 13)
    frame.professionStatus:SetPoint("TOPLEFT", frame.professionSearchBox, "BOTTOMLEFT", 0, -4)
    frame.professionStatus:SetPoint("RIGHT", panel, "RIGHT", -18, 0)
    frame.professionStatus:SetJustifyH("LEFT")
    setTextColor(frame.professionStatus, THEME.textSoft)

    frame.professionSyncButton = api.CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    frame.professionSyncButton:SetSize(140, 27)
    frame.professionSyncButton:SetText("Sync profession")
    frame.professionSyncButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -24, -177)
    frame.professionSyncButton:SetScript("OnClick", function() GGM.SyncSelectedProfession(frame, true) end)
    frame.professionSyncStatus = frame.sharedStatus

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
    hookListScroll(frame.professionRecipeScroll, function()
        if browserVisible(frame) and frame.activeTab == "Professions" then renderProfessionRows(frame) end
    end)
    frame.professionSearchBox:SetScript("OnTextChanged", function()
        if not browserVisible(frame) or frame.activeTab ~= "Professions" or not frame.professionCatalog then return end
        debounceSearch(frame, "recipeSearchGeneration", "Professions", function()
            if frame.professionCatalog then updateProfessionRecipeBrowser(frame) end
        end)
    end)

    frame.professionsPage = page
    GGM.RefreshVisibleProfessionLibrary(frame)
    GGM.SelectProfession(frame, "Alchemy")
end

updateProfessionRecipeBrowser = function(frame, prepared)
    frame.recipeSearchGeneration = (frame.recipeSearchGeneration or 0) + 1
    local catalog = frame.professionCatalog or { state = "unavailable", recipes = {}, message = nil }
    local recipes = type(catalog.recipes) == "table" and catalog.recipes or {}
    local query = frame.professionSearchBox:GetText() or ""
    if not prepared and GGM.StartCPUJob then
        local generation = frame.recipeSearchGeneration
        return browserRead(frame, "recipeFilter", "Professions", function()
            return GGM.FilterProfessionRecipeBrowserEntries(recipes, query)
        end, function(filtered)
            if frame.professionCatalog == catalog and frame.recipeSearchGeneration == generation
                and frame.professionSearchBox:GetText() == query then updateProfessionRecipeBrowser(frame, filtered) end
        end, function() frame.professionDirty = true end)
    end
    local filtered = prepared or GGM.FilterProfessionRecipeBrowserEntries(recipes, query)
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

    renderProfessionRows(frame)
    if GGM.RefreshRecipeDetailsWindow then GGM.RefreshRecipeDetailsWindow(frame) end
end

renderProfessionRows = function(frame)
    local filtered = frame.filteredProfessionRecipes or {}
    frame.professionRecipeContent:SetHeight(math.max(#filtered * 46, 1))
    local first, last = viewportRange(frame.professionRecipeScroll, #filtered, 46, 230)
    local used = 0
    for resultIndex = first, last do
        local recipe = filtered[resultIndex]
        used = used + 1
        local index = used
        local row = frame.professionRecipeRows[index]
        if not row then
            row = frame.api.CreateFrame("Button", nil, frame.professionRecipeContent)
            row:RegisterForClicks("LeftButtonUp")
            row:SetScript("OnClick", function(self)
                GGM.ShowRecipeDetailsWindow(frame, self.recipe)
            end)
            if row.SetHighlightTexture then row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD") end
            row.outputIcon = row:CreateTexture(nil, "ARTWORK")
            row.outputIcon:SetSize(30, 30)
            row.outputIcon:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -8)
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
            GGM.ApplyJournalFont(row.name, 17, "bold")
            -- Bound the label inside the scroll row instead of relying on an
            -- automatically sized FontString when the hidden page is laid out.
            row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 50, -8)
            row.name:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -18, 8)
            row.name:SetJustifyH("LEFT")
            setTextColor(row.name, THEME.text)
            row.separator = row:CreateTexture(nil, "BORDER")
            row.separator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 50, 0)
            row.separator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -18, 0)
            row.separator:SetHeight(1)
            setColor(row.separator, THEME.borderSoft)
            frame.professionRecipeRows[index] = row
        end

        row.recipe = recipe
        row.outputIcon:SetTexture(recipe.outputIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.name:SetText(recipe.name or "Unknown recipe")
        local rowHeight = 45
        row:SetHeight(rowHeight)
        row:ClearAllPoints()
        local y = (resultIndex - 1) * 46
        row:SetPoint("TOPLEFT", frame.professionRecipeContent, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", frame.professionRecipeContent, "TOPRIGHT", 0, -y)
        row:Show()
    end
    for index = used + 1, #frame.professionRecipeRows do
        local row = frame.professionRecipeRows[index]
        row.recipe = nil
        row:Hide()
    end
end

flushProfessionCatalog = function(frame)
    if not browserVisible(frame) or frame.activeTab ~= "Professions" or not frame.db
        or type(GGM.BuildProfessionRecipeCatalog) ~= "function" then return false end
    if not frame.professionDirty and not frame.professionLibraryDirty and frame.professionCatalog then return false end
    GGM.RefreshVisibleProfessionLibrary(frame)
    frame.professionLibraryDirty = nil
    if frame.professionLibraryMode == "Own" and frame.visibleProfessionEntries[1] then
        local selectedVisible = false
        for _, entry in ipairs(frame.visibleProfessionEntries) do
            if entry.key == frame.selectedProfession then selectedVisible = true; break end
        end
        if not selectedVisible then return GGM.SelectProfession(frame, frame.visibleProfessionEntries[1].key) end
    end
    if not frame.professionDirty and frame.professionCatalog then return false end
    local profession
    for _, item in ipairs(PROFESSIONS) do
        if item.key == frame.selectedProfession then profession = item; break end
    end
    if not profession then return false end
    frame.professionDirty = nil
    if GGM.StartCPUJob and not frame.professionCatalog then
        frame.professionCount:SetText("Preparing…")
        frame.professionStatus:SetText("Preparing saved recipes…")
        frame.professionStatus:Show()
    end
    local scroll = frame.professionRecipeScroll:GetVerticalScroll()
    return browserRead(frame, "catalogBuild", "Professions", function()
        local catalog = GGM.BuildProfessionRecipeCatalog(frame.db, profession.professionID, profession.key, frame.api)
        return catalog
    end, function(catalog)
        frame.professionCatalog = catalog
        frame.professionDirty = nil
        updateProfessionRecipeBrowser(frame)
        frame.professionRecipeScroll:SetVerticalScroll(scroll)
    end, function() frame.professionDirty = true end)
end

function GGM.RefreshVisibleProfessionCatalog()
    local frame = GGM.guildGearBrowserFrame
    if not frame then return false end
    frame.professionDirty = true
    if frame.cpuOwners and GGM.CancelCPUJob then GGM.CancelCPUJob(frame.cpuOwners.catalogBuild) end
    if frame.activeTab ~= "Professions" then return false end
    return queueBrowserRefresh(frame)
end

local updateBrowserList

local function setPageHeader(frame, title, subtitle)
    frame.pageTitle:SetText(title)
    frame.pageSubtitle:SetText(subtitle or "")
    if subtitle and subtitle ~= "" then frame.pageSubtitle:Show() else frame.pageSubtitle:Hide() end
end

function GGM.SetSharedStatus(frame, message)
    if not frame or not frame.sharedStatus then return false end
    local text = type(message) == "string" and message or ""
    frame.sharedStatus:SetText(text)
    local visible = text ~= ""
    if visible then
        frame.sharedStatus:Show()
    else
        frame.sharedStatus:Hide()
    end
    return visible
end

function GGM.SelectGuildGearBrowserTab(frame, selectedKey)
    if selectedKey ~= "Character" and selectedKey ~= "Professions" and selectedKey ~= "Bank" then return false end
    if selectedKey ~= "Professions" and GGM.HideRecipeDetailsWindow then GGM.HideRecipeDetailsWindow(frame) end
    if frame.activeTab ~= selectedKey then cancelBrowserReads(frame) end
    frame.activeTab = selectedKey
    if frame.TitleText then frame.TitleText:SetText("The Guild Book") end

    if selectedKey == "Character" then setPageHeader(frame, "Characters", "Inspect last-known guild equipment")
    elseif selectedKey == "Professions" then setPageHeader(frame, "Professions", "")
    else setPageHeader(frame, "Bank", "") end

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
        frame.professionLibraryToggle:Show()
        flushProfessionCatalog(frame)
        if browserVisible(frame) and frame.db then
            if frame.professionLibraryMode == "Own" then
                openSelectedProfessionContext(frame, frame.selectedProfessionID)
            end
            GGM.SyncSelectedProfession(frame, false)
        end
    else
        frame.professionsPage:Hide()
        frame.professionLibraryToggle:Hide()
    end
    for pageKey, page in pairs(frame.placeholderPages) do if pageKey == selectedKey then page:Show() else page:Hide() end end
    if frame.bankPage then
        if selectedKey == "Bank" then
            frame.bankPage:Show()
            if type(GGM.RefreshVisibleBankView) == "function" then GGM.RefreshVisibleBankView() end
        else
            frame.bankPage:Hide()
        end
    end

    if showCharacter then
        setBrowserContentVisible(frame, true)
        if browserVisible(frame) then
            if frame.charactersDirty then refreshCharacterBrowser(frame)
            else updateBrowserList(frame, frame.api) end
        end
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

updateBrowserList = function(frame, api, prepared)
    frame.characterSearchGeneration = (frame.characterSearchGeneration or 0) + 1
    if not prepared and GGM.StartCPUJob and browserVisible(frame) and frame.activeTab == "Character" then
        local entries, db, view, query = frame.entries, frame.db, frame.browserView, frame.searchBox:GetText() or ""
        local generation = frame.characterSearchGeneration
        return browserRead(frame, "characterFilter", "Character", function()
            local active = GGM.FilterGuildGearBrowserOwnership(entries, db, view)
            return { active = active, filtered = GGM.FilterGuildGearBrowserEntries(active, query) }
        end, function(result)
            if frame.entries == entries and frame.browserView == view and frame.characterSearchGeneration == generation
                and frame.searchBox:GetText() == query then updateBrowserList(frame, api, result) end
        end, function() frame.charactersDirty = true end)
    end
    frame.activeEntries = prepared and prepared.active or GGM.FilterGuildGearBrowserOwnership(frame.entries, frame.db, frame.browserView)
    frame.filteredEntries = prepared and prepared.filtered or GGM.FilterGuildGearBrowserEntries(frame.activeEntries, frame.searchBox:GetText() or "")

    local selectedStillVisible = false
    for _, entry in ipairs(frame.filteredEntries) do
        if frame.selectedEntry and entry.key == frame.selectedEntry.key then
            frame.selectedEntry = entry
            selectedStillVisible = true
            break
        end
    end
    if not selectedStillVisible then frame.selectedEntry = frame.filteredEntries[1] end

    if frame.characterCount then
        frame.characterCount:SetText(tostring(#frame.filteredEntries) .. (#frame.filteredEntries == 1 and " character" or " characters"))
    end

    renderCharacterRows(frame, api)

    if #frame.activeEntries == 0 then
        frame.listEmpty:SetText(gearUnavailableMessage(frame.db) and "Gear unavailable"
            or (frame.browserView == "Mine" and "No personal snapshots yet" or "No guild snapshots yet"))
        frame.listEmpty:Show()
    elseif #frame.filteredEntries == 0 then
        frame.listEmpty:SetText("No characters match your search")
        frame.listEmpty:Show()
    else frame.listEmpty:Hide() end

    updateSearchHint(frame)
    renderBrowserDetail(frame, frame.selectedEntry, api)
    if frame.activeTab ~= "Character" then setBrowserContentVisible(frame, false) end
end

renderCharacterRows = function(frame, api)
    local rows = frame.listRows
    frame.listContent:SetHeight(math.max(#frame.filteredEntries * UI.characterRowHeight, 1))
    local first, last = viewportRange(frame.listScroll, #frame.filteredEntries, UI.characterRowHeight, 200)
    local used = 0
    for resultIndex = first, last do
        local entry = frame.filteredEntries[resultIndex]
        used = used + 1
        local index = used
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
        row:SetPoint("TOPLEFT", frame.listContent, "TOPLEFT", 0, -(resultIndex - 1) * UI.characterRowHeight)
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

    for index = used + 1, #rows do
        rows[index].entry = nil
        rows[index]:Hide()
    end

end

local function updateBrowserViewButtonStyles(frame)
    for _, button in ipairs({ frame.mineButton, frame.guildButton }) do
        local selected = button.key == frame.browserView
        button.selected = selected
        if selected then
            if button.LockHighlight then button:LockHighlight() end
        elseif button.UnlockHighlight then
            button:UnlockHighlight()
        end
    end
end

local function createBrowserViewButton(api, frame, key, label, x)
    local button = api.CreateFrame("Button", nil, frame.searchPanel, "UIPanelButtonTemplate")
    button:SetSize(UI.ownershipButtonWidth, UI.controlHeightCompact)
    button:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", x, -62)
    button.variant = "ghost"
    button.label = button.Text
    if not button.label then
        button.label = createText(button, "OVERLAY", "GameFontNormalSmall")
        button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
        local nativeSetText = button.SetText
        button.SetText = function(self, value)
            if nativeSetText then nativeSetText(self, value) end
            self.label:SetText(value or "")
        end
    end
    button:SetText(label)
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

    tab.iconHolder = createSurface(api, tab, THEME.slot, THEME.borderSoft)
    tab.iconHolder:SetSize(42, 42)
    tab.iconHolder:SetPoint("CENTER", tab, "LEFT", 12 + UI.navigationIconSize / 2, 0)
    tab.icon = tab.iconHolder:CreateTexture(nil, "ARTWORK")
    tab.icon:SetPoint("TOPLEFT", tab.iconHolder, "TOPLEFT", 3, -3)
    tab.icon:SetPoint("BOTTOMRIGHT", tab.iconHolder, "BOTTOMRIGHT", -3, 3)
    tab.icon:SetTexture(iconPath)
    tab.icon:SetAlpha(0.88)

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
    local panel = api.CreateFrame("Frame", nil, frame)
    panel:SetSize(UI.characterDetailWidth, UI.characterDetailHeight)
    panel:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.characterDetailX, -UI.characterDetailTop)
    panel.background = panel:CreateTexture(nil, "BACKGROUND")
    panel.background:SetPoint("TOPLEFT", panel, "TOPLEFT", 9, -9)
    panel.background:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -9, 9)
    panel.background:SetTexture(JOURNAL_TEXTURES.gearPage)
    panel.background:SetTexCoord(0, 1, 0, 1)
    panel.backgroundMask = panel:CreateMaskTexture()
    panel.backgroundMask:SetTexture(JOURNAL_TEXTURES.professionMask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    panel.backgroundMask:SetAllPoints(panel.background)
    panel.background:AddMaskTexture(panel.backgroundMask)
    panel.goldRule = panel:CreateTexture(nil, "ARTWORK")
    panel.goldRule:SetPoint("TOPLEFT", panel, "TOPLEFT", 34, -145)
    panel.goldRule:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -34, -145)
    panel.goldRule:SetHeight(1)
    setColor(panel.goldRule, THEME.gold, 0.48)
    panel.sectionLabel = createEyebrow(panel, "EQUIPMENT SNAPSHOT")
    panel.sectionLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 34, -25)
    return panel
end

local function createSlotButton(api, frame, trackedSlot, layout, x, y)
    local button = api.CreateFrame("Button", nil, frame.gearPanel)
    button:SetSize(44, 44)
    button:SetPoint("CENTER", frame.gearPanel, "TOPLEFT", x, y)
    button.paperDollGroup, button.paperDollOrder = layout.group, layout.order

    button.slotBackground = button:CreateTexture(nil, "BACKGROUND")
    button.slotBackground:SetPoint("TOPLEFT", button, "TOPLEFT", 4, -4)
    button.slotBackground:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 4)
    setColor(button.slotBackground, THEME.slot)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 4, -4)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 4)

    -- Quickslot artwork has an inset rim; keep it behind the opaque item
    -- texture so that rim cannot draw a second box across the icon.
    button.quickslot = button:CreateTexture(nil, "BORDER")
    button.quickslot:SetAllPoints(button)
    button.quickslot:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    button.quickslot:SetAlpha(0.92)
    button.borderEdges = createFlatBorder(button, THEME.borderSoft, 1)

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
    button.label:SetFont(api.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 14, "")
    if button.label.SetWordWrap then button.label:SetWordWrap(true) end
    setTextColor(button.label, THEME.textSoft)
    button.status = createText(button, "OVERLAY", "GameFontDisableSmall")
    button.status:SetFont(api.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "")
    setTextColor(button.status, THEME.muted)

    -- Keep the native paper-doll silhouette: slots beside the portrait,
    -- names extending outward. Two-line names fit inside each 47px row.
    if layout.group == "left" then
        button.label:SetWidth(156); button.label:SetJustifyH("RIGHT"); button.label:SetPoint("RIGHT", button, "LEFT", -8, 0)
        button.status:SetWidth(156); button.status:SetJustifyH("RIGHT"); button.status:SetPoint("TOPRIGHT", button.label, "BOTTOMRIGHT", 0, -2)
    elseif layout.group == "right" then
        button.label:SetWidth(156); button.label:SetJustifyH("LEFT"); button.label:SetPoint("LEFT", button, "RIGHT", 8, 0)
        button.status:SetWidth(156); button.status:SetJustifyH("LEFT"); button.status:SetPoint("TOPLEFT", button.label, "BOTTOMLEFT", 0, -2)
    else
        button.label:SetWidth(72); button.label:SetJustifyH("CENTER"); button.label:SetPoint("TOP", button, "BOTTOM", 0, -5)
        button.status:SetWidth(72); button.status:SetJustifyH("CENTER"); button.status:SetPoint("TOP", button.label, "BOTTOM", 0, -1)
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
    if frame.SetFrameStrata then frame:SetFrameStrata("DIALOG") end
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
        cancelBrowserReads(self)
        if GGM.HideRecipeDetailsWindow then GGM.HideRecipeDetailsWindow(self) end
        if self.craftingContextSkillLineID and self.craftingContextOpenedByGuildBook then
            local professionFrame = self.api.ProfessionsFrame or self.api.TradeSkillFrame
            if type(GGM.CloseBlizzardProfessionPanel) == "function" then
                GGM.CloseBlizzardProfessionPanel(self.api, professionFrame)
            elseif professionFrame and type(professionFrame.Hide) == "function" then
                pcall(professionFrame.Hide, professionFrame)
            end
        end
        self.professionLibraryDirty = true
        self.professionLibraryMode = "Own"
        self.craftingContextSkillLineID = nil
        self.craftingContextOpenedByGuildBook = nil
    end)
    frame.entries, frame.filteredEntries, frame.listRows, frame.slotButtons = {}, {}, {}, {}
    frame.browserView = "Guild"

    if frame.SetMovable then frame:SetMovable(true) end
    if frame.EnableMouse then frame:EnableMouse(true) end
    if frame.RegisterForDrag then frame:RegisterForDrag("LeftButton") end
    frame:SetScript("OnDragStart", function(self)
        local settings = GGM.ReadBrowserWindowSettings and GGM.ReadBrowserWindowSettings(self.db)
        if settings and settings.locked then return end
        if self.StartMoving then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self) if self.StopMovingOrSizing then self:StopMovingOrSizing() end end)

    frame.background = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    frame.background:SetAllPoints(frame)
    frame.background:SetTexture(JOURNAL_TEXTURES.window)
    frame.background:SetVertexColor(1, 1, 1, 1)
    frame.background:SetAlpha(1)

    -- The journal texture contains painted navigation buttons laid out for a
    -- 1400x630 canvas. Keep that section at its original scale as the taller
    -- equipment page grows; only the illustration below the buttons stretches.
    local originalHeight, navigationBottom = 630, 366
    local railUV = UI.railWidth / UI.windowWidth
    local splitUV = navigationBottom / originalHeight
    frame.navigationBackdropTop = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    frame.navigationBackdropTop:SetTexture(JOURNAL_TEXTURES.window)
    frame.navigationBackdropTop:SetSize(UI.railWidth, navigationBottom)
    frame.navigationBackdropTop:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.navigationBackdropTop:SetTexCoord(0, railUV, 0, splitUV)
    frame.navigationBackdropBottom = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    frame.navigationBackdropBottom:SetTexture(JOURNAL_TEXTURES.window)
    frame.navigationBackdropBottom:SetWidth(UI.railWidth)
    frame.navigationBackdropBottom:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -navigationBottom)
    frame.navigationBackdropBottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    frame.navigationBackdropBottom:SetTexCoord(0, railUV, splitUV, 1)

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
    GGM.ApplyJournalFont(frame.brandTitle, 19, "bold")
    frame.brandTitle:SetPoint("TOPLEFT", frame.brandIconFrame, "TOPRIGHT", 10, -5)
    frame.brandTitle:SetText("The Guild Book")
    setTextColor(frame.brandTitle, THEME.railGold)

    local navLabel = createSectionLabel(frame.navigationRail, "LIBRARY")
    GGM.ApplyJournalFont(navLabel, 15)
    navLabel:SetPoint("TOPLEFT", frame.navigationRail, "TOPLEFT", 38, -100)
    setTextColor(navLabel, THEME.railMuted)
    frame.navigationTabs = {
        createNavigationTab(api, frame, "Professions", "Professions", "Recipe memory", "Interface\\Icons\\Trade_BlackSmithing", -122),
        createNavigationTab(api, frame, "Character", "Characters", "Gear snapshots", "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest", -185),
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
    frame.pageSubtitle:SetWidth(278)
    setTextColor(frame.pageSubtitle, THEME.muted)
    -- Keep one readable status slot above the page art, shared by every tab.
    frame.sharedStatus = createText(frame, "OVERLAY", "GameFontHighlightSmall")
    GGM.ApplyJournalFont(frame.sharedStatus, 13)
    frame.sharedStatus:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.professionDetailX, -36)
    frame.sharedStatus:SetSize(480, 20)
    frame.sharedStatus:SetJustifyH("LEFT")
    if type(frame.sharedStatus.SetWordWrap) == "function" then frame.sharedStatus:SetWordWrap(false) end
    setTextColor(frame.sharedStatus, THEME.text)
    frame.sharedStatus:Hide()
    createCloseButton(api, frame)

    frame.searchPanel = createSurface(api, frame, THEME.panel, THEME.borderSoft, true)
    frame.searchPanel:SetSize(UI.characterLibraryWidth, 148)
    frame.searchPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.characterLibraryX, -UI.contentTop)
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
    frame.searchBox:SetScript("OnTextChanged", function()
        updateSearchHint(frame)
        if not browserVisible(frame) or frame.activeTab ~= "Character" then return end
        debounceSearch(frame, "characterSearchGeneration", "Character", function() updateBrowserList(frame, api) end)
    end)

    frame.listPanel = createSurface(api, frame, THEME.panel, THEME.borderSoft, true)
    frame.listPanel:SetSize(UI.characterLibraryWidth, UI.characterLibraryBottom - UI.contentTop - 148)
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
    hookListScroll(frame.listScroll, function()
        if browserVisible(frame) and frame.activeTab == "Character" then renderCharacterRows(frame, api) end
    end)
    frame.listEmpty = createText(frame.listPanel, "OVERLAY", "GameFontHighlightSmall")
    frame.listEmpty:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 16, -58)
    frame.listEmpty:SetWidth(238)
    frame.listEmpty:SetJustifyH("LEFT")
    setTextColor(frame.listEmpty, THEME.muted)
    frame.listEmpty:Hide()

    frame.gearPanel = createGearPanel(api, frame)
    frame.gearSyncButton = api.CreateFrame("Button", nil, frame.gearPanel, "UIPanelButtonTemplate")
    frame.gearSyncButton:SetSize(112, 27)
    frame.gearSyncButton:SetText("Sync gear")
    frame.gearSyncButton:SetPoint("TOPLEFT", frame.gearPanel, "TOPLEFT", 307, -115)
    frame.gearSyncButton:SetScript("OnClick", function() GGM.SyncSelectedGear(frame) end)
    frame.gearSyncStatus = frame.sharedStatus
    frame.gearSyncButton:Hide()
    GGM.SetSharedStatus(frame, "")
    frame.gearSyncButton:SetScript("OnUpdate", function(_, elapsed)
        frame.gearSyncElapsed = (frame.gearSyncElapsed or 0) + elapsed
        if frame.gearSyncElapsed < 1 then return end
        frame.gearSyncElapsed = 0
        refreshGearSyncControls(frame)
        for _, button in ipairs(frame.slotButtons or {}) do
            if button.pendingItemString then
                local link = GGM.BuildItemHyperlink(api, button.pendingItemString)
                local name = link and link:match("|h%[(.-)%]|h")
                if name then
                    button.label:SetText(name)
                    button.itemLink = link
                    if name ~= "Item " .. tostring(button.itemID) then button.pendingItemString = nil end
                end
            end
        end
    end)
    frame.characterLine = createText(frame.gearPanel, "OVERLAY", "GameFontNormalHuge")
    GGM.ApplyJournalFont(frame.characterLine, 30, "bold")
    frame.characterLine:SetPoint("TOPLEFT", frame.gearPanel, "TOPLEFT", 34, -50)
    frame.characterLine:SetSize(345, 38)
    if frame.characterLine.SetWordWrap then frame.characterLine:SetWordWrap(false) end
    frame.characterLine:SetJustifyH("LEFT")
    setTextColor(frame.characterLine, THEME.text)
    frame.realmLine = createText(frame.gearPanel, "OVERLAY", "GameFontHighlightSmall")
    frame.realmLine:SetPoint("TOPLEFT", frame.gearPanel, "TOPLEFT", 35, -88)
    frame.realmLine:SetWidth(345)
    frame.realmLine:SetJustifyH("LEFT")
    if frame.realmLine.SetWordWrap then frame.realmLine:SetWordWrap(false) end
    setTextColor(frame.realmLine, THEME.muted)
    frame.modelStage = createSurface(api, frame.gearPanel, THEME.panel, THEME.borderSoft)
    frame.modelStage:SetSize(208, 218)
    frame.modelStage:SetPoint("TOP", frame.gearPanel, "TOP", 0, -164)
    frame.modelStage.background:Hide()
    for _, edge in ipairs(frame.modelStage.border) do edge:Hide() end
    frame.stageLabel = createSectionLabel(frame.modelStage, "SAVED PORTRAIT")
    frame.stageLabel:SetPoint("TOP", frame.modelStage, "TOP", 0, -3)
    frame.stageRule = createDivider(frame.modelStage, 30, 30, -24)

    frame.characterModelView = GGM.CreateSavedCharacterModel(api, frame.modelStage)
    if frame.characterModelView.model then
        local view = frame.characterModelView
        view.model:SetSize(208, 182)
        view.model:SetPoint("BOTTOM", frame.modelStage, "BOTTOM", 0, 0)
        view.model.background:Hide()
        view.model.portraitBorder:SetSize(120, 120)
        view.model.portraitBorder:ClearAllPoints()
        view.model.portraitBorder:SetPoint("TOP", view.model, "TOP", 0, 0)
        setColor(view.model.portraitBorder, THEME.gold)
        view.portrait:SetSize(110, 110)
        -- Native icon-frame artwork contains padding and does not stretch into
        -- a portrait surround. Draw the edges at the actual portrait bounds.
        view.portraitFrame = api.CreateFrame("Frame", nil, view.model)
        view.portraitFrame:SetAllPoints(view.model.portraitBorder)
        view.portraitFrame.border = createFlatBorder(view.portraitFrame, THEME.borderDark)
        view.portraitFrame.innerBorder = createFlatBorder(view.portraitFrame, THEME.goldBright, 1)
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

    local sideX = { left = 220, right = UI.characterDetailWidth - 220 }
    local sideStartY, sidePitch = -175, 47
    local bottomX = { UI.characterDetailWidth / 2 - 78, UI.characterDetailWidth / 2, UI.characterDetailWidth / 2 + 78 }
    local bottomY = -421
    for index, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local layout = GGM.BROWSER_SLOT_LAYOUT[trackedSlot.key]
        local x, y
        if layout.group == "bottom" then x, y = bottomX[layout.order], bottomY
        else x = sideX[layout.group]; y = sideStartY - (layout.order - 1) * sidePitch end
        frame.slotButtons[index] = createSlotButton(api, frame, trackedSlot, layout, x, y)
    end

    frame.detailFooter = createSurface(api, frame.gearPanel, THEME.panelAlt, THEME.borderSoft)
    frame.detailFooter:SetPoint("BOTTOMLEFT", frame.gearPanel, "BOTTOMLEFT", 14, 10)
    frame.detailFooter:SetPoint("BOTTOMRIGHT", frame.gearPanel, "BOTTOMRIGHT", -14, 10)
    frame.detailFooter:SetHeight(20)
    frame.detailFooter.background:Hide()
    for _, edge in ipairs(frame.detailFooter.border) do edge:Hide() end

    frame.capturedLine = createText(frame.detailFooter, "OVERLAY", "GameFontHighlightSmall")
    frame.capturedLine:SetSize(152, 16)
    frame.capturedLine:SetPoint("RIGHT", frame.detailFooter, "RIGHT", -8, 0)
    GGM.ApplyJournalFont(frame.capturedLine, 12)
    frame.capturedLine:SetJustifyH("RIGHT")
    if frame.capturedLine.SetWordWrap then frame.capturedLine:SetWordWrap(false) end
    setTextColor(frame.capturedLine, THEME.textSoft)

    frame.snapshotCaption = createSectionLabel(frame.detailFooter, "LAST CAPTURED")
    GGM.ApplyJournalFont(frame.snapshotCaption, 11, "bold")
    frame.snapshotCaption:SetSize(104, 16)
    frame.snapshotCaption:SetPoint("RIGHT", frame.capturedLine, "LEFT", -8, 0)
    frame.snapshotCaption:SetJustifyH("RIGHT")
    if frame.snapshotCaption.SetWordWrap then frame.snapshotCaption:SetWordWrap(false) end

    local footerText = createText(frame.detailFooter, "OVERLAY", "GameFontDisableSmall")
    footerText:SetPoint("LEFT", frame.detailFooter, "LEFT", 8, 0)
    -- Fixed capture bounds reserve space even while selection changes hide it.
    footerText:SetPoint("RIGHT", frame.snapshotCaption, "LEFT", -12, 0)
    footerText:SetHeight(16)
    footerText:SetJustifyH("LEFT")
    if footerText.SetWordWrap then footerText:SetWordWrap(false) end
    GGM.ApplyJournalFont(footerText, 12)
    footerText:SetText("Last-known equipment · Hover a slot to view the saved item")
    setTextColor(footerText, THEME.muted)

    frame.placeholderPages = {}
    if type(GGM.CreateBankPage) == "function" then
        GGM.CreateBankPage(api, frame)
    else
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
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    return frame
end

refreshCharacterBrowser = function(frame)
    if not browserVisible(frame) or frame.activeTab ~= "Character" or not frame.db then return false end
    local scroll = frame.listScroll:GetVerticalScroll()
    frame.charactersDirty = nil
    local db, view, query = frame.db, frame.browserView, frame.searchBox:GetText() or ""
    return browserRead(frame, "characterBuild", "Character", function()
        local entries = GGM.BuildGuildGearBrowserEntries(db)
        local active = GGM.FilterGuildGearBrowserOwnership(entries, db, view)
        return { entries = entries, active = active, filtered = GGM.FilterGuildGearBrowserEntries(active, query) }
    end, function(result)
        if frame.browserView ~= view or frame.searchBox:GetText() ~= query then
            frame.charactersDirty = true
            queueBrowserRefresh(frame)
            return
        end
        frame.entries = result.entries
        frame.charactersDirty = nil
        updateBrowserList(frame, frame.api, result)
        frame.listScroll:SetVerticalScroll(scroll)
    end, function() frame.charactersDirty = true end)
end

function GGM.ShowGuildGearBrowserWindow(api, db)
    if not GGM.guildGearBrowserFrame then GGM.guildGearBrowserFrame = GGM.CreateGuildGearBrowserWindow(api) end
    local frame = GGM.guildGearBrowserFrame
    if frame.db ~= db then frame.professionDirty = true end
    frame.db = db
    if GGM.ApplyBrowserWindowSettings then GGM.ApplyBrowserWindowSettings(frame, db) end
    -- Reopening reads current gear even if no companion notification was available.
    frame.charactersDirty = true
    frame:Show()
    GGM.SelectGuildGearBrowserTab(frame, frame.activeTab or "Professions")
    if frame.SetFrameStrata then frame:SetFrameStrata("DIALOG") end
    if frame.Raise then frame:Raise() end
    return frame.detailModel
end

function GGM.RefreshVisibleGuildGearBrowser()
    local frame = GGM.guildGearBrowserFrame
    if not frame then return false end
    frame.charactersDirty = true
    if frame.cpuOwners and GGM.CancelCPUJob then
        GGM.CancelCPUJob(frame.cpuOwners.characterBuild)
        GGM.CancelCPUJob(frame.cpuOwners.characterFilter)
    end
    if type(GGM.db) == "table" then
        if frame.db ~= GGM.db then frame.professionDirty = true end
        frame.db = GGM.db
    end
    if frame.activeTab ~= "Character" then return false end
    return queueBrowserRefresh(frame)
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

local function chatEmitter(api)
    local chatFrame = api.DEFAULT_CHAT_FRAME
    if chatFrame and type(chatFrame.AddMessage) == "function" then
        return function(message) chatFrame:AddMessage(message) end
    elseif type(api.print) == "function" then
        return function(message) api.print(message) end
    end
    return function() end
end

REQUEST_ERRORS = {
    ["request-target-invalid"] = "Usage: /ggm request Name-Realm",
    ["sync-unavailable"] = "Gear sync is unavailable.",
    ["sync-snapshot-request-pending"] = "A gear request for this character is already pending.",
    ["sync-snapshot-request-cooldown"] = "Please wait before requesting this character again.",
    ["sync-outbound-queue-full"] = "Gear sync is busy. Try again later.",
    ["sync-pending-request-limit"] = "Too many gear requests are pending. Try again later.",
    ["send-addon-message-failed:NotInGuild"] = "Gear sync requires guild membership.",
    ["send-addon-message-failed:AddonMessageThrottle"] = "Gear sync was throttled. Try again later.",
    ["send-addon-message-failed:AddOnMessageLockdown"] = "Gear sync is currently restricted. Try again later.",
}

local function printRequestError(api, err)
    chatEmitter(api)(REQUEST_ERRORS[err] or ("Gear request could not be queued (" .. tostring(err) .. ")."))
end

local function printAddonStatus(api)
    local emit = chatEmitter(api)
    emit("The Guild Book status:")
    local professionSync = GGM.professionSync
    local professionTransport = professionSync and professionSync.transport
    emit("Profession sync: " .. (professionSync and professionSync.registered and "registered" or "unavailable") .. " (GC_PROF3)")
    emit("Profession roster: " .. (professionSync and professionSync.rosterReady and "ready" or "not ready"))
    local professionError = professionTransport and professionTransport.lastSendError
        or professionSync and professionSync.lastError or GGM.lastProfessionSyncError
    emit("Profession sync error: " .. tostring(professionError or "none"))
    emit("Profession roster error: " .. tostring(GGM.lastProfessionIndexError or "none"))
    local transport = GGM.guildSync and GGM.guildSync.transport
    emit("Gear sync: " .. (GGM.guildSync and "registered" or "unavailable") .. " (" .. GGM.SYNC_PREFIX .. ")")
    local sendErr = transport and transport.lastSendError or GGM.lastSyncError
    local receiveErr = transport and transport.lastReceiveError or GGM.lastSyncReceiveError
    emit("Gear sync send/request error: " .. tostring(sendErr or "none"))
    emit("Gear sync receive error: " .. tostring(receiveErr or "none"))
    if GGM.gearStartupError then
        emit("Gear storage: unavailable (" .. tostring(GGM.gearStartupError) .. ")")
        if GGM.gearStartupError == "gear-companion-missing" then
            emit("Install and enable The Guild Book gear beside The Guild Book in Interface/AddOns.")
        elseif type(GGM.gearStartupError) == "string" and GGM.gearStartupError:match("^gear%-backend%-") then
            emit("The Guild Book gear could not provide a compatible gear backend (" .. GGM.gearStartupError
                .. "). Check that The Guild Book gear is enabled and up to date; saved gear was left unchanged.")
        else
            emit("Gear is stored separately in WTF/Account/<account>/SavedVariables/The Guild Book gear.lua (TheGuildBookGearDB). Close WoW and back up that file before any manual reset.")
        end
    end
    if GGM.startupError then
        emit("Database: unavailable (" .. tostring(GGM.startupError) .. ")")
        if type(GGM.startupError) == "string"
            and GGM.startupError:match("^unsupported%-schema%-version:%d+$") then
            emit("No automatic migration is available. Close WoW, back up and remove WTF/Account/<account>/SavedVariables/The Guild Book.lua (or remove only its TheGuildBookDB global), then relaunch.")
            emit("This clears profession snapshots/index data and local-character metadata. Gear and bank companion databases are separate.")
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
        if type(message) == "string" and message:match("^%s*options%s*$") then
            if type(GGM.ShowGuildBookOptions) == "function" then
                GGM.ShowGuildBookOptions(api, GGM.db)
            end
            return
        end
        if type(message) == "string" and message:match("^%s*status%s*$") then
            printAddonStatus(api)
            return
        end

        local target, requestErr = parseRequestedIdentity(message)
        if target then
            if not GGM.guildSync then
                GGM.lastSyncError = "sync-unavailable"
                printRequestError(api, GGM.lastSyncError)
                return
            end

            local queued, queueErr = GGM.RequestCompleteSnapshot(GGM.guildSync, target)
            if queued then
                GGM.lastSyncError = nil
                chatEmitter(api)("Gear request queued for " .. target.key .. ". Waiting for a cached snapshot.")
            else
                GGM.lastSyncError = queueErr
                printRequestError(api, queueErr)
            end
            return
        end

        if requestErr then
            GGM.lastSyncError = requestErr
            printRequestError(api, requestErr)
            return
        end

        GGM.ShowGuildGearBrowserWindow(api, GGM.db)
    end
end
