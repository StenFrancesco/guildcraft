local T = require("tests.testlib")

local NIL = {}

local function withGlobals(replacements, fn)
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

local function stubSnapshotUI(GGM, registerFn)
    GGM.RegisterSnapshotTestSlashCommand = registerFn or function() end
    GGM.CreateGuildSync = GGM.CreateGuildSync or function()
        return {}, nil
    end
    GGM.RegisterGuildSync = GGM.RegisterGuildSync or function()
        return true, nil
    end
    GGM.PublishConfirmedSlot = GGM.PublishConfirmedSlot or function()
        return true, nil
    end
    GGM.HandleGuildSyncAddonMessage = GGM.HandleGuildSyncAddonMessage or function()
        return "ignored", nil
    end
    GGM.CreateProfessionLinkSaveController = GGM.CreateProfessionLinkSaveController or function(_, db)
        return { db = db }, nil
    end
    GGM.RegisterProfessionLinkSaveController = GGM.RegisterProfessionLinkSaveController or function()
        return true, nil
    end
    GGM.ObserveGuildProfessionMessage = GGM.ObserveGuildProfessionMessage or function()
        return "ignored", nil
    end
    GGM.RefreshProfessionSaveButton = GGM.RefreshProfessionSaveButton or function()
        return "hidden"
    end
    GGM.ClearProfessionSaveContext = GGM.ClearProfessionSaveContext or function() end
end

T.test("main registers Phase 4 local gear and addon-message events", function()
    local registered = {}
    local onEvent
    local frame = {
        RegisterEvent = function(_, event)
            registered[event] = true
        end,
        SetScript = function(_, scriptName, handler)
            T.assertEqual(scriptName, "OnEvent")
            onEvent = handler
        end,
    }

    withGlobals({
        CreateFrame = function(frameType)
            T.assertEqual(frameType, "Frame")
            return frame
        end,
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function(existing)
            return existing or { schemaVersion = 1, characters = {} }, nil
        end
        GGM.StartLocalPlayerGearTracking = function()
            return {}, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            return "ignored", nil
        end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)

        T.assertTrue(registered.ADDON_LOADED == true)
        T.assertTrue(registered.PLAYER_LOGIN == true)
        T.assertTrue(registered.PLAYER_EQUIPMENT_CHANGED == true)
        T.assertTrue(registered.CHAT_MSG_ADDON == true)
        T.assertTrue(registered.CHAT_MSG_GUILD == true)
        T.assertTrue(registered.TRADE_SKILL_SHOW == true)
        T.assertTrue(registered.TRADE_SKILL_CLOSE == true)
        T.assertTrue(registered.GUILD_ROSTER_UPDATE == true)
        T.assertTrue(registered.PLAYER_GUILD_UPDATE == true)
        T.assertTrue(registered.PLAYER_ENTERING_WORLD == true)
        T.assertFalse(GGM.professionRosterMembershipCurrent)
        T.assertNotNil(onEvent)
    end)
end)

