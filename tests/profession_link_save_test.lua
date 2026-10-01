local T = require("tests.testlib")

local function loadModule()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/CharacterIdentity.lua", GGM)
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

T.test("guild profession provenance records the reported sender", function()
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
    T.assertEqual(controller.sourceByLink["trade:Player-1-ABC:164:75:100"].reportedBy.key, "Alice-Silvermoon")
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

    T.assertEqual(controller.sourceByLink["trade:Player-1-ABC:164:75:100"].reportedBy.key, "Alice-Silvermoon")
end)

T.test("opening an observed guild trade link records sender without treating them as owner", function()
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
    T.assertNil(controller.activeIdentity)
    T.assertEqual(controller.activeReportedBy.key, "Alice-Silvermoon")
    T.assertEqual(controller.activeSource, "guild")
    T.assertEqual(controller.activeLink, "trade:Player-1-ABC:164:75:100")
end)

T.test("opening an unobserved trade link does not offer saving", function()
    local GGM = loadModule()
    local controller = GGM.CreateProfessionLinkSaveController({}, {})

    local result = GGM.HandleProfessionHyperlinkOpened(controller, "trade:someone-else")

    T.assertEqual(result, "ignored")
    T.assertNil(controller.activeIdentity)
end)

T.test("save click captures and persists the active player profession", function()
    local GGM = loadModule()
    local savedIdentity
    local savedSnapshot
    local savedOptions
    GGM.CaptureLinkedProfessionSnapshot = function()
        return {
            professionID = 164, professionName = "Blacksmithing",
            capturedAt = 1700004000, source = GGM.PROFESSION_SOURCE_PLAYER,
            status = GGM.PROFESSION_CACHE_STATUS, recipes = {},
        }, nil
    end
    GGM.SaveProfessionSnapshot = function(_, identity, snapshot, options)
        savedIdentity = identity
        savedSnapshot = snapshot
        savedOptions = options
        return true, nil
    end

    local controller = GGM.CreateProfessionLinkSaveController({}, {})
    controller.activeIdentity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }
    controller.activeSource = "player"

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertEqual(result, "saved")
    T.assertNil(err)
    T.assertEqual(savedIdentity.key, "Alice-Silvermoon")
    T.assertEqual(savedSnapshot.professionID, 164)
    T.assertNil(savedOptions)
end)

T.test("guild trade link saves under the roster member whose GUID matches the link", function()
    local GGM = loadModule()
    local capturedSource
    local savedIdentity
    local savedOptions
    GGM.CaptureLinkedProfessionSnapshot = function(_, source)
        capturedSource = source
        return { professionID = 164, source = source }, nil
    end
    GGM.SaveProfessionSnapshot = function(_, identity, _, options)
        savedIdentity = identity
        savedOptions = options
        return true, nil
    end

    local controller = GGM.CreateProfessionLinkSaveController({
        GetNumGuildMembers = function(includeOffline)
            T.assertTrue(includeOffline)
            return 1
        end,
        GetGuildRosterInfo = function(index)
            T.assertEqual(index, 1)
            return "Alice-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-ABC"
        end,
    }, {})
    controller.activeLink = "trade:Player-1-ABC:164:75:100"
    controller.activeOwnerGUID = "Player-1-ABC"
    controller.activeSource = "guild"
    GGM.professionRosterMembershipCurrent = true

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertEqual(result, "saved")
    T.assertNil(err)
    T.assertEqual(capturedSource, GGM.PROFESSION_SOURCE_GUILD_LINK)
    T.assertEqual(savedIdentity.key, "Alice-Silvermoon")
    T.assertEqual(savedIdentity.guid, "Player-1-ABC")
    T.assertTrue(savedOptions.guildMembershipVerified)
end)

