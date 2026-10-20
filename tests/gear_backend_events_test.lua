local T = require("tests.testlib")

local NIL = {}

local function withGlobals(replacements, fn)
    replacements.DysgearMemoryAPI = NIL
    replacements.DysgearMemoryError = NIL
    replacements.GuildGearMemoryGearChanged = NIL
    local originals = {}

    for key, value in pairs(replacements) do
        originals[key] = {
            existed = rawget(_G, key) ~= nil,
            value = rawget(_G, key),
        }

        if value == NIL then
            _G[key] = nil
        else
            _G[key] = value
        end
    end

    local ok, err = pcall(fn)

    for key, original in pairs(originals) do
        if original.existed then
            _G[key] = original.value
        else
            _G[key] = nil
        end
    end

    if not ok then
        error(err, 0)
    end
end

local function stubBackend(GGM)
    GGM.InitializeGearDatabase = function(existing) return GGM.InitializeDatabase(existing) end
    GGM.CreateGuildSync = GGM.CreateGuildSync or function() return {}, nil end
    GGM.RegisterGuildSync = GGM.RegisterGuildSync or function() return true, nil end
    GGM.PublishConfirmedSlot = GGM.PublishConfirmedSlot or function() return true, nil end
    GGM.HandleGuildSyncAddonMessage = GGM.HandleGuildSyncAddonMessage or function() return "ignored", nil end
end

T.test("player login defers stable gear tracking until equipment is ready", function()
    local onEvent
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler)
            onEvent = handler
        end,
    }

    local startCount = 0
    local deferredStartup
    local tracker = { pendingBySlot = {} }

    withGlobals({
        CreateFrame = function()
            return frame
        end,
        C_Timer = {
            After = function(delay, callback)
                T.assertEqual(delay, 1)
                deferredStartup = callback
            end,
        },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = {
            DEFAULT_STABILITY_DELAY_SECONDS = 300,
        }
        stubBackend(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.StartLocalPlayerGearTracking = function(api, db, delay)
            T.assertTrue(api == _G)
            T.assertTrue(db == GGM.db)
            T.assertEqual(delay, 300)
            startCount = startCount + 1
            return tracker, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            return "ignored", nil
        end

        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")

        T.assertEqual(startCount, 0)
        T.assertNotNil(deferredStartup)
        deferredStartup()

        T.assertEqual(startCount, 1)
        T.assertTrue(GGM.gearTracker == tracker)
        T.assertNil(GGM.lastGearTrackingError)
    end)
end)

T.test("equipment change routes the changed inventory slot to the active tracker", function()
    local onEvent
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler)
            onEvent = handler
        end,
    }

    local tracker = { pendingBySlot = {} }
    local routedTracker
    local routedSlotID

    withGlobals({
        CreateFrame = function()
            return frame
        end,
        C_Timer = { After = function(_, callback) callback() end },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = {
            DEFAULT_STABILITY_DELAY_SECONDS = 300,
        }
        stubBackend(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.StartLocalPlayerGearTracking = function()
            return tracker, nil
        end
        GGM.HandlePlayerEquipmentChanged = function(activeTracker, equipmentSlotID)
            routedTracker = activeTracker
            routedSlotID = equipmentSlotID
            return "pending", nil
        end

        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")
        onEvent(frame, "PLAYER_EQUIPMENT_CHANGED", 16, true)

        T.assertTrue(routedTracker == tracker)
        T.assertEqual(routedSlotID, 16)
        T.assertNil(GGM.lastGearTrackingError)
    end)
end)

T.test("equipment change before tracker startup is ignored", function()
    local onEvent
    local routed = false
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler)
            onEvent = handler
        end,
    }

    withGlobals({
        CreateFrame = function()
            return frame
        end,
    }, function()
        local GGM = {}
        stubBackend(GGM)
        GGM.InitializeDatabase = function(existing)
            return existing or { schemaVersion = 1, characters = {} }, nil
        end
        GGM.StartLocalPlayerGearTracking = function()
            return {}, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            routed = true
            return "pending", nil
        end

        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "PLAYER_EQUIPMENT_CHANGED", 16, true)

        T.assertFalse(routed)
    end)