T.test("guild roster refresh is bounded to guild periods and reconciliation waits for roster updates", function()
    local registered = {}
    local onEvent
    local rosterRefreshCount = 0
    local reconcileCount = 0
    local addonMessageCount = 0
    local publishCount = 0
    local isInGuild = true
    local frame = {
        RegisterEvent = function(_, event) registered[event] = true end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }

    withGlobals({
        CreateFrame = function() return frame end,
        GuildGearMemoryDB = NIL,
        IsInGuild = function() return isInGuild end,
        C_GuildInfo = {
            GuildRoster = function() rosterRefreshCount = rosterRefreshCount + 1 end,
        },
        C_ChatInfo = {
            SendAddonMessage = function() addonMessageCount = addonMessageCount + 1 end,
        },
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function(existing)
            return existing or { schemaVersion = 1, characters = {}, professions = {} }, nil
        end
        GGM.CreateGuildSync = function() return {}, nil end
        GGM.RegisterGuildSync = function() return true, nil end
        GGM.PublishConfirmedSlot = function() publishCount = publishCount + 1; return true end
        GGM.ReconcileProfessionGuildRoster = function()
            reconcileCount = reconcileCount + 1
            GGM.professionRosterMembershipCurrent = true
            return true, nil
        end
        GGM.StartLocalPlayerGearTracking = function() return {}, nil end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        onEvent(frame, "PLAYER_ENTERING_WORLD")

        T.assertEqual(rosterRefreshCount, 1)
        T.assertEqual(reconcileCount, 0)
        T.assertTrue(GGM.professionRosterRefreshPending)
        T.assertTrue(GGM.professionRosterRefreshIssued)

        onEvent(frame, "PLAYER_ENTERING_WORLD")
        onEvent(frame, "GUILD_ROSTER_UPDATE")
        T.assertEqual(rosterRefreshCount, 1)
        T.assertEqual(reconcileCount, 1)
        T.assertFalse(GGM.professionRosterRefreshPending)
        T.assertTrue(GGM.professionRosterMembershipCurrent)

        onEvent(frame, "PLAYER_ENTERING_WORLD")
        T.assertTrue(GGM.professionRosterMembershipCurrent)
        T.assertEqual(rosterRefreshCount, 1)
        T.assertEqual(reconcileCount, 1)

        onEvent(frame, "GUILD_ROSTER_UPDATE")
        T.assertEqual(rosterRefreshCount, 1)
        T.assertEqual(reconcileCount, 2)

        isInGuild = false
        onEvent(frame, "PLAYER_GUILD_UPDATE")
        T.assertEqual(reconcileCount, 3)
        T.assertFalse(GGM.professionRosterRefreshIssued)
        T.assertFalse(GGM.professionRosterRefreshPending)

        isInGuild = true
        onEvent(frame, "PLAYER_GUILD_UPDATE")
        T.assertEqual(rosterRefreshCount, 2)
        T.assertEqual(reconcileCount, 3)
        T.assertTrue(GGM.professionRosterRefreshPending)
        onEvent(frame, "GUILD_ROSTER_UPDATE")
        T.assertEqual(reconcileCount, 4)
        T.assertEqual(rosterRefreshCount, 2)
        T.assertEqual(addonMessageCount, 0)
        T.assertEqual(publishCount, 0)
    end)
end)

T.test("guild membership API failure clears cached roster readiness", function()
    local onEvent
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }
    withGlobals({
        CreateFrame = function() return frame end,
        GuildGearMemoryDB = NIL,
        IsInGuild = function() error("guild state unavailable") end,
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {}, professions = {} }, nil
        end
        GGM.CreateGuildSync = function() return {}, nil end
        GGM.RegisterGuildSync = function() return true, nil end
        GGM.ReconcileProfessionGuildRoster = function()
            error("must not reconcile when IsInGuild fails")
        end
        GGM.professionRosterMembershipCurrent = true

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        GGM.professionRosterMembershipCurrent = true
        onEvent(frame, "PLAYER_ENTERING_WORLD")

        T.assertFalse(GGM.professionRosterMembershipCurrent)
        T.assertEqual(GGM.lastProfessionIndexError, "profession-roster-unavailable")
    end)
end)

T.test("failed guild roster refresh cannot make a later roster event authoritative", function()
    for _, failureMode in ipairs({ "missing", "throwing" }) do
        local onEvent
        local refreshCalls = 0
        local reconcileCalls = 0
        local frame = {
            RegisterEvent = function() end,
            SetScript = function(_, _, handler) onEvent = handler end,
        }
        local replacements = {
            CreateFrame = function() return frame end,
            GuildGearMemoryDB = NIL,
            IsInGuild = function() return true end,
        }
        if failureMode == "throwing" then
            replacements.C_GuildInfo = {
                GuildRoster = function()
                    refreshCalls = refreshCalls + 1
                    error("roster refresh failed")
                end,
            }
        else
            replacements.C_GuildInfo = NIL
        end

        withGlobals(replacements, function()
            local GGM = {}
            stubSnapshotUI(GGM)
            GGM.InitializeDatabase = function()
                return { schemaVersion = 4, characters = {}, professions = {} }, nil
            end
            GGM.ReconcileProfessionGuildRoster = function()
                reconcileCalls = reconcileCalls + 1
                GGM.professionRosterMembershipCurrent = true
                return true, nil
            end

            T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
            onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
            onEvent(frame, "PLAYER_ENTERING_WORLD")

            T.assertTrue(GGM.professionRosterRefreshIssued)
            T.assertFalse(GGM.professionRosterRefreshSucceeded)
            T.assertFalse(GGM.professionRosterMembershipCurrent)
            local attemptedRefreshCalls = refreshCalls
            onEvent(frame, "GUILD_ROSTER_UPDATE")

            T.assertEqual(refreshCalls, attemptedRefreshCalls)
            T.assertEqual(reconcileCalls, 0)
            T.assertFalse(GGM.professionRosterMembershipCurrent)
            onEvent(frame, "PLAYER_ENTERING_WORLD")
            T.assertEqual(refreshCalls, attemptedRefreshCalls)
        end)
    end
end)