T.test("guild profession save fails closed while roster membership is not current", function()
    local GGM = loadModule()
    local saveCalls = 0
    GGM.CaptureLinkedProfessionSnapshot = function()
        return { professionID = 164 }, nil
    end
    GGM.SaveProfessionSnapshot = function()
        saveCalls = saveCalls + 1
        return true, nil
    end
    local controller = GGM.CreateProfessionLinkSaveController({
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Alice-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-ABC"
        end,
    }, {})
    controller.activeLink = "trade:Player-1-ABC:164:75:100"
    controller.activeOwnerGUID = "Player-1-ABC"
    controller.activeSource = "guild"
    GGM.professionRosterMembershipCurrent = false

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertNil(result)
    T.assertEqual(err, "profession-roster-incomplete")
    T.assertEqual(saveCalls, 0)
end)

T.test("guild trade link with no matching roster GUID fails closed before saving", function()
    local GGM = loadModule()
    local saveCalls = 0
    GGM.CaptureLinkedProfessionSnapshot = function()
        return { professionID = 164 }, nil
    end
    GGM.SaveProfessionSnapshot = function()
        saveCalls = saveCalls + 1
        return true, nil
    end

    local controller = GGM.CreateProfessionLinkSaveController({
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Alice-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, nil
        end,
    }, {})
    controller.activeLink = "trade:Player-1-ABC:164:75:100"
    controller.activeOwnerGUID = "Player-1-ABC"
    controller.activeSource = "guild"
    GGM.professionRosterMembershipCurrent = true

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertNil(result)
    T.assertEqual(err, "profession-owner-not-in-guild")
    T.assertEqual(saveCalls, 0)
end)

T.test("guild trade link resolves a full hyphenated realm from roster owner", function()
    local GGM = loadModule()
    local controller = GGM.CreateProfessionLinkSaveController({
        GetRealmName = function() return "Silvermoon" end,
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Alice-Argent-Dawn", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-ABC"
        end,
    }, {})
    local link = "trade:Player-1-ABC:164:75:100"
    GGM.ObserveGuildProfessionMessage(controller, "|H" .. link .. "|h[Blacksmithing]|h", "Bob-Silvermoon")

    T.assertEqual(GGM.HandleProfessionHyperlinkOpened(controller, link), "guild-profession-link")
    T.assertEqual(controller.activeIdentity.name, "Alice")
    T.assertEqual(controller.activeIdentity.realm, "Argent-Dawn")
    T.assertEqual(controller.activeIdentity.key, "Alice-Argent-Dawn")
    T.assertEqual(controller.activeIdentity.guid, "Player-1-ABC")
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
    controller.activeSource = "player"

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertNil(result)
    T.assertEqual(err, "profession-data-unavailable")
    T.assertEqual(saveCalls, 0)
end)

T.test("save button is shown only when a guild owner GUID matches the current roster", function()
    local GGM = loadModule()
    local visible = false
    local button = {
        Show = function() visible = true end,
        Hide = function() visible = false end,
    }
    local controller = GGM.CreateProfessionLinkSaveController({
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Alice-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-ABC"
        end,
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return true end,
            IsTradeSkillReady = function() return true end,
        },
    }, {})
    controller.button = button
    controller.activeSource = "guild"
    controller.activeOwnerGUID = "Player-1-ABC"

    T.assertEqual(GGM.RefreshProfessionSaveButton(controller), "shown")
    T.assertTrue(visible)

    controller.activeOwnerGUID = "Player-1-MISSING"
    T.assertEqual(GGM.RefreshProfessionSaveButton(controller), "hidden")
    T.assertFalse(visible)
end)

T.test("own profession context uses the player identity and shows when ready", function()
    local GGM = loadModule()
    local visible = false
    local controller = GGM.CreateProfessionLinkSaveController({
        UnitFullName = function() return "Longbusbiggus", "Silvermoon" end,
        UnitGUID = function() return "Player-1-ABC" end,
        GetRealmName = function() return "Silvermoon" end,
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return false end,
            IsTradeSkillReady = function() return true end,
        },
    }, {})
    controller.button = {
        Show = function() visible = true end,
        Hide = function() visible = false end,
    }

    T.assertEqual(GGM.RefreshProfessionSaveButton(controller), "shown")
    T.assertTrue(visible)
    T.assertEqual(controller.activeIdentity.key, "Longbusbiggus-Silvermoon")
    T.assertEqual(controller.activeSource, "player")
end)

