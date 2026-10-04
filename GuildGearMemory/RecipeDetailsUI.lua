local _, GGM = ...

local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local MAX_NATIVE_CRAFTERS = 12
local createCrafterDropdown

local function text(parent, font, point, relative, relativePoint, x, y, width)
    local label = parent:CreateFontString(nil, "OVERLAY", font)
    label:SetPoint(point, relative, relativePoint, x, y)
    label:SetJustifyH("LEFT")
    if width then label:SetWidth(width) end
    return label
end

local function shown(frame)
    return frame and frame:IsShown()
end

local function closeCrafterMenu(details)
    if details.crafterMenu then details.crafterMenu:Hide() end
    local api = details.api
    if details.nativeDropdown and api.UIDROPDOWNMENU_OPEN_MENU == details.crafterDropdown
        and type(api.CloseDropDownMenus) == "function" then api.CloseDropDownMenus() end
end

local function sortedCrafters(recipe)
    local owners, seen = {}, {}
    for _, owner in ipairs(recipe.knownBy or {}) do
        if type(owner) == "table" and type(owner.key) == "string"
            and type(owner.name) == "string" and type(owner.realm) == "string"
            and not seen[owner.key] then
            owners[#owners + 1] = owner
            seen[owner.key] = true
        end
    end
    table.sort(owners, function(a, b)
        local an, bn = string.lower(a.name), string.lower(b.name)
        if an ~= bn then return an < bn end
        local ar, br = string.lower(a.realm), string.lower(b.realm)
        if ar ~= br then return ar < br end
        return a.key < b.key
    end)
    return owners
end

local function selectCrafter(details, key)
    local owner
    for _, candidate in ipairs(details.crafters) do
        if candidate.key == key then owner = candidate; break end
    end
    if key ~= nil and not owner then return end
    details.selectedCrafterKey = owner and owner.key or nil
    local label = owner and (owner.name .. "-" .. owner.realm) or "Select crafter"
    closeCrafterMenu(details)
    if details.nativeDropdown then
        details.api.UIDropDownMenu_SetSelectedValue(details.crafterDropdown, details.selectedCrafterKey)
        details.api.UIDropDownMenu_SetText(details.crafterDropdown, label)
    else
        details.crafterDropdown:SetText(label .. "   v")
    end
    details.crafterStatus:SetText(owner
        and ("Last-known recipe knowledge\nSaved: " .. (owner.savedDate or "Date unavailable"))
        or "No known crafters in saved records.")
end

local function updateCrafters(details, recipe, preserveSelection)
    local previous = preserveSelection and details.selectedCrafterKey or nil
    details.crafters = sortedCrafters(recipe)
    if details.nativeDropdown and #details.crafters > MAX_NATIVE_CRAFTERS then
        closeCrafterMenu(details)
        details.crafterDropdown:Hide()
        createCrafterDropdown(details, true)
    end
    local selected
    for _, owner in ipairs(details.crafters) do
        if owner.key == previous then selected = previous; break end
    end
    selectCrafter(details, selected or (details.crafters[1] and details.crafters[1].key))
end

createCrafterDropdown = function(details, forceScrollable)
    local api = details.api
    details.nativeDropdown = not forceScrollable and #details.crafters <= MAX_NATIVE_CRAFTERS
        and type(api.UIDropDownMenu_Initialize) == "function"
        and type(api.UIDropDownMenu_CreateInfo) == "function"
        and type(api.UIDropDownMenu_AddButton) == "function"
        and type(api.UIDropDownMenu_SetText) == "function"
        and type(api.UIDropDownMenu_SetSelectedValue) == "function"
        and type(api.UIDropDownMenu_SetWidth) == "function"
    if details.nativeDropdown then
        local dropdown = api.CreateFrame("Frame", "GuildGearMemoryRecipeCrafterDropdown", details, "UIDropDownMenuTemplate")
        dropdown:SetPoint("BOTTOMLEFT", details, "BOTTOMLEFT", 2, 110)
        api.UIDropDownMenu_SetWidth(dropdown, 370)
        details.crafterDropdown = dropdown
        api.UIDropDownMenu_Initialize(dropdown, function()
            for _, owner in ipairs(details.crafters) do
                local key = owner.key
                local info = api.UIDropDownMenu_CreateInfo()
                info.text = owner.name .. "-" .. owner.realm
                info.value, info.checked = key, details.selectedCrafterKey == key
                info.func = function() selectCrafter(details, key) end
                api.UIDropDownMenu_AddButton(info)
            end
        end)
        return
    end

    -- A scrollable choice menu keeps clients without the legacy dropdown API usable.
    local dropdown = api.CreateFrame("Button", nil, details, "UIPanelButtonTemplate")
    dropdown:SetSize(396, 26)
    dropdown:SetPoint("BOTTOMLEFT", details, "BOTTOMLEFT", 20, 116)
    details.crafterDropdown = dropdown
    local menu = api.CreateFrame("Frame", nil, details, "BasicFrameTemplateWithInset")
    menu:SetSize(396, 220)
    menu:SetPoint("BOTTOMLEFT", dropdown, "TOPLEFT", 0, 4)
    menu.TitleText:SetText("Known crafters")
    menu:Hide()
    details.crafterMenu, details.crafterButtons = menu, {}
    local scroll = api.CreateFrame("ScrollFrame", nil, menu, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", menu, "TOPLEFT", 10, -30)
    scroll:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -30, 10)
    local content = api.CreateFrame("Frame", nil, scroll)
    content:SetSize(352, 1)
    scroll:SetScrollChild(content)
    dropdown:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide(); return end
        if #details.crafters == 0 then return end
        for index, owner in ipairs(details.crafters) do
            local button = details.crafterButtons[index]
            if not button then
                button = api.CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
                button:SetSize(352, 26)
                button:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * 28)
                button:SetScript("OnClick", function(self) selectCrafter(details, self.crafterKey) end)
                details.crafterButtons[index] = button
            end
            button.crafterKey = owner.key
            button:SetText(owner.name .. "-" .. owner.realm)
            button:Show()
        end
        for index = #details.crafters + 1, #details.crafterButtons do details.crafterButtons[index]:Hide() end
        content:SetHeight(math.max(1, #details.crafters * 28))
        scroll:SetVerticalScroll(0)
        menu:Show()
    end)
end

local function renderMaterials(details, model)
    details.materialModel = model
    details.materialStatus:SetText(model.message or (#model.materials == 0 and "No crafting materials required." or ""))
    local rowIndex, y = 0, 0
    local function addRow(label, icon, heading)
        rowIndex = rowIndex + 1
        local row = details.materialRows[rowIndex]
        if not row then
            row = details.api.CreateFrame("Frame", nil, details.materialContent)
            row:SetSize(380, 32)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(24, 24)
            row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
            row.label = text(row, "GameFontHighlightSmall", "TOPLEFT", row, "TOPLEFT", 40, -8, 332)
            details.materialRows[rowIndex] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", details.materialContent, "TOPLEFT", 0, -y)
        row.label:ClearAllPoints()
        row.label:SetPoint("TOPLEFT", row, "TOPLEFT", heading and 0 or 40, -8)
        row.label:SetWidth(heading and 372 or 332)
        row.label:SetText(label)
        local rowHeight = math.max(32, row.label:GetStringHeight() + 16)
        row:SetHeight(rowHeight)
        row.label:SetTextColor(heading and 1 or 0.9, heading and 0.82 or 0.9, heading and 0 or 0.9)
        if heading then row.icon:Hide() else row.icon:SetTexture(icon or UNKNOWN_ICON); row.icon:Show() end
        row:Show()
        y = y + rowHeight
    end
    for _, group in ipairs(model.materials) do
        local label = (group.optional and "Optional: " or "Required: ") .. group.name .. " x" .. group.quantity
        if #group.choices > 1 then label = label .. " (choose one)" end
        addRow(label, nil, true)
        for _, choice in ipairs(group.choices) do addRow(choice.name, choice.icon, false) end
    end
    for index = rowIndex + 1, #details.materialRows do details.materialRows[index]:Hide() end
    details.materialContent:SetHeight(math.max(1, y))
    details.materialScroll:SetVerticalScroll(0)
end

local function createWindow(browser, recipe)
    local api = browser.api
    local name = "GuildGearMemoryRecipeDetailsFrame"
    local details = api.CreateFrame("Frame", name, api.UIParent, "BasicFrameTemplateWithInset")
    details.api = api
    details:SetSize(440, 560)
    details:SetPoint("CENTER", api.UIParent, "CENTER", 100, 0)
    details:SetFrameStrata("DIALOG")
    details:SetClampedToScreen(true)
    details:SetMovable(true)
    details:EnableMouse(true)
    details:RegisterForDrag("LeftButton")
    details:SetScript("OnDragStart", function(self) self:StartMoving() end)
    details:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    details.TitleText:SetText("Recipe details")
    details.closeButton = details.CloseButton or api.CreateFrame("Button", nil, details, "UIPanelCloseButton")
    details.closeButton:SetPoint("TOPRIGHT", details, "TOPRIGHT", -2, -2)
    details.closeButton:SetScript("OnClick", function() details:Hide() end)
    details.recipeIcon = details:CreateTexture(nil, "ARTWORK")
    details.recipeIcon:SetSize(48, 48)
    details.recipeIcon:SetPoint("TOPLEFT", details, "TOPLEFT", 20, -42)
    details.recipeName = text(details, "GameFontNormalLarge", "TOPLEFT", details, "TOPLEFT", 82, -44, 326)
    details.recipeName:SetHeight(36)
    if details.recipeName.SetMaxLines then details.recipeName:SetMaxLines(2) end
    details.professionName = text(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", 82, -84, 326)
    text(details, "GameFontNormal", "TOPLEFT", details, "TOPLEFT", 20, -108):SetText("Crafting materials")
    details.materialStatus = text(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", 20, -128, 392)
    details.materialStatus:SetHeight(40)
    details.materialScroll = api.CreateFrame("ScrollFrame", nil, details, "UIPanelScrollFrameTemplate")
    details.materialScroll:SetPoint("TOPLEFT", details, "TOPLEFT", 20, -174)
    details.materialScroll:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -40, 174)
    details.materialContent = api.CreateFrame("Frame", nil, details.materialScroll)
    details.materialContent:SetSize(380, 1)
    details.materialScroll:SetScrollChild(details.materialContent)
    details.materialRows, details.crafters = {}, sortedCrafters(recipe)
    text(details, "GameFontNormal", "BOTTOMLEFT", details, "BOTTOMLEFT", 20, 150):SetText("Known crafters")
    details.crafterStatus = text(details, "GameFontHighlightSmall", "BOTTOMLEFT", details, "BOTTOMLEFT", 20, 66, 396)
    details.crafterStatus:SetHeight(40)
    text(details, "GameFontDisableSmall", "BOTTOMLEFT", details, "BOTTOMLEFT", 20, 24, 396)
        :SetText("Crafter knowledge is cached from saved profession records.")
    createCrafterDropdown(details)
    api.UISpecialFrames = api.UISpecialFrames or {}
    local registered = false
    for _, frameName in ipairs(api.UISpecialFrames) do if frameName == name then registered = true; break end end
    if not registered then table.insert(api.UISpecialFrames, name) end
    details:SetScript("OnHide", function(self)
        self:StopMovingOrSizing()
        self.selectedCrafterKey, self.recipeID = nil, nil
        self.crafters = {}
        closeCrafterMenu(self)
    end)
    details:Hide()
    browser.recipeDetailsFrame = details
    return details
end

function GGM.HideRecipeDetailsWindow(browser)
    if browser.recipeDetailsFrame then browser.recipeDetailsFrame:Hide() end
end

function GGM.ShowRecipeDetailsWindow(browser, recipe)
    if browser.activeTab ~= "Professions" or type(recipe) ~= "table" then return nil end
    local canonical
    for _, entry in ipairs((browser.professionCatalog or {}).recipes or {}) do
        if entry.recipeID == recipe.recipeID then canonical = entry; break end
    end
    if not canonical then return nil end
    local details = browser.recipeDetailsFrame or createWindow(browser, canonical)
    local preserveSelection = details.recipeID == canonical.recipeID
    details.recipeID = canonical.recipeID
    details.recipeName:SetText(canonical.name or "Unknown recipe")
    details.recipeIcon:SetTexture(canonical.outputIcon or UNKNOWN_ICON)
    details.professionName:SetText(browser.selectedProfession or "Profession")
    updateCrafters(details, canonical, preserveSelection)
    renderMaterials(details, GGM.BuildRecipeMaterialDetails(browser.api, canonical.recipeID))
    details:Show()
    return details
end

function GGM.RefreshRecipeDetailsWindow(browser)
    local details = browser.recipeDetailsFrame
    if not shown(details) then return end
    if browser.activeTab == "Professions" then
        for _, recipe in ipairs((browser.professionCatalog or {}).recipes or {}) do
            if recipe.recipeID == details.recipeID then
                details.recipeName:SetText(recipe.name or "Unknown recipe")
                details.recipeIcon:SetTexture(recipe.outputIcon or UNKNOWN_ICON)
                updateCrafters(details, recipe, true)
                return
            end
        end
    end
    GGM.HideRecipeDetailsWindow(browser)
end
