local _, GGM = ...

local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local MAX_NATIVE_CRAFTERS = 12
local WHISPER_COOLDOWN_SECONDS = 2
local createCrafterDropdown
local refreshCrafterWhisperState
local shown
local setActionMode
local updateTrackingControls
local renderMaterials

local function createUIPanelButton(api, parent, label, width, height)
    local button = api.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button.label = button.Text
    if not button.label then
        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
        local nativeSetText = button.SetText
        button.SetText = function(self, value)
            if nativeSetText then nativeSetText(self, value) end
            self.label:SetText(value or "")
        end
    end
    button:SetText(label)
    return button
end

local function isPublic(api, value)
    if type(api.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(api.issecretvalue, value)
    return ok and secret == false
end

local function parseAmount(api, value)
    if not isPublic(api, value) or type(value) ~= "string" or not value:match("^%d+$") then return nil end
    local amount = tonumber(value)
    if not amount or amount < 1 or amount > 999 or amount ~= math.floor(amount) then return nil end
    return amount
end

local function craftSafety(api)
    if type(api) ~= "table" or type(api.InCombatLockdown) ~= "function" then
        return false, "Crafting unavailable: safety check unavailable."
    end
    local ok, inCombat = pcall(api.InCombatLockdown)
    if not ok or not isPublic(api, inCombat) or type(inCombat) ~= "boolean" then
        return false, "Crafting unavailable: safety check unavailable."
    end
    if inCombat then return false, "Crafting unavailable during combat." end
    local trade = api.C_TradeSkillUI
    if type(trade) ~= "table" or type(trade.CraftRecipe) ~= "function"
        or type(trade.GetRecipeInfo) ~= "function" then
        return false, "Crafting unavailable: profession API unavailable."
    end
    return true
end

local function maxCraftable(details)
    local trade = details.api.C_TradeSkillUI
    local ok, info = pcall(trade.GetRecipeInfo, details.recipeID)
    if not ok or not isPublic(details.api, info) or type(info) ~= "table" then return nil end
    local craftable = rawget(info, "craftable")
    if not isPublic(details.api, craftable) or craftable ~= true then return nil end

    if type(trade.GetCraftableCount) ~= "function" then return nil end
    local countOK, maximum = pcall(trade.GetCraftableCount, details.recipeID)
    if not countOK or not isPublic(details.api, maximum) or type(maximum) ~= "number"
        or maximum < 0 or maximum ~= maximum or maximum == math.huge
        or maximum ~= math.floor(maximum) then return nil end
    return maximum
end

local function recipeIsCraftable(details)
    local trade = details.api.C_TradeSkillUI
    local ok, info = pcall(trade.GetRecipeInfo, details.recipeID)
    if not ok or not isPublic(details.api, info) or type(info) ~= "table" then return false end
    local craftable = rawget(info, "craftable")
    return isPublic(details.api, craftable) and craftable == true
end

local function liveRecipeKnown(details)
    local browser, api = details.browser, details.api
    if not browser or type(details.recipeID) ~= "number"
        or type(browser.selectedProfessionID) ~= "number"
        or browser.craftingContextSkillLineID ~= browser.selectedProfessionID then return false end
    if details.ownMode then return true end
    local trade = api.C_TradeSkillUI
    if type(trade) ~= "table" or type(trade.GetRecipeInfo) ~= "function" then return false end
    local activeSkillLineID
    if type(trade.GetBaseProfessionInfo) == "function" then
        local lineOK, info = pcall(trade.GetBaseProfessionInfo)
        if not lineOK or not isPublic(api, info) or type(info) ~= "table" then return false end
        activeSkillLineID = rawget(info, "professionID")
    elseif type(trade.GetTradeSkillLine) == "function" then
        local lineOK
        lineOK, activeSkillLineID = pcall(trade.GetTradeSkillLine)
        if not lineOK then return false end
    else
        return false
    end
    if not isPublic(api, activeSkillLineID)
        or activeSkillLineID ~= browser.selectedProfessionID then return false end
    local ok, info = pcall(trade.GetRecipeInfo, details.recipeID)
    if not ok or not isPublic(api, info) or type(info) ~= "table" then return false end
    local learned = rawget(info, "learned")
    if not isPublic(api, learned) or learned ~= true then return false end
    local spellBook = api.C_SpellBook
    if type(spellBook) ~= "table" or type(spellBook.IsSpellKnown) ~= "function" then return false end
    local knownOK, known = pcall(spellBook.IsSpellKnown, details.recipeID)
    return knownOK and isPublic(api, known) and known == true
end

local function openGuildCraftingContext(details)
    local browser = details.browser
    local trade = browser.api.C_TradeSkillUI
    if browser.professionLibraryMode ~= "All"
        or type(trade) ~= "table" or type(trade.GetRecipeInfo) ~= "function"
        or type(GGM.OpenSelectedProfessionContext) ~= "function" then return false end
    if browser.craftingContextSkillLineID == browser.selectedProfessionID then
        -- The browser owns this shared context: its All-mode filter model still
        -- needs live profession data after the recipe details window is closed.
        details.openedCraftingContext = false
        return true
    end
    local opened = GGM.OpenSelectedProfessionContext(browser, browser.selectedProfessionID, true)
    details.openedCraftingContext = false
    return opened
end

local function requestGuildCraftingContext(details)
    if openGuildCraftingContext(details) then
        details.craftingContextRecipeID = details.recipeID
    end
    setActionMode(details, details.browser.professionLibraryMode == "Own")
end

local function hideProfessionFrame(details)
    local frame = details.api.ProfessionsFrame or details.api.TradeSkillFrame
    if frame and type(GGM.HideBlizzardProfessionPanel) == "function" then
        GGM.HideBlizzardProfessionPanel(details.api, frame)
    elseif frame and type(frame.Hide) == "function" then
        pcall(frame.Hide, frame)
    end
    if frame and type(frame.SetFrameStrata) == "function" then
        pcall(frame.SetFrameStrata, frame, "MEDIUM")
    end
    if frame and type(frame.SetFrameLevel) == "function" then
        pcall(frame.SetFrameLevel, frame, 1)
    end
end

local function ensureCraftingContext(details)
    if not details.craftMode or not details.recipeID then return false end
    if details.craftingContextRecipeID == details.recipeID
        and details.browser.craftingContextSkillLineID == details.browser.selectedProfessionID then return true end
    if details.browser and details.browser.craftingContextSkillLineID == details.browser.selectedProfessionID then
        details.craftingContextRecipeID = details.recipeID
        return true
    end
    return false
end

local function showActionStatus(details, action)
    if details.craftMode and not details.ownMode then
        if action == "whisper" then
            details.craftStatus:Hide()
            details.whisperStatus:Show()
        else
            details.whisperStatus:Hide()
            details.craftStatus:Show()
        end
    end
end

local function updateCraftControls(details)
    if not details.createButton then return end
    local contextReady = details.craftMode == true and ensureCraftingContext(details)
    local safe, message = craftSafety(details.api)
    local amount = parseAmount(details.api, details.amountInput:GetText())
    local craftable = contextReady and safe and liveRecipeKnown(details) and recipeIsCraftable(details)
    local maximum = safe and maxCraftable(details) or nil
    details.maxCraftable = maximum
    details.createAllButton:SetText("Create All [" .. tostring(maximum or 0) .. "]")
    details.createButton:SetEnabled(craftable and amount ~= nil
        and (details.ownMode or maximum ~= nil) and (maximum == nil or amount <= maximum))
    details.createAllButton:SetEnabled(craftable and maximum ~= nil and maximum > 0)
    if details.craftStatus then
        if not contextReady then details.craftStatus:SetText("Crafting unavailable: profession context is not ready.")
        elseif not safe then details.craftStatus:SetText(message)
        elseif not craftable then details.craftStatus:SetText("This recipe cannot currently be crafted.")
        elseif maximum == nil then details.craftStatus:SetText(details.ownMode
            and "Create All availability is unavailable." or "Crafting quantity is unavailable.")
        elseif maximum == 0 then details.craftStatus:SetText("No crafts currently available.")
        elseif amount == nil then details.craftStatus:SetText("Enter an amount from 1 to " .. maximum .. ".")
        elseif amount > maximum then details.craftStatus:SetText("Amount exceeds the available quantity.")
        else details.craftStatus:SetText("") end
        showActionStatus(details, "craft")
    end
end

local function craftRecipe(details, quantity)
    local currentRecipe = false
    if details.browser and details.browser.activeTab == "Professions" and shown(details) then
        for _, recipe in ipairs((details.browser.professionCatalog or {}).recipes or {}) do
            if recipe.recipeID == details.recipeID then currentRecipe = true; break end
        end
    end
    if not currentRecipe then
        details.craftStatus:SetText("Crafting unavailable: recipe selection is stale.")
        showActionStatus(details, "craft")
        return false
    end
    if not details.craftMode or not details.browser
        or details.browser.craftingContextSkillLineID ~= details.browser.selectedProfessionID then
        details.craftStatus:SetText("Crafting unavailable: profession context is not ready.")
        showActionStatus(details, "craft")
        return false
    end
    local safe, message = craftSafety(details.api)
    local maximum = safe and maxCraftable(details) or nil
    if not safe then details.craftStatus:SetText(message); showActionStatus(details, "craft"); return false end
    if not liveRecipeKnown(details) or not recipeIsCraftable(details)
        or (not details.ownMode and maximum == nil)
        or not quantity or quantity < 1 or (maximum and quantity > maximum) then
        details.craftStatus:SetText("Crafting quantity is unavailable.")
        showActionStatus(details, "craft")
        return false
    end
    local ok, result = pcall(details.api.C_TradeSkillUI.CraftRecipe, details.recipeID, quantity)
    if not ok or (result ~= nil and result ~= true) then
        details.craftStatus:SetText("Crafting could not be started.")
        showActionStatus(details, "craft")
        return false
    end
    details.craftStatus:SetText("Craft request accepted.")
    showActionStatus(details, "craft")
    return true
end

local function chatSendFunction(api)
    local chatInfo = api.C_ChatInfo
    if type(chatInfo) == "table" then
        if type(chatInfo.SendChatMessage) == "function" then return chatInfo.SendChatMessage end
        if type(api.SendChatMessage) == "function" then return api.SendChatMessage end
        return nil
    end
    if chatInfo == nil and type(api.SendChatMessage) == "function" then return api.SendChatMessage end
    return nil
end

local function whisperSafety(api)
    if type(api.InCombatLockdown) ~= "function" then return false, "Whisper unavailable: safety check unavailable." end
    local combatOK, inCombat = pcall(api.InCombatLockdown)
    if not combatOK or not isPublic(api, inCombat) or type(inCombat) ~= "boolean" then
        return false, "Whisper unavailable: safety check unavailable."
    end
    if inCombat then return false, "Whisper unavailable during combat." end

    local chatInfo = api.C_ChatInfo
    if type(chatInfo) ~= "table" or type(chatInfo.InChatMessagingLockdown) ~= "function" then
        return false, "Whisper unavailable: chat safety check unavailable."
    end
    local restrictionOK, restricted = pcall(chatInfo.InChatMessagingLockdown)
    if not restrictionOK or not isPublic(api, restricted) or type(restricted) ~= "boolean" then
        return false, "Whisper unavailable: chat safety check unavailable."
    end
    if restricted then return false, "Whisper unavailable: chat is restricted." end
    if not chatSendFunction(api) then return false, "Whisper unavailable: chat API unavailable." end

    if type(api.GetTime) ~= "function" then return false, "Whisper unavailable: cooldown check unavailable." end
    local timeOK, now = pcall(api.GetTime)
    if not timeOK or not isPublic(api, now) or type(now) ~= "number"
        or now ~= now or now < 0 or now == math.huge then
        return false, "Whisper unavailable: cooldown check unavailable."
    end
    return true, nil, now
end

local function updateWhisperButton(details)
    if not details.whisperButton then return end
    local amount = parseAmount(details.api, details.amountInput:GetText())
    local selected = details.selectedCrafterKey ~= nil
    local safetyOK, _, now = whisperSafety(details.api)
    local cooldownOK = safetyOK and (details.lastWhisperAt == nil
        or now - details.lastWhisperAt >= WHISPER_COOLDOWN_SECONDS)
    details.whisperButton:SetEnabled(selected and amount ~= nil
        and details.crafterPresence == "online" and cooldownOK == true)
end

refreshCrafterWhisperState = function(details, actionMessage, checkRoster)
    if not details or not details.whisperStatus then return end
    local explicitMessage = actionMessage ~= nil
    if checkRoster ~= false then
        details.crafterPresence = GGM.GetCrafterRosterStatus(details.api, details.selectedCrafterKey)
    end
    local statusText = details.crafterPresence == "online" and "Online (guild roster)"
        or details.crafterPresence == "offline" and "Offline (guild roster)"
        or "Unavailable (guild roster)"
    details.whisperPresenceStatus:SetText(statusText)
    if not actionMessage then
        if details.crafterPresence == "online" then
            local safe, safetyMessage = whisperSafety(details.api)
            if not safe then actionMessage = safetyMessage
            elseif not parseAmount(details.api, details.amountInput:GetText()) then
                actionMessage = "Enter an amount from 1 to 999."
            end
        elseif details.crafterPresence == "offline" then
            actionMessage = "Selected crafter is offline."
        elseif details.selectedCrafterKey then
            actionMessage = "Guild roster status is unavailable."
        end
    end
    details.whisperStatus:SetText(actionMessage or "")
    if explicitMessage then showActionStatus(details, "whisper") end
    updateWhisperButton(details)
end

local function scheduleCooldownRefresh(details)
    local timer = details.api.C_Timer
    if type(timer) == "table" and type(timer.After) == "function" then
        pcall(timer.After, WHISPER_COOLDOWN_SECONDS, function()
            if shown(details) then updateWhisperButton(details) end
        end)
    end
end

local function sendCrafterWhisper(details)
    local api = details.api
    local amount = parseAmount(api, details.amountInput:GetText())
    if not amount then
        refreshCrafterWhisperState(details, "Enter an amount from 1 to 999.", false)
        updateWhisperButton(details)
        return
    end
    if not details.selectedCrafterKey then
        refreshCrafterWhisperState(details, "Select a crafter first.", false)
        return
    end
    local selectedKnownCrafter = false
    for _, crafter in ipairs(details.crafters or {}) do
        if crafter.key == details.selectedCrafterKey then selectedKnownCrafter = true; break end
    end
    if not selectedKnownCrafter then
        refreshCrafterWhisperState(details, "Whisper unavailable: crafter selection is stale.", false)
        return
    end

    local presence = GGM.GetCrafterRosterStatus(api, details.selectedCrafterKey)
    details.crafterPresence = presence
    if presence ~= "online" then
        refreshCrafterWhisperState(details,
            presence == "offline" and "Selected crafter is offline."
            or "Guild roster status is unavailable.", false)
        return
    end

    local safe, safetyMessage, now = whisperSafety(api)
    if not safe then
        refreshCrafterWhisperState(details, safetyMessage, false)
        return
    end
    if details.lastWhisperAt ~= nil and now - details.lastWhisperAt < WHISPER_COOLDOWN_SECONDS then
        refreshCrafterWhisperState(details, "Please wait before sending another request.", false)
        return
    end

    local recipeName = details.currentRecipeName
    if not isPublic(api, recipeName) or type(recipeName) ~= "string" or recipeName == ""
        or #recipeName > 512 or recipeName:find("%c") then
        refreshCrafterWhisperState(details, "Whisper unavailable: recipe name unavailable.", false)
        return
    end
    local message = "Hi! Do you have time to craft " .. amount .. " x " .. recipeName .. " for me?"
    if #message > 255 then
        refreshCrafterWhisperState(details, "Whisper unavailable: recipe name is too long.", false)
        return
    end
    local send = chatSendFunction(api)
    if not send then
        refreshCrafterWhisperState(details, "Whisper unavailable: chat API unavailable.", false)
        return
    end
    details.lastWhisperAt = now
    scheduleCooldownRefresh(details)
    local sendOK, sendResult = pcall(send, message, "WHISPER", nil, details.selectedCrafterKey)
    if not sendOK then
        refreshCrafterWhisperState(details, "Whisper unavailable: request could not be sent.", false)
        return
    end
    if sendResult ~= nil and not isPublic(api, sendResult) then
        refreshCrafterWhisperState(details, "Whisper unavailable: request could not be sent.", false)
        return
    end
    if sendResult == false or (sendResult ~= nil and type(sendResult) ~= "boolean") then
        refreshCrafterWhisperState(details, "Whisper unavailable: request could not be sent.", false)
        return
    end

    refreshCrafterWhisperState(details, "Request attempted; delivery is not confirmed.", false)
end

local WINDOW_WIDTH, WINDOW_HEIGHT = 540, 620
local CONTENT_WIDTH, MATERIAL_WIDTH = 468, 424

local function applyTextTheme(label, tone)
    local theme = GGM.UITheme
    local color = theme and theme[tone or "text"]
    if color and label and type(label.SetTextColor) == "function" then
        label:SetTextColor(color[1], color[2], color[3], color[4] or 1)
    end
end

local function border(panel, inset, tone)
    local theme = GGM.UITheme or {}
    local color = theme[tone or "border"] or { 0.48, 0.30, 0.10, 1 }
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = panel:CreateTexture(nil, "BORDER")
        local top = side == "TOP" or side == "LEFT" or side == "RIGHT"
        local bottom = side == "BOTTOM" or side == "LEFT" or side == "RIGHT"
        if top then edge:SetPoint("TOP" .. (side == "RIGHT" and "RIGHT" or "LEFT"), panel,
            "TOP" .. (side == "RIGHT" and "RIGHT" or "LEFT"), side == "RIGHT" and -inset or inset, -inset) end
        if bottom then edge:SetPoint("BOTTOM" .. (side == "RIGHT" and "RIGHT" or "LEFT"), panel,
            "BOTTOM" .. (side == "RIGHT" and "RIGHT" or "LEFT"), side == "RIGHT" and -inset or inset, inset) end
        if side == "TOP" or side == "BOTTOM" then
            edge:SetPoint(side .. "RIGHT", panel, side .. "RIGHT", -inset, side == "TOP" and -inset or inset)
            edge:SetHeight(1)
        else edge:SetWidth(1) end
        edge:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    end
end

local function surface(api, parent, kind, backgroundOwner, sublevel)
    local panel = api.CreateFrame("Frame", nil, parent)
    -- Decorative surfaces share the parent's level so their background cannot
    -- cover text/controls drawn on the parent frame.
    if panel.SetFrameLevel and parent.GetFrameLevel then panel:SetFrameLevel(parent:GetFrameLevel()) end
    -- Permanent sheets belong to the window's texture stack. Equal-level
    -- sibling frames do not provide a reliable background ordering contract.
    if backgroundOwner then
        panel.background = backgroundOwner:CreateTexture(nil, "BACKGROUND", nil, sublevel)
    end
    GGM.ApplyJournalSurface(panel, kind or "parchment")
    if kind == "recipe" then
        panel.background:SetTexture("Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\recipe-page.blp")
        return panel
    end
    border(panel, 0, "border")
    border(panel, 3, "borderSoft")
    return panel
end

local function text(parent, font, point, relative, relativePoint, x, y, width)
    local label = parent:CreateFontString(nil, "OVERLAY", font)
    label:SetPoint(point, relative, relativePoint, x, y)
    label:SetJustifyH("LEFT")
    if width then label:SetWidth(width) end
    if label.SetJustifyV then label:SetJustifyV("TOP") end
    if type(GGM.ApplyJournalFont) == "function" then
        local sizes = { GameFontNormalLarge = 20, GameFontNormal = 16,
            GameFontHighlightSmall = 14, GameFontDisableSmall = 13 }
        GGM.ApplyJournalFont(label, sizes[font] or 14,
            (font == "GameFontNormalLarge" or font == "GameFontNormal") and "bold" or nil)
    end
    applyTextTheme(label, "text")
    return label
end

shown = function(frame)
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
        and ("Last-known recipe\nSaved: " .. (owner.savedDate or "Date unavailable"))
        or "No known crafters in saved records.")
    refreshCrafterWhisperState(details)
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
        dropdown:SetPoint("BOTTOMLEFT", details, "BOTTOMLEFT", 20, 180)
        api.UIDropDownMenu_SetWidth(dropdown, CONTENT_WIDTH - 40)
        for _, key in ipairs({ "Left", "Middle", "Right" }) do
            if dropdown[key] and dropdown[key].Hide then dropdown[key]:Hide() end
        end
        -- Legacy dropdowns offset their visible control by 16 UI units.
        local paper = surface(api, dropdown, "button")
        paper:SetPoint("TOPLEFT", dropdown, "TOPLEFT", 16, -4)
        paper:SetSize(CONTENT_WIDTH, 32)
        if paper.SetFrameLevel and dropdown.GetFrameLevel then
            paper:SetFrameLevel(dropdown:GetFrameLevel())
        end
        if dropdown.Text then
            GGM.ApplyJournalFont(dropdown.Text, 15)
            applyTextTheme(dropdown.Text, "text")
            dropdown.Text:ClearAllPoints()
            dropdown.Text:SetPoint("LEFT", dropdown, "LEFT", 28, -5)
            dropdown.Text:SetWidth(CONTENT_WIDTH - 48)
            dropdown.Text:SetJustifyH("LEFT")
        end
        if dropdown.Button then
            dropdown.Button:ClearAllPoints()
            dropdown.Button:SetPoint("TOPLEFT", dropdown, "TOPLEFT", CONTENT_WIDTH - 16, -8)
            dropdown.Button:SetSize(24, 24)
        end
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
    local dropdown = type(GGM.CreateFlatButton) == "function"
        and GGM.CreateFlatButton(api, details, "Select crafter   v", CONTENT_WIDTH, 34, "secondary")
        or nil
    if not dropdown then dropdown = api.CreateFrame("Button", nil, details, "UIPanelButtonTemplate") end
    dropdown:SetSize(CONTENT_WIDTH, 34)
    dropdown:SetPoint("BOTTOMLEFT", details, "BOTTOMLEFT", 36, 174)
    if dropdown.label then
        dropdown.label:ClearAllPoints()
        dropdown.label:SetPoint("LEFT", dropdown, "LEFT", 12, 0)
        dropdown.label:SetWidth(CONTENT_WIDTH - 24)
        dropdown.label:SetJustifyH("LEFT")
        GGM.ApplyJournalFont(dropdown.label, 15)
    end
    details.crafterDropdown = dropdown
    local menu = surface(api, details)
    menu:SetSize(CONTENT_WIDTH, 220)
    menu:SetPoint("BOTTOMLEFT", dropdown, "TOPLEFT", 0, 4)
    if menu.SetFrameLevel and dropdown.GetFrameLevel then menu:SetFrameLevel(dropdown:GetFrameLevel() + 10) end
    text(menu, "GameFontNormal", "TOPLEFT", menu, "TOPLEFT", 12, -12, CONTENT_WIDTH - 24):SetText("Known crafters")
    menu:Hide()
    details.crafterMenu, details.crafterButtons = menu, {}
    local scroll = api.CreateFrame("ScrollFrame", nil, menu, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", menu, "TOPLEFT", 12, -40)
    scroll:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -34, 12)
    local content = api.CreateFrame("Frame", nil, scroll)
    content:SetSize(CONTENT_WIDTH - 46, 1)
    scroll:SetScrollChild(content)
    dropdown:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide(); return end
        if #details.crafters == 0 then return end
        for index, owner in ipairs(details.crafters) do
            local button = details.crafterButtons[index]
            if not button then
                button = type(GGM.CreateFlatButton) == "function"
                    and GGM.CreateFlatButton(api, content, owner.name .. "-" .. owner.realm, CONTENT_WIDTH - 46, 30, "ghost")
                    or nil
                if not button then button = api.CreateFrame("Button", nil, content, "UIPanelButtonTemplate") end
                button:SetSize(CONTENT_WIDTH - 46, 30)
                button:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * 34)
                if button.label then button.label:SetWidth(CONTENT_WIDTH - 70) end
                button:SetScript("OnClick", function(self) selectCrafter(details, self.crafterKey) end)
                details.crafterButtons[index] = button
            end
            button.crafterKey = owner.key
            button:SetText(owner.name .. "-" .. owner.realm)
            button:Show()
        end
        for index = #details.crafters + 1, #details.crafterButtons do details.crafterButtons[index]:Hide() end
        content:SetHeight(math.max(1, #details.crafters * 34))
        scroll:SetVerticalScroll(0)
        menu:Show()
    end)
end

local function materialBankNotes(details, model)
    local itemIDs = {}
    for _, group in ipairs(model.materials) do
        for _, choice in ipairs(group.choices) do
            if choice.itemID then itemIDs[choice.itemID] = true end
        end
    end
    if not next(itemIDs) then return {} end
    local locations = GGM.BuildMaterialBankItemLocations(details.api, itemIDs,
        rawget(details.api, "TheGuildBookBankDB"))
    local currentKey = GGM.GetMaterialBankPlayerKey(details.api)
    local notes = {}
    for itemID, banks in pairs(locations) do
        local lines = {}
        for _, bank in ipairs(banks) do
            if bank.count and bank.count > 0 then
                local count = (bank.partial and "at least " or "") .. bank.count
                local observation = bank.partial and "last-known; incomplete" or "last-known"
                local line = bank.key == currentKey and ("Your bank: " .. count)
                    or (bank.key .. ": " .. count .. " in personal bank")
                lines[#lines + 1] = line .. " (" .. observation .. ")"
            end
        end
        notes[itemID] = table.concat(lines, "\n")
    end
    return notes
end

renderMaterials = function(details, model, preserveScroll)
    local scrollPosition = preserveScroll and details.materialScroll:GetVerticalScroll() or 0
    details.materialModel = model
    details.pendingMaterialItemIDs = model.pendingItemIDs or {}
    local bankNotes = materialBankNotes(details, model)
    local message = model.message or (#model.materials == 0 and "No crafting materials required." or "")
    details.materialStatus:SetText(message)
    if message == "" then details.materialStatus:Hide() else details.materialStatus:Show() end
    details.materialScroll:ClearAllPoints()
    details.materialScroll:SetPoint("TOPLEFT", details, "TOPLEFT", 46, message == "" and -210 or -244)
    details.materialScroll:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -70, 274)
    if #model.materials == 0 then details.materialScroll:Hide() else details.materialScroll:Show() end
    local rowIndex, y = 0, 0
    local function addRow(label, icon, heading, itemID)
        rowIndex = rowIndex + 1
        local row = details.materialRows[rowIndex]
        if not row then
            row = details.api.CreateFrame("Frame", nil, details.materialContent)
            row:SetSize(MATERIAL_WIDTH, 32)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(24, 24)
            row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
            row.label = text(row, "GameFontHighlightSmall", "TOPLEFT", row, "TOPLEFT", 40, -8, MATERIAL_WIDTH - 48)
            row.bankNote = text(row, "GameFontDisableSmall", "TOPLEFT", row, "TOPLEFT", 40, -28, MATERIAL_WIDTH - 48)
            applyTextTheme(row.bankNote, "muted")
            details.materialRows[rowIndex] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", details.materialContent, "TOPLEFT", 0, -y)
        row.label:ClearAllPoints()
        row.label:SetPoint("TOPLEFT", row, "TOPLEFT", heading and 0 or 40, -8)
        row.label:SetWidth(heading and MATERIAL_WIDTH - 8 or MATERIAL_WIDTH - 48)
        row.label:SetText(label)
        local rowHeight = math.max(32, row.label:GetStringHeight() + 16)
        local note = itemID and bankNotes[itemID] or ""
        row.bankNote:SetText(note or "")
        if note and note ~= "" then
            row.bankNote:ClearAllPoints()
            row.bankNote:SetPoint("TOPLEFT", row, "TOPLEFT", 40, -rowHeight + 4)
            rowHeight = rowHeight + row.bankNote:GetStringHeight() + 4
            row.bankNote:Show()
        else row.bankNote:Hide() end
        row:SetHeight(rowHeight)
        applyTextTheme(row.label, heading and "text" or "textSoft")
        if heading then row.icon:Hide() else row.icon:SetTexture(icon or UNKNOWN_ICON); row.icon:Show() end
        row:Show()
        y = y + rowHeight
    end
    for _, group in ipairs(model.materials) do
        if #group.choices == 1 then
            local choice = group.choices[1]
            addRow(choice.name .. "  × " .. group.quantity .. (group.optional and "  · Optional" or "  · Required"), choice.icon, false, choice.itemID)
        else
            local label = (group.optional and "Optional: " or "Required: ") .. group.name .. " × " .. group.quantity
            if #group.choices > 1 then label = label .. " (choose one)" end
            addRow(label, nil, true)
            for _, choice in ipairs(group.choices) do addRow(choice.name, choice.icon, false, choice.itemID) end
        end
    end
    for index = rowIndex + 1, #details.materialRows do details.materialRows[index]:Hide() end
    details.materialContent:SetHeight(math.max(1, y))
    if preserveScroll and type(details.materialScroll.GetVerticalScrollRange) == "function" then
        scrollPosition = math.min(scrollPosition, math.max(0, details.materialScroll:GetVerticalScrollRange()))
    end
    details.materialScroll:SetVerticalScroll(scrollPosition)
    if updateTrackingControls then updateTrackingControls(details) end
end

function GGM.RefreshRecipeMaterialBankNotes()
    local browser = GGM.guildGearBrowserFrame
    local details = browser and browser.recipeDetailsFrame
    if not shown(details) or not details.materialModel then return false end
    renderMaterials(details, details.materialModel, true)
    return true
end

updateTrackingControls = function(details)
    if not details.trackMaterialsButton then return end
    local tracked = GGM.LoadMaterialTracking(details.api, details.browser.db)
    if tracked and tracked.recipeID == details.recipeID then
        details.trackMaterialsButton:SetEnabled(true)
        return
    end
    local amount = parseAmount(details.api, details.amountInput:GetText())
    local snapshot = GGM.CreateMaterialTrackingSnapshot(details.api, details.recipeID,
        details.currentRecipeName, amount, details.materialModel)
    details.trackMaterialsButton:SetEnabled(snapshot ~= nil)
end

local function createWhisperControls(details)
    local api = details.api
    details.amountInput = api.CreateFrame("EditBox", nil, details)
    details.amountInput:SetSize(52, 30)
    details.amountInput:SetPoint("BOTTOMLEFT", details, "BOTTOMLEFT", 74, 88)
    GGM.ApplyJournalSurface(details.amountInput, "button")
    border(details.amountInput, 0, "border")
    GGM.ApplyJournalFont(details.amountInput, 16, "bold")
    details.amountInput:SetTextColor(0.19, 0.125, 0.07, 1)
    details.amountInput:SetJustifyH("CENTER")
    details.amountInput:SetAutoFocus(false)
    details.amountInput:SetNumeric(true)
    details.amountInput:SetMaxLetters(3)
    details.amountInput:SetText("1")
    details.amountInput:SetScript("OnTextChanged", function()
        refreshCrafterWhisperState(details, nil, false)
        updateCraftControls(details)
        updateTrackingControls(details)
    end)

    local function makeAmountButton(label, offset, delta)
        local button = createUIPanelButton(api, details, label, 30, 30)
        button:SetPoint("BOTTOMLEFT", details, "BOTTOMLEFT", offset, 88)
        button:SetScript("OnClick", function()
            local amount = parseAmount(api, details.amountInput:GetText()) or 1
            details.amountInput:SetText(tostring(math.max(1, math.min(999, amount + delta))))
        end)
        return button
    end
    details.amountMinusButton = makeAmountButton("−", 36, -1)
    details.amountPlusButton = makeAmountButton("+", 134, 1)

    details.whisperButton = createUIPanelButton(api, details, "Whisper crafter", 180, 30)
    details.whisperButton:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -36, 96)
    details.whisperButton:SetScript("OnClick", function() sendCrafterWhisper(details) end)

    details.openProfessionButton = createUIPanelButton(api, details, "Open profession", 180, 30)
    details.openProfessionButton:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -36, 64)
    details.openProfessionButton:SetScript("OnClick", function()
        requestGuildCraftingContext(details)
    end)

    details.createButton = createUIPanelButton(api, details, "Create", 180, 30)
    details.createButton:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -36, 106)
    details.createButton:SetScript("OnClick", function()
        craftRecipe(details, parseAmount(api, details.amountInput:GetText()))
    end)

    details.createAllButton = createUIPanelButton(api, details, "Create All [0]", 180, 30)
    details.createAllButton:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -36, 68)
    details.createAllButton:SetScript("OnClick", function()
        craftRecipe(details, details.maxCraftable)
    end)

    text(details, "GameFontHighlightSmall", "BOTTOMLEFT", details, "BOTTOMLEFT", 36, 126, 130)
        :SetText("Amount")

    details.whisperPresenceStatus = text(details, "GameFontHighlightSmall", "BOTTOMLEFT", details,
        "BOTTOMLEFT", 36, 59, CONTENT_WIDTH)
    details.whisperStatus = text(details, "GameFontHighlightSmall", "BOTTOMLEFT", details,
        "BOTTOMLEFT", 36, 25, CONTENT_WIDTH)
    details.whisperPresenceStatus:SetHeight(18)
    details.whisperStatus:SetHeight(32)

    details.craftStatus = text(details, "GameFontHighlightSmall", "BOTTOMLEFT", details,
        "BOTTOMLEFT", 36, 25, CONTENT_WIDTH)
    details.craftStatus:SetHeight(32)

    details.rosterEventFrame = api.CreateFrame("Frame", nil, details)
    details.rosterEventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
    details.rosterEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    details.rosterEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    details.rosterEventFrame:RegisterEvent("TRADE_SKILL_SHOW")
    details.rosterEventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
    details.rosterEventFrame:RegisterEvent("TRADE_SKILL_CRAFT_BEGIN")
    details.rosterEventFrame:RegisterEvent("TRADE_SKILL_CLOSE")
    details.rosterEventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    details.rosterEventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    local function refreshMaterialDetails()
        local model = GGM.BuildRecipeMaterialDetails(details.api, details.recipeID)
        local combatOK, inCombat = false, nil
        if model.state == "unavailable" and type(details.api.InCombatLockdown) == "function" then
            combatOK, inCombat = pcall(details.api.InCombatLockdown)
        end
        if model.state == "unavailable" and combatOK
            and isPublic(details.api, inCombat) and inCombat == true then
            details.retryMaterialsAfterCombat = true
            return false
        end
        details.retryMaterialsAfterCombat = nil
        renderMaterials(details, model, true)
        return true
    end
    details.rosterEventFrame:SetScript("OnEvent", function(_, event, ...)
        if not shown(details) then return end
        if event == "ITEM_DATA_LOAD_RESULT" then
            local itemID, success = ...
            if isPublic(details.api, itemID) and isPublic(details.api, success)
                and success == true and details.pendingMaterialItemIDs
                and details.pendingMaterialItemIDs[itemID] then
                refreshMaterialDetails()
            end
            return
        end
        if event == "PLAYER_REGEN_ENABLED" or event == "TRADE_SKILL_LIST_UPDATE"
            or event == "GET_ITEM_INFO_RECEIVED" then
            refreshMaterialDetails()
        end
        if event == "TRADE_SKILL_CLOSE" then
            details.craftingContextRecipeID = nil
            details.openedCraftingContext = nil
            details.browser.craftingContextSkillLineID = nil
            details.browser.craftingContextOpenedByGuildBook = nil
            details.pendingCraftQuantity = nil
            setActionMode(details, details.browser.professionLibraryMode == "Own")
            return
        end
        if details.ownMode and (event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE") then
            hideProfessionFrame(details)
            updateCraftControls(details)
            if details.pendingCraftQuantity then
                local quantity = details.pendingCraftQuantity
                details.pendingCraftQuantity = nil
                craftRecipe(details, quantity)
            end
        else
            refreshCrafterWhisperState(details)
            if event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_SHOW"
                or event == "TRADE_SKILL_CRAFT_BEGIN"
                or event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
                setActionMode(details, details.browser.professionLibraryMode == "Own")
            end
        end
    end)
    updateWhisperButton(details)
    updateCraftControls(details)
end

setActionMode = function(details, ownMode)
    local function visible(control, value)
        if not control then return end
        if value then control:Show() else control:Hide() end
    end
    details.ownMode = ownMode == true
    details.craftMode = details.ownMode or liveRecipeKnown(details)
    details.createButton:ClearAllPoints()
    details.createAllButton:ClearAllPoints()
    if details.craftMode and not details.ownMode then
        details.createButton:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -36, 64)
        details.createAllButton:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -36, 32)
        details.craftStatus:SetWidth(220)
        details.whisperStatus:SetWidth(220)
    else
        details.createButton:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -36, 106)
        details.createAllButton:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -36, 68)
        details.craftStatus:SetWidth(CONTENT_WIDTH)
        details.whisperStatus:SetWidth(CONTENT_WIDTH)
    end
    if details.crafterHeading then
        if details.ownMode then details.crafterHeading:SetText("CRAFTING")
        else details.crafterHeading:SetText("KNOWN CRAFTERS") end
    end
    if details.crafterDropdown then
        if details.ownMode then details.crafterDropdown:Hide() else details.crafterDropdown:Show() end
    end
    if details.crafterStatus then
        if details.ownMode then details.crafterStatus:SetText("") end
        visible(details.crafterStatus, not details.ownMode)
    end
    visible(details.whisperPresenceStatus, not details.ownMode)
    visible(details.whisperStatus, not details.ownMode)
    visible(details.whisperButton, not details.ownMode)
    visible(details.openProfessionButton, not details.ownMode and not details.craftMode)
    if details.openProfessionButton then
        local combatOK, inCombat = pcall(details.api.InCombatLockdown)
        local secretOK, secret = pcall(details.api.issecretvalue, inCombat)
        details.openProfessionButton:SetEnabled(combatOK and secretOK and secret == false
            and inCombat == false)
    end
    visible(details.createButton, details.craftMode)
    visible(details.createAllButton, details.craftMode)
    visible(details.craftStatus, details.craftMode)
    if details.craftMode then updateCraftControls(details) end
    if not details.ownMode then updateWhisperButton(details) end
