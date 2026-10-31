local _, GGM = ...

local function bounded(value, low, high, default)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        return default
    end
    return math.max(low, math.min(high, value))
end

-- Browsing is read-only: absent defaults become saved preferences only when
-- the options window explicitly asks for an editable settings table.
function GGM.ReadBrowserWindowSettings(db)
    local ui = type(db) == "table" and db.uiSettings
    local saved = type(ui) == "table" and ui.window
    if type(saved) ~= "table" then saved = {} end
    local scale = bounded(saved.scale, 0.75, 1.25, 1)
    local positionX, positionY
    if type(saved.positionX) == "number" and saved.positionX == saved.positionX
        and saved.positionX >= 0 and saved.positionX <= 1
        and type(saved.positionY) == "number" and saved.positionY == saved.positionY
        and saved.positionY >= 0 and saved.positionY <= 1 then
        positionX, positionY = saved.positionX, saved.positionY
    end
    return {
        scale = scale,
        recipeScale = bounded(saved.recipeScale, 0.75, 1.25, scale),
        opacity = bounded(saved.opacity, 0.6, 1, 1),
        locked = saved.locked == true,
        autoAlignRecipe = saved.autoAlignRecipe ~= false,
        manualProfessionSync = saved.manualProfessionSync == true,
        manualGearSync = saved.manualGearSync == true,
        positionX = positionX,
        positionY = positionY,
    }
end

function GGM.GetBrowserWindowSettings(db)
    if type(db) ~= "table" then return nil end
    local values = GGM.ReadBrowserWindowSettings(db)
    if type(db.uiSettings) ~= "table" then db.uiSettings = {} end
    if type(db.uiSettings.window) ~= "table" then db.uiSettings.window = {} end
    for key, value in pairs(values) do db.uiSettings.window[key] = value end
    return db.uiSettings.window
end

local function fittedScale(frame, root, requested)
    if root and root.GetWidth and root.GetHeight and frame.GetWidth and frame.GetHeight then
        local width, height = frame:GetWidth(), frame:GetHeight()
        local sw, sh = root:GetWidth(), root:GetHeight()
        if width > 0 and height > 0 and sw > 24 and sh > 24 then
            return math.max(0.01, math.min(requested, (sw - 24) / width, (sh - 24) / height))
        end
    end
    return requested
end

function GGM.ApplyBrowserWindowSettings(browser, db)
    local saved = GGM.ReadBrowserWindowSettings(db)
    if not browser or not saved then return end
    local root = browser.api.UIParent
    if browser.SetScale then browser:SetScale(fittedScale(browser, root, saved.scale)) end
    if browser.SetAlpha then browser:SetAlpha(saved.opacity) end
    if saved.positionX and saved.positionY and root and root.GetWidth and root.GetHeight then
        local width, height = root:GetWidth(), root:GetHeight()
        if width > 0 and height > 0 then
            browser:ClearAllPoints()
            browser:SetPoint("CENTER", root, "BOTTOMLEFT", saved.positionX * width, saved.positionY * height)
        end
    end
    if saved.locked and browser.StopMovingOrSizing then browser:StopMovingOrSizing() end
    GGM.ApplyRecipeDetailsWindowSettings(browser, db)
    if GGM.RefreshManualProfessionSync then GGM.RefreshManualProfessionSync(browser) end
    if GGM.RefreshGearSyncControls then GGM.RefreshGearSyncControls(browser) end
end

function GGM.ApplyRecipeDetailsWindowSettings(browser, db)
    if not browser then return end
    local saved = GGM.ReadBrowserWindowSettings(db or browser.db)
    if not saved then return end
    local root = browser.api and browser.api.UIParent
    local details = browser.recipeDetailsFrame
    if details then
        if details.SetScale then details:SetScale(fittedScale(details, root, saved.recipeScale)) end
        if details.SetAlpha then details:SetAlpha(saved.opacity) end
    end
end

