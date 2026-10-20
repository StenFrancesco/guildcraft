local ADDON_NAME, GearMemory = ...
local api = _G

local frame = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_EQUIPMENT_CHANGED", "CHAT_MSG_ADDON",
    "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "PLAYER_UPDATE_RESTING", "PLAYER_REGEN_ENABLED" }) do
    frame:RegisterEvent(event)
end

local function notifyDisplay()
    if type(api.GuildGearMemoryGearChanged) == "function" then pcall(api.GuildGearMemoryGearChanged) end
end

local function publishConfirmedSlot(...)
    if not GearMemory.guildSync then return end
    local queued, err = GearMemory.PublishConfirmedSlot(GearMemory.guildSync, ...)
    if queued then GearMemory.lastSyncError = nil else GearMemory.lastSyncError = err end
    notifyDisplay()
end

frame:SetScript("OnEvent", function(_, event, ...)
    local arg1 = ...
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        local database, err = GearMemory.InitializeGearDatabase(api.TheGuildBookGearDB)
        api.DysgearMemoryError = err
        GearMemory.startupError = err
        if not database then
            api.DysgearMemoryAPI = nil
            notifyDisplay()
            return
        end
        api.TheGuildBookGearDB = database
        GearMemory.db = database
        api.DysgearMemoryAPI = {
            schemaVersion = 2,
            GetDatabase = function() return GearMemory.db end,
            GetBackend = function() return GearMemory end,
        }
        local sync, syncErr = GearMemory.CreateGuildSync(api, database)
        if sync then
            local registered, registerErr = GearMemory.RegisterGuildSync(sync)
            if registered then GearMemory.guildSync = sync else syncErr = registerErr end
        end
        GearMemory.lastSyncError = syncErr
        notifyDisplay()
        return
    end

    if not GearMemory.db or GearMemory.startupError then return end

    if event == "PLAYER_LOGIN" then
        if GearMemory.guildSync and type(GearMemory.LoginGearSync) == "function" then GearMemory.LoginGearSync(GearMemory.guildSync) end
        if GearMemory.gearTracker or GearMemory.trackingStartupScheduled then return end
        GearMemory.trackingStartupScheduled = true
        api.C_Timer.After(1, function()
            GearMemory.trackingStartupScheduled = false
            if GearMemory.gearTracker or GearMemory.startupError then return end
            local tracker, err = GearMemory.StartLocalPlayerGearTracking(
                api, GearMemory.db, GearMemory.DEFAULT_STABILITY_DELAY_SECONDS, publishConfirmedSlot
            )
            GearMemory.gearTracker = tracker
            if GearMemory.guildSync then GearMemory.guildSync.localGearTracker = tracker end
            GearMemory.lastGearTrackingError = err
            GearMemory.lastCaptureError = err
            notifyDisplay()
        end)
        return
    end

    if event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" or event == "PLAYER_ENTERING_WORLD"
        or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS"
        or event == "PLAYER_UPDATE_RESTING" or event == "PLAYER_REGEN_ENABLED" then
        if type(GearMemory.WakeGearSync) == "function" then GearMemory.WakeGearSync(GearMemory.guildSync) end
        return
    end

    if event == "PLAYER_EQUIPMENT_CHANGED" then
        if not GearMemory.gearTracker then return end
        local _, err = GearMemory.HandlePlayerEquipmentChanged(GearMemory.gearTracker, arg1)
        GearMemory.lastGearTrackingError = err
        notifyDisplay()
        return
    end

    if event == "CHAT_MSG_ADDON" then
        if not GearMemory.guildSync then return end
        local _, err = GearMemory.HandleGuildSyncAddonMessage(GearMemory.guildSync, ...)
        GearMemory.lastSyncReceiveError = err
        notifyDisplay()
    end
end)
