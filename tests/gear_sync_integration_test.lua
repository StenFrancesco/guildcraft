local T = require("tests.testlib")

-- Each client loads the real addon modules into its own namespace. Only the
-- Blizzard API boundary is simulated; timers and guild delivery share a clock.
local function guild()
    local bus = { now = 100, timers = {}, clients = {}, frames = {}, messages = {}, assemblies = {} }
    function bus:schedule(delay, callback)
        local timer = { due = self.now + delay, callback = callback }
        function timer:Cancel() self.cancelled = true end
        self.timers[#self.timers + 1] = timer
        return timer
    end
    function bus:advance(seconds)
        local untilTime = self.now + seconds
        for _ = 1, 10000 do
            local selected
            for _, timer in ipairs(self.timers) do
                if not timer.fired and not timer.cancelled and timer.due <= untilTime
                    and (not selected or timer.due < selected.due) then selected = timer end
            end
            if not selected then self.now = untilTime; return end
            self.now, selected.fired = selected.due, true
            selected.callback()
        end
        error("unbounded guild timer activity")
    end
    function bus:client(name)
        local G = {}
        for _, module in ipairs({ "Constants", "GearData", "CharacterIdentity", "GearSnapshot", "ProfessionIndex", "Storage", "SavedDatabases",
            "StableGearTracker", "LocalGearMemory", "SyncProtocol", "SyncTransport", "GuildSync" }) do
            T.loadUnitModule(module, G)
        end
        T.loadAddonFile("The Guild Book gear/AutomaticSync.lua", G)
        T.loadAddonFile("The Guild Book gear/GearAutomaticSync.lua", G)
        -- This suite isolates sync behavior; the real adapter contract is tested separately.
        G.AttachGearBackend = function(backend)
            if type(backend) ~= "table" then return false, "gear-backend-invalid" end
            G.gearBackend = backend
            return true, nil
        end
        local client = { G = G, identity = { key = name .. "-Silvermoon", name = name, realm = "Silvermoon", guid = name }, items = {} }
        for _, slot in ipairs(G.TRACKED_SLOTS) do client.items[slot.inventorySlotID] = 1000 + slot.inventorySlotID end
        local api = {
            UnitFullName = function() return name, "Silvermoon" end,
            UnitGUID = function() return name end,
            GetRealmName = function() return "Silvermoon" end,
            GetTime = function() return self.now end,
            random = function() return client.delay or 0 end,
            issecretvalue = function() return false end,
            IsInGuild = function() return not client.left end,
            InCombatLockdown = function() return client.combat or false end,
            IsResting = function() return true end,
            C_Map = { GetBestMapForUnit = function() return client.map or 84 end },
            GetGuildInfo = function() return client.guildName or "Guild", nil, nil, "Silvermoon" end,
            GetNumGuildMembers = function() return #self.clients end,
            GetGuildRosterInfo = function(index)
                local member = self.clients[index]
                if client.rosterBroken then return nil end
                return member.identity.key, nil, nil, nil, nil, nil, nil, nil, not member.offline,
                    nil, nil, nil, nil, nil, nil, nil, member.identity.guid
            end,
            GetServerTime = function() return 1700000000 + math.floor(self.now) end,
            GetInventorySlotInfo = function(inventoryName)
                for _, slot in ipairs(G.TRACKED_SLOTS) do
                    if slot.inventoryName == inventoryName then return slot.inventorySlotID end
                end
            end,
            GetInventoryItemID = function(_, id) return client.items[id] end,
            GetInventoryItemLink = function(_, id)
                local item = client.items[id]
                return item and ("|Hitem:" .. item .. "|h[Gear]|h") or nil
            end,
            C_Timer = { NewTimer = function(delay, callback) return self:schedule(delay, callback) end },
            C_ChatInfo = {},
        }
        api.C_ChatInfo.RegisterAddonMessagePrefix = function(prefix) client.prefix = prefix; return 0 end
        api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel)
            local sent = { sender = client.identity.key, prefix = prefix, text = frame, channel = channel, at = self.now }
            self.frames[#self.frames + 1] = sent
            if client.sendResult then return client.sendResult end
            local id, index, total, chunk = frame:match("^F1|(%d+)|(%d+)|(%d+)|(.*)$")
            local key = client.identity.key .. ":" .. id
            if tonumber(index) == 1 then self.assemblies[key] = {} end
            local chunks = self.assemblies[key]
            chunks[tonumber(index)] = chunk
            if tonumber(index) == tonumber(total) then
                self.messages[#self.messages + 1] = { sender = sent.sender, at = self.now, message = assert(G.DecodeSyncMessage(table.concat(chunks))) }
            end
            self:schedule(0, function()
                for _, receiver in ipairs(self.clients) do
                    if not receiver.drop then
                        receiver.lastState, receiver.lastError = receiver.G.HandleGuildSyncAddonMessage(receiver.sync, prefix, frame, channel, sent.sender)
                    end
                end
            end)
            return 0
        end
        T.mockChatThrottle(api)
        local gearDB = { schemaVersion = G.SCHEMA_VERSION, characters = {}, localCharacters = {} }
        api.DysgearMemoryAPI = { schemaVersion = 2, GetDatabase = function() return gearDB end, GetBackend = function() return G end }
        local db, startupErr, professionDB = G.InitializeSavedDatabases(api)
        assert(db, startupErr)
        api.TheGuildBookDB, api.TheGuildBookGearDB = professionDB, gearDB
        client.api, client.db = api, db
        assert(client.db.characters == api.TheGuildBookGearDB.characters)
        assert(api.TheGuildBookDB.characters == nil)
        client.sync = assert(G.CreateGuildSync(api, client.db))
        assert(G.RegisterGuildSync(client.sync))
        function client:startTracking()
            self.tracker = assert(self.G.StartLocalPlayerGearTracking(self.api, self.db, nil, function(...)
                assert(self.G.PublishConfirmedSlot(self.sync, ...))
            end))
            self.sync.localGearTracker = self.tracker
        end
        function client:change(slot, item)
            self.items[slot] = item
            return self.G.HandlePlayerEquipmentChanged(self.tracker, slot)
        end
        self.clients[#self.clients + 1] = client
        return client
    end
    function bus:count(kind)
        local count = 0
        for _, entry in ipairs(self.messages) do if entry.message.type == kind then count = count + 1 end end
        return count
    end
    return bus
end

T.test("automatic gear login fetches online and offline cached snapshots without opening the browser", function()
    local bus = guild()
    local alice, bob, offline = bus:client("Alice"), bus:client("Bob"), bus:client("Offline")
    alice:startTracking(); offline:startTracking(); offline.offline, offline.drop = true, true
    local snapshot = assert(offline.G.BuildRuntimeGearSnapshot(offline.api, offline.db.characters[offline.identity.key].gear))
    assert(alice.G.SaveCompleteCharacterRecord(alice.db, offline.identity, snapshot, 5))
    bob.delay = 300
    assert(bob.G.LoginGearSync(bob.sync)); assert(bob.G.LoginGearSync(bob.sync))
    bus:advance(299); T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 0)
    bus:advance(100)
    T.assertNotNil(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    T.assertNotNil(bob.G.GetCompleteCharacterRecord(bob.db, offline.identity.key))
    T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 2)
    local frames = #bus.frames; bus:advance(5000); T.assertEqual(#bus.frames, frames)
end)

T.test("automatic gear retries only failed targets at the stationary city cooldown", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    alice:startTracking(); alice.drop = true
    assert(bob.G.LoginGearSync(bob.sync)); bus:advance(1000)
    T.assertNil(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 1)
    alice.drop = false; bus:advance(400)
    T.assertNotNil(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 2)
    local count = #bus.frames; bus:advance(8000); T.assertEqual(#bus.frames, count)
end)

T.test("a sole busy gear cache responder serves the queued request after outgoing traffic drains", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    alice:startTracking()
    for index = 1, 8 do
        local target = { key = "Missing" .. index .. "-Silvermoon", name = "Missing" .. index, realm = "Silvermoon" }
        assert(alice.G.SendSyncPayload(alice.sync.transport, assert(alice.G.EncodeSyncSnapshotRequest(alice.identity, target, string.format("%06d", index)))))
    end
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(90)
    T.assertNotNil(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    T.assertEqual(bus:count("SNAPSHOT_RESPONSE"), 1)
end)

T.test("gear automatic target batches rotate past unresponsive members", function()
    local bus = guild()
    local requester = bus:client("Requester")
    for index = 1, 16 do bus:client("Absent" .. index) end
    local provider = bus:client("Zulu")
    provider:startTracking()
    assert(requester.G.LoginGearSync(requester.sync)); bus:advance(5000)
    T.assertNotNil(requester.G.GetCompleteCharacterRecord(requester.db, provider.identity.key))
end)

T.test("gear automatic interruption preserves completed targets and waits for city recovery", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    alice:startTracking(); bob.rosterBroken = true
    assert(bob.G.LoginGearSync(bob.sync)); bus:advance(100)
    T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 0)
    bob.rosterBroken = false; bob.map = 37
    bus:advance(1300); T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 0)
    bob.map = 84; bob.G.WakeGearSync(bob.sync); bus:advance(100)
    T.assertNotNil(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    bob.left = true; bob.G.WakeGearSync(bob.sync)
    T.assertTrue(bob.sync.automaticController.stopped)
    bob.left, bob.rosterBroken = false, true
    bob.G.WakeGearSync(bob.sync)
    T.assertTrue(bob.sync.automaticController.stopped)
    bob.rosterBroken = false
    bob.G.WakeGearSync(bob.sync)
    T.assertFalse(bob.sync.automaticController.stopped)
end)

T.test("gear automatic work restarts on a verified guild switch wake", function()
    local bus = guild()
    bus:client("Alice")
    local bob = bus:client("Bob")
    assert(bob.G.LoginGearSync(bob.sync)); bus:advance(100)
    local oldGuild = bob.sync.automaticGuild
    T.assertEqual(oldGuild, "Guild:Silvermoon")

    bob.guildName = "OtherGuild"
    bob.G.WakeGearSync(bob.sync)
    T.assertFalse(bob.sync.automaticController.stopped)
    T.assertEqual(bob.sync.automaticGuild, nil)
    T.assertEqual(bob.sync.automaticRemaining, nil)
    T.assertEqual(bob.sync.automaticCursor, nil)

    bus:advance(100)
    T.assertFalse(bob.sync.automaticController.stopped)
    T.assertEqual(bob.sync.automaticGuild, "OtherGuild:Silvermoon")
    T.assertNotNil(bob.sync.automaticRemaining)
end)

T.test("busy gear response expires without sending a late snapshot", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    alice:startTracking()
    local original, held = alice.api.ChatThrottleLib.SendAddonMessage, nil
    alice.api.ChatThrottleLib.SendAddonMessage = function(lib, priority, prefix, text, channel, target, queue, callback, arg)
        held = function() original(lib, priority, prefix, text, channel, target, queue, callback, arg) end
    end
    assert(alice.G.SendSyncPayload(alice.sync.transport, assert(alice.G.EncodeSyncSnapshotRequest(alice.identity, bob.identity, "999999"))))
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity)); bus:advance(31)
    T.assertEqual(alice.sync.pendingSnapshotResponseCount, 0)
    alice.api.ChatThrottleLib.SendAddonMessage = original; held(); bus:advance(90)
    T.assertEqual(bus:count("SNAPSHOT_RESPONSE"), 0)
end)

