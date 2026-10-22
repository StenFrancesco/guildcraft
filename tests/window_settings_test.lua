local T = require("tests.testlib")

local function frame(width, height, scale)
    local f = { width = width or 1400, height = height or 630,
        scale = scale or 1, alpha = 1, scripts = {}, points = {} }
    function f:GetWidth() return self.width end
    function f:GetHeight() return self.height end
    function f:GetScale() return self.scale end
    function f:GetEffectiveScale() return self.scale * (self.parentScale or 1) end
    function f:SetScale(v) self.scale = v end
    function f:SetAlpha(v) self.alpha = v end
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function f:StopMovingOrSizing() self.moving = false end
    function f:GetLeft() return self.left end
    function f:GetRight() return self.left + self.width end
    function f:GetTop() return self.top end
    return f
end

local function fixture(saved, width, height)
    local G = {}
    T.loadAddonFile("The Guild Book/WindowSettings.lua", G)
    local root = frame(width or 2560, height or 1440)
    local browser = frame()
    browser.api = { UIParent = root }
    browser.db = { uiSettings = { window = saved, minimap = { hide = true } }, professions = { kept = true } }
    browser.left, browser.top = 100, 1300
    browser.recipeDetailsFrame = frame(540, 620)
    G.guildGearBrowserFrame = browser
    return G, browser, browser.db, root
end

T.test("window preferences default and normalize independently of saved addon data", function()
    local G, browser, db = fixture()
    T.assertEqual(type(G.GetBrowserWindowSettings), "function")
    local p = G.GetBrowserWindowSettings(db)
    T.assertEqual(p.scale, 1)
    T.assertEqual(p.opacity, 1)
    T.assertFalse(p.locked)
    T.assertTrue(p.autoAlignRecipe)
    T.assertTrue(db.uiSettings.minimap.hide)
    T.assertTrue(db.professions.kept)
    T.assertEqual(G.GetBrowserWindowSettings(db), p)
    for _, bad in ipairs({ "bad", {scale=0/0, opacity=math.huge},
        {scale=-math.huge, opacity="bad"} }) do
        db.uiSettings.window = bad
        p = G.GetBrowserWindowSettings(db)
        T.assertEqual(p.scale, 1)
        T.assertEqual(p.opacity, 1)
    end
    db.uiSettings.window = {scale=5,opacity=0,locked=true,autoAlignRecipe=false}
    p = G.GetBrowserWindowSettings(db)
    T.assertEqual(p.scale, 1.25)
    T.assertEqual(p.opacity, 0.6)
    T.assertTrue(p.locked)
    T.assertFalse(p.autoAlignRecipe)
end)

T.test("appearance applies to main and independent recipe windows without changing positions", function()
    local G, b, db = fixture({scale=1.2, opacity=0.7})
    b:SetPoint("CENTER")
    b.recipeDetailsFrame:SetPoint("CENTER")
    G.ApplyBrowserWindowSettings(b, db)
    T.assertEqual(b.scale, 1.2)
    T.assertEqual(b.alpha, 0.7)
    T.assertEqual(b.recipeDetailsFrame.scale, 1.2)
    T.assertEqual(b.recipeDetailsFrame.alpha, 0.7)
    T.assertEqual(b.points[1][1], "CENTER")
    T.assertEqual(b.recipeDetailsFrame.points[1][1], "CENTER")
end)

T.test("actual window size fits the screen without erasing requested size", function()
    local G, b, db = fixture({scale=1.25}, 1000, 600)
    G.ApplyBrowserWindowSettings(b, db)
    T.assertTrue(b.width*b.scale <= 976)
    T.assertTrue(b.height*b.scale <= 576)
    T.assertEqual(db.uiSettings.window.scale, 1.25)
end)

T.test("lock stops an active main-window drag and center clears old anchors", function()
    local G, b, db, root = fixture({locked=true})
    b.moving = true
    G.ApplyBrowserWindowSettings(b, db)
    T.assertFalse(b.moving)
    b:SetPoint("TOPLEFT")
    b.moving = true
    G.CenterGuildBookWindow(b)
    T.assertFalse(b.moving)
    T.assertEqual(#b.points, 1)
    T.assertEqual(b.points[1][1], "CENTER")
    T.assertEqual(b.points[1][2], root)
end)

T.test("recipe alignment uses independent root coordinates at right then left then screen fallback", function()
    local G, b, db, root = fixture()
    local d = b.recipeDetailsFrame
    G.PositionRecipeDetailsWindow(b, d)
    local p = d.points[1]
    T.assertEqual(p[1], "TOPLEFT")
    T.assertEqual(p[2], root)
    T.assertEqual(p[4], 1508)
    T.assertEqual(p[5], 1300)
    b.left = 700
    G.PositionRecipeDetailsWindow(b, d)
    T.assertEqual(d.points[1][4], 152)
    root.width = 1500
    b.left = 50
    G.PositionRecipeDetailsWindow(b, d)
    T.assertTrue(d.points[1][4] >= 0)
    T.assertTrue(d.points[1][4]+540 <= root.width)
    b.top = 1700
    G.PositionRecipeDetailsWindow(b, d)
    T.assertEqual(d.points[1][5], root.height)
    b.top = 100
    G.PositionRecipeDetailsWindow(b, d)
    T.assertEqual(d.points[1][5], d.height)
end)

T.test("alignment respects distinct effective scales and leaves disabled positions untouched", function()
    local G, b, db, root = fixture({autoAlignRecipe=true})
    root.scale, b.parentScale = 0.8, 0.8
    b.scale, b.left, b.top = 0.75, 100, 1000
    local d = b.recipeDetailsFrame
    d.scale, d.parentScale = 0.75, 0.8
    G.PositionRecipeDetailsWindow(b, d)
    T.assertEqual(d.points[1][4], 1508)
    T.assertEqual(d.points[1][5], 1000)
    db.uiSettings.window.autoAlignRecipe = false
    d:ClearAllPoints()
    d:SetPoint("CENTER")
    G.PositionRecipeDetailsWindow(b, d)
    T.assertEqual(d.points[1][1], "CENTER")
end)

T.test("reading defaults for browsing or recipe alignment never creates saved preferences", function()
    local G, b, db = fixture()
    db.uiSettings = nil
    G.ApplyBrowserWindowSettings(b, db)
    G.PositionRecipeDetailsWindow(b, b.recipeDetailsFrame)
    T.assertNil(db.uiSettings)
    T.assertTrue(db.professions.kept)
end)
