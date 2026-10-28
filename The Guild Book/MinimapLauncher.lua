local _, GGM = ...

local DEFAULT_ANGLE = 225

local function preferences(db)
    if type(db) ~= "table" then return nil end
    if type(db.uiSettings) ~= "table" then db.uiSettings = {} end
    if type(db.uiSettings.minimap) ~= "table" then db.uiSettings.minimap = {} end
    local settings = db.uiSettings.minimap
    settings.hide = settings.hide == true
    settings.locked = settings.locked == true
    local angle = settings.angle
    if type(angle) ~= "number" or angle ~= angle or angle == math.huge or angle == -math.huge then
        angle = DEFAULT_ANGLE
    end
    settings.angle = angle % 360
    return settings
end

local function label(parent, text, x, y)
    local font = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    font:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    font:SetText(text)
    return font
end

local function panel(api, name, width, height, alwaysOnTop)
    local frame = api.CreateFrame("Frame", name, api.UIParent,
        api.BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(width, height)
    frame:SetFrameStrata(alwaysOnTop and "FULLSCREEN_DIALOG" or "DIALOG")
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = alwaysOnTop and "Interface\\Buttons\\WHITE8X8"
                or "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 32, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        if alwaysOnTop and frame.SetBackdropColor then
            frame:SetBackdropColor(0.08, 0.06, 0.04, 1)
        end
    end
    api.UISpecialFrames = api.UISpecialFrames or {}
    table.insert(api.UISpecialFrames, name)
    frame:Hide()
    return frame
end

local function stopDrag(button)
    button:SetScript("OnUpdate", nil)
    button.dragging = false
end

local function position(button)
    local minimap = button.minimap
    local radians = math.rad(button.settings.angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", minimap, "CENTER",
        math.cos(radians) * (minimap:GetWidth() / 2 + 8),
        math.sin(radians) * (minimap:GetHeight() / 2 + 8))
end

local function refreshLauncher()
    local button = GGM.minimapButton
    if not button then return end
    position(button)
    if button.settings.locked then stopDrag(button) end
    if button.settings.hide then button:Hide() else button:Show() end
end

local function createOptionsControls(api, frame, suffix)
    local function checkbox(text, y, update)
        local check = api.CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        check:SetSize(26, 26)
        check:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, y)
        local caption = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        caption:SetPoint("LEFT", check, "RIGHT", 4, 0)
        caption:SetText(text)
        check:SetScript("OnClick", function(self)
            update(frame.settings, self:GetChecked() and true or false)
            refreshLauncher()
            GGM.RefreshOtherGuildBookOptions(frame)
        end)
        return check
    end
    frame.showIcon = checkbox("Show minimap icon", -52,
        function(saved, checked) saved.hide = not checked end)
    frame.lockIcon = checkbox("Lock icon position", -87,
        function(saved, checked) saved.locked = checked end)
    frame.resetPosition = api.CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.resetPosition:SetSize(180, 24)
    frame.resetPosition:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -128)
    frame.resetPosition:SetText("Reset icon position")
    frame.resetPosition:SetScript("OnClick", function()
        frame.settings.angle = DEFAULT_ANGLE
        refreshLauncher()
        GGM.RefreshOtherGuildBookOptions(frame)
    end)
    GGM.CreateWindowOptionsControls(api, frame, suffix)
end

local function refreshOptions(frame, db)
    frame.optionsDB = db
    frame.settings = preferences(db)
    GGM.RefreshWindowOptionsControls(frame, db)
    frame.showIcon:SetChecked(not frame.settings.hide)
    frame.lockIcon:SetChecked(frame.settings.locked)
end

function GGM.RefreshOtherGuildBookOptions(frame)
    local db = frame.optionsDB or frame.windowDB
    if not db then return end
    local other = frame == GGM.guildBookOptionsFrame
        and GGM.guildBookSettingsPanel or GGM.guildBookOptionsFrame
    if other and other ~= frame and other.IsShown and other:IsShown() then
        refreshOptions(other, db)
    end
end

