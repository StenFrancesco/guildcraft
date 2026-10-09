local _, GGM = ...

local BANK_PAGE_TOP = 64
local BANK_PAGE_BOTTOM = 56
local LEFT_X, LEFT_WIDTH = 314, 297
local RIGHT_X = 629
local LIST_ROW_HEIGHT, LIST_ROW_PITCH = 44, 50
local TAB_ROW_HEIGHT, TAB_ROW_PITCH = 34, 39
local GRID_COLUMNS, GRID_BUTTON_SIZE, GRID_X_PITCH, GRID_ROW_PITCH = 8, 68, 76, 88

local function safeString(api, value)
    local check = type(api) == "table" and api.issecretvalue or nil
    if type(check) ~= "function" then check = rawget(_G, "issecretvalue") end
    if type(check) ~= "function" then return nil, false, "unknown" end
    local ok, secret = pcall(check, value)
    if not ok or secret ~= false then return nil, false, "unsafe" end
    if value == nil then return nil, true, "empty" end
    if type(value) ~= "string" then return nil, true, "invalid" end
    if value == "" then return nil, true, "empty" end
    return value, true, "value"
end

local function currentGuildIdentity(api)
    if type(api) ~= "table" or type(api.GetGuildInfo) ~= "function" then return nil end
    local guildOK, guildName, _, _, guildRealm = pcall(api.GetGuildInfo, "player")
    if not guildOK then return nil end
    local safeGuildName, guildNameKnown = safeString(api, guildName)
    if not guildNameKnown or not safeGuildName then return nil end
    local realmName, realmKnown, realmState = safeString(api, guildRealm)
    if not realmKnown then return nil end
    if not realmName then
        if realmState ~= "empty" then return nil end
        if type(api.GetRealmName) ~= "function" then return nil end
        local realmOK, localRealm = pcall(api.GetRealmName)
        if not realmOK then return nil end
        localRealm, realmKnown = safeString(api, localRealm)
        if not realmKnown then return nil end
        realmName = localRealm
    end
    if not realmName then return nil end
    return { key = safeGuildName .. "-" .. realmName, name = safeGuildName, realm = realmName }
end

local function label(parent, text, size, bold)
    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if type(GGM.ApplyJournalFont) == "function" then GGM.ApplyJournalFont(value, size or 14, bold and "bold" or nil) end
    value:SetText(text or "")
    local theme = GGM.UITheme or {}
    local color = theme.text or { 0.19, 0.125, 0.07, 1 }
    if value.SetTextColor then value:SetTextColor(color[1], color[2], color[3], color[4] or 1) end
    return value
end

local function setText(control, value)
    if not control then return end
    control:SetText(value or "")
    if value and value ~= "" then control:Show() else control:Hide() end
end

local function createButton(api, parent, text, width, height, variant)
    local button
    if type(GGM.CreateFlatButton) == "function" then
        button = GGM.CreateFlatButton(api, parent, text, width, height, variant or "secondary")
    else
        button = api.CreateFrame("Button", nil, parent)
        button:SetSize(width, height)
        button.label = label(button, text, 14, true)
        button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
    end
    return button
end

local function getScroll(scroll)
    if type(scroll.GetVerticalScroll) == "function" then
        local ok, value = pcall(scroll.GetVerticalScroll, scroll)
        if ok and type(value) == "number" then return value end
    end
    return type(scroll.verticalScroll) == "number" and scroll.verticalScroll or 0
end

local function setScroll(scroll, value)
    if scroll and type(scroll.SetVerticalScroll) == "function" then scroll:SetVerticalScroll(value or 0) end
end