function GGM.SaveGuildBookWindowPosition(browser)
    if not browser or type(browser.db) ~= "table" then return end
    local root = browser.api and browser.api.UIParent
    if not root or not root.GetWidth or not root.GetHeight or not browser.GetCenter then return end
    local width, height = root:GetWidth(), root:GetHeight()
    local centerX, centerY = browser:GetCenter()
    if width <= 0 or height <= 0 or type(centerX) ~= "number" or type(centerY) ~= "number" then return end
    local rootScale = root.GetEffectiveScale and root:GetEffectiveScale() or 1
    local browserScale = browser.GetEffectiveScale and browser:GetEffectiveScale() or rootScale
    if rootScale <= 0 or browserScale <= 0 then return end

    local saved = GGM.GetBrowserWindowSettings(browser.db)
    if not saved then return end
    saved.positionX = math.max(0, math.min(1, centerX * browserScale / (width * rootScale)))
    saved.positionY = math.max(0, math.min(1, centerY * browserScale / (height * rootScale)))
end

function GGM.CenterGuildBookWindow(browser)
    if not browser then return end
    if browser.StopMovingOrSizing then browser:StopMovingOrSizing() end
    browser:ClearAllPoints()
    browser:SetPoint("CENTER", browser.api.UIParent, "CENTER", 0, 0)
    local saved = GGM.GetBrowserWindowSettings(browser.db)
    if saved then
        saved.positionX = nil
        saved.positionY = nil
    end
end

function GGM.PositionRecipeDetailsWindow(browser, details)
    local saved = GGM.ReadBrowserWindowSettings(browser.db)
    if not saved or not saved.autoAlignRecipe then return end
    local root = browser.api.UIParent
    if not root or not root.GetEffectiveScale or not root.GetWidth or not root.GetHeight
        or not browser.GetEffectiveScale or not browser.GetLeft or not browser.GetRight
        or not browser.GetTop or not details.GetEffectiveScale then return end
    local left, right, top = browser:GetLeft(), browser:GetRight(), browser:GetTop()
    if not left or not right or not top then return end
    local rootScale, browserScale, detailScale =
        root:GetEffectiveScale(), browser:GetEffectiveScale(), details:GetEffectiveScale()
    if rootScale <= 0 or browserScale <= 0 or detailScale <= 0 then return end
    -- Work in physical pixels, then convert to the independent details frame's
    -- coordinates. Anchoring to UIParent lets either window move freely later.
    local screenWidth, screenHeight = root:GetWidth() * rootScale, root:GetHeight() * rootScale
    local width, height = details:GetWidth() * detailScale, details:GetHeight() * detailScale
    local gap = 8 * browserScale
    local x = right * browserScale + gap
    if x + width > screenWidth then x = left * browserScale - gap - width end
    x = math.max(0, math.min(x, screenWidth - width))
    local y = math.min(screenHeight, math.max(height, top * browserScale))
    details:StopMovingOrSizing()
    details:ClearAllPoints()
    details:SetPoint("TOPLEFT", root, "BOTTOMLEFT", x / detailScale, y / detailScale)
end

local function caption(parent, text, x, y)
    local font = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    font:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    font:SetText(text)
    return font
end

function GGM.RefreshWindowOptionsControls(frame, db)
    frame.windowDB = db
    local saved = GGM.GetBrowserWindowSettings(db)
    if not saved then return end
    frame.windowSettings = saved
    frame.updatingWindowControls = true
    frame.windowScale:SetValue(saved.scale * 100)
    frame.recipeScale:SetValue(saved.recipeScale * 100)
    frame.windowOpacity:SetValue(saved.opacity * 100)
    frame.lockWindow:SetChecked(saved.locked)
    frame.alignRecipe:SetChecked(saved.autoAlignRecipe)
    frame.manualProfessionSync:SetChecked(saved.manualProfessionSync)
    frame.manualGearSync:SetChecked(saved.manualGearSync)
    frame.windowScale.caption:SetText("Main window size: " .. math.floor(saved.scale * 100 + 0.5) .. "%")
    frame.recipeScale.caption:SetText("Recipe details size: " .. math.floor(saved.recipeScale * 100 + 0.5) .. "%")
    frame.windowOpacity.caption:SetText("Opacity: " .. math.floor(saved.opacity * 100 + 0.5) .. "%")
    frame.updatingWindowControls = nil