T.test("save click stores the open player's profession under the player identity", function()
    local GGM = loadModule()
    local capturedSource
    local savedIdentity
    local savedSnapshot
    local controller = GGM.CreateProfessionLinkSaveController({
        UnitFullName = function() return "Longbusbiggus", "Silvermoon" end,
        UnitGUID = function() return "Player-1-ABC" end,
        GetRealmName = function() return "Silvermoon" end,
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return false end,
            IsTradeSkillReady = function() return true end,
        },
    }, {})
    controller.button = {
        Show = function() end,
        Hide = function() end,
    }
    GGM.RefreshProfessionSaveButton(controller)
    GGM.CaptureLinkedProfessionSnapshot = function(_, source)
        capturedSource = source
        return {
            professionID = 164,
            source = source,
        }, nil
    end
    GGM.SaveProfessionSnapshot = function(_, identity, snapshot)
        savedIdentity = identity
        savedSnapshot = snapshot
        return true, nil
    end

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertEqual(result, "saved")
    T.assertNil(err)
    T.assertEqual(capturedSource, GGM.PROFESSION_SOURCE_PLAYER)
    T.assertEqual(savedIdentity.key, "Longbusbiggus-Silvermoon")
    T.assertEqual(savedSnapshot.source, GGM.PROFESSION_SOURCE_PLAYER)
end)

T.test("first player profession save activates and indexes the player after current roster confirms membership", function()
    local GGM = loadModule()
    T.loadAddonFile("GuildGearMemory/ProfessionSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionIndex.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    local db = assert(GGM.InitializeDatabase(nil))
    local api = {
        UnitFullName = function() return "Alice", "Silvermoon" end,
        UnitGUID = function() return "Player-1-ABC" end,
        GetRealmName = function() return "Silvermoon" end,
        IsInGuild = function() return true end,
        GetNumGuildMembers = function(includeOffline)
            T.assertTrue(includeOffline)
            return 1
        end,
        GetGuildRosterInfo = function(index)
            T.assertEqual(index, 1)
            return "Alice-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-ABC"
        end,
    }
    T.assertTrue(GGM.ReconcileProfessionGuildRoster(api, db))
    T.assertTrue(GGM.professionRosterMembershipCurrent)
    T.assertNil(db.localCharacterIDByGUID["Player-1-ABC"])

    local controller = GGM.CreateProfessionLinkSaveController(api, db)
    controller.activeIdentity = assert(GGM.BuildPlayerIdentity(api))
    controller.activeSource = "player"
    GGM.CaptureLinkedProfessionSnapshot = function(_, source)
        return {
            complete = true,
            professionID = 164, professionName = "Blacksmithing",
            capturedAt = 1700000000, source = source,
            status = GGM.PROFESSION_CACHE_STATUS,
            recipes = { { recipeID = 41234, name = "Copper Bracers" } },
        }, nil
    end

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertEqual(result, "saved")
    T.assertNil(err)
    local localID = db.localCharacterIDByGUID["Player-1-ABC"]
    T.assertNotNil(localID)
    T.assertTrue(db.professionCharacters[localID].active)
    local matches = assert(GGM.GetProfessionRecipeCharacters(db, 164, 41234))
    T.assertEqual(#matches, 1)
    T.assertEqual(matches[1].guid, "Player-1-ABC")
end)

T.test("player profession save does not activate when current roster does not verify the player GUID", function()
    local GGM = loadModule()
    local savedIdentity
    local savedOptions
    GGM.professionRosterMembershipCurrent = true
    GGM.CaptureLinkedProfessionSnapshot = function()
        return { professionID = 164 }, nil
    end
    GGM.SaveProfessionSnapshot = function(_, identity, _, options)
        savedIdentity = identity
        savedOptions = options
        return true, nil
    end
    local controller = GGM.CreateProfessionLinkSaveController({
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Bob-Silvermoon", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-2-DEF"
        end,
    }, {})
    controller.activeIdentity = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-ABC",
    }
    controller.activeSource = "player"

    T.assertEqual(GGM.SaveActiveLinkedProfession(controller), "saved")
    T.assertEqual(savedIdentity.guid, "Player-1-ABC")
    T.assertNil(savedOptions)
end)

T.test("player profession save aborts when current roster verification is unavailable", function()
    local GGM = loadModule()
    local saveCalls = 0
    GGM.professionRosterMembershipCurrent = true
    GGM.CaptureLinkedProfessionSnapshot = function()
        return { professionID = 164 }, nil
    end
    GGM.SaveProfessionSnapshot = function()
        saveCalls = saveCalls + 1
        return true, nil
    end
    local controller = GGM.CreateProfessionLinkSaveController({
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function() error("roster temporarily unavailable") end,
    }, {})
    controller.activeIdentity = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-ABC",
    }
    controller.activeSource = "player"

    local result, err = GGM.SaveActiveLinkedProfession(controller)

    T.assertNil(result)
    T.assertEqual(err, "profession-roster-unavailable")
    T.assertEqual(saveCalls, 0)
end)

