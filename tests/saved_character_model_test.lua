local T = require("tests.testlib")

local function loadModel()
    local GGM = {}
    T.loadAddonFile("The Guild Book/SavedCharacterModel.lua", GGM)
    return GGM
end

local function control()
    local value = { visible = false }
    function value:Hide() self.visible = false end
    function value:Show() self.visible = true end
    function value:SetText(text) self.text = text end
    function value:SetTextColor() end
    function value:SetAllPoints() end
    function value:SetSize() end
    function value:SetPoint() end
    function value:SetWidth() end
    function value:SetJustifyH() end
    function value:SetColorTexture(...) self.color = { ... }; self.atlas = nil; self.texture = nil end
    function value:SetTexture(texture) self.texture = texture; self.atlas = nil end
    function value:SetTexCoord(...) self.texCoord = { ... } end
    function value:SetAtlas(atlas) self.atlas = atlas; self.texture = nil end
    function value:CreateTexture() return control() end
    function value:CreateFontString() return control() end
    return value
end

local function makeView(GGM, options)
    options = options or {}
    local calls = {}
    local api = {
        CreateFrame = function(frameType, name, parent)
            T.assertEqual(frameType, "Frame")
            T.assertNil(name)
            T.assertNotNil(parent)
            if options.noFrame then return nil end
            return control()
        end,
        C_CreatureInfo = { GetRaceInfo = function(raceID)
            calls[#calls + 1] = "race:" .. raceID
            return options.raceInfo
        end },
        C_Texture = { GetAtlasInfo = function(atlas)
            calls[#calls + 1] = "atlas:" .. atlas
            if options.atlases and options.atlases[atlas] then return {} end
        end },
        GetPlayerInfoByGUID = function(guid)
            calls[#calls + 1] = "class:" .. guid
            if options.classFails then error("class unavailable") end
            return "Localized class", options.classToken
        end,
        GetNumGuildMembers = function() return #(options.roster or {}) end,
        GetGuildRosterInfo = function(index) return unpack(options.roster[index], 1, 17) end,
        GetRealmName = function() return "Silvermoon" end,
        SetPortraitTextureFromCreatureDisplayID = function(texture, displayID)
            calls[#calls + 1] = "display:" .. displayID
            if options.displayFails then error("display unavailable") end
            texture:SetTexture("display:" .. displayID)
        end,
    }
    return GGM.CreateSavedCharacterModel(api, {}), calls
end

local function record(raceID, sex, displayID)
    return { identity = { key = "Alice-Silvermoon", guid = "Player-1",
        raceID = raceID, sex = sex, displayID = displayID }, gear = { slots = {} } }
end

T.test("saved portrait supports every Classic class without race or display ID", function()
    local GGM = loadModel()
    for _, classToken in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
        "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
        local atlas = "classicon-" .. classToken:lower()
        local view = makeView(GGM, { classToken = classToken, atlases = { [atlas] = true } })
        T.assertEqual(GGM.RenderSavedCharacterModel(view, record()), "shown")
        T.assertTrue(view.model.visible)
        T.assertTrue(view.portraitRendered)
        T.assertEqual(view.portraitSource, atlas)
        T.assertEqual(view.portrait.atlas, atlas)
        T.assertEqual(view.caption.text, "Class icon")
        T.assertFalse(view.questionMark.visible)
    end
end)

T.test("saved class renders while offline without any class lookup APIs", function()
    local GGM = loadModel()
    local view = makeView(GGM, { atlases = { ["classicon-hunter"] = true } })
    view.api.GetPlayerInfoByGUID = nil
    view.api.GetNumGuildMembers = nil
    local saved = record()
    saved.identity.classToken = "HUNTER"
    GGM.RenderSavedCharacterModel(view, saved)
    T.assertEqual(view.portrait.atlas, "classicon-hunter")
    T.assertFalse(view.questionMark.visible)
end)

T.test("successful class lookup backfills an older saved identity", function()
    local GGM = loadModel()
    local view = makeView(GGM, { classToken = "PRIEST" })
    local saved = record()
    GGM.RenderSavedCharacterModel(view, saved)
    T.assertEqual(saved.identity.classToken, "PRIEST")
end)

T.test("saved portrait falls back to the built-in class sheet and keeps identity labels", function()
    local GGM = loadModel()
    local view = makeView(GGM, { classToken = "MAGE", raceInfo = { raceName = "Orc" } })

    T.assertEqual(GGM.RenderSavedCharacterModel(view, record(2, 3)), "shown")
    T.assertEqual(view.portraitSource, "legacy-class-sheet")
    T.assertEqual(view.portrait.texture, "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
    T.assertEqual(view.portrait.texCoord[1], 0.25)
    T.assertEqual(view.portrait.texCoord[3], 0)
    T.assertEqual(view.raceLabel.text, "Orc")
    T.assertEqual(view.sexLabel.text, "Female")
end)

T.test("saved portrait resolves an offline guild member when GUID lookup fails", function()
    local GGM = loadModel()
    local view = makeView(GGM, { classFails = true,
        atlases = { ["classicon-priest"] = true },
        roster = { { [1] = "Alice", [9] = false, [11] = "PRIEST", [17] = "Player-1" } },
    })
    T.assertEqual(GGM.RenderSavedCharacterModel(view, record()), "shown")
    T.assertEqual(view.portrait.atlas, "classicon-priest")
end)

T.test("guild class name fallback includes realm and rejects a mismatching GUID", function()
    local GGM = loadModel()
    local view = makeView(GGM, { roster = {
        { [1] = "Alice-OtherRealm", [11] = "MAGE" },
        { [1] = "Alice-Silvermoon", [11] = "PRIEST", [17] = "Player-2" },
        { [1] = "Alice", [11] = "DRUID" },
    } })
    T.assertEqual(GGM.RenderSavedCharacterModel(view, record()), "shown")
    T.assertEqual(view.portrait.texCoord[1], 0.7421875)
end)

T.test("non-Classic classes do not render a race or display portrait", function()
    local GGM = loadModel()
    for _, classToken in ipairs({ "DEATHKNIGHT", "MONK", "DEMONHUNTER", "EVOKER" }) do
        local view = makeView(GGM, { classToken = classToken })
        GGM.RenderSavedCharacterModel(view, record(1, 2, 12345))
        T.assertFalse(view.portraitRendered)
        T.assertNil(view.portrait.texture)
        T.assertTrue(view.questionMark.visible)
    end
end)

T.test("unavailable portrait keeps saved gear panel visible and labels the absence", function()
    local GGM = loadModel()
    local view = makeView(GGM, { displayFails = true })

    T.assertEqual(GGM.RenderSavedCharacterModel(view, record(nil, nil, 12345)), "shown")
    T.assertTrue(view.model.visible)
    T.assertFalse(view.portraitRendered)
    T.assertTrue(view.questionMark.visible)
    T.assertEqual(view.raceLabel.text, "Race unavailable")
    T.assertEqual(view.sexLabel.text, "Gender unavailable")
    T.assertEqual(view.caption.text, "Class icon unavailable")
end)

T.test("changing selection clears the previous portrait and labels", function()
    local GGM = loadModel()
    local view = makeView(GGM, { classToken = "WARRIOR", atlases = { ["classicon-warrior"] = true } })
    T.assertEqual(GGM.RenderSavedCharacterModel(view, record(1, 2, 101)), "shown")

    view.api.GetPlayerInfoByGUID = nil
    T.assertEqual(GGM.RenderSavedCharacterModel(view, record(nil, nil)), "shown")
    T.assertNil(view.portrait.atlas)
    T.assertFalse(view.portraitRendered)
    T.assertNil(view.portraitSource)
    T.assertTrue(view.questionMark.visible)
    T.assertEqual(view.raceLabel.text, "Race unavailable")

    T.assertTrue(GGM.ClearSavedCharacterModel(view))
    T.assertFalse(view.model.visible)
    T.assertEqual(view.raceLabel.text, "")
    T.assertEqual(view.caption.text, "")
end)

T.test("missing record identity and failed frame creation are unavailable", function()
    local GGM = loadModel()
    local view = makeView(GGM)
    T.assertEqual(GGM.RenderSavedCharacterModel(view, {}), "identity-unavailable")
    T.assertFalse(view.model.visible)

    local failedView = makeView(GGM, { noFrame = true })
    T.assertNil(failedView.model)
    T.assertEqual(GGM.RenderSavedCharacterModel(failedView, record(1, 2)), "render-unavailable")
end)