local function createScroll(api, parent, width, height, topLeftX, topLeftY)
    local scroll = api.CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", topLeftX, topLeftY)
    scroll:SetSize(width, height)
    local content = api.CreateFrame("Frame", nil, scroll)
    content:SetSize(width, 1)
    scroll:SetScrollChild(content)
    scroll.content = content
    if type(scroll.EnableMouseWheel) == "function" then scroll:EnableMouseWheel(true) end
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local current = getScroll(self)
        local contentHeight = type(self.content.GetHeight) == "function"
            and self.content:GetHeight() or self.content.height or 0
        local scrollHeight = type(self.GetHeight) == "function" and self:GetHeight() or self.height or 0
        local maxScroll = math.max(0, contentHeight - scrollHeight)
        setScroll(self, math.max(0, math.min(maxScroll, current - delta * 42)))
    end)
    return scroll, content
end

local function getTab(model, tabID)
    if type(model) ~= "table" or type(model.tabs) ~= "table" then return nil end
    for _, tab in ipairs(model.tabs) do if tab.id == tabID then return tab end end
end

local function detailEmptyText(entry, detail)
    if detail and detail.hasRecord then return detail.emptyStateText end
    if not entry then return "Select a bank snapshot." end
    if entry.companionState == "missing" then
        return "Install DysbankMemory beside GuildGearMemory under _retail_/Interface/AddOns/DysbankMemory to browse saved bank snapshots."
    end
    if entry.companionState == "unsupported" then return "DysbankMemory API schema is unsupported." end
    if entry.databaseState == "unsupported" then return "Saved bank data has an unsupported schema." end
    if entry.kind == "guild" and not entry.guildKey then return "Current guild identity is unavailable." end
    if entry.kind == "guild" then return "No saved snapshot for this guild." end
    return "No saved bank data for this character."
end

local function styleSelected(button, selected)
    if not button then return end
    button.selected = selected == true
    if type(GGM.SetFlatButtonState) == "function" then
        GGM.SetFlatButtonState(button, selected and "selected" or "idle")
    elseif button.SetAlpha then
        button:SetAlpha(selected and 1 or 0.78)
    end
end

local function currentSavedTab(page)
    return getTab(page.detailModel, page.selectedTabID)
end

