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

-- Visual-only palette inspired by CurseForge's modern dark surfaces: flat charcoal
-- cards, low-contrast separators, bright text, and a restrained orange accent.
-- These values are intentionally local to the browser UI and do not affect data,
-- filtering, selection, sync, or tooltip behavior.
local CF = {
    window = { 0.045, 0.045, 0.052, 0.99 },
    topbar = { 0.070, 0.070, 0.080, 1.00 },
    panel = { 0.082, 0.082, 0.092, 0.98 },
    panelRaised = { 0.105, 0.105, 0.118, 1.00 },
    panelHover = { 0.145, 0.145, 0.158, 0.92 },
    border = { 0.205, 0.205, 0.225, 1.00 },
    borderSoft = { 0.145, 0.145, 0.160, 1.00 },
    accent = { 0.945, 0.310, 0.125, 1.00 },
    accentSoft = { 0.370, 0.120, 0.055, 0.78 },
    text = { 0.955, 0.955, 0.965 },
    muted = { 0.650, 0.650, 0.685 },
}

local function setColor(texture, color)
    texture:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
end

local function createFlatBorder(panel, color)
    local top = panel:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    top:SetHeight(1)
    setColor(top, color)

    local bottom = panel:CreateTexture(nil, "BORDER")
    bottom:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    bottom:SetHeight(1)
    setColor(bottom, color)

    local left = panel:CreateTexture(nil, "BORDER")
    left:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
    left:SetWidth(1)
    setColor(left, color)

    local right = panel:CreateTexture(nil, "BORDER")
    right:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(1)
    setColor(right, color)
end

-- Flat content card used for search/list areas.  Kept on basic textures only so it
-- remains safe across Classic clients while shedding the older leather/inset look.
local function createClassicInsetPanel(api, parent, width, height)
    local panel = api.CreateFrame("Frame", nil, parent)
    panel:SetSize(width, height)

    panel.background = panel:CreateTexture(nil, "BACKGROUND")
    panel.background:SetAllPoints(panel)
    setColor(panel.background, CF.panel)

    panel.inner = panel:CreateTexture(nil, "BACKGROUND")
    panel.inner:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -2)
    panel.inner:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 2)
    panel.inner:SetColorTexture(0.068, 0.068, 0.076, 0.82)

    createFlatBorder(panel, CF.border)
    return panel
end

-- Equipment content card.  The paper-doll slot layout is unchanged; only the
-- presentation is flattened into a CurseForge-like dark card with an orange rule.
local function createClassicGearPanel(api, parent)
    local panel = api.CreateFrame("Frame", nil, parent)
    panel:SetSize(570, 438)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 292, -156)

    panel.background = panel:CreateTexture(nil, "BACKGROUND")
    panel.background:SetAllPoints(panel)
    setColor(panel.background, CF.panel)

    panel.headerBackground = panel:CreateTexture(nil, "BORDER")
    panel.headerBackground:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
    panel.headerBackground:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1)
    panel.headerBackground:SetHeight(36)
    setColor(panel.headerBackground, CF.panelRaised)

    panel.headerLine = panel:CreateTexture(nil, "BORDER")
    panel.headerLine:SetPoint("BOTTOMLEFT", panel.headerBackground, "BOTTOMLEFT", 0, 0)
    panel.headerLine:SetPoint("BOTTOMRIGHT", panel.headerBackground, "BOTTOMRIGHT", 0, 0)
    panel.headerLine:SetHeight(2)
    setColor(panel.headerLine, CF.accent)

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.title:SetPoint("LEFT", panel.headerBackground, "LEFT", 14, 1)
    panel.title:SetText("Equipment")
    panel.title:SetTextColor(CF.text[1], CF.text[2], CF.text[3])

    createFlatBorder(panel, CF.border)
    return panel
end