end)

T.test("addon loaded creates and registers guild sync without sending a logical message", function()
    local onEvent
    local publishCount = 0
    local createdDb
    local sync = { marker = "sync" }
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler)
            onEvent = handler
        end,
    }

    withGlobals({
        CreateFrame = function()
            return frame
        end,
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = {}
        stubBackend(GGM)
        GGM.InitializeDatabase = function()
            createdDb = { schemaVersion = 1, characters = {} }
            return createdDb, nil
        end
        GGM.CreateGuildSync = function(api, db)
            T.assertTrue(api == _G)
            T.assertTrue(db == createdDb)
            return sync, nil
        end
        GGM.RegisterGuildSync = function(activeSync)
            T.assertTrue(activeSync == sync)
            return true, nil
        end
        GGM.PublishConfirmedSlot = function()
            publishCount = publishCount + 1
            return true, nil
        end
        GGM.StartLocalPlayerGearTracking = function()
            return {}, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            return "ignored", nil
        end

        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")

        T.assertTrue(GGM.guildSync == sync)
        T.assertEqual(publishCount, 0)
        T.assertNil(GGM.lastSyncError)
    end)
end)

T.test("player login passes a post-persistence publisher into local tracking but does not publish by itself", function()
    local onEvent
    local deferredStartup
    local confirmationCallback
    local publishCount = 0
    local sync = { marker = "sync" }
    local tracker = { marker = "tracker" }
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler)
            onEvent = handler
        end,
    }

    withGlobals({
        CreateFrame = function()
            return frame
        end,
        C_Timer = {
            After = function(_, callback)
                deferredStartup = callback
            end,
        },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = {
            DEFAULT_STABILITY_DELAY_SECONDS = 300,
        }
        stubBackend(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.CreateGuildSync = function()
            return sync, nil
        end
        GGM.RegisterGuildSync = function()
            return true, nil
        end
        GGM.StartLocalPlayerGearTracking = function(_, _, delay, onConfirmed)
            T.assertEqual(delay, 300)
            confirmationCallback = onConfirmed
            return tracker, nil
        end
        GGM.PublishConfirmedSlot = function(activeSync, characterKey, slotKey, slotValue, confirmedAt, confirmedSequence)
            T.assertTrue(activeSync == sync)
            T.assertEqual(characterKey, "Alice-Silvermoon")
            T.assertEqual(slotKey, "HEAD")
            T.assertEqual(slotValue.itemID, 9999)
            T.assertEqual(confirmedAt, 1700003000)
            T.assertEqual(confirmedSequence, 6)
            publishCount = publishCount + 1
            return true, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            return "ignored", nil
        end

        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")

        T.assertEqual(publishCount, 0)
        T.assertNotNil(deferredStartup)
        deferredStartup()
        T.assertEqual(publishCount, 0)
        T.assertNotNil(confirmationCallback)
        T.assertTrue(sync.localGearTracker == tracker)

        confirmationCallback(
            "Alice-Silvermoon",
            "HEAD",
            { inventorySlotID = 1, itemID = 9999, itemLink = "|Hitem:9999|h[Test]|h" },
            1700003000,
            6
        )

        T.assertEqual(publishCount, 1)
        T.assertNil(GGM.lastSyncError)
    end)
end)

T.test("chat msg addon routes the full addon-message tuple to guild sync", function()
    local onEvent
    local received
    local sync = { marker = "sync" }
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler)
            onEvent = handler
        end,
    }

    withGlobals({
        CreateFrame = function()
            return frame
        end,
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = {}
        stubBackend(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.CreateGuildSync = function()
            return sync, nil
        end
        GGM.RegisterGuildSync = function()
            return true, nil
        end
        GGM.StartLocalPlayerGearTracking = function()
            return {}, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            return "ignored", nil
        end
        GGM.HandleGuildSyncAddonMessage = function(activeSync, prefix, text, channel, sender)
            received = {
                sync = activeSync,
                prefix = prefix,
                text = text,
                channel = channel,
                sender = sender,
            }
            return "slot-applied", nil
        end

        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "CHAT_MSG_ADDON", "DysGuildGear", "frame", "GUILD", "Alice-Silvermoon")

        T.assertTrue(received.sync == sync)
        T.assertEqual(received.prefix, "DysGuildGear")
        T.assertEqual(received.text, "frame")
        T.assertEqual(received.channel, "GUILD")
        T.assertEqual(received.sender, "Alice-Silvermoon")
        T.assertNil(GGM.lastSyncReceiveError)
    end)
end)