T.test("save button is parented to the profession UI", function()
    local GGM = loadModule()
    local professionFrame = {}
    local createAllButton = {}
    professionFrame.CraftingPage = {
        SchematicForm = {
            CreateAllButton = createAllButton,
        },
    }
    local createdParent
    local statusWidth
    local button = {
        SetSize = function() end,
        SetPoint = function(_, point, relativeTo, relativePoint, x, y)
            T.assertEqual(point, "RIGHT")
            T.assertTrue(relativeTo == createAllButton)
            T.assertEqual(relativePoint, "LEFT")
            T.assertEqual(x, -8)
            T.assertEqual(y, 0)
        end,
        SetText = function() end,
        Hide = function() end,
        CreateFontString = function()
            return {
                SetPoint = function() end,
                SetWidth = function(_, width) statusWidth = width end,
                SetJustifyH = function() end,
                SetText = function() end,
            }
        end,
        SetScript = function() end,
    }
    local controller = GGM.CreateProfessionLinkSaveController({
        UIParent = {},
        ProfessionsFrame = professionFrame,
        CreateFrame = function(_, _, parent)
            createdParent = parent
            return button
        end,
    }, {})

    local created, err = GGM.CreateProfessionSaveButton(controller)

    T.assertTrue(created)
    T.assertNil(err)
    T.assertTrue(createdParent == professionFrame)
    T.assertEqual(statusWidth, 340)
end)

T.test("refresh creates the button when the profession UI becomes available later", function()
    local GGM = loadModule()
    local professionFrame = {}
    local visible = false
    local statusWidth
    local controller = GGM.CreateProfessionLinkSaveController({
        ProfessionsFrame = professionFrame,
        UnitFullName = function() return "Longbusbiggus", "Silvermoon" end,
        UnitGUID = function() return "Player-1-ABC" end,
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return false end,
            IsTradeSkillReady = function() return true end,
        },
        CreateFrame = function()
            return {
                SetSize = function() end,
                SetPoint = function() end,
                SetText = function() end,
                Show = function() visible = true end,
                Hide = function() end,
                CreateFontString = function()
                    return {
                        SetPoint = function() end,
                        SetWidth = function(_, width) statusWidth = width end,
                        SetJustifyH = function() end,
                        SetText = function() end,
                    }
                end,
                SetScript = function() end,
            }
        end,
    }, {})

    T.assertEqual(GGM.RefreshProfessionSaveButton(controller), "shown")
    T.assertTrue(controller.button ~= nil)
    T.assertTrue(visible)
    T.assertEqual(statusWidth, 340)
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
            professionID = 171, professionName = "Alchemy",
            capturedAt = 1700006000, source = GGM.PROFESSION_SOURCE_PLAYER,
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
    controller.activeSource = "player"

    T.assertEqual(GGM.SaveActiveLinkedProfession(controller), "saved")
    T.assertEqual(publishCalls, 0)
    T.assertEqual(sendCalls, 0)
end)

T.test("observing guild profession links is local-only", function()
    local GGM = loadModule()
    local sendCalls = 0
    local publishCalls = 0
    GGM.PublishConfirmedSlot = function() publishCalls = publishCalls + 1 end
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
    T.assertEqual(publishCalls, 0)
end)