local function renderBrowserDetail(frame, entry, api)
    if type(GGM.ClearSavedCharacterModel) == "function" then
        GGM.ClearSavedCharacterModel(frame.characterModelView)
    elseif frame.characterModelView and frame.characterModelView.model then
        frame.characterModelView.model:Hide()
    end
    if frame.modelUnavailableLabel then frame.modelUnavailableLabel:Hide() end
    frame.detailModel = nil
    for _, control in ipairs({ frame.characterLine, frame.realmLine, frame.capturedLine, frame.completenessLine }) do control:Hide() end
    frame.detailEmpty:Hide()
    for _, slot in ipairs(frame.slotButtons) do slot:Hide() end
    if not entry then
        if #frame.activeEntries == 0 then
            frame.detailEmpty:SetText(frame.browserView == "Mine" and "No saved personal gear" or "No saved guild gear")
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
    local renderState = type(GGM.RenderSavedCharacterModel) == "function"
        and GGM.RenderSavedCharacterModel(frame.characterModelView, model.modelInput)
        or "render-unavailable"
    model.modelState = renderState
    if renderState == "shown" then
        if frame.characterModelView.model then frame.characterModelView.model:Show() end
    else
        if frame.characterModelView.model then frame.characterModelView.model:Hide() end
        frame.modelUnavailableLabel:SetText("2D paper doll unavailable")
        frame.modelUnavailableLabel:Show()
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
        frame.modelUnavailableLabel,
    }
    if not visible then
        for _, control in ipairs(conditionalControls) do
            if control then control:Hide() end
        end
        if type(GGM.ClearSavedCharacterModel) == "function" then
            GGM.ClearSavedCharacterModel(frame.characterModelView)
        elseif frame.characterModelView and frame.characterModelView.model then
            frame.characterModelView.model:Hide()
        end
    end

    if frame.gearPanel then
        if visible then frame.gearPanel:Show() else frame.gearPanel:Hide() end
    end
    for _, button in ipairs(frame.slotButtons) do
        if not visible then button:Hide() end
    end
    if frame.characterModelView and frame.characterModelView.model then
        if visible and frame.detailModel and frame.detailModel.modelState == "shown" then
            frame.characterModelView.model:Show()
        else
            frame.characterModelView.model:Hide()
        end
    end
end

local PROFESSIONS = {
    { key = "Alchemy", icon = "Interface\\Icons\\Trade_Alchemy" },
    { key = "Blacksmithing", icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { key = "Enchanting", icon = "Interface\\Icons\\Trade_Engraving" },
    { key = "Engineering", icon = "Interface\\Icons\\Trade_Engineering" },
    { key = "Leatherworking", icon = "Interface\\Icons\\Trade_LeatherWorking" },
    { key = "Tailoring", icon = "Interface\\Icons\\Trade_Tailoring" },
}

local function professionButtonColor(button, selected)
    if selected then
        button.background:SetColorTexture(0.25, 0.18, 0.055, 0.98)
    else
        button.background:SetColorTexture(0.055, 0.055, 0.065, 0.96)
    end
end

function GGM.SelectProfession(frame, selectedKey)
    local selectedProfession
    for _, profession in ipairs(PROFESSIONS) do
        if profession.key == selectedKey then
            selectedProfession = profession
            break
        end
    end
    if not selectedProfession then return false end

    frame.selectedProfession = selectedKey
    frame.professionHeading:SetText(selectedKey)
    for _, button in ipairs(frame.professionButtons) do
        local selected = button.key == selectedKey
        professionButtonColor(button, selected)
        if selected then button.label:SetTextColor(1, 0.82, 0) else button.label:SetTextColor(0.9, 0.9, 0.9) end
    end
    return true
end

local function createProfessionButton(api, page, profession, offset)
    local button = api.CreateFrame("Button", nil, page)
    button:SetSize(178, 52)
    button:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -offset)

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(button)
    button.background = background

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(38, 38)
    icon:SetPoint("LEFT", button, "LEFT", 8, 0)
    icon:SetTexture(profession.icon)

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", icon, "RIGHT", 10, 0)
    label:SetPoint("RIGHT", button, "RIGHT", -6, 0)
    label:SetJustifyH("LEFT")
    label:SetText(profession.key)

    button.key = profession.key
    button.label = label
    button:RegisterForClicks("LeftButtonUp")
    button:SetScript("OnClick", function() GGM.SelectProfession(page.owner, profession.key) end)
    button:SetScript("OnEnter", function()
        if page.owner.selectedProfession ~= profession.key then
            background:SetColorTexture(0.11, 0.11, 0.12, 0.98)
        end
    end)
    button:SetScript("OnLeave", function()
        professionButtonColor(button, page.owner.selectedProfession == profession.key)
    end)
    professionButtonColor(button, false)
    return button
end