function GGM.ShowGuildBookOptions(api, db)
    local settings = preferences(db)
    if not settings or type(api.CreateFrame) ~= "function" then return nil end
    local frame = GGM.guildBookOptionsFrame
    if not frame then
        frame = panel(api, "TheGuildBookOptionsFrame", 340, 580, true)
        GGM.guildBookOptionsFrame = frame
        frame:SetPoint("CENTER", api.UIParent, "CENTER", 0, 0)
        frame:SetMovable(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        frame:SetScript("OnHide", function(self) self:StopMovingOrSizing() end)
        label(frame, "The Guild Book - Options", 18, -18)
        local close = api.CreateFrame("Button", nil, frame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
        close:SetScript("OnClick", function() frame:Hide() end)

        createOptionsControls(api, frame)
        local hint = label(frame, "/ggm options opens this window.", 20, -551)
        hint:SetFontObject("GameFontHighlightSmall")
    end
    refreshOptions(frame, db)
    frame:Show()
    if frame.Raise then frame:Raise() end
    return frame
end

function GGM.RegisterGuildBookSettings(api, db)
    if GGM.guildBookSettingsPanel or type(db) ~= "table" or type(api.CreateFrame) ~= "function" then return end
    local modern = type(api.Settings) == "table"
        and type(api.Settings.RegisterCanvasLayoutCategory) == "function"
        and type(api.Settings.RegisterAddOnCategory) == "function"
    if not modern and type(api.InterfaceOptions_AddCategory) ~= "function" then return end
    local frame = api.CreateFrame("Frame", nil, api.UIParent)
    frame.name = "The Guild Book"
    label(frame, "The Guild Book", 20, -18)
    createOptionsControls(api, frame, "Settings")
    frame:SetScript("OnShow", function() refreshOptions(frame, db) end)
    if modern then
        local category = api.Settings.RegisterCanvasLayoutCategory(frame, frame.name)
        api.Settings.RegisterAddOnCategory(category)
    else
        api.InterfaceOptions_AddCategory(frame)
    end
    GGM.guildBookSettingsPanel = frame
    return frame
end

local function showMenu(api, db, button)
    local menu = GGM.minimapMenu
    if not menu then
        menu = panel(api, "TheGuildBookMinimapMenu", 140, 44)
        GGM.minimapMenu = menu
        local options = api.CreateFrame("Button", nil, menu, "UIPanelButtonTemplate")
        options:SetSize(120, 24)
        options:SetPoint("CENTER", menu, "CENTER", 0, 0)
        options:SetText("Options")
        options:SetScript("OnClick", function()
            menu:Hide()
            GGM.ShowGuildBookOptions(api, db)
        end)
        menu.optionsButton = options
    end
    if menu:IsShown() then menu:Hide(); return end
    menu:ClearAllPoints()
    menu:SetPoint("TOPRIGHT", button, "BOTTOMLEFT", 0, 0)
    menu:Show()
    if menu.Raise then menu:Raise() end
end

function GGM.InitializeMinimapLauncher(api, db)
    local settings = preferences(db)
    if not settings or type(api.CreateFrame) ~= "function" or not api.Minimap then return nil end
    local button = GGM.minimapButton
    if button then
        button.settings = settings
        refreshLauncher()
        return button
    end
    button = api.CreateFrame("Button", "TheGuildBookMinimapButton", api.Minimap)
    GGM.minimapButton = button
    button.settings, button.minimap = settings, api.Minimap
    button:SetSize(32, 32)
    button:SetFrameStrata("MEDIUM")
    if api.Minimap.GetFrameLevel then button:SetFrameLevel(api.Minimap:GetFrameLevel() + 8) end
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", button, "CENTER", 0, 0)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- A drag may or may not generate OnClick on release, depending on client.
    -- Clear suppression on the next press so the next deliberate click works.
    button:SetScript("OnMouseDown", function(self) self.suppressClick = nil end)
    button:SetScript("OnClick", function(self, mouseButton)
        if self.suppressClick then self.suppressClick = nil; return end
        if mouseButton == "RightButton" then
            showMenu(api, db, self)
        elseif mouseButton == "LeftButton" then
            if GGM.minimapMenu then GGM.minimapMenu:Hide() end
            GGM.ShowGuildGearBrowserWindow(api, db)
        end
    end)
    button:SetScript("OnDragStart", function(self)
        if self.settings.locked or type(api.GetCursorPosition) ~= "function" then return end
        self.dragging, self.suppressClick = true, true
        if api.GameTooltip then api.GameTooltip:Hide() end
        if GGM.minimapMenu then GGM.minimapMenu:Hide() end
        self:SetScript("OnUpdate", function()
            local x, y = api.GetCursorPosition()
            local cx, cy = self.minimap:GetCenter()
            if not cx or not cy then return end
            local scale = self.minimap:GetEffectiveScale()
            x, y = x / scale - cx, y / scale - cy
            if x == 0 and y == 0 then return end
            -- atan2 is supplied by WoW and Lua 5.1; math.atan has only one
            -- argument on the legacy client.
            self.settings.angle = math.deg(math.atan2(y, x)) % 360
            position(self)
        end)
    end)
    button:SetScript("OnDragStop", stopDrag)
    button:SetScript("OnHide", function(self)
        stopDrag(self)
        if GGM.minimapMenu then GGM.minimapMenu:Hide() end
        if api.GameTooltip then api.GameTooltip:Hide() end
    end)
    button:SetScript("OnEnter", function(self)
        if self.dragging or not api.GameTooltip then return end
        api.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        api.GameTooltip:SetText("The Guild Book")
        api.GameTooltip:AddLine("Left-click: Open The Guild Book", 1, 1, 1)
        api.GameTooltip:AddLine("Right-click: Options", 1, 1, 1)
        api.GameTooltip:AddLine(self.settings.locked and "Icon position locked"
            or "Drag: Move minimap icon", 0.8, 0.8, 0.8)
        api.GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        if api.GameTooltip then api.GameTooltip:Hide() end
    end)
    refreshLauncher()
    return button
end