local function renderEntries(page, listScroll, listContent)
    local entries = page.entries or {}
    local contentWidth = math.max(1, (listScroll.width or LEFT_WIDTH) - 24)
    listContent:SetWidth(contentWidth)
    listContent:SetHeight(math.max(1, #entries * LIST_ROW_PITCH))
    page.entryButtons = page.entryButtons or {}
    for index, entry in ipairs(entries) do
        local button = page.entryButtons[index]
        if not button then
            button = createButton(page.api, listContent, "", contentWidth, LIST_ROW_HEIGHT, "ghost")
            page.entryButtons[index] = button
        end
        local text = entry.kind == "guild" and entry.label or (entry.name .. " · " .. entry.realm)
        local status = entry.status == "incomplete" and " · Incomplete"
            or (entry.status == "cached" and " · Cached" or "")
        button:SetText(text .. status)
        if button.label then
            button.label:SetWidth(contentWidth - 12)
            button.label:SetJustifyH("LEFT")
        end
        button.key = entry.key
        button.entry = entry
        button:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -((index - 1) * LIST_ROW_PITCH))
        button:SetScript("OnClick", function(self) GGM.SelectBankEntry(page, self.entry) end)
        button:Show()
        styleSelected(button, page.selectedEntry and page.selectedEntry.key == entry.key)
    end
    for index = #entries + 1, #page.entryButtons do page.entryButtons[index]:Hide() end
    setText(page.listCount, tostring(#entries) .. (#entries == 1 and " entry" or " entries"))
end

local function renderTabs(page, selectedEntry)
    local tabs = page.detailModel and page.detailModel.tabs or {}
    local width = math.max(1, (page.tabScroll.width or 640) - 24)
    page.tabContent:SetWidth(width)
    page.tabContent:SetHeight(math.max(1, #tabs * TAB_ROW_PITCH))
    page.tabButtons = page.tabButtons or {}
    for index, tab in ipairs(tabs) do
        local button = page.tabButtons[index]
        if not button then
            button = createButton(page.api, page.tabContent, "", width, TAB_ROW_HEIGHT, "ghost")
            page.tabButtons[index] = button
        end
        button:SetText(tab.name .. " · " .. tab.statusText)
        if button.label then
            button.label:SetWidth(width - 12)
            button.label:SetJustifyH("LEFT")
        end
        button.tabID = tab.id
        button:SetPoint("TOPLEFT", page.tabContent, "TOPLEFT", 0, -((index - 1) * TAB_ROW_PITCH))
        button:SetScript("OnClick", function(self) GGM.SelectBankTab(page, self.tabID) end)
        button:Show()
        styleSelected(button, page.selectedTabID == tab.id)
    end
    for index = #tabs + 1, #page.tabButtons do page.tabButtons[index]:Hide() end
    if #tabs == 0 then setText(page.tabsEmpty, "No observed bank tabs.") else page.tabsEmpty:Hide() end
end

local function renderSlots(page)
    local tab = currentSavedTab(page)
    local slots = tab and tab.slots or {}
    local width = math.max(1, (page.itemScroll.width or 640) - 24)
    page.itemContent:SetWidth(width)
    local rowCount = math.ceil(#slots / GRID_COLUMNS)
    page.itemContent:SetHeight(math.max(1, rowCount * GRID_ROW_PITCH))
    page.itemButtons = page.itemButtons or {}
    for index, slot in ipairs(slots) do
        local button = page.itemButtons[index]
        if not button then
            button = page.api.CreateFrame("Button", nil, page.itemContent)
            button:SetSize(GRID_BUTTON_SIZE, GRID_BUTTON_SIZE)
            button.background = button:CreateTexture(nil, "BACKGROUND")
            button.background:SetAllPoints(button)
            button.background:SetColorTexture(0.025, 0.022, 0.018, 1)
            button.icon = button:CreateTexture(nil, "ARTWORK")
            button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 5, -5)
            button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -5, 5)
            button.label = label(button, "", 11)
            button.label:SetPoint("BOTTOM", button, "BOTTOM", 0, -14)
            button.label:SetWidth(GRID_BUTTON_SIZE + 4)
            button.label:SetJustifyH("CENTER")
            page.itemButtons[index] = button
        end
        local column = (index - 1) % GRID_COLUMNS
        local row = math.floor((index - 1) / GRID_COLUMNS)
        button:SetPoint("TOPLEFT", page.itemContent, "TOPLEFT", column * GRID_X_PITCH, -(row * GRID_ROW_PITCH))
        button.slotID = slot.id
        button.slot = slot
        button.icon:SetTexture(slot.icon or (slot.itemID and "Interface\\Icons\\INV_Misc_QuestionMark")
            or "Interface\\Icons\\INV_Misc_QuestionMark")
        button.label:SetText(slot.itemID and (slot.count and slot.count > 1 and tostring(slot.count) or "")
            or (slot.empty and "Empty" or (slot.observed and "Empty" or "Not observed")))
        button:SetScript("OnClick", function(self) GGM.SelectBankSlot(page, self.slotID) end)
        button:SetScript("OnEnter", function(self)
            local tooltip = page.api.GameTooltip
            if self.slot.itemLink and tooltip and type(tooltip.SetHyperlink) == "function" then
                if type(tooltip.SetOwner) == "function" then tooltip:SetOwner(self, "ANCHOR_RIGHT") end
                tooltip:SetHyperlink(self.slot.itemLink)
                if type(tooltip.Show) == "function" then tooltip:Show() end
            end
        end)
        button:SetScript("OnLeave", function()
            local tooltip = page.api.GameTooltip
            if tooltip and type(tooltip.Hide) == "function" then tooltip:Hide() end
        end)
        button:Show()
        styleSelected(button, page.selectedSlotID == slot.id)
        if button.background and button.background.SetColorTexture then
            local color = GGM.UITheme and GGM.UITheme.slot or { 0.02, 0.018, 0.015, 1 }
            if page.selectedSlotID == slot.id then
                local selected = GGM.UITheme and GGM.UITheme.gold or { 0.475, 0.295, 0.075, 1 }
                button.background:SetColorTexture(selected[1], selected[2], selected[3], 0.55)
            else
                button.background:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
            end
        end
    end
    for index = #slots + 1, #page.itemButtons do page.itemButtons[index]:Hide() end
    if tab and tab.status == "unavailable" then
        setText(page.slotsEmpty, "This tab was unavailable at the last observation.")
    elseif #slots == 0 then
        setText(page.slotsEmpty, detailEmptyText(page.selectedEntry, page.detailModel) or "No saved slots.")
    else
        page.slotsEmpty:Hide()
    end
end

local function updateDetail(page)
    local entry = page.selectedEntry
    page.detailModel = entry and GGM.BuildBankDetail(entry, page.api) or nil
    if not page.detailModel or not page.detailModel.hasRecord then
        setText(page.detailTitle, entry and (entry.kind == "guild" and "Guild Bank" or entry.name) or "Bank snapshots")
        setText(page.detailStatus, detailEmptyText(entry, page.detailModel))
        setText(page.tabStatus, "")
        page.selectedTabID, page.selectedSlotID = nil, nil
        local tooltip = page.api.GameTooltip
        if tooltip and type(tooltip.Hide) == "function" then tooltip:Hide() end
        renderTabs(page, entry)
        renderSlots(page)
        return
    end

    setText(page.detailTitle, page.detailModel.name .. (page.detailModel.kind == "guild" and "" or " · " .. page.detailModel.realm))
    local status = page.detailModel.completenessText .. " · Last observed " .. page.detailModel.capturedAtText
    if entry.companionState == "missing" then status = status .. " · DysbankMemory not loaded" end
    if entry.companionState == "unsupported" then status = status .. " · companion API unsupported" end
    setText(page.detailStatus, status)
    local selected = getTab(page.detailModel, page.selectedTabID)
    if not selected then
        page.selectedTabID = page.detailModel.selectedTabID
        selected = getTab(page.detailModel, page.selectedTabID)
    end
    local selectedSlotFound = false
    if selected then
        for _, slot in ipairs(selected.slots) do
            if slot.id == page.selectedSlotID then selectedSlotFound = true; break end
        end
    end
    if not selectedSlotFound then page.selectedSlotID = nil end
    if selected then
        setText(page.tabStatus, selected.statusText .. " · " .. selected.capturedAtText)
        if selected.status == "incomplete" then
            page.detailStatus:SetText(page.detailStatus:GetText() .. " · one or more tabs are incomplete")
        end
    else
        setText(page.tabStatus, "")
    end
    renderTabs(page, entry)
    renderSlots(page)
end

local function refreshPage(page, db, bankDB)
    if not page then return false end
    local listPosition = getScroll(page.listScroll)
    local tabPosition = getScroll(page.tabScroll)
    local itemPosition = getScroll(page.itemScroll)
    local selectedKey = page.selectedEntry and page.selectedEntry.key
    local selectedTabID = page.selectedTabID
    local selectedSlotID = page.selectedSlotID
    local guildIdentity = currentGuildIdentity(page.api)
    page.guildIdentity = guildIdentity
    page.entries = GGM.BuildBankEntries(db, bankDB, guildIdentity)
    page.selectedEntry = nil
    for _, entry in ipairs(page.entries) do
        if entry.key == selectedKey then page.selectedEntry = entry; break end
    end
    if not page.selectedEntry then page.selectedEntry = page.entries[1] end
    page.selectedTabID, page.selectedSlotID = selectedTabID, selectedSlotID
    renderEntries(page, page.listScroll, page.listContent)
    updateDetail(page)
    setScroll(page.listScroll, listPosition)
    setScroll(page.tabScroll, tabPosition)
    setScroll(page.itemScroll, itemPosition)
    return true
end

function GGM.SelectBankEntry(page, entry)
    if not page or type(entry) ~= "table" then return false end
    local found = false
    for _, candidate in ipairs(page.entries or {}) do if candidate.key == entry.key then found = true; entry = candidate; break end end
    if not found then return false end
    page.selectedEntry = entry
    page.selectedTabID, page.selectedSlotID = nil, nil
    setScroll(page.tabScroll, 0)
    setScroll(page.itemScroll, 0)
    updateDetail(page)
    renderEntries(page, page.listScroll, page.listContent)
    return true
end

function GGM.SelectBankTab(page, tabID)
    if not page or not getTab(page.detailModel, tabID) then return false end
    page.selectedTabID, page.selectedSlotID = tabID, nil
    setScroll(page.itemScroll, 0)
    updateDetail(page)
    return true
end

function GGM.SelectBankSlot(page, slotID)
    if type(page) ~= "table" or type(slotID) ~= "number" or slotID < 1
        or slotID ~= math.floor(slotID) then return false end
    local tab = currentSavedTab(page)
    if not tab then return false end
    for _, slot in ipairs(tab.slots) do
        if slot.id == slotID then page.selectedSlotID = slotID; renderSlots(page); return true end
    end
    return false
end

function GGM.CreateBankPage(api, frame)
    local page = api.CreateFrame("Frame", nil, frame)
    page:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -BANK_PAGE_TOP)
    page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -50, BANK_PAGE_BOTTOM)
    page:Hide()
    page.api, page.owner = api, frame
    page.entries, page.entryButtons, page.tabButtons, page.itemButtons = {}, {}, {}, {}

    page.listCount = label(page, "0 entries", 12)
    page.listCount:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", LEFT_X + 2, 9)
    page.listScroll, page.listContent = createScroll(api, page, LEFT_WIDTH, 410, LEFT_X, -53)

    page.detailTitle = label(page, "Bank snapshots", 24, true)
    page.detailTitle:SetPoint("TOPLEFT", page, "TOPLEFT", RIGHT_X + 22, -14)
    page.detailStatus = label(page, "", 13)
    page.detailStatus:SetPoint("TOPLEFT", page.detailTitle, "BOTTOMLEFT", 0, -5)
    page.detailStatus:SetWidth(638)
    page.detailStatus:SetJustifyH("LEFT")
    page.tabStatus = label(page, "", 12)
    page.tabStatus:SetPoint("TOPLEFT", page, "TOPLEFT", RIGHT_X + 22, -76)
    page.tabScroll, page.tabContent = createScroll(api, page, 674, 114, RIGHT_X + 22, -96)
    page.tabsEmpty = label(page, "No observed bank tabs.", 14)
    page.tabsEmpty:SetPoint("TOPLEFT", page, "TOPLEFT", RIGHT_X + 26, -101)
    page.slotsLabel = label(page, "SAVED ITEMS", 13, true)
    page.slotsLabel:SetPoint("TOPLEFT", page, "TOPLEFT", RIGHT_X + 22, -220)
    page.itemScroll, page.itemContent = createScroll(api, page, 674, 244, RIGHT_X + 22, -240)
    page.slotsEmpty = label(page, "", 15)
    page.slotsEmpty:SetPoint("CENTER", page.itemScroll, "CENTER", 0, 0)

    page:Show()
    refreshPage(page, frame.db, rawget(_G, "DysbankMemoryDB"))
    page:Hide()
    frame.bankPage = page
    return page
end

function GGM.RefreshVisibleBankView()
    local frame = GGM.guildGearBrowserFrame
    if not frame or frame.activeTab ~= "Bank" or not frame.bankPage then return false end
    if type(frame.IsShown) == "function" and not frame:IsShown() then return false end
    return refreshPage(frame.bankPage, frame.db, rawget(_G, "DysbankMemoryDB"))
end

_G.GuildGearMemoryBankChanged = function()
    return GGM.RefreshVisibleBankView()
end