T.test("guild chat routes message and sender only to profession provenance", function()
    local onEvent
    local observed
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }

    withGlobals({
        CreateFrame = function() return frame end,
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 3, characters = {}, localCharacters = {}, professions = {} }, nil
        end
        GGM.CreateProfessionLinkSaveController = function(_, db)
            return { db = db }, nil
        end
        GGM.RegisterProfessionLinkSaveController = function() return true, nil end
        GGM.ObserveGuildProfessionMessage = function(controller, message, sender)
            observed = { controller = controller, message = message, sender = sender }
            return "observed", nil
        end
        GGM.StartLocalPlayerGearTracking = function() return {}, nil end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        onEvent(frame, "CHAT_MSG_GUILD", "|Htrade:abc|h[Alchemy]|h", "Alice-Silvermoon")

        T.assertTrue(observed.controller == GGM.professionLinkSave)
        T.assertEqual(observed.message, "|Htrade:abc|h[Alchemy]|h")
        T.assertEqual(observed.sender, "Alice-Silvermoon")
    end)
end)

T.test("trade skill show only refreshes the local profession save control", function()
    local onEvent
    local refreshCount = 0
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }

    withGlobals({
        CreateFrame = function() return frame end,
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 3, characters = {}, localCharacters = {}, professions = {} }, nil
        end
        GGM.CreateProfessionLinkSaveController = function() return {}, nil end
        GGM.RegisterProfessionLinkSaveController = function() return true, nil end
        GGM.RefreshProfessionSaveButton = function()
            refreshCount = refreshCount + 1
            return "shown"
        end
        GGM.StartLocalPlayerGearTracking = function() return {}, nil end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        onEvent(frame, "TRADE_SKILL_SHOW")

        T.assertEqual(refreshCount, 1)
    end)
end)

T.test("trade skill list update refreshes the local profession save control after linked data becomes ready", function()
    local onEvent
    local refreshCount = 0
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }

    withGlobals({
        CreateFrame = function() return frame end,
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 3, characters = {}, localCharacters = {}, professions = {} }, nil
        end
        GGM.CreateProfessionLinkSaveController = function() return {}, nil end
        GGM.RegisterProfessionLinkSaveController = function() return true, nil end
        GGM.RefreshProfessionSaveButton = function()
            refreshCount = refreshCount + 1
            return "shown"
        end
        GGM.StartLocalPlayerGearTracking = function() return {}, nil end
        GGM.HandlePlayerEquipmentChanged = function() return "ignored", nil end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        onEvent(frame, "TRADE_SKILL_LIST_UPDATE")

        T.assertEqual(refreshCount, 1)
    end)
end)

T.test("main registers the snapshot slash command before addon loaded", function()
    local onEvent
    local registeredApi
    local registrationCount = 0
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
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {}
        GGM.InitializeDatabase = function(existing)
            return existing or { schemaVersion = 1, characters = {} }, nil
        end
        GGM.StartLocalPlayerGearTracking = function()
            return nil, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            return "ignored", nil
        end
        stubSnapshotUI(GGM, function(api)
            registrationCount = registrationCount + 1
            registeredApi = api
        end)

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        T.assertTrue(registeredApi == _G)
        T.assertEqual(registrationCount, 1)

        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")

        T.assertTrue(registeredApi == _G)
        T.assertEqual(registrationCount, 1)
    end)
end)

T.test("addon loaded initializes the SavedVariables database", function()
    local onEvent
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
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function(existing)
            T.assertNil(existing)
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.StartLocalPlayerGearTracking = function()
            return nil, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            return "ignored", nil
        end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")

        T.assertNotNil(_G.GuildGearMemoryDB)
        T.assertTrue(GGM.db == _G.GuildGearMemoryDB)
        T.assertNil(GGM.startupError)
    end)
end)

T.test("player login defers stable gear tracking until equipment is ready", function()
    local onEvent
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler)
            onEvent = handler
        end,
    }

    local startCount = 0
    local ownershipCount = 0
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
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {
            DEFAULT_STABILITY_DELAY_SECONDS = 300,
        }
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.RecordLocalPlayerOwnership = function(api, db)
            T.assertTrue(api == _G)
            T.assertTrue(db == GGM.db)
            ownershipCount = ownershipCount + 1
            return true, nil
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

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        onEvent(frame, "PLAYER_LOGIN")

        T.assertEqual(ownershipCount, 1)
        T.assertEqual(startCount, 0)
        T.assertNotNil(deferredStartup)
        T.assertNil(GGM.lastLocalOwnershipError)
        deferredStartup()

        T.assertEqual(startCount, 1)
        T.assertTrue(GGM.gearTracker == tracker)
        T.assertNil(GGM.lastGearTrackingError)
    end)