T.test("GC_GEAR clients exchange one explicit cached baseline with multiple responders", function()
    local bus = guild()
    local alice, bob, carol = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    alice:startTracking()
    local baseline = assert(alice.G.BuildRuntimeGearSnapshot(alice.api, alice.db.characters[alice.identity.key].gear))
    assert(carol.G.SaveCompleteCharacterRecord(carol.db, alice.identity, baseline, 0))
    bus:advance(600)
    T.assertEqual(#bus.frames, 0)
    T.assertEqual(bob.prefix, "GC_GEAR")
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(90)
    local received = assert(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    T.assertEqual(received.gear.slots[1], "item:1001")
    T.assertNil(received.gear.slots.HEAD)
    T.assertEqual(received.confirmedSequence, 0)
    T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 1)
    T.assertEqual(bus:count("SNAPSHOT_RESPONSE"), 1)
    T.assertEqual(bob.sync.pendingSnapshotRequestCount, 0)
    for _, frame in ipairs(bus.frames) do
        T.assertEqual(frame.prefix, "GC_GEAR")
        T.assertEqual(frame.channel, "GUILD")
        T.assertTrue(#frame.text <= 255)
    end
    local count = #bus.frames
    bus:advance(600)
    T.assertEqual(#bus.frames, count)
end)

T.test("GC_GEAR stability deltas detect missed updates and automatically repair the complete baseline", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    alice:startTracking()
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(90)
    local count = #bus.frames
    alice:change(1, 2001)
    bus:advance(100)
    alice:change(1, 1001)
    bus:advance(300)
    T.assertEqual(#bus.frames, count)
    alice:change(1, 3001)
    bus:advance(299)
    T.assertEqual(#bus.frames, count)
    bus:advance(10)
    T.assertEqual(bob.db.characters[alice.identity.key].gear.slots[1], "item:3001")
    T.assertEqual(bus:count("SLOT_UPDATE"), 1)
    bob.drop = true
    alice:change(1, 4001)
    bus:advance(310)
    bob.drop = false
    alice:change(2, 4002)
    bus:advance(310)
    T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 2)
    bus:advance(90)
    local repaired = assert(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    T.assertEqual(repaired.gear.slots[1], "item:4001")
    T.assertEqual(repaired.gear.slots[2], "item:4002")
    T.assertEqual(repaired.confirmedSequence, 3)
    T.assertFalse(repaired.refreshNeeded == true)
end)

T.test("GC_GEAR paces separate one-frame logical messages", function()
    local bus = guild()
    local bob = bus:client("Bob")
    for _, name in ipairs({ "Alice", "Carol" }) do
        assert(bob.G.RequestCompleteSnapshot(bob.sync, { key = name .. "-Silvermoon", name = name, realm = "Silvermoon" }))
    end
    T.assertEqual(#bus.frames, 1)
    bus:advance(3)
    T.assertEqual(#bus.frames, 2)
    T.assertTrue(bus.frames[2].at - bus.frames[1].at + 0.000001 >= bob.G.SYNC_SEND_INTERVAL_SECONDS)
end)

T.test("GC_GEAR busy cache responders do not send a second late snapshot", function()
    local bus = guild()
    local alice, bob, carol = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    alice:startTracking()
    local baseline = assert(alice.G.BuildRuntimeGearSnapshot(alice.api, alice.db.characters[alice.identity.key].gear))
    assert(carol.G.SaveCompleteCharacterRecord(carol.db, alice.identity, baseline, 1))
    for index = 1, 8 do
        local target = { key = "Missing" .. index .. "-Silvermoon", name = "Missing" .. index, realm = "Silvermoon" }
        assert(carol.G.SendSyncPayload(carol.sync.transport, assert(carol.G.EncodeSyncSnapshotRequest(carol.identity, target, string.format("%06d", index)))))
    end
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(90)
    T.assertNotNil(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    T.assertEqual(bus:count("SNAPSHOT_RESPONSE"), 1)
    T.assertEqual(carol.sync.pendingSnapshotResponseCount, 0)
end)

T.test("GC_GEAR ignores old prefixes and fails closed on unavailable guild sends", function()
    local bus = guild()
    local bob = bus:client("Bob")
    local state, err = bob.G.HandleGuildSyncAddonMessage(bob.sync, "DysGuildGear", "bad", "GUILD", "Alice-Silvermoon")
    T.assertEqual(state, "ignored"); T.assertNil(err)
    bob.sendResult = 10
    local sent, sendErr = bob.G.RequestCompleteSnapshot(bob.sync, { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" })
    T.assertFalse(sent)
    T.assertEqual(sendErr, "send-addon-message-failed:NotInGuild")
    T.assertEqual(bob.sync.pendingSnapshotRequestCount, 0)
    bus:advance(600)
    T.assertEqual(#bus.frames, 1)
end)

T.test("GC_GEAR simultaneous stable slots are paced and remain sequential", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    alice:startTracking()
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(90)
    alice:change(1, 9001)
    alice:change(2, 9002)
    bus:advance(310)
    local record = assert(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    T.assertEqual(record.confirmedSequence, 2)
    T.assertEqual(record.gear.slots[1], "item:9001")
    T.assertEqual(record.gear.slots[2], "item:9002")
    T.assertNil(alice.sync.transport.lastReceiveError)
    local changes = {}
    for _, entry in ipairs(bus.messages) do
        if entry.message.type == "SLOT_UPDATE" then changes[#changes + 1] = entry end
    end
    T.assertEqual(#changes, 2)
    T.assertTrue(changes[2].at - changes[1].at + 0.000001 >= alice.G.SYNC_SEND_INTERVAL_SECONDS)
end)

T.test("GC_GEAR snapshot throttling releases the responder without retrying", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    alice:startTracking()
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(0)
    -- Advertise successfully, then fail before the complete response is sent.
    bus:advance(alice.G.SYNC_SNAPSHOT_RESPONSE_MAX_DELAY_SECONDS)
    alice.sendResult = 3
    bus:advance(90)
    T.assertEqual(alice.sync.pendingSnapshotResponseCount, 0)
    T.assertEqual(#alice.sync.transport.outboundFrames, 0)
    T.assertEqual(alice.sync.transport.lastSendError, "send-addon-message-failed:AddonMessageThrottle")
    T.assertNil(bob.db.characters[alice.identity.key])
    local count = #bus.frames
    bus:advance(600)
    T.assertEqual(#bus.frames, count)
end)

T.test("GC_GEAR first owner update acquires a missing baseline without manual requests", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    alice:startTracking()
    alice:change(1, 8123)
    bus:advance(390)
    local received = assert(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    T.assertEqual(received.gear.slots[1], "item:8123")
    T.assertEqual(received.confirmedSequence, 1)
    T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 1)
    T.assertEqual(bus:count("SNAPSHOT_RESPONSE"), 1)
end)

T.test("GC_GEAR manual refresh after cooldown receives the newest peer snapshot", function()
    local bus = guild()
    local alice, bob, carol = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    alice:startTracking()
    local baseline = assert(alice.G.BuildRuntimeGearSnapshot(alice.api, alice.db.characters[alice.identity.key].gear))
    assert(carol.G.SaveCompleteCharacterRecord(carol.db, alice.identity, baseline, 0))
    alice.drop = true
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    -- A complete request takes a few seconds, not the full response cooldown.
    bus:advance(15)
    assert(bob.G.GetCompleteCharacterRecord(bob.db, alice.identity.key))
    alice.drop = true
    bus:advance(bob.G.SYNC_SNAPSHOT_REQUEST_COOLDOWN_SECONDS)
    baseline.slots.HEAD = { inventorySlotID = 1, itemID = 9898, itemLink = "|Hitem:9898|h[New]|h" }
    baseline.capturedAt = carol.api.GetServerTime()
    baseline.slotObservedAt = nil
    assert(carol.G.SaveCompleteCharacterRecord(carol.db, alice.identity, baseline, 2))
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(15)
    T.assertEqual(bob.db.characters[alice.identity.key].gear.slots[1], "item:9898")
    T.assertEqual(bob.db.characters[alice.identity.key].confirmedSequence, 2)
end)

T.test("GC_GEAR chooses the newest available offline cache and sends one complete response", function()
    local bus = guild()
    local alice, bob, carol, dave = bus:client("Alice"), bus:client("Bob"), bus:client("Carol"), bus:client("Dave")
    alice:startTracking()
    alice.drop = true
    local baseline = assert(alice.G.BuildRuntimeGearSnapshot(alice.api, alice.db.characters[alice.identity.key].gear))
    assert(carol.G.SaveCompleteCharacterRecord(carol.db, alice.identity, baseline, 1))
    baseline.slots.HEAD = { inventorySlotID = 1, itemID = 9654, itemLink = "|Hitem:9654|h[Newest]|h" }
    assert(dave.G.SaveCompleteCharacterRecord(dave.db, alice.identity, baseline, 3))
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(90)
    T.assertEqual(bob.db.characters[alice.identity.key].confirmedSequence, 3)
    T.assertEqual(bob.db.characters[alice.identity.key].gear.slots[1], "item:9654")
    T.assertEqual(bus:count("SNAPSHOT_RESPONSE"), 1)
end)

T.test("GC_GEAR selects a newer inspection over a higher owner sequence and shares it normally", function()
    local bus = guild()
    local alice, bob, carol, dave = bus:client("Alice"), bus:client("Bob"), bus:client("Carol"), bus:client("Dave")
    alice:startTracking()
    alice.drop = true
    local old = assert(alice.G.BuildRuntimeGearSnapshot(alice.api, alice.db.characters[alice.identity.key].gear))
    assert(carol.G.SaveCompleteCharacterRecord(carol.db, alice.identity, old, 40))
    assert(bob.G.SaveCompleteCharacterRecord(bob.db, alice.identity, old, 40))
    bus:advance(10)
    local fresh = assert(alice.G.CapturePlayerGearSnapshot(alice.api))
    fresh.slots.HEAD = { inventorySlotID = 1, itemID = 9876, itemLink = "|Hitem:9876|h[Inspected]|h" }
    assert(dave.G.SaveObservedCharacterRecord(dave.db, alice.identity, fresh))
    T.assertEqual(dave.db.characters[alice.identity.key].confirmedSequence, 0)
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(30)
    T.assertEqual(bob.db.characters[alice.identity.key].gear.slots[1], "item:9876")
    T.assertEqual(bob.db.characters[alice.identity.key].gear.capturedAt, fresh.capturedAt)
    T.assertEqual(bob.db.characters[alice.identity.key].confirmedSequence, 40)
    T.assertEqual(bus:count("SNAPSHOT_RESPONSE"), 1)
end)

T.test("GC_GEAR fresh inspection permits a response during an older snapshot cooldown", function()
    local bus = guild()
    local alice, bob, carol = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    alice:startTracking(); alice.drop = true
    local baseline = assert(alice.G.BuildRuntimeGearSnapshot(alice.api, alice.db.characters[alice.identity.key].gear))
    assert(carol.G.SaveCompleteCharacterRecord(carol.db, alice.identity, baseline, 0))
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(15)
    local fresh = assert(alice.G.CapturePlayerGearSnapshot(alice.api))
    fresh.slots.HEAD = { inventorySlotID = 1, itemID = 9123, itemLink = "|Hitem:9123|h[Inspect]|h" }
    assert(carol.G.SaveObservedCharacterRecord(carol.db, alice.identity, fresh))
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity, 1, fresh.capturedAt))
    bus:advance(20)
    T.assertEqual(bob.db.characters[alice.identity.key].gear.slots[1], "item:9123")
    T.assertEqual(bus:count("SNAPSHOT_RESPONSE"), 2)
end)

T.test("GC_GEAR a later owner observation remains eligible after a complete inspection", function()
    local bus = guild()
    local alice, bob, carol, dave = bus:client("Alice"), bus:client("Bob"), bus:client("Carol"), bus:client("Dave")
    alice:startTracking(); alice.drop = true
    local old = assert(alice.G.BuildRuntimeGearSnapshot(alice.api, alice.db.characters[alice.identity.key].gear))
    assert(dave.G.SaveCompleteCharacterRecord(dave.db, alice.identity, old, 0))
    bus:advance(10)
    local inspected = assert(alice.G.CapturePlayerGearSnapshot(alice.api))
    assert(carol.G.SaveObservedCharacterRecord(carol.db, alice.identity, inspected))
    bus:advance(10)
    assert(dave.G.ApplyReceivedCharacterSlot(dave.db, alice.identity.key, "HEAD",
        { inventorySlotID = 1, itemID = 9991, itemLink = "|Hitem:9991|h[Later]|h" }, dave.api.GetServerTime(), 1))
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
    bus:advance(30)
    T.assertEqual(bob.db.characters[alice.identity.key].gear.slots[1], "item:9991")
end)

T.test("GC_GEAR shares and updates an inspected character using a realm spelling alias", function()
    local bus = guild()
    local alice, bob, carol = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    alice:startTracking(); alice.drop = true
    local baseline = assert(alice.G.BuildRuntimeGearSnapshot(alice.api, alice.db.characters[alice.identity.key].gear))
    assert(carol.G.SaveCompleteCharacterRecord(carol.db, alice.identity, baseline, 0))
    local alias = { key = "Alice-Silver moon", name = "Alice", realm = "Silver moon", guid = alice.identity.guid }
    assert(bob.G.SaveObservedCharacterRecord(bob.db, alias, baseline))
    bus:advance(10)
    baseline.capturedAt = carol.api.GetServerTime()
    baseline.slotObservedAt = nil
    baseline.slots.HEAD = { inventorySlotID = 1, itemID = 9912, itemLink = "|Hitem:9912|h[New]|h" }
    assert(carol.G.SaveObservedCharacterRecord(carol.db, alice.identity, baseline))
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alias))
    bus:advance(30)
    T.assertEqual(bob.db.characters[alias.key].gear.slots[1], "item:9912")
    T.assertNil(bob.db.characters[alice.identity.key])
    local update = assert(bob.G.EncodeSyncSlotUpdate(alice.identity, 1, "HEAD",
        { inventorySlotID = 1, itemID = 9913, itemLink = "|Hitem:9913|h[Later]|h" }, bob.api.GetServerTime()))
    T.assertEqual(bob.G.HandleGuildSyncPayload(bob.sync, alice.identity.key, update), "slot-applied")
    T.assertEqual(bob.db.characters[alias.key].gear.slots[1], "item:9913")
end)