end

function GGM.CreateWindowOptionsControls(api, frame, suffix)
    caption(frame, "Window", 20, -173)
    local function apply()
        GGM.ApplyBrowserWindowSettings(GGM.guildGearBrowserFrame, frame.windowDB)
    end
    local function slider(name, text, y, low, high, key)
        name = name .. (suffix or "")
        local control = api.CreateFrame("Slider", name, frame, "OptionsSliderTemplate")
        control:SetSize(270, 16)
        control:SetPoint("TOPLEFT", frame, "TOPLEFT", 30, y)
        control:SetOrientation("HORIZONTAL")
        control:SetMinMaxValues(low, high)
        control:SetValueStep(1)
        if control.SetObeyStepOnDrag then control:SetObeyStepOnDrag(true) end
        -- Named templates expose endpoint labels on both supported clients.
        if api[name .. "Low"] then api[name .. "Low"]:SetText(low .. "%") end
        if api[name .. "High"] then api[name .. "High"]:SetText(high .. "%") end
        if api[name .. "Text"] then api[name .. "Text"]:SetText("") end
        control.caption = caption(frame, text, 20, y + 23)
        control:SetScript("OnValueChanged", function(_, value)
            if frame.updatingWindowControls or not frame.windowSettings then return end
            frame.windowSettings[key] = math.floor(value + 0.5) / 100
            GGM.RefreshWindowOptionsControls(frame, frame.windowDB)
            apply()
            GGM.RefreshOtherGuildBookOptions(frame)
        end)
        return control
    end
    frame.windowScale = slider("TheGuildBookWindowScaleSlider", "Main window size", -224, 75, 125, "scale")
    frame.recipeScale = slider("TheGuildBookRecipeScaleSlider", "Recipe details size", -285, 75, 125, "recipeScale")
    frame.windowOpacity = slider("TheGuildBookWindowOpacitySlider", "Opacity", -346, 60, 100, "opacity")
    local function checkbox(text, y, key)
        local check = api.CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        check:SetSize(26, 26)
        check:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, y)
        local font = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        font:SetPoint("LEFT", check, "RIGHT", 4, 0)
        font:SetText(text)
        check:SetScript("OnClick", function(self)
            frame.windowSettings[key] = self:GetChecked() and true or false
            apply()
            GGM.RefreshOtherGuildBookOptions(frame)
        end)
        return check
    end
    frame.lockWindow = checkbox("Lock window position", -382, "locked")
    frame.alignRecipe = checkbox("Auto-align recipe details", -416, "autoAlignRecipe")
    frame.manualProfessionSync = checkbox("Show manual profession sync", -450, "manualProfessionSync")
    frame.manualGearSync = checkbox("Show manual gear sync", -484, "manualGearSync")
    local function button(text, y, action)
        local control = api.CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        control:SetSize(180, 24)
        control:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, y)
        control:SetText(text)
        control:SetScript("OnClick", action)
        return control
    end
    frame.centerWindow = button("Center window", -528, function()
        GGM.CenterGuildBookWindow(GGM.guildGearBrowserFrame)
    end)
    frame.resetAppearance = button("Reset appearance", -563, function()
        frame.windowSettings.scale, frame.windowSettings.recipeScale, frame.windowSettings.opacity = 1, 1, 1
        GGM.RefreshWindowOptionsControls(frame, frame.windowDB)
        apply()
        GGM.RefreshOtherGuildBookOptions(frame)
    end)
end