local function createProfessionsPage(api, frame)
    local page = api.CreateFrame("Frame", nil, frame)
    page:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -48)
    page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 18)
    page.owner = frame
    page:Hide()

    local panel = page:CreateTexture(nil, "BACKGROUND")
    panel:SetPoint("TOPLEFT", page, "TOPLEFT", 190, 0)
    panel:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    panel:SetColorTexture(0.035, 0.035, 0.04, 0.8)

    frame.professionButtons = {}
    for index, profession in ipairs(PROFESSIONS) do
        frame.professionButtons[index] = createProfessionButton(api, page, profession, (index - 1) * 58)
    end

    frame.professionHeading = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.professionHeading:SetPoint("TOPLEFT", page, "TOPLEFT", 210, -30)
    frame.professionHeading:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    frame.professionHeading:SetJustifyH("LEFT")

    local placeholder = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    placeholder:SetPoint("TOPLEFT", frame.professionHeading, "BOTTOMLEFT", 0, -18)
    placeholder:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetText("Details will be added later.")

    frame.professionsPage = page
    GGM.SelectProfession(frame, "Alchemy")
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
        if selected then
            setColor(tab.background, CF.panelRaised)
            tab.label:SetTextColor(CF.text[1], CF.text[2], CF.text[3])
            if tab.accent then tab.accent:Show() end
            if tab.icon then tab.icon:SetAlpha(1) end
        else
            setColor(tab.background, CF.panel)
            tab.label:SetTextColor(CF.muted[1], CF.muted[2], CF.muted[3])
            if tab.accent then tab.accent:Hide() end
            if tab.icon then tab.icon:SetAlpha(0.72) end
        end
    end

    local showCharacter = selectedKey == "Character"
    if selectedKey == "Professions" then frame.professionsPage:Show() else frame.professionsPage:Hide() end
    for pageKey, page in pairs(frame.placeholderPages) do
        if pageKey == selectedKey and pageKey ~= "Professions" then page:Show() else page:Hide() end
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
    frame.activeEntries = GGM.FilterGuildGearBrowserOwnership(frame.entries, frame.db, frame.browserView)
    frame.filteredEntries = GGM.FilterGuildGearBrowserEntries(frame.activeEntries, frame.searchBox:GetText() or "")
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
            row:SetSize(224, 32)

            row.base = row:CreateTexture(nil, "BACKGROUND")
            row.base:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            row.base:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
            row.base:SetColorTexture(0.072, 0.072, 0.080, 0.70)

            row.selection = row:CreateTexture(nil, "BACKGROUND")
            row.selection:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            row.selection:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
            setColor(row.selection, CF.accentSoft)
            row.selection:Hide()

            row.selectedBar = row:CreateTexture(nil, "ARTWORK")
            row.selectedBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            row.selectedBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            row.selectedBar:SetWidth(3)
            setColor(row.selectedBar, CF.accent)
            row.selectedBar:Hide()

            row.hover = row:CreateTexture(nil, "HIGHLIGHT")
            row.hover:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            row.hover:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
            setColor(row.hover, CF.panelHover)

            row.separator = row:CreateTexture(nil, "BORDER")
            row.separator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 8, 0)
            row.separator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 0)
            row.separator:SetHeight(1)
            setColor(row.separator, CF.borderSoft)

            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.label:SetPoint("LEFT", row, "LEFT", 12, 0)
            row.label:SetWidth(204)
            row.label:SetJustifyH("LEFT")
            row:RegisterForClicks("LeftButtonUp")
            rows[index] = row
        end
        row.entry = entry
        row.label:SetText(entry.name .. " - " .. entry.realm)
        row:SetPoint("TOPLEFT", frame.listContent, "TOPLEFT", 0, -(index - 1) * 32)
        row.selected = frame.selectedEntry ~= nil and frame.selectedEntry.key == entry.key
        if row.selected then
            row.selection:Show()
            row.selectedBar:Show()
        else
            row.selection:Hide()
            row.selectedBar:Hide()
        end
        if row.label.SetTextColor then
            if row.selected then
                row.label:SetTextColor(CF.text[1], CF.text[2], CF.text[3])
            else
                row.label:SetTextColor(0.86, 0.86, 0.88)
            end
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
    frame.listContent:SetHeight(math.max(#frame.filteredEntries * 32, 1))

    if #frame.activeEntries == 0 then
        frame.listEmpty:SetText(frame.browserView == "Mine" and "No saved personal gear" or "No saved guild gear")
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

local function updateBrowserViewButtonStyles(frame)
    for _, button in ipairs({ frame.mineButton, frame.guildButton }) do
        local selected = button.key == frame.browserView
        button.selected = selected
        if selected then
            setColor(button.background, CF.accentSoft)
            for _, border in ipairs(button.border) do setColor(border, CF.accent) end
            button.label:SetTextColor(CF.text[1], CF.text[2], CF.text[3])
        else
            setColor(button.background, CF.panelRaised)
            for _, border in ipairs(button.border) do setColor(border, CF.border) end
            button.label:SetTextColor(CF.muted[1], CF.muted[2], CF.muted[3])
        end
    end
end

local function createBrowserViewButton(api, frame, key, label, x)
    local button = api.CreateFrame("Button", nil, frame.searchPanel)
    button:SetSize(45, 21)
    button:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", x, -6)
    button.background = button:CreateTexture(nil, "BACKGROUND")
    button.background:SetAllPoints(button)
    setColor(button.background, CF.panelRaised)
    button.border = {}
    local edges = {
        { "TOPLEFT", "TOPLEFT", "TOPRIGHT", "TOPRIGHT", 0, 0, 0, 0, "height" },
        { "BOTTOMLEFT", "BOTTOMLEFT", "BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, 0, 0, "height" },
        { "TOPLEFT", "TOPLEFT", "BOTTOMLEFT", "BOTTOMLEFT", 0, 0, 0, 0, "width" },
        { "TOPRIGHT", "TOPRIGHT", "BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, 0, 0, "width" },
    }
    for index, edge in ipairs(edges) do
        local border = button:CreateTexture(nil, "BORDER")
        border:SetPoint(edge[1], button, edge[2], edge[5], edge[6])
        border:SetPoint(edge[3], button, edge[4], edge[7], edge[8])
        if edge[9] == "height" then border:SetHeight(1) else border:SetWidth(1) end
        setColor(border, CF.border)
        button.border[index] = border
    end
    button.hover = button:CreateTexture(nil, "HIGHLIGHT")
    button.hover:SetAllPoints(button)
    setColor(button.hover, CF.panelHover)
    button.label = createText(button, "OVERLAY", "GameFontHighlightSmall")
    button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.label:SetText(label)
    button:RegisterForClicks("LeftButtonUp")
    button.key = key
    button:SetScript("OnClick", function()
        frame.browserView = key
        updateBrowserViewButtonStyles(frame)
        updateBrowserList(frame, api)
    end)
    return button
end

local function createNavigationTab(api, frame, key, label, iconPath, offset)
    local tab = api.CreateFrame("Button", nil, frame)
    tab:SetSize(116, 34)
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 16 + offset, -48)

    local background = tab:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(tab)
    setColor(background, CF.panel)

    local accent = tab:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
    accent:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
    accent:SetHeight(2)
    setColor(accent, CF.accent)
    accent:Hide()

    local hover = tab:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints(tab)
    setColor(hover, CF.panelHover)

    local icon = tab:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", tab, "LEFT", 10, 0)
    icon:SetTexture(iconPath)
    icon:SetAlpha(0.72)

    local text = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 7, 0)
    text:SetText(label)
    text:SetJustifyH("LEFT")
    text:SetTextColor(CF.muted[1], CF.muted[2], CF.muted[3])

    tab.key = key
    tab.background = background
    tab.accent = accent
    tab.icon = icon
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
    frame.browserView = "Guild"

    -- Cover the default parchment/inset treatment with a flat dark application shell.
    -- Template-owned regions are hidden conditionally so this stays compatible with
    -- Classic variants that expose slightly different frame members.
    if frame.Bg and frame.Bg.Hide then frame.Bg:Hide() end
    if frame.TitleBg and frame.TitleBg.Hide then frame.TitleBg:Hide() end
    if frame.TopTileStreaks and frame.TopTileStreaks.Hide then frame.TopTileStreaks:Hide() end
    if frame.TopTileStreak and frame.TopTileStreak.Hide then frame.TopTileStreak:Hide() end
    if frame.Portrait and frame.Portrait.Hide then frame.Portrait:Hide() end
    if frame.NineSlice and frame.NineSlice.Hide then frame.NineSlice:Hide() end
    if frame.Inset and frame.Inset.Hide then frame.Inset:Hide() end

    frame.cfBackground = frame:CreateTexture(nil, "BACKGROUND")
    frame.cfBackground:SetAllPoints(frame)
    setColor(frame.cfBackground, CF.window)

    frame.cfTopbar = frame:CreateTexture(nil, "BORDER")
    frame.cfTopbar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    frame.cfTopbar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    frame.cfTopbar:SetHeight(39)
    setColor(frame.cfTopbar, CF.topbar)

    frame.cfTopbarAccent = frame:CreateTexture(nil, "BORDER")
    frame.cfTopbarAccent:SetPoint("BOTTOMLEFT", frame.cfTopbar, "BOTTOMLEFT", 0, 0)
    frame.cfTopbarAccent:SetPoint("BOTTOMRIGHT", frame.cfTopbar, "BOTTOMRIGHT", 0, 0)
    frame.cfTopbarAccent:SetHeight(2)
    setColor(frame.cfTopbarAccent, CF.accent)
    createFlatBorder(frame, CF.border)

    if frame.TitleText.ClearAllPoints then
        frame.TitleText:ClearAllPoints()
        frame.TitleText:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -12)
    end
    if frame.TitleText.SetTextColor then
        frame.TitleText:SetTextColor(CF.text[1], CF.text[2], CF.text[3])
    end

    -- Left browser column: compact filter card over a dense, table-like result list.
    frame.searchPanel = createClassicInsetPanel(api, frame, 258, 66)
    frame.searchPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -90)

    frame.searchLabel = createText(frame.searchPanel, "OVERLAY", "GameFontNormal")
    frame.searchLabel:SetText("Search characters")
    frame.searchLabel:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", 12, -9)
    frame.searchLabel:SetTextColor(CF.muted[1], CF.muted[2], CF.muted[3])

    frame.searchLabel:SetWidth(132)
    frame.mineButton = createBrowserViewButton(api, frame, "Mine", "Mine", 154)
    frame.guildButton = createBrowserViewButton(api, frame, "Guild", "Guild", 204)
    updateBrowserViewButtonStyles(frame)

    frame.searchBox = api.CreateFrame("EditBox", nil, frame.searchPanel, "InputBoxTemplate")
    frame.searchBox:SetSize(232, 25)
    frame.searchBox:SetPoint("TOPLEFT", frame.searchPanel, "TOPLEFT", 12, -32)

    frame.searchBoxBackground = frame.searchBox:CreateTexture(nil, "BACKGROUND")
    frame.searchBoxBackground:SetPoint("TOPLEFT", frame.searchBox, "TOPLEFT", -3, 2)
    frame.searchBoxBackground:SetPoint("BOTTOMRIGHT", frame.searchBox, "BOTTOMRIGHT", 3, -2)
    frame.searchBoxBackground:SetColorTexture(0.040, 0.040, 0.046, 1)
    createFlatBorder(frame.searchBox, CF.border)
    if frame.searchBox.Left and frame.searchBox.Left.Hide then frame.searchBox.Left:Hide() end
    if frame.searchBox.Middle and frame.searchBox.Middle.Hide then frame.searchBox.Middle:Hide() end
    if frame.searchBox.Right and frame.searchBox.Right.Hide then frame.searchBox.Right:Hide() end
    frame.searchBox:SetAutoFocus(false)
    frame.searchBox:SetScript("OnTextChanged", function()
        updateBrowserList(frame, api)
    end)

    frame.listPanel = createClassicInsetPanel(api, frame, 258, 430)
    frame.listPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -164)

    frame.listScroll = api.CreateFrame("ScrollFrame", nil, frame.listPanel, "UIPanelScrollFrameTemplate")
    frame.listScroll:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 7, -7)
    frame.listScroll:SetSize(242, 416)
    frame.listContent = api.CreateFrame("Frame", nil, frame.listScroll)
    frame.listContent:SetSize(224, 1)
    frame.listScroll:SetScrollChild(frame.listContent)
    frame.listEmpty = createText(frame.listPanel, "OVERLAY", "GameFontNormal")
    frame.listEmpty:SetPoint("TOPLEFT", frame.listPanel, "TOPLEFT", 14, -16)
    frame.listEmpty:Hide()

    frame.characterLine = createText(frame, "OVERLAY", "GameFontNormalLarge")
    frame.characterLine:SetPoint("TOPLEFT", frame, "TOPLEFT", 300, -94)
    frame.realmLine = createText(frame, "OVERLAY", "GameFontHighlight")
    frame.realmLine:SetPoint("TOPLEFT", frame.characterLine, "BOTTOMLEFT", 0, -4)
    frame.capturedLine = createText(frame, "OVERLAY", "GameFontHighlightSmall")
    frame.capturedLine:SetPoint("TOPLEFT", frame.realmLine, "BOTTOMLEFT", 0, -5)
    frame.completenessLine = createText(frame, "OVERLAY", "GameFontHighlightSmall")
    frame.completenessLine:SetPoint("LEFT", frame.capturedLine, "RIGHT", 16, 0)
    frame.characterLine:SetTextColor(CF.text[1], CF.text[2], CF.text[3])
    frame.realmLine:SetTextColor(CF.muted[1], CF.muted[2], CF.muted[3])
    frame.capturedLine:SetTextColor(CF.muted[1], CF.muted[2], CF.muted[3])
    frame.completenessLine:SetTextColor(CF.accent[1], CF.accent[2], CF.accent[3])
    frame.gearPanel = createClassicGearPanel(api, frame)

    frame.characterModelView = GGM.CreateSavedCharacterModel(api, frame.gearPanel)
    if frame.characterModelView.model then
        frame.characterModelView.model:SetSize(220, 252)
        frame.characterModelView.model:SetPoint("CENTER", frame.gearPanel, "CENTER", 0, 6)
        frame.characterModelView.model:Hide()
    end
    frame.modelUnavailableLabel = createText(frame.gearPanel, "OVERLAY", "GameFontDisableSmall")
    frame.modelUnavailableLabel:SetSize(220, 36)
    frame.modelUnavailableLabel:SetPoint("CENTER", frame.gearPanel, "CENTER", 0, 6)
    frame.modelUnavailableLabel:SetJustifyH("CENTER")
    frame.modelUnavailableLabel:SetTextColor(CF.muted[1], CF.muted[2], CF.muted[3])
    frame.modelUnavailableLabel:Hide()

    frame.detailEmpty = createText(frame.gearPanel, "OVERLAY", "GameFontNormalLarge")
    frame.detailEmpty:SetPoint("CENTER", frame.gearPanel, "CENTER", 0, -12)
    frame.detailEmpty:Hide()

    -- Classic 2D paper-doll arrangement: eight slots on each side and weapons
    -- along the bottom. The center prefers a verified race+sex icon atlas and
    -- falls back without affecting the saved gear display.
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
        button.slotBackground:SetColorTexture(0.030, 0.030, 0.035, 1)

        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetSize(36, 36)
        button.icon:SetPoint("CENTER", button, "CENTER", 0, 0)

        button.border = api.CreateFrame("Frame", nil, button)
        button.border:SetSize(42, 42)
        button.border:SetPoint("CENTER", button, "CENTER", 0, 0)
        createFlatBorder(button.border, CF.border)

        button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
        button.highlight:SetSize(42, 42)
        button.highlight:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.highlight:SetColorTexture(CF.accent[1], CF.accent[2], CF.accent[3], 0.28)

        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.label:SetText(slotDisplayNames[trackedSlot.key])
        button.label:SetTextColor(0.80, 0.80, 0.83)

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
    for _, pageKey in ipairs({ "Bank" }) do
        local page = createText(frame, "OVERLAY", "GameFontNormalLarge")
        page:SetPoint("CENTER", frame, "CENTER", 0, 0)
        page:SetText(pageKey .. " content will be added later.")
        page:SetTextColor(CF.muted[1], CF.muted[2], CF.muted[3])
        page:Hide()
        frame.placeholderPages[pageKey] = page
    end
    createProfessionsPage(api, frame)
    frame.navigationTabs = {
        createNavigationTab(api, frame, "Character", "Character", "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest", 0),
        createNavigationTab(api, frame, "Professions", "Professions", "Interface\\Icons\\Trade_BlackSmithing", 122),
        createNavigationTab(api, frame, "Bank", "Bank", "Interface\\Icons\\INV_Misc_Bag_10", 244),
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
    frame.db = db
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