end)

T.test("player login ownership failure does not block existing gear tracking", function()
    local onEvent
    local deferredStartup
    local startCount = 0
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }

    withGlobals({
        CreateFrame = function() return frame end,
        C_Timer = {
            After = function(_, callback) deferredStartup = callback end,
        },
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = { DEFAULT_STABILITY_DELAY_SECONDS = 300 }
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 6, characters = {}, localCharacterGUIDs = {} }, nil
        end
        GGM.RecordLocalPlayerOwnership = function()
            return false, "player-guid-unavailable"
        end
        GGM.StartLocalPlayerGearTracking = function()
            startCount = startCount + 1
            return {}, nil
        end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        onEvent(frame, "PLAYER_LOGIN")

        T.assertEqual(GGM.lastLocalOwnershipError, "player-guid-unavailable")
        T.assertEqual(startCount, 0)

        deferredStartup()

        T.assertEqual(startCount, 1)
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
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {
            DEFAULT_STABILITY_DELAY_SECONDS = 300,
        }
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.RecordLocalPlayerOwnership = function()
            return true, nil
        end
        GGM.StartLocalPlayerGearTracking = function()
            return tracker, nil
        end
        GGM.HandlePlayerEquipmentChanged = function(activeTracker, equipmentSlotID)
            routedTracker = activeTracker
            routedSlotID = equipmentSlotID
            return "pending", nil
        end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
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
        stubSnapshotUI(GGM)
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

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "PLAYER_EQUIPMENT_CHANGED", 16, true)

        T.assertFalse(routed)
    end)
end)

T.test("unsupported saved schema blocks tracking instead of overwriting data", function()
    local onEvent
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler)
            onEvent = handler
        end,
    }

    local startCount = 0

    withGlobals({
        CreateFrame = function()
            return frame
        end,
        GuildGearMemoryDB = { schemaVersion = 99, characters = {} },
    }, function()
        local GGM = {
            DEFAULT_STABILITY_DELAY_SECONDS = 300,
        }
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return nil, "unsupported-schema-version:99"
        end
        GGM.StartLocalPlayerGearTracking = function()
            startCount = startCount + 1
            return nil, nil
        end
        GGM.HandlePlayerEquipmentChanged = function()
            return "ignored", nil
        end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        onEvent(frame, "PLAYER_LOGIN")

        T.assertEqual(startCount, 0)
        T.assertEqual(GGM.startupError, "unsupported-schema-version:99")
    end)
end)

T.test("unsupported schema four SavedVariables remain untouched for manual reset", function()
    local onEvent
    local frame = {
        RegisterEvent = function() end,
        SetScript = function(_, _, handler) onEvent = handler end,
    }
    local oldDB = { schemaVersion = 4, characters = { sentinel = true } }

    withGlobals({
        CreateFrame = function() return frame end,
        GuildGearMemoryDB = oldDB,
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function(existing)
            T.assertTrue(existing == oldDB)
            return nil, "unsupported-schema-version:4"
        end

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")

        T.assertTrue(_G.GuildGearMemoryDB == oldDB)
        T.assertTrue(_G.GuildGearMemoryDB.characters.sentinel)
        T.assertEqual(GGM.startupError, "unsupported-schema-version:4")
        T.assertNil(GGM.db)
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
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
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

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")

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
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {
            DEFAULT_STABILITY_DELAY_SECONDS = 300,
        }
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.RecordLocalPlayerOwnership = function()
            return true, nil
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

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
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
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {}
        stubSnapshotUI(GGM)
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

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
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
        GuildGearMemoryDB = NIL,
    }, function()
        local GGM = {
            DEFAULT_STABILITY_DELAY_SECONDS = 300,
        }
        stubSnapshotUI(GGM)
        GGM.InitializeDatabase = function()
            return { schemaVersion = 1, characters = {} }, nil
        end
        GGM.RecordLocalPlayerOwnership = function()
            return true, nil
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

        T.loadAddonFile("GuildGearMemory/Main.lua", GGM)
        onEvent(frame, "ADDON_LOADED", "GuildGearMemory")
        onEvent(frame, "PLAYER_LOGIN")
        deferredStartup()

        T.assertEqual(startCount, 1)
        T.assertNil(GGM.guildSync)
        T.assertEqual(GGM.lastSyncError, "prefix-register-failed:MaxPrefixes")
    end)
end)
