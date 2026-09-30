local ADDON_NAME, GGM = ...

GGM.professionRosterMembershipCurrent = false
GGM.professionRosterRefreshIssued = false
GGM.professionRosterRefreshPending = false

GGM.RegisterSnapshotTestSlashCommand(_G)

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("CHAT_MSG_GUILD")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
frame:RegisterEvent("TRADE_SKILL_CLOSE")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

local function publishConfirmedSlot(characterKey, slotKey, slotValue, confirmedAt, confirmedSequence)
    if not GGM.guildSync then
        return
    end

    local queued, queueErr = GGM.PublishConfirmedSlot(
        GGM.guildSync,
        characterKey,
        slotKey,
        slotValue,
        confirmedAt,
        confirmedSequence
    )

    if queued then
        GGM.lastSyncError = nil
    else
        GGM.lastSyncError = queueErr
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    local arg1 = ...

    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then
            return
        end

        local db, err = GGM.InitializeDatabase(GuildGearMemoryDB)
        if not db then
            GGM.startupError = err
            return
        end

        GuildGearMemoryDB = db
        GGM.db = db
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

        local sync, syncErr = GGM.CreateGuildSync(_G, db)
        if not sync then
            GGM.guildSync = nil
            GGM.lastSyncError = syncErr
            return
        end

        local registered, registerErr = GGM.RegisterGuildSync(sync)
        if not registered then
            GGM.guildSync = nil
            GGM.lastSyncError = registerErr
            return
        end

        GGM.guildSync = sync
        GGM.lastSyncError = nil
        return
    end

    if event == "PLAYER_LOGIN" then
        if not GGM.db or GGM.startupError then
            return
        end

        C_Timer.After(1, function()
            if GGM.gearTracker or GGM.startupError or not GGM.db then
                return
            end

            local tracker, err = GGM.StartLocalPlayerGearTracking(
                _G,
                GGM.db,
                GGM.DEFAULT_STABILITY_DELAY_SECONDS,
                publishConfirmedSlot
            )
            GGM.gearTracker = tracker
            if GGM.guildSync then
                GGM.guildSync.localGearTracker = tracker
            end
            GGM.lastGearTrackingError = err
            GGM.lastCaptureError = err
        end)
        return
    end

    if event == "PLAYER_EQUIPMENT_CHANGED" then
        if not GGM.gearTracker or GGM.startupError then
            return
        end

        local _, err = GGM.HandlePlayerEquipmentChanged(GGM.gearTracker, arg1)
        GGM.lastGearTrackingError = err
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
        GGM.professionRosterMembershipCurrent = false
        local guildOk, inGuild = pcall(_G.IsInGuild)
        if not guildOk or type(inGuild) ~= "boolean" then
            GGM.lastProfessionIndexError = "profession-roster-unavailable"
            return
        end
        if not inGuild then
            GGM.professionRosterRefreshIssued = false
            GGM.professionRosterRefreshPending = false
            local ok, err = GGM.ReconcileProfessionGuildRoster(_G, GGM.db)
            if ok then GGM.lastProfessionIndexError = nil else GGM.lastProfessionIndexError = err end
            return
        end
        if GGM.professionRosterRefreshIssued then return end
        GGM.professionRosterMembershipCurrent = false
        GGM.professionRosterRefreshIssued = true
        local guildInfo = _G.C_GuildInfo
        if type(guildInfo) ~= "table" or type(guildInfo.GuildRoster) ~= "function" then
            GGM.lastProfessionIndexError = "profession-roster-unavailable"
            return
        end
        GGM.professionRosterRefreshPending = true
        local requestOk = pcall(guildInfo.GuildRoster)
        if not requestOk then
            GGM.professionRosterRefreshPending = false
            GGM.lastProfessionIndexError = "profession-roster-unavailable"
        end
        return
    end

    if event == "GUILD_ROSTER_UPDATE" then
        if not GGM.db or GGM.startupError or not GGM.professionRosterRefreshIssued then return end
        GGM.professionRosterRefreshPending = false
        local ok, err = GGM.ReconcileProfessionGuildRoster(_G, GGM.db)
        if ok then GGM.lastProfessionIndexError = nil else GGM.lastProfessionIndexError = err end
        return
    end

    if event == "CHAT_MSG_ADDON" then
        if not GGM.guildSync or GGM.startupError then
            return
        end

        local prefix, text, channel, sender = ...
        local _, receiveErr = GGM.HandleGuildSyncAddonMessage(
            GGM.guildSync,
            prefix,
            text,
            channel,
            sender
        )
        GGM.lastSyncReceiveError = receiveErr
    end
end)