end

local function setRecipeTitle(details, name)
    details.recipeName:SetText(name or "Unknown recipe")
    details.recipeName:SetHeight(math.min(56, math.max(28, details.recipeName:GetStringHeight())))
    details.professionName:ClearAllPoints()
    details.professionName:SetPoint("TOPLEFT", details.recipeName, "BOTTOMLEFT", 0, -6)
end

local function createWindow(browser, recipe)
    local api = browser.api
    local name = "GuildGearMemoryRecipeDetailsFrame"
    local details = api.CreateFrame("Frame", name, api.UIParent)
    details.api = api
    details.browser = browser
    details.background = details:CreateTexture(nil, "BACKGROUND", nil, -8)
    GGM.ApplyJournalSurface(details, "leather")
    details.paper = surface(api, details, "recipe", details, -7)
    details.paper:SetAllPoints(details)
    details:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    if details.SetScale and browser.GetScale then details:SetScale(browser:GetScale()) end
    details:SetPoint("CENTER", api.UIParent, "CENTER", 100, 0)
    details:SetFrameStrata("DIALOG")
    details:SetClampedToScreen(true)
    details:SetMovable(true)
    details:EnableMouse(true)
    details:RegisterForDrag("LeftButton")
    details:SetScript("OnDragStart", function(self) self:StartMoving() end)
    details:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    details.TitleText = text(details, "GameFontNormal", "TOPLEFT", details, "TOPLEFT", 36, -30, CONTENT_WIDTH - 44)
    details.TitleText:SetText("RECIPE DETAILS")
    applyTextTheme(details.TitleText, "muted")
    GGM.ApplyJournalFont(details.TitleText, 13, "bold")
    details.closeButton = api.CreateFrame("Button", nil, details, "UIPanelCloseButton")
    details.closeButton:SetSize(32, 32)
    details.closeButton:SetPoint("TOPRIGHT", details, "TOPRIGHT", -24, -22)
    details.closeButton:SetScript("OnClick", function() details:Hide() end)
    details.iconFrame = surface(api, details, "button", details, -5)
    details.iconFrame:SetSize(66, 66)
    details.iconFrame:SetPoint("TOPLEFT", details, "TOPLEFT", 36, -66)
    details.recipeIcon = details.iconFrame:CreateTexture(nil, "ARTWORK")
    details.recipeIcon:SetPoint("TOPLEFT", details.iconFrame, "TOPLEFT", 6, -6)
    details.recipeIcon:SetPoint("BOTTOMRIGHT", details.iconFrame, "BOTTOMRIGHT", -6, 6)
    details.recipeIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    details.recipeName = text(details, "GameFontNormalLarge", "TOPLEFT", details, "TOPLEFT", 118, -66, 374)
    GGM.ApplyJournalFont(details.recipeName, 24, "bold")
    details.recipeName:SetHeight(56)
    if details.recipeName.SetMaxLines then details.recipeName:SetMaxLines(2) end
    details.professionName = text(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", 118, -124, 374)
    applyTextTheme(details.professionName, "muted")
    GGM.ApplyJournalFont(details.professionName, 16, "italic")
    details.materialPanel = surface(api, details, "parchment", details, -6)
    details.materialPanel:SetPoint("TOPLEFT", details, "TOPLEFT", 32, -164)
    details.materialPanel:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -32, 262)
    details.materialPanel.background:SetColorTexture(0.93, 0.78, 0.51, 0.18)
    details.materialHeading = text(details, "GameFontNormal", "TOPLEFT", details, "TOPLEFT", 46, -180, 270)
    details.materialHeading:SetText("CRAFTING MATERIALS")
    details.materialStatus = text(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", 46, -208, 424)
    details.materialStatus:SetHeight(32)
    applyTextTheme(details.materialStatus, "muted")
    details.materialScroll = api.CreateFrame("ScrollFrame", nil, details, "UIPanelScrollFrameTemplate")
    details.materialScroll:SetPoint("TOPLEFT", details, "TOPLEFT", 36, -234)
    details.materialScroll:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", -56, 208)
    details.materialContent = api.CreateFrame("Frame", nil, details.materialScroll)
    details.materialContent:SetSize(MATERIAL_WIDTH, 1)
    details.materialScroll:SetScrollChild(details.materialContent)
    details.materialRows, details.crafters = {}, sortedCrafters(recipe)
    details.crafterHeading = text(details, "GameFontNormal", "BOTTOMLEFT", details, "BOTTOMLEFT", 36, 226, CONTENT_WIDTH)
    details.crafterHeading:SetText("KNOWN CRAFTERS")
    details.crafterStatus = text(details, "GameFontHighlightSmall", "BOTTOMLEFT", details, "BOTTOMLEFT", 198, 130, 306)
    details.crafterStatus:SetHeight(36)
    applyTextTheme(details.crafterStatus, "muted")
    details.cachedStatus = text(details, "GameFontDisableSmall", "BOTTOMLEFT", details, "BOTTOMLEFT", 36, 208, CONTENT_WIDTH)
    details.cachedStatus:SetHeight(16)
    details.cachedStatus:SetText("Recipe knowledge is cached.")
    applyTextTheme(details.cachedStatus, "muted")
    createWhisperControls(details)
    details.trackMaterialsButton = createUIPanelButton(api, details, "Track materials", 144, 26)
    details.trackMaterialsButton:SetPoint("TOPRIGHT", details, "TOPRIGHT", -46, -172)
    details.trackMaterialsButton:SetScript("OnClick", function()
        local tracked = GGM.LoadMaterialTracking(api, browser.db)
        if tracked and tracked.recipeID == details.recipeID then
            GGM.UntrackRecipeMaterials(api, browser.db)
            updateTrackingControls(details)
            return
        end
        local amount = parseAmount(api, details.amountInput:GetText())
        -- Read again at the user's click rather than trusting a stale schematic.
        local model = GGM.BuildRecipeMaterialDetails(api, details.recipeID)
        renderMaterials(details, model)
        GGM.TrackRecipeMaterials(api, browser.db, details.recipeID, details.currentRecipeName, amount, model)
    end)
    createCrafterDropdown(details)
    setActionMode(details, browser.professionLibraryMode == "Own")
    api.UISpecialFrames = api.UISpecialFrames or {}
    local registered = false
    for _, frameName in ipairs(api.UISpecialFrames) do if frameName == name then registered = true; break end end
    if not registered then table.insert(api.UISpecialFrames, name) end
    details:SetScript("OnHide", function(self)
        self:StopMovingOrSizing()
        if self.openedCraftingContext and self.browser.craftingContextOpenedByGuildBook then
            self.openedCraftingContext = nil
            local professionFrame = self.api.ProfessionsFrame or self.api.TradeSkillFrame
            if type(GGM.CloseBlizzardProfessionPanel) == "function" then
                GGM.CloseBlizzardProfessionPanel(self.api, professionFrame)
            end
            self.browser.craftingContextSkillLineID = nil
            self.browser.craftingContextOpenedByGuildBook = nil
        end
        self.selectedCrafterKey, self.recipeID = nil, nil
        self.craftingContextRecipeID = nil
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

local function findProfessionRecipe(browser, recipeID)
    for _, entry in ipairs((browser.professionCatalog or {}).recipes or {}) do
        if entry.recipeID == recipeID then return entry end
    end

    if browser.professionLibraryMode ~= "Own" or not browser.selectedProfessionID then return nil end
    local model = browser.professionRecipeFilterModel
    if type(model) ~= "table" or model.professionID ~= browser.selectedProfessionID
        or type(model.recipes) ~= "table" then
        return nil
    end
    for _, entry in ipairs(model.recipes) do
        if entry.recipeID == recipeID then return entry end
    end
end

function GGM.ShowRecipeDetailsWindow(browser, recipe)
    if browser.activeTab ~= "Professions" or type(recipe) ~= "table" then return nil end
    local canonical = findProfessionRecipe(browser, recipe.recipeID)
    if not canonical then return nil end
    local firstDisplay = browser.recipeDetailsFrame == nil
    local details = browser.recipeDetailsFrame or createWindow(browser, canonical)
    local preserveSelection = details.recipeID == canonical.recipeID
    if not preserveSelection then details.amountInput:SetText("1") end
    details.recipeID = canonical.recipeID
    openGuildCraftingContext(details)
    setActionMode(details, browser.professionLibraryMode == "Own")
    details.currentRecipeName = canonical.name
    setRecipeTitle(details, canonical.name)
    details.recipeIcon:SetTexture(canonical.outputIcon or UNKNOWN_ICON)
    details.professionName:SetText(browser.selectedProfession or "Profession")
    updateCrafters(details, canonical, preserveSelection)
    renderMaterials(details, GGM.BuildRecipeMaterialDetails(browser.api, canonical.recipeID))
    if GGM.ApplyRecipeDetailsWindowSettings then GGM.ApplyRecipeDetailsWindowSettings(browser) end
    if firstDisplay and GGM.PositionRecipeDetailsWindow then GGM.PositionRecipeDetailsWindow(browser, details) end
    details:Show()
    if details.SetFrameStrata then details:SetFrameStrata("TOOLTIP") end
    if details.Raise then details:Raise() end
    return details
end

function GGM.RefreshRecipeDetailsWindow(browser)
    local details = browser.recipeDetailsFrame
    if not shown(details) then return end
    if browser.activeTab == "Professions" then
        local recipe = findProfessionRecipe(browser, details.recipeID)
        if recipe then
            setRecipeTitle(details, recipe.name)
            details.recipeIcon:SetTexture(recipe.outputIcon or UNKNOWN_ICON)
            details.currentRecipeName = recipe.name
            updateCrafters(details, recipe, true)
            setActionMode(details, browser.professionLibraryMode == "Own")
            return
        end
    end
    GGM.HideRecipeDetailsWindow(browser)
end
