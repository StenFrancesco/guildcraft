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
