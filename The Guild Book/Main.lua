local ADDON_NAME, GGM = ...

GGM.professionRosterMembershipCurrent = false
GGM.professionRosterRefreshIssued = false
GGM.professionRosterRefreshPending = false
GGM.professionRosterRefreshSucceeded = false

GGM.RegisterSnapshotTestSlashCommand(_G)

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_GUILD")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
frame:RegisterEvent("TRADE_SKILL_CLOSE")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

local function refreshVisibleProfessionCatalog()
    if type(GGM.RefreshVisibleProfessionCatalog) == "function" then
        GGM.RefreshVisibleProfessionCatalog()
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    local arg1 = ...

    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_GUILD_UPDATE" or event == "GUILD_ROSTER_UPDATE" then
        if type(GGM.RefreshVisibleBankView) == "function" then
            GGM.RefreshVisibleBankView()
        end
    end

    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then
            return
        end

        local db, err, professionDB, gearDB, gearErr = GGM.InitializeSavedDatabases(_G)
        if not db then
            GGM.startupError = err
            return
        end

        GuildGearMemoryDB = professionDB
        GGM.db = db
        GGM.gearDB = gearDB
        GGM.gearStartupError = gearErr
        GGM.startupError = nil

        local professionLinkSave, professionControllerErr = GGM.CreateProfessionLinkSaveController(_G, db)
        if professionLinkSave then
            local professionRegistered, professionRegisterErr = GGM.RegisterProfessionLinkSaveController(professionLinkSave)
            if professionRegistered then
                GGM.professionLinkSave = professionLinkSave
                GGM.lastProfessionSaveError = nil
            else
                GGM.professionLinkSave = nil
                GGM.lastProfessionSaveError = professionRegisterErr
            end
        else
            GGM.professionLinkSave = nil
            GGM.lastProfessionSaveError = professionControllerErr
        end

        if type(GGM.RefreshGearBackendState) == "function" then GGM.RefreshGearBackendState() end
        return
    end

    if event == "PLAYER_LOGIN" then
        if not GGM.db or GGM.startupError then
            return
        end

        local ownershipRecorded, ownershipErr = GGM.RecordLocalPlayerOwnership(
            _G,
            GGM.db
        )
        if ownershipRecorded then
            GGM.lastLocalOwnershipError = nil
        else
            GGM.lastLocalOwnershipError = ownershipErr
        end

        return
    end

    if event == "CHAT_MSG_GUILD" then
        if not GGM.professionLinkSave or GGM.startupError then return end
        local message, sender = ...
        local _, err = GGM.ObserveGuildProfessionMessage(GGM.professionLinkSave, message, sender)
        GGM.lastProfessionSaveError = err
        return
    end

    if event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
        if GGM.professionLinkSave and not GGM.startupError then
            GGM.RefreshProfessionSaveButton(GGM.professionLinkSave)
        end
        return
    end

    if event == "TRADE_SKILL_CLOSE" then
        if GGM.professionLinkSave then
            GGM.ClearProfessionSaveContext(GGM.professionLinkSave)
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_GUILD_UPDATE" then
        if not GGM.db or GGM.startupError then return end
        local guildOk, inGuild = pcall(_G.IsInGuild)
        if not guildOk or type(inGuild) ~= "boolean" then
            GGM.professionRosterMembershipCurrent = false
            GGM.lastProfessionIndexError = "profession-roster-unavailable"
            refreshVisibleProfessionCatalog()
            return
        end
        if not inGuild then
            GGM.professionRosterRefreshIssued = false
            GGM.professionRosterRefreshPending = false
            GGM.professionRosterRefreshSucceeded = false
            local ok, err = GGM.ReconcileProfessionGuildRoster(_G, GGM.db)
            if ok then GGM.lastProfessionIndexError = nil else GGM.lastProfessionIndexError = err end
            refreshVisibleProfessionCatalog()
            return
        end
        if GGM.professionRosterRefreshIssued then return end
        GGM.professionRosterMembershipCurrent = false
        GGM.professionRosterRefreshIssued = true
        GGM.professionRosterRefreshSucceeded = false
        local guildInfo = _G.C_GuildInfo
        if type(guildInfo) ~= "table" or type(guildInfo.GuildRoster) ~= "function" then
            GGM.lastProfessionIndexError = "profession-roster-unavailable"
            refreshVisibleProfessionCatalog()
            return
        end
        GGM.professionRosterRefreshPending = true
        local requestOk, requestResult = pcall(guildInfo.GuildRoster)
        if not requestOk or requestResult == false then
            GGM.professionRosterRefreshPending = false
            GGM.lastProfessionIndexError = "profession-roster-unavailable"
            refreshVisibleProfessionCatalog()
        else
            GGM.professionRosterRefreshSucceeded = true
        end
        return
    end

    if event == "GUILD_ROSTER_UPDATE" then
        if not GGM.db or GGM.startupError or not GGM.professionRosterRefreshSucceeded then return end
        GGM.professionRosterRefreshPending = false
        local ok, err = GGM.ReconcileProfessionGuildRoster(_G, GGM.db)
        if ok then GGM.lastProfessionIndexError = nil else GGM.lastProfessionIndexError = err end
        refreshVisibleProfessionCatalog()
        return
    end

end)
