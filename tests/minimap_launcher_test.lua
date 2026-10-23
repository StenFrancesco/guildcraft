local T = require("tests.testlib")

local function fixture(db)
    local GGM, frames = {}, {}
    local function region()
        local r = { scripts = {}, shown = true }
        for _, method in ipairs({ "SetSize", "SetWidth", "SetHeight", "SetFrameStrata",
            "SetFrameLevel", "EnableMouse", "RegisterForClicks", "RegisterForDrag",
            "SetMovable", "SetClampedToScreen", "StartMoving", "StopMovingOrSizing",
            "SetTexture", "SetTexCoord", "SetAllPoints", "SetNormalTexture",
            "SetHighlightTexture", "SetPushedTexture", "SetFontObject",
            "SetTextColor", "SetJustifyH", "SetBackdrop", "SetBackdropColor",
            "SetBackdropBorderColor", "SetAutoFocus" }) do
            r[method] = function() end
        end
        function r:SetScript(name, fn) self.scripts[name] = fn end
        function r:HookScript(name, fn) self.scripts[name] = fn end
        function r:SetPoint(...) self.point = { ... } end
        function r:ClearAllPoints() self.point = nil end
        function r:Show() self.shown = true end
        function r:Hide()
            self.shown = false
            if self.scripts.OnHide then self.scripts.OnHide(self) end
        end
        function r:IsShown() return self.shown end
        function r:SetText(text) self.text = text end
        function r:SetOrientation(value) self.orientation = value end
        function r:SetMinMaxValues(low, high) self.low, self.high = low, high end
        function r:SetValueStep(value) self.step = value end
        function r:SetValue(value)
            self.value = value
            if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, value) end
        end
        function r:SetChecked(value) self.checked = value end
        function r:GetChecked() return self.checked end
        function r:CreateTexture() return region() end
        function r:CreateFontString() return region() end
        return r
    end
    local api = { UIParent = region(), UISpecialFrames = {} }
    api.Minimap = region()
    function api.Minimap:GetWidth() return 140 end
    function api.Minimap:GetHeight() return 140 end
    function api.Minimap:GetEffectiveScale() return 2 end
    function api.Minimap:GetCenter() return 100, 100 end
    api.GetCursorPosition = function() return 400, 200 end
    api.CreateFrame = function(_, name, parent, template)
        local f = region()
        f.name, f.parent, f.template = name, parent, template
        if name then api[name] = f end
        frames[#frames + 1] = f
        return f
    end
    local opens = 0
    GGM.ShowGuildGearBrowserWindow = function(_, passedDB)
        T.assertEqual(passedDB, db)
        opens = opens + 1
    end
    T.loadAddonFile("The Guild Book/WindowSettings.lua", GGM)
    T.loadAddonFile("The Guild Book/MinimapLauncher.lua", GGM)
    return GGM, api, frames, function() return opens end
end

T.test("minimap starts visible with compatible optional defaults and reuses its button", function()
    local db = { professions = { preserved = true } }
    local G, api, frames = fixture(db)
    T.assertEqual(type(G.InitializeMinimapLauncher), "function")
    local icon = G.InitializeMinimapLauncher(api, db)
    T.assertTrue(icon:IsShown())
    T.assertEqual(db.uiSettings.minimap.hide, false)
    T.assertEqual(db.uiSettings.minimap.locked, false)
    T.assertEqual(db.uiSettings.minimap.angle, 225)
    T.assertTrue(db.professions.preserved)
    local count = #frames
    T.assertEqual(G.InitializeMinimapLauncher(api, db), icon)
    T.assertEqual(#frames, count)
end)

T.test("minimap click opens browser and right click offers Options without opening browser", function()
    local db = {}
    local G, api, _, opens = fixture(db)
    local icon = G.InitializeMinimapLauncher(api, db)
    icon.scripts.OnClick(icon, "LeftButton")
    T.assertEqual(opens(), 1)
    icon.scripts.OnClick(icon, "RightButton")
    T.assertEqual(opens(), 1)
    T.assertTrue(G.minimapMenu:IsShown())
    G.minimapMenu.optionsButton.scripts.OnClick()
    T.assertFalse(G.minimapMenu:IsShown())
    T.assertTrue(G.guildBookOptionsFrame:IsShown())
end)

T.test("options hide and restore minimap and retain preferences across a fresh load", function()
    local db = {}
    local G, api = fixture(db)
    local icon = G.InitializeMinimapLauncher(api, db)
    local options = G.ShowGuildBookOptions(api, db)
    options.showIcon:SetChecked(false)
    options.showIcon.scripts.OnClick(options.showIcon)
    T.assertFalse(icon:IsShown())
    T.assertTrue(db.uiSettings.minimap.hide)
    local fresh, freshAPI = fixture(db)
    local restored = fresh.InitializeMinimapLauncher(freshAPI, db)
    T.assertFalse(restored:IsShown())
    local recovered = fresh.ShowGuildBookOptions(freshAPI, db)
    T.assertFalse(recovered.showIcon:GetChecked())
    recovered.showIcon:SetChecked(true)
    recovered.showIcon.scripts.OnClick(recovered.showIcon)
    T.assertTrue(restored:IsShown())
    T.assertFalse(db.uiSettings.minimap.hide)
    T.assertEqual(fresh.ShowGuildBookOptions(freshAPI, db), recovered)
end)

T.test("dragging accounts for minimap scale and locking stops movement", function()
    local db = {}
    local G, api = fixture(db)
    local icon = G.InitializeMinimapLauncher(api, db)
    icon.scripts.OnDragStart(icon)
    T.assertEqual(type(icon.scripts.OnUpdate), "function")
    icon.scripts.OnUpdate(icon)
    T.assertEqual(db.uiSettings.minimap.angle, 0)
    icon.scripts.OnDragStop(icon)
    T.assertNil(icon.scripts.OnUpdate)
    local options = G.ShowGuildBookOptions(api, db)
    options.lockIcon:SetChecked(true)
    options.lockIcon.scripts.OnClick(options.lockIcon)
    icon.scripts.OnDragStart(icon)
    T.assertNil(icon.scripts.OnUpdate)
    T.assertTrue(db.uiSettings.minimap.locked)
    options.resetPosition.scripts.OnClick()
    T.assertEqual(db.uiSettings.minimap.angle, 225)
    T.assertTrue(db.uiSettings.minimap.locked)
end)

T.test("hiding a dragging icon stops updates and suppresses drag click", function()
    local db = {}
    local G, api, _, opens = fixture(db)
    local icon = G.InitializeMinimapLauncher(api, db)
    icon.scripts.OnDragStart(icon)
    icon.scripts.OnDragStop(icon)
    icon.scripts.OnClick(icon, "LeftButton")
    T.assertEqual(opens(), 0)
    icon.scripts.OnClick(icon, "LeftButton")
    T.assertEqual(opens(), 1)
    icon.scripts.OnDragStart(icon)
    icon:Hide()
    T.assertNil(icon.scripts.OnUpdate)
end)

T.test("invalid UI preferences recover without touching other saved fields", function()
    for _, bad in ipairs({ "broken", { minimap = "broken" },
        { minimap = { angle = 0/0, hide = "yes", locked = 1 } },
        { minimap = { angle = math.huge } } }) do
        local db = { uiSettings = bad, professions = { kept = true } }
        local G, api = fixture(db)
        local icon = G.InitializeMinimapLauncher(api, db)
        T.assertTrue(icon:IsShown())
        T.assertEqual(db.uiSettings.minimap.angle, 225)
        T.assertTrue(db.professions.kept)
    end
end)

T.test("missing minimap leaves options usable and absent database is not replaced", function()
    local db = {}
    local G, api = fixture(db)
    api.Minimap = nil
    T.assertNil(G.InitializeMinimapLauncher(api, db))
    T.assertNotNil(G.ShowGuildBookOptions(api, db))
    T.assertNil(G.ShowGuildBookOptions(api, nil))
end)

T.test("options slash command bypasses opening the main browser", function()
    local db = {}
    local G, api, _, opens = fixture(db)
    T.loadAddonFile("The Guild Book/SnapshotTestUI.lua", G)
    local optionsCalls = 0
    G.db = db
    G.ShowGuildBookOptions = function(passedAPI, passedDB)
        T.assertEqual(passedAPI, api)
        T.assertEqual(passedDB, db)
        optionsCalls = optionsCalls + 1
    end
    G.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList.GUILDGEARMEMORY("  options  ")
    T.assertEqual(optionsCalls, 1)
    T.assertEqual(opens(), 0)
end)

T.test("a drag without a release click does not swallow the next real click", function()
    local db = {}
    local G, api, _, opens = fixture(db)
    local icon = G.InitializeMinimapLauncher(api, db)
    icon.scripts.OnDragStart(icon)
    icon.scripts.OnDragStop(icon)
    T.assertEqual(type(icon.scripts.OnMouseDown), "function")
    icon.scripts.OnMouseDown(icon)
    icon.scripts.OnClick(icon, "LeftButton")
    T.assertEqual(opens(), 1)
end)

T.test("saved angles normalize and scaled drag reaches every quadrant", function()
    local db = { uiSettings = { unrelated = true, minimap = { angle = 450 } } }
    local G, api = fixture(db)
    local icon = G.InitializeMinimapLauncher(api, db)
    T.assertEqual(db.uiSettings.minimap.angle, 90)
    T.assertTrue(db.uiSettings.unrelated)
    for _, sample in ipairs({ {200, 400, 90}, {0, 200, 180}, {200, 0, 270} }) do
        api.GetCursorPosition = function() return sample[1], sample[2] end
        icon.scripts.OnDragStart(icon)
        icon.scripts.OnUpdate(icon)
        T.assertEqual(db.uiSettings.minimap.angle, sample[3])
        icon.scripts.OnDragStop(icon)
    end
end)

T.test("window options save changes immediately and reset only appearance", function()
    local db = { uiSettings = { window = {locked=true,autoAlignRecipe=false},
        minimap = {hide=true,angle=90} } }
    local G, api = fixture(db)
    local applied = 0
    G.guildGearBrowserFrame = {}
    G.ApplyBrowserWindowSettings = function(_, passedDB)
        T.assertEqual(passedDB, db)
        applied = applied + 1
    end
    local options = G.ShowGuildBookOptions(api, db)
    T.assertNotNil(options.windowScale)
    T.assertEqual(options.windowScale.value, 100)
    T.assertEqual(options.windowOpacity.value, 100)
    T.assertEqual(applied, 0, "opening settings must not rewrite appearance")
    options.windowScale:SetValue(85)
    options.windowOpacity:SetValue(65)
    T.assertEqual(db.uiSettings.window.scale, 0.85)
    T.assertEqual(db.uiSettings.window.opacity, 0.65)
    T.assertEqual(applied, 2)
    options.lockWindow:SetChecked(false)
    options.lockWindow.scripts.OnClick(options.lockWindow)
    T.assertFalse(db.uiSettings.window.locked)
    options.alignRecipe:SetChecked(true)
    options.alignRecipe.scripts.OnClick(options.alignRecipe)
    T.assertTrue(db.uiSettings.window.autoAlignRecipe)
    options.resetAppearance.scripts.OnClick()
    T.assertEqual(db.uiSettings.window.scale, 1)
    T.assertEqual(db.uiSettings.window.opacity, 1)
    T.assertFalse(db.uiSettings.window.locked)
    T.assertTrue(db.uiSettings.window.autoAlignRecipe)
    T.assertTrue(db.uiSettings.minimap.hide)
    T.assertEqual(db.uiSettings.minimap.angle, 90)
    local fresh, freshAPI = fixture(db)
    local restored = fresh.ShowGuildBookOptions(freshAPI, db)
    T.assertFalse(restored.lockWindow:GetChecked())
    T.assertTrue(restored.alignRecipe:GetChecked())
end)
T.test("separate size sliders retain legacy size independently and reset both sizes", function()
    local db = {uiSettings={window={scale=0.9,locked=true,autoAlignRecipe=false}}}
    local G, api = fixture(db)
    local options = G.ShowGuildBookOptions(api, db)
    T.assertEqual(options.windowScale.value, 90)
    T.assertNotNil(options.recipeScale)
    T.assertEqual(options.recipeScale.value, 90)
    options.windowScale:SetValue(80)
    T.assertEqual(options.recipeScale.value, 90)
    options.recipeScale:SetValue(120)
    T.assertEqual(options.windowScale.value, 80)
    T.assertEqual(db.uiSettings.window.scale, 0.8)
    T.assertEqual(db.uiSettings.window.recipeScale, 1.2)
    local fresh, freshAPI = fixture(db)
    local restored = fresh.ShowGuildBookOptions(freshAPI, db)
    T.assertEqual(restored.windowScale.value, 80)
    T.assertEqual(restored.recipeScale.value, 120)
    restored.resetAppearance.scripts.OnClick()
    T.assertEqual(db.uiSettings.window.scale, 1)
    T.assertEqual(db.uiSettings.window.recipeScale, 1)
    T.assertEqual(restored.windowScale.value, 100)
    T.assertEqual(restored.recipeScale.value, 100)
    T.assertTrue(db.uiSettings.window.locked)
    T.assertFalse(db.uiSettings.window.autoAlignRecipe)
end)
