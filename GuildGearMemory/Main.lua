local ADDON_NAME, GGM = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("CHAT_MSG_ADDON")

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

        GGM.RegisterSnapshotTestSlashCommand(_G)

        local db, err = GGM.InitializeDatabase(GuildGearMemoryDB)
        if not db then
            GGM.startupError = err
            return
        end

        GuildGearMemoryDB = db
        GGM.db = db
        GGM.startupError = nil

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
