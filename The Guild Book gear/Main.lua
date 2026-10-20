local ADDON_NAME, GearMemory = ...
local api = _G

local TRACKING_RETRY_DELAYS = { 1, 2, 4, 8, 16, 30 }
local READY_RETRY_DELAYS = { 1, 2, 4 }
local MIN_REQUEST_RECOVERY_INTERVAL = 5

local frame = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_EQUIPMENT_CHANGED", "CHAT_MSG_ADDON", "INSPECT_READY",
    "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "PLAYER_UPDATE_RESTING", "PLAYER_REGEN_ENABLED" }) do
    frame:RegisterEvent(event)
end

local function notifyDisplay(dataChanged)
    if type(api.GuildGearMemoryGearChanged) == "function" then pcall(api.GuildGearMemoryGearChanged, dataChanged == true) end
end

local function publishConfirmedSlot(...)
    if not GearMemory.guildSync then notifyDisplay(true); return end
    local queued, err = GearMemory.PublishConfirmedSlot(GearMemory.guildSync, ...)
    if queued then GearMemory.lastSyncError = nil else GearMemory.lastSyncError = err end
    notifyDisplay(true)
end

local function isPublic(value)
    if type(api.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(api.issecretvalue, value)
    return ok and secret == false
end

local function normalizeRealm(realm)
    return type(realm) == "string" and realm:gsub("%s", ""):lower() or nil
end

local function currentGuildKey()
    if type(api.IsInGuild) ~= "function" or type(api.InCombatLockdown) ~= "function"
        or type(api.GetGuildInfo) ~= "function" then return nil end
    local guildOK, inGuild = pcall(api.IsInGuild)
    local combatOK, inCombat = pcall(api.InCombatLockdown)
    if not guildOK or not combatOK or not isPublic(inGuild) or not isPublic(inCombat)
        or inGuild ~= true or inCombat ~= false then return nil end
    local infoOK, guildName, _, _, guildRealm = pcall(api.GetGuildInfo, "player")
    if not infoOK or not isPublic(guildName) or type(guildName) ~= "string" or guildName == "" then return nil end
    if not isPublic(guildRealm) then return nil end
    if guildRealm == nil or guildRealm == "" then
        local realmOK, realm = pcall(api.GetRealmName)
        if not realmOK or not isPublic(realm) then return nil end
        guildRealm = realm
    end
    if type(guildRealm) ~= "string" or guildRealm == "" then return nil end
    return guildName .. ":" .. guildRealm
end

local function cancelGearReadyTimer()
    local timer = GearMemory.gearReadyTimer
    GearMemory.gearReadyTimer, GearMemory.gearReadyTimerGuild = nil, nil
    GearMemory.gearReadyTimerGeneration = (GearMemory.gearReadyTimerGeneration or 0) + 1
    if timer and type(timer.Cancel) == "function" then pcall(timer.Cancel, timer) end
end

local maybeScheduleGearReady

local function scheduleGearReady(guildKey, delay)
    cancelGearReadyTimer()
    local generation = GearMemory.gearReadyTimerGeneration
    if type(api.C_Timer) ~= "table" or type(api.C_Timer.NewTimer) ~= "function" then
        GearMemory.lastSyncError = "gear-ready-timer-unavailable"
        return false
    end
    local ok, timer = pcall(api.C_Timer.NewTimer, delay, function()
        if GearMemory.gearReadyTimerGeneration ~= generation then return end
        GearMemory.gearReadyTimer, GearMemory.gearReadyTimerGuild = nil, nil
        local currentGuild = currentGuildKey()
        if currentGuild ~= guildKey then
            GearMemory.gearReadyPending = true
            if currentGuild then maybeScheduleGearReady(true) end
            return
        end
        if type(GearMemory.AnnounceLocalGearReady) == "function" and GearMemory.gearTracker then
            local ticket = { guild = guildKey, completed = false }
            GearMemory.gearReadyInFlight = ticket
            local function complete(sent, err)
                if ticket.completed then return end
                ticket.completed = true
                if GearMemory.gearReadyInFlight ~= ticket then return end
                GearMemory.gearReadyInFlight = nil
                if sent == true and currentGuildKey() == guildKey then
                    GearMemory.gearReadyAnnouncedGuilds = GearMemory.gearReadyAnnouncedGuilds or {}
                    GearMemory.gearReadyAnnouncedGuilds[guildKey] = true
                    GearMemory.gearReadyRetryCounts = GearMemory.gearReadyRetryCounts or {}
                    GearMemory.gearReadyRetryCounts[guildKey] = 0
                    GearMemory.gearReadyPending = false
                    GearMemory.lastSyncError = nil
                else
                    GearMemory.gearReadyPending = true
                    GearMemory.lastSyncError = err or "gear-ready-send-failed"
                    if currentGuildKey() == guildKey then
                        GearMemory.gearReadyRetryCounts = GearMemory.gearReadyRetryCounts or {}
                        local count = (GearMemory.gearReadyRetryCounts[guildKey] or 0) + 1
                        GearMemory.gearReadyRetryCounts[guildKey] = count
                        local retryDelay = READY_RETRY_DELAYS[count]
                        if retryDelay then scheduleGearReady(guildKey, retryDelay) end
                    end
                end
                notifyDisplay(true)
            end
            local callOK, queued, sendErr, token = pcall(GearMemory.AnnounceLocalGearReady, GearMemory.guildSync, complete)
            if not callOK then complete(false, tostring(queued))
            elseif queued then
                if GearMemory.gearReadyInFlight == ticket then ticket.token = token end
            else complete(false, sendErr) end
        else
            GearMemory.gearReadyPending = true
        end
    end)
    if not ok or not timer then
        GearMemory.lastSyncError = "gear-ready-timer-create-failed"
        GearMemory.gearReadyPending = true
        return false
    end
    GearMemory.gearReadyTimer, GearMemory.gearReadyTimerGuild = timer, guildKey
    return true
end

maybeScheduleGearReady = function(eventWake)
    if not GearMemory.gearTracker or not GearMemory.guildSync then return false end
    GearMemory.gearReadyPending = true
    local guildKey = currentGuildKey()
    local inFlight = GearMemory.gearReadyInFlight
    if inFlight and inFlight.guild ~= guildKey then
        if inFlight.token and GearMemory.guildSync.transport then
            pcall(GearMemory.CancelSyncPayload, GearMemory.guildSync.transport, inFlight.token)
        end
        GearMemory.gearReadyInFlight = nil
        GearMemory.gearReadyPending = true
    end
    if not guildKey then
        if GearMemory.gearReadyTimer then cancelGearReadyTimer() end
        return false
    end
    GearMemory.gearReadyAnnouncedGuilds = GearMemory.gearReadyAnnouncedGuilds or {}
    if GearMemory.gearReadyAnnouncedGuilds[guildKey] then
        GearMemory.gearReadyPending = false
        return false
    end
    if GearMemory.gearReadyInFlight then return false end
    if GearMemory.gearReadyTimer then
        if GearMemory.gearReadyTimerGuild == guildKey then return false end
        cancelGearReadyTimer()
    end
    GearMemory.gearReadyRetryCounts = GearMemory.gearReadyRetryCounts or {}
    if eventWake then
        local nowOK, now = pcall(api.GetTime)
        if not nowOK or not isPublic(now) or type(now) ~= "number" or now < 0 then return false end
        GearMemory.gearReadyLastWakeAt = GearMemory.gearReadyLastWakeAt or {}
        local lastWake = GearMemory.gearReadyLastWakeAt[guildKey]
        if type(lastWake) == "number" and now >= lastWake and now - lastWake < MIN_REQUEST_RECOVERY_INTERVAL then
            return false
        end
        GearMemory.gearReadyLastWakeAt[guildKey] = now
        GearMemory.gearReadyRetryCounts[guildKey] = 0
    end
    local retryCount = GearMemory.gearReadyRetryCounts[guildKey] or 0
    if retryCount >= #READY_RETRY_DELAYS and not eventWake then return false end
    local jitterOK, jitter = pcall(math.random, 1, 3)
    if not jitterOK or type(jitter) ~= "number" or jitter < 1 or jitter > 3 then jitter = 2 end
    return scheduleGearReady(guildKey, jitter)
end

local function retainGearTracker(tracker, err)
    GearMemory.gearTracker = tracker
    if GearMemory.guildSync then GearMemory.guildSync.localGearTracker = tracker end
    GearMemory.lastGearTrackingError = err
    GearMemory.lastCaptureError = err
    GearMemory.trackingStartupExhausted = false
    if tracker and not err then
        GearMemory.lastGearTrackingError = nil
        GearMemory.lastCaptureError = nil
        maybeScheduleGearReady(false)
    end
    notifyDisplay(true)
end

local function attemptLocalTracking()
    local ok, tracker, err = pcall(GearMemory.StartLocalPlayerGearTracking,
        api, GearMemory.db, GearMemory.DEFAULT_STABILITY_DELAY_SECONDS, publishConfirmedSlot)
    if not ok then
        err, tracker = tostring(tracker), nil
    elseif not tracker and not err then
        err = "local-gear-tracker-unavailable"
    end
    if tracker then retainGearTracker(tracker, err) else
        GearMemory.lastGearTrackingError = err
        GearMemory.lastCaptureError = err
        notifyDisplay(true)
    end
    return tracker, err
end

local function scheduleTrackingAttempt(attemptNumber)
    if attemptNumber > #TRACKING_RETRY_DELAYS then
        GearMemory.trackingStartupScheduled = false
        GearMemory.trackingStartupExhausted = true
        return false
    end
    if GearMemory.trackingStartupScheduled or GearMemory.gearTracker then return false end
    GearMemory.trackingStartupScheduled = true
    local generation = (GearMemory.trackingStartupGeneration or 0) + 1
    GearMemory.trackingStartupGeneration = generation
    local delay = TRACKING_RETRY_DELAYS[attemptNumber]
    local timerOK = type(api.C_Timer) == "table" and type(api.C_Timer.After) == "function"
    if not timerOK then
        GearMemory.trackingStartupScheduled = false
        GearMemory.trackingStartupExhausted = true
        GearMemory.lastGearTrackingError = "gear-capture-timer-unavailable"
        GearMemory.lastCaptureError = GearMemory.lastGearTrackingError
        return false
    end
    local ok, timerErr = pcall(api.C_Timer.After, delay, function()
        if GearMemory.trackingStartupGeneration ~= generation or not GearMemory.trackingStartupScheduled then return end
        GearMemory.trackingStartupScheduled = false
        if GearMemory.gearTracker or GearMemory.startupError then return end
        GearMemory.trackingStartupAttempts = (GearMemory.trackingStartupAttempts or 0) + 1
        local tracker = attemptLocalTracking()
        if tracker then return end
        local nextAttempt = attemptNumber + 1
        if nextAttempt <= #TRACKING_RETRY_DELAYS then
            scheduleTrackingAttempt(nextAttempt)
        else
            GearMemory.trackingStartupExhausted = true
            notifyDisplay(true)
        end
    end)
    if not ok then
        GearMemory.trackingStartupScheduled = false
        GearMemory.trackingStartupExhausted = true
        GearMemory.lastGearTrackingError = "gear-capture-timer-failed:" .. tostring(timerErr)
        GearMemory.lastCaptureError = GearMemory.lastGearTrackingError
        return false
    end
    return true
end

local function sameLocalCharacter(target)
    if type(target) ~= "table" or type(GearMemory.BuildPlayerIdentity) ~= "function" then return false end
    local ok, localIdentity, identityErr = pcall(GearMemory.BuildPlayerIdentity, api)
    if not ok or not localIdentity then
        GearMemory.lastSnapshotRecoveryError = ok and identityErr or tostring(localIdentity)
        return false
    end
    if target.name ~= localIdentity.name or normalizeRealm(target.realm) ~= normalizeRealm(localIdentity.realm) then return false end
    if target.guid ~= nil and localIdentity.guid ~= nil and target.guid ~= localIdentity.guid then return false end
    return true
end

local function recoverLocalSnapshot(target)
    if GearMemory.gearTracker or not GearMemory.trackingStartupExhausted then return false, "local-capture-not-exhausted" end
    if not sameLocalCharacter(target) then return false, "local-snapshot-target-mismatch" end
    local ok, now = pcall(api.GetTime)
    if not ok or not isPublic(now) or type(now) ~= "number" or now < 0 then
        return false, "local-snapshot-recovery-time-unavailable"
    end
    local lastAttempt = GearMemory.lastSnapshotRecoveryAt
    if type(lastAttempt) == "number" and now - lastAttempt < MIN_REQUEST_RECOVERY_INTERVAL then
        return false, "local-snapshot-recovery-throttled"
    end
    GearMemory.lastSnapshotRecoveryAt = now
    local tracker, err = attemptLocalTracking()
    if not tracker then return false, err end
    return true, nil
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
            if registered then
                GearMemory.guildSync = sync
                sync.onChanged = notifyDisplay
                sync.onLocalSnapshotRequest = recoverLocalSnapshot
            else syncErr = registerErr end
        end
        GearMemory.lastSyncError = syncErr
        if type(GearMemory.InstallInspectGearCapture) == "function" then
            local inspectCapture, inspectErr = GearMemory.InstallInspectGearCapture(api, database, function()
                notifyDisplay(true)
            end)
            GearMemory.inspectGearCapture = inspectCapture
            GearMemory.lastInspectCaptureError = inspectErr
        end
        notifyDisplay()
        return
    end

    if not GearMemory.db or GearMemory.startupError then return end

    if event == "INSPECT_READY" then
        if type(GearMemory.HandleInspectGearReady) ~= "function" or not GearMemory.inspectGearCapture then return end
        local _, inspectErr = GearMemory.HandleInspectGearReady(GearMemory.inspectGearCapture, arg1)
        if inspectErr then GearMemory.lastInspectCaptureError = inspectErr
        else GearMemory.lastInspectCaptureError = nil end
        return
    end

    if event == "PLAYER_LOGIN" then
        if GearMemory.guildSync and type(GearMemory.LoginGearSync) == "function" then GearMemory.LoginGearSync(GearMemory.guildSync) end
        if not GearMemory.gearTracker and not GearMemory.trackingStartupScheduled
            and not GearMemory.trackingStartupExhausted and not GearMemory.trackingStartupStarted then
            GearMemory.trackingStartupStarted = true
            GearMemory.trackingStartupAttempts = 0
            scheduleTrackingAttempt(1)
        end
        if GearMemory.gearTracker then maybeScheduleGearReady(true) end
        return
    end

    if event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" or event == "PLAYER_ENTERING_WORLD"
        or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS"
        or event == "PLAYER_UPDATE_RESTING" or event == "PLAYER_REGEN_ENABLED" then
        if type(GearMemory.WakeGearSync) == "function" then GearMemory.WakeGearSync(GearMemory.guildSync) end
        if GearMemory.gearTracker then maybeScheduleGearReady(true) end
        return
    end

    if event == "PLAYER_EQUIPMENT_CHANGED" then
        if not GearMemory.gearTracker then return end
        local _, err = GearMemory.HandlePlayerEquipmentChanged(GearMemory.gearTracker, arg1)
        GearMemory.lastGearTrackingError = err
        notifyDisplay()
        if GearMemory.gearReadyPending then maybeScheduleGearReady(false) end
        return
    end

    if event == "CHAT_MSG_ADDON" then
        if not GearMemory.guildSync then return end
        local _, err = GearMemory.HandleGuildSyncAddonMessage(GearMemory.guildSync, ...)
        GearMemory.lastSyncReceiveError = err
        notifyDisplay()
    end
end)