T.test("sync registration failure does not disable local stable tracking", function()
    local onEvent
    local deferredStartup
    local startCount = 0
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler)
            onEvent = handler
        end,
    }

    withGlobals({
        CreateFrame = function()
            return frame
        end,
        C_Timer = {
            After = function(_, callback)
                deferredStartup = callback
            end,
        },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = {
            DEFAULT_STABILITY_DELAY_SECONDS = 300,
        }
        stubBackend(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.CreateGuildSync = function()
            return {}, nil
        end
        GGM.RegisterGuildSync = function()
            return false, "prefix-register-failed:MaxPrefixes"
        end
        GGM.StartLocalPlayerGearTracking = function()
            startCount = startCount + 1
            return {}, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            return "ignored", nil
        end

        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")
        deferredStartup()

        T.assertEqual(startCount, 1)
        T.assertNil(GGM.guildSync)
        T.assertEqual(GGM.lastSyncError, "prefix-register-failed:MaxPrefixes")
    end)
end)

T.test("login retries a transient local capture failure and keeps one active tracker", function()
    local onEvent
    local pending
    local scheduledDelays = {}
    local starts = 0
    local tracker = { pendingBySlot = {} }
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }
    withGlobals({
        CreateFrame = function() return frame end,
        C_Timer = { After = function(delay, callback)
            scheduledDelays[#scheduledDelays + 1] = delay
            pending = callback
        end },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = { DEFAULT_STABILITY_DELAY_SECONDS = 300 }
        stubBackend(GGM)
        GGM.InitializeDatabase = function() return { schemaVersion = 1, characters = {} }, nil end
        local sync = {}
        GGM.CreateGuildSync = function() return sync, nil end
        GGM.RegisterGuildSync = function() return true, nil end
        GGM.StartLocalPlayerGearTracking = function()
            starts = starts + 1
            if starts == 1 then return nil, "item-link-unavailable:HEAD" end
            return tracker, nil
        end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end
        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")
        T.assertEqual(scheduledDelays[1], 1)
        onEvent(frame, "PLAYER_LOGIN")
        pending()
        T.assertEqual(starts, 1)
        T.assertEqual(GGM.lastGearTrackingError, "item-link-unavailable:HEAD")
        T.assertEqual(scheduledDelays[2], 2)
        local retry = pending
        onEvent(frame, "PLAYER_LOGIN")
        retry()
        T.assertEqual(starts, 2)
        T.assertTrue(GGM.gearTracker == tracker)
        T.assertTrue(sync.localGearTracker == tracker)
        T.assertNil(GGM.lastGearTrackingError)
        T.assertEqual(#scheduledDelays, 2)
    end)
end)

T.test("permanent local capture failures stop after six bounded attempts", function()
    local onEvent
    local timers, starts = {}, 0
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }
    withGlobals({
        CreateFrame = function() return frame end,
        C_Timer = { After = function(delay, callback)
            timers[#timers + 1] = { delay = delay, callback = callback }
        end },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = { DEFAULT_STABILITY_DELAY_SECONDS = 300 }
        stubBackend(GGM)
        GGM.InitializeDatabase = function() return { schemaVersion = 1, characters = {} }, nil end
        GGM.StartLocalPlayerGearTracking = function()
            starts = starts + 1
            return nil, "item-link-unavailable:HEAD"
        end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end
        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")
        for index = 1, 6 do
            T.assertEqual(timers[index].delay, ({ 1, 2, 4, 8, 16, 30 })[index])
            onEvent(frame, "PLAYER_LOGIN")
            timers[index].callback()
        end
        T.assertEqual(starts, 6)
        T.assertEqual(#timers, 6)
        T.assertEqual(GGM.lastGearTrackingError, "item-link-unavailable:HEAD")
        T.assertTrue(GGM.trackingStartupExhausted)
        onEvent(frame, "PLAYER_LOGIN")
        onEvent(frame, "PLAYER_EQUIPMENT_CHANGED", 1, true)
        T.assertEqual(#timers, 6)
        T.assertEqual(starts, 6)
    end)
end)

T.test("a tracker returned with a reconciliation error is retained without duplicate startup", function()
    local onEvent
    local timers, starts = {}, 0
    local tracker = { pendingBySlot = {} }
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }
    withGlobals({
        CreateFrame = function() return frame end,
        C_Timer = { After = function(delay, callback)
            timers[#timers + 1] = { delay = delay, callback = callback }
        end },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = { DEFAULT_STABILITY_DELAY_SECONDS = 300 }
        stubBackend(GGM)
        GGM.InitializeDatabase = function() return { schemaVersion = 1, characters = {} }, nil end
        local sync = {}
        GGM.CreateGuildSync = function() return sync, nil end
        GGM.RegisterGuildSync = function() return true, nil end
        GGM.StartLocalPlayerGearTracking = function()
            starts = starts + 1
            return tracker, "item-link-unavailable:HEAD"
        end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end
        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")
        timers[1].callback()
        onEvent(frame, "PLAYER_LOGIN")
        T.assertEqual(starts, 1)
        T.assertEqual(#timers, 1)
        T.assertTrue(GGM.gearTracker == tracker)
        T.assertTrue(sync.localGearTracker == tracker)
        T.assertEqual(GGM.lastGearTrackingError, "item-link-unavailable:HEAD")
    end)
end)


T.test("a request for this player retries capture only after startup exhaustion and at five-second intervals", function()
    local onEvent
    local timers, starts, now = {}, 0, 100
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1234-AAAA" }
    local tracker = { pendingBySlot = {} }
    local confirmationPublisher
    local frame = { RegisterEvent = function() end, SetScript = function(_, _, handler) onEvent = handler end }
    withGlobals({
        CreateFrame = function() return frame end,
        GetTime = function() return now end,
        issecretvalue = function() return false end,
        C_Timer = { After = function(delay, callback) timers[#timers + 1] = { delay = delay, callback = callback } end },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = { DEFAULT_STABILITY_DELAY_SECONDS = 300 }
        stubBackend(GGM)
        GGM.InitializeDatabase = function() return { schemaVersion = 1, characters = {} }, nil end
        GGM.BuildPlayerIdentity = function() return identity end
        local sync = {}
        GGM.CreateGuildSync = function() return sync, nil end
        GGM.RegisterGuildSync = function() return true, nil end
        GGM.StartLocalPlayerGearTracking = function(_, _, _, onConfirmed)
            starts = starts + 1
            confirmationPublisher = onConfirmed
            if starts < 8 then return nil, "item-link-unavailable:HEAD" end
            return tracker, nil
        end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end
        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")
        for index = 1, 6 do timers[index].callback() end
        T.assertTrue(GGM.trackingStartupExhausted)
        local requestTarget = { key = identity.key, name = identity.name, realm = identity.realm, guid = identity.guid }
        local mismatched = { key = identity.key, name = identity.name, realm = identity.realm, guid = "Player-1234-OTHER" }
        T.assertFalse(sync.onLocalSnapshotRequest(mismatched))
        T.assertEqual(starts, 6)
        T.assertFalse(sync.onLocalSnapshotRequest(requestTarget))
        T.assertEqual(starts, 7)
        T.assertEqual(#timers, 6)
        T.assertFalse(sync.onLocalSnapshotRequest(requestTarget))
        now = now + 4.9
        T.assertFalse(sync.onLocalSnapshotRequest(requestTarget))
        T.assertEqual(starts, 7)
        now = now + 0.1
        T.assertTrue(sync.onLocalSnapshotRequest(requestTarget))
        T.assertEqual(starts, 8)
        T.assertTrue(GGM.gearTracker == tracker)
        T.assertTrue(sync.localGearTracker == tracker)
        T.assertTrue(type(confirmationPublisher) == "function")
        T.assertNil(GGM.lastGearTrackingError)
    end)
end)


T.test("readiness fail-closes on a secret guild realm", function()
    local onEvent
    local startup
    local timers = {}
    local frame = { RegisterEvent = function() end, SetScript = function(_, _, handler) onEvent = handler end }
    withGlobals({
        CreateFrame = function() return frame end,
        GetRealmName = function() return "Silvermoon" end,
        GetTime = function() return 100 end,
        IsInGuild = function() return true end,
        InCombatLockdown = function() return false end,
        issecretvalue = function(value) return value == "secret" end,
        GetGuildInfo = function() return "Guild", nil, nil, "secret" end,
        C_Timer = {
            After = function(_, callback) startup = callback end,
            NewTimer = function(delay, callback) timers[#timers + 1] = { delay = delay, callback = callback }; return { Cancel = function() end } end,
        },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = {}
        stubBackend(GGM)
        GGM.InitializeDatabase = function() return { schemaVersion = 1, characters = {} }, nil end
        GGM.CreateGuildSync = function() return {}, nil end
        GGM.RegisterGuildSync = function() return true, nil end
        GGM.StartLocalPlayerGearTracking = function() return { pendingBySlot = {} }, nil end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end
        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")
        startup()
        onEvent(frame, "GUILD_ROSTER_UPDATE")
        T.assertEqual(#timers, 0)
    end)
end)

T.test("readiness send failure stays pending and a guild exit cancels stale work", function()
    local onEvent
    local startup
    local currentGuild, now = "Guild A", 100
    local timers, finishReady, cancelled = {}, nil, 0
    local frame = { RegisterEvent = function() end, SetScript = function(_, _, handler) onEvent = handler end }
    withGlobals({
        CreateFrame = function() return frame end,
        GetRealmName = function() return "Silvermoon" end,
        GetTime = function() return now end,
        IsInGuild = function() return currentGuild ~= nil end,
        InCombatLockdown = function() return false end,
        issecretvalue = function() return false end,
        GetGuildInfo = function() return currentGuild, nil, nil, "Silvermoon" end,
        C_Timer = {
            After = function(_, callback) startup = callback end,
            NewTimer = function(delay, callback)
                local timer = { delay = delay, callback = callback, cancelled = false }
                function timer:Cancel() self.cancelled = true end
                function timer:Fire() if not self.cancelled then self.callback() end end
                timers[#timers + 1] = timer
                return timer
            end,
        },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = {}
        stubBackend(GGM)
        GGM.InitializeDatabase = function() return { schemaVersion = 1, characters = {} }, nil end
        local sync = { transport = {} }
        GGM.CreateGuildSync = function() return sync, nil end
        GGM.RegisterGuildSync = function() return true, nil end
        GGM.StartLocalPlayerGearTracking = function() return { pendingBySlot = {} }, nil end
        GGM.CancelSyncPayload = function(_, token) T.assertTrue(token == "ready-token"); cancelled = cancelled + 1 end
        GGM.AnnounceLocalGearReady = function(_, onFinished)
            finishReady = onFinished
            return true, nil, "ready-token"
        end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end
        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")
        startup()
        onEvent(frame, "PLAYER_GUILD_UPDATE")
        timers[1]:Fire()
        T.assertTrue(GGM.gearReadyPending)
        finishReady(false, "send-addon-message-failed:NotInGuild")
        T.assertEqual(#timers, 2)
        currentGuild = nil
        now = now + 5
        onEvent(frame, "PLAYER_GUILD_UPDATE")
        T.assertTrue(timers[2].cancelled)
        T.assertTrue(GGM.gearReadyPending)
        currentGuild = "Guild B"
        now = now + 5
        onEvent(frame, "PLAYER_GUILD_UPDATE")
        T.assertEqual(#timers, 3)
        timers[3]:Fire()
        T.assertEqual(cancelled, 0)
        T.assertTrue(GGM.gearReadyInFlight ~= nil)
        currentGuild = nil
        onEvent(frame, "PLAYER_GUILD_UPDATE")
        T.assertEqual(cancelled, 1)
        T.assertNil(GGM.gearReadyInFlight)
    end)
end)

T.test("gear readiness defers until usable membership and cancels stale guild timers", function()
    local onEvent
    local startup
    local timers, readyCount = {}, 0
    local currentGuild, now = nil, 100
    local frame = { RegisterEvent = function() end, SetScript = function(_, _, handler) onEvent = handler end }
    withGlobals({
        CreateFrame = function() return frame end,
        GetRealmName = function() return "Silvermoon" end,
        GetTime = function() return now end,
        IsInGuild = function() return currentGuild ~= nil end,
        InCombatLockdown = function() return false end,
        issecretvalue = function() return false end,
        GetGuildInfo = function() return currentGuild, nil, nil, "Silvermoon" end,
        C_Timer = {
            After = function(_, callback) startup = callback end,
            NewTimer = function(delay, callback)
                local timer = { delay = delay, callback = callback, cancelled = false }
                function timer:Cancel() self.cancelled = true end
                function timer:Fire() if not self.cancelled then self.callback() end end
                timers[#timers + 1] = timer
                return timer
            end,
        },
        TheGuildBookGearDB = NIL,
    }, function()
        local GGM = {}
        stubBackend(GGM)
        GGM.InitializeDatabase = function() return { schemaVersion = 1, characters = {} }, nil end
        local sync = {}
        GGM.CreateGuildSync = function() return sync, nil end
        GGM.RegisterGuildSync = function() return true, nil end
        GGM.StartLocalPlayerGearTracking = function() return { pendingBySlot = {} }, nil end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end
        GGM.AnnounceLocalGearReady = function(activeSync, onFinished)
            T.assertTrue(activeSync == sync)
            readyCount = readyCount + 1
            onFinished(true, nil)
            return true, nil, {}
        end
        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "The Guild Book gear")
        onEvent(frame, "PLAYER_LOGIN")
        startup()
        T.assertEqual(#timers, 0)

        currentGuild = "Guild A"
        now = now + 5
        onEvent(frame, "PLAYER_GUILD_UPDATE")
        T.assertEqual(#timers, 1)
        T.assertTrue(timers[1].delay >= 1 and timers[1].delay <= 3)
        currentGuild = "Guild B"
        onEvent(frame, "GUILD_ROSTER_UPDATE")
        T.assertTrue(timers[1].cancelled)
        T.assertEqual(#timers, 2)
        timers[1]:Fire()
        T.assertEqual(readyCount, 0)
        timers[2]:Fire()
        T.assertEqual(readyCount, 1)
        local timerCount = #timers
        onEvent(frame, "GUILD_ROSTER_UPDATE")
        T.assertEqual(#timers, timerCount)
        currentGuild = "Guild A"
        now = now + 5
        onEvent(frame, "PLAYER_GUILD_UPDATE")
        T.assertEqual(#timers, timerCount + 1)
        timers[#timers]:Fire()
        T.assertEqual(readyCount, 2)
    end)
end)
