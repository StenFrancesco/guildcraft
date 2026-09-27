local T = require("tests.testlib")

local function loadModel()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/SavedCharacterModel.lua", GGM)
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
        SetPortraitTextureFromCreatureDisplayID = function(texture, displayID)
            calls[#calls + 1] = "display:" .. displayID
            if options.displayFails then error("display unavailable") end
            texture:SetTexture("display:" .. displayID)
        end,
    }
    return GGM.CreateSavedCharacterModel(api, {}), calls
end

local function record(raceID, sex, displayID)
    return { identity = { raceID = raceID, sex = sex, displayID = displayID }, gear = { slots = {} } }
end

T.test("saved portrait uses a verified race atlas without requiring gear or display ID", function()
    local GGM = loadModel()
    local view = makeView(GGM, {
        raceInfo = { clientFileString = "Human", raceName = "Human" },
        atlases = { ["raceicon128-human-male"] = true },
    })

    T.assertEqual(GGM.RenderSavedCharacterModel(view, record(1, 2)), "shown")
    T.assertTrue(view.model.visible)
    T.assertTrue(view.portraitRendered)
    T.assertEqual(view.portraitSource, "raceicon128-human-male")
    T.assertEqual(view.portrait.atlas, "raceicon128-human-male")
    T.assertEqual(view.raceLabel.text, "Human")
    T.assertEqual(view.sexLabel.text, "Male")
    T.assertEqual(view.caption.text, "Saved race portrait")
    T.assertFalse(view.questionMark.visible)
end)

T.test("saved portrait falls back to the legacy race sheet", function()
    local GGM = loadModel()
    local view = makeView(GGM)

    T.assertEqual(GGM.RenderSavedCharacterModel(view, record(2, 3)), "shown")
    T.assertEqual(view.portraitSource, "legacy-race-sheet")
    T.assertEqual(view.portrait.texture, "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Races")
    T.assertEqual(view.portrait.texCoord[1], 0.375)
    T.assertEqual(view.portrait.texCoord[3], 0.75)
    T.assertEqual(view.sexLabel.text, "Female")
end)

T.test("saved portrait uses display ID when a race icon is unavailable", function()
    local GGM = loadModel()
    local view, calls = makeView(GGM)

    T.assertEqual(GGM.RenderSavedCharacterModel(view, record(99, 2, 12345)), "shown")
    T.assertEqual(view.portraitSource, "display-id")
    T.assertEqual(view.portrait.texture, "display:12345")
    T.assertEqual(calls[#calls], "display:12345")
    T.assertEqual(view.caption.text, "Saved 2D portrait")
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
    T.assertEqual(view.caption.text, "Saved gear - portrait not available")
end)

T.test("changing selection clears the previous portrait and labels", function()
    local GGM = loadModel()
    local view = makeView(GGM, { atlases = { ["raceicon128-human-male"] = true } })
    T.assertEqual(GGM.RenderSavedCharacterModel(view, record(1, 2, 101)), "shown")

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
