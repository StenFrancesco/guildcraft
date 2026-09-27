local T = require("tests.testlib")

local function loadModule()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionLinkSave.lua", GGM)
    return GGM
end

T.test("extracts exact trade hyperlinks from guild chat text", function()
    local GGM = loadModule()
    local links = GGM.ExtractProfessionTradeLinks(
        "Alice: |cffffd000|Htrade:Player-1-ABC:164:75:100|h[Blacksmithing]|h|r and |Hitem:123|h[item]|h"
    )

    T.assertEqual(#links, 1)
    T.assertEqual(links[1], "trade:Player-1-ABC:164:75:100")
end)

T.test("guild profession provenance maps exact link to sender identity", function()
    local GGM = loadModule()
    local controller = GGM.CreateProfessionLinkSaveController({
        GetRealmName = function() return "Silvermoon" end,
    }, {})

    local result, err = GGM.ObserveGuildProfessionMessage(
        controller,
        "|Htrade:Player-1-ABC:164:75:100|h[Blacksmithing]|h",
        "Alice-Silvermoon"
    )

    T.assertEqual(result, "observed")
    T.assertNil(err)
    T.assertEqual(controller.sourceByLink["trade:Player-1-ABC:164:75:100"].identity.key, "Alice-Silvermoon")
end)

T.test("non-profession guild chat creates no provenance entry", function()
    local GGM = loadModule()
    local controller = GGM.CreateProfessionLinkSaveController({
        GetRealmName = function() return "Silvermoon" end,
    }, {})

    local result = GGM.ObserveGuildProfessionMessage(controller, "hello guild", "Alice-Silvermoon")
    T.assertEqual(result, "ignored")
    T.assertNil(next(controller.sourceByLink))
end)

T.test("same-realm sender without realm is normalized using current realm", function()
    local GGM = loadModule()
    local controller = GGM.CreateProfessionLinkSaveController({
        GetRealmName = function() return "Silvermoon" end,
    }, {})

    GGM.ObserveGuildProfessionMessage(
        controller,
        "|Htrade:Player-1-ABC:164:75:100|h[Blacksmithing]|h",
        "Alice"
    )

    T.assertEqual(controller.sourceByLink["trade:Player-1-ABC:164:75:100"].identity.key, "Alice-Silvermoon")
end)

T.test("opening an observed guild trade link activates its sender without opening anything itself", function()
    local GGM = loadModule()
    local controller = GGM.CreateProfessionLinkSaveController({
        GetRealmName = function() return "Silvermoon" end,
    }, {})
    GGM.ObserveGuildProfessionMessage(
        controller,
        "|Htrade:Player-1-ABC:164:75:100|h[Blacksmithing]|h",
        "Alice-Silvermoon"
    )

    local result = GGM.HandleProfessionHyperlinkOpened(controller, "trade:Player-1-ABC:164:75:100")

    T.assertEqual(result, "guild-profession-link")
    T.assertEqual(controller.activeIdentity.key, "Alice-Silvermoon")
    T.assertEqual(controller.activeLink, "trade:Player-1-ABC:164:75:100")
end)

T.test("opening an unobserved trade link does not offer saving", function()
    local GGM = loadModule()
    local controller = GGM.CreateProfessionLinkSaveController({}, {})

    local result = GGM.HandleProfessionHyperlinkOpened(controller, "trade:someone-else")

    T.assertEqual(result, "ignored")
    T.assertNil(controller.activeIdentity)
end)

T.test("save click captures and persists the active linked profession", function()
    local GGM = loadModule()
    local savedIdentity
    local savedSnapshot
    GGM.CaptureLinkedProfessionSnapshot = function()
        return {
            professionID = 164, professionName = "Blacksmithing", skillLevel = 75, maxSkillLevel = 100,
            capturedAt = 1700004000, source = GGM.PROFESSION_SOURCE_GUILD_LINK,
            status = GGM.PROFESSION_CACHE_STATUS, recipes = {},
        }, nil
    end
    GGM.SaveProfessionSnapshot = function(_, identity, snapshot)
        savedIdentity = identity
        savedSnapshot = snapshot
        return true, nil
    end

    local controller = GGM.CreateProfessionLinkSaveController({}, {})
    controller.activeIdentity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertEqual(result, "saved")
    T.assertNil(err)
    T.assertEqual(savedIdentity.key, "Alice-Silvermoon")
    T.assertEqual(savedSnapshot.professionID, 164)
end)

T.test("capture failure does not write SavedVariables", function()
    local GGM = loadModule()
    local saveCalls = 0
    GGM.CaptureLinkedProfessionSnapshot = function()
        return nil, "profession-data-unavailable"
    end
    GGM.SaveProfessionSnapshot = function()
        saveCalls = saveCalls + 1
        return true, nil
    end

    local controller = GGM.CreateProfessionLinkSaveController({}, {})
    controller.activeIdentity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertNil(result)
    T.assertEqual(err, "profession-data-unavailable")
    T.assertEqual(saveCalls, 0)
end)

T.test("save button is shown only when active guild link profession is linked and ready", function()
    local GGM = loadModule()
    local visible = false
    local button = {
        Show = function() visible = true end,
        Hide = function() visible = false end,
    }
    local controller = GGM.CreateProfessionLinkSaveController({
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return true end,
            IsTradeSkillReady = function() return true end,
        },
    }, {})
    controller.button = button
    controller.activeIdentity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }

    T.assertEqual(GGM.RefreshProfessionSaveButton(controller), "shown")
    T.assertTrue(visible)

    controller.activeIdentity = nil
    T.assertEqual(GGM.RefreshProfessionSaveButton(controller), "hidden")
    T.assertFalse(visible)
end)

T.test("saving a profession snapshot does not call guild sync or addon messaging", function()
    local GGM = loadModule()
    local publishCalls = 0
    local sendCalls = 0

    GGM.PublishConfirmedSlot = function()
        publishCalls = publishCalls + 1
    end
    GGM.CaptureLinkedProfessionSnapshot = function()
        return {
            professionID = 171, professionName = "Alchemy", skillLevel = 50, maxSkillLevel = 100,
            capturedAt = 1700006000, source = GGM.PROFESSION_SOURCE_GUILD_LINK,
            status = GGM.PROFESSION_CACHE_STATUS, recipes = {},
        }, nil
    end
    GGM.SaveProfessionSnapshot = function() return true, nil end

    local controller = GGM.CreateProfessionLinkSaveController({
        C_ChatInfo = {
            SendAddonMessage = function() sendCalls = sendCalls + 1 end,
        },
    }, {})
    controller.activeIdentity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }

    T.assertEqual(GGM.SaveActiveLinkedProfession(controller), "saved")
    T.assertEqual(publishCalls, 0)
    T.assertEqual(sendCalls, 0)
end)

T.test("observing guild profession links is local-only", function()
    local GGM = loadModule()
    local sendCalls = 0
    local controller = GGM.CreateProfessionLinkSaveController({
        GetRealmName = function() return "Silvermoon" end,
        C_ChatInfo = {
            SendAddonMessage = function() sendCalls = sendCalls + 1 end,
        },
    }, {})

    GGM.ObserveGuildProfessionMessage(
        controller,
        "|Htrade:Player-1-ABC:171:50:100|h[Alchemy]|h",
        "Alice-Silvermoon"
    )

    T.assertEqual(sendCalls, 0)
end)
