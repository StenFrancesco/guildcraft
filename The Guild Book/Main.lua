local ADDON_NAME, GGM = ...

GGM.professionRosterMembershipCurrent = false
GGM.professionRosterRefreshIssued = false
GGM.professionRosterRefreshPending = false
GGM.professionRosterRefreshSucceeded = false

GGM.RegisterSnapshotTestSlashCommand(_G)

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
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

local function refreshProfessionSyncRoster()
    if not GGM.professionSync then return end
    if not GGM.professionRosterMembershipCurrent then
        GGM.professionSync.rosterReady = false
        GGM.CancelProfessionSync(GGM.professionSync)
        return
    end
    local ready, err = GGM.RefreshProfessionSyncRoster(GGM.professionSync)
    GGM.lastProfessionSyncError = err
    if ready and GGM.professionPlayerLoggedIn and not GGM.professionLoginSyncIssued then
        if GGM.LoginProfessionSync(GGM.professionSync) then GGM.professionLoginSyncIssued = true end
    end
end

local function requestProfessionAutoSave()
    local controller = GGM.professionLinkSave
    if not controller or controller.panelOpen ~= true or GGM.startupError then return end
    local request = {}
    controller.autoSaveRequest = request
    local function save()
        if controller.autoSaveRequest ~= request then return end
        controller.autoSaveRequest = nil
        local _, err = GGM.TryAutoSaveProfession(controller)
        GGM.lastProfessionSaveError = err
    end
    -- SetItemRef is observed by a post-hook. Let it establish the new owner
    -- before handling synchronous panel events raised while opening the link.
    if type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" then
        _G.C_Timer.After(0, save)
    else
        save()
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

        local db, err, professionDB, gearDB, gearErr, updateRuntimeGearDatabase = GGM.InitializeSavedDatabases(_G)
        if not db then
            GGM.startupError = err
            return
        end

        TheGuildBookDB = professionDB
        GGM.db = db
        GGM.gearDB = gearDB
        GGM.gearStartupError = gearErr
        GGM.updateRuntimeGearDatabase = updateRuntimeGearDatabase
        GGM.startupError = nil

        if type(GGM.CreateProfessionSync) == "function" then
            local sync, syncErr = GGM.CreateProfessionSync(_G, db)
            if sync then
                local registered, registerErr = GGM.RegisterProfessionSync(sync)
                if registered then GGM.professionSync = sync else syncErr = registerErr end
            end
            GGM.lastProfessionSyncError = syncErr
        end

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

        GGM.professionPlayerLoggedIn = true
        refreshProfessionSyncRoster()

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

    if event == "CHAT_MSG_ADDON" then
        if GGM.professionSync and not GGM.startupError then
            local _, err = GGM.HandleProfessionSyncAddonMessage(GGM.professionSync, ...)
            GGM.lastProfessionSyncError = err
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
            if event == "TRADE_SKILL_SHOW" then GGM.professionLinkSave.panelOpen = true end
            GGM.RefreshProfessionSaveButton(GGM.professionLinkSave)
            requestProfessionAutoSave()
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
        if event == "PLAYER_GUILD_UPDATE" then
            GGM.professionRosterRefreshIssued = false
            GGM.professionRosterRefreshSucceeded = false
            GGM.professionRosterMembershipCurrent = false
            if GGM.professionSync then
                GGM.professionSync.rosterReady = false
                GGM.CancelProfessionSync(GGM.professionSync)
            end
        end
        local guildOk, inGuild = pcall(_G.IsInGuild)
        if not guildOk or type(inGuild) ~= "boolean" then
            GGM.professionRosterMembershipCurrent = false
            GGM.lastProfessionIndexError = "profession-roster-unavailable"
            refreshProfessionSyncRoster()
            refreshVisibleProfessionCatalog()
            return
        end
        if not inGuild then
            GGM.professionRosterRefreshIssued = false
            GGM.professionRosterRefreshPending = false
            GGM.professionRosterRefreshSucceeded = false
            local ok, err = GGM.ReconcileProfessionGuildRoster(_G, GGM.db)
            if ok then GGM.lastProfessionIndexError = nil else GGM.lastProfessionIndexError = err end
            refreshProfessionSyncRoster()
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
        refreshProfessionSyncRoster()
        refreshVisibleProfessionCatalog()
        requestProfessionAutoSave()
        return
    end

end)
