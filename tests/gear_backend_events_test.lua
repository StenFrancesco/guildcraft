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
        DysgearMemoryDB = NIL,
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

        T.loadAddonFile("DysgearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "DysgearMemory")
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
        DysgearMemoryDB = NIL,
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

        T.loadAddonFile("DysgearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "DysgearMemory")
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

        T.loadAddonFile("DysgearMemory/Main.lua", GGM)
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
        DysgearMemoryDB = NIL,
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

        T.loadAddonFile("DysgearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "DysgearMemory")

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
        DysgearMemoryDB = NIL,
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

        T.loadAddonFile("DysgearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "DysgearMemory")
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
        DysgearMemoryDB = NIL,
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

        T.loadAddonFile("DysgearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "DysgearMemory")
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
        DysgearMemoryDB = NIL,
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

        T.loadAddonFile("DysgearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "DysgearMemory")
        onEvent(frame, "PLAYER_LOGIN")
        deferredStartup()

        T.assertEqual(startCount, 1)
        T.assertNil(GGM.guildSync)
        T.assertEqual(GGM.lastSyncError, "prefix-register-failed:MaxPrefixes")
    end)
end)
