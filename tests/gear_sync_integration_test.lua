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
            T.loadAddonFile("GuildGearMemory/" .. module .. ".lua", G)
        end
        local client = { G = G, identity = { key = name .. "-Silvermoon", name = name, realm = "Silvermoon", guid = name }, items = {} }
        for _, slot in ipairs(G.TRACKED_SLOTS) do client.items[slot.inventorySlotID] = 1000 + slot.inventorySlotID end
        local api = {
            UnitFullName = function() return name, "Silvermoon" end,
            UnitGUID = function() return name end,
            GetRealmName = function() return "Silvermoon" end,
            GetTime = function() return self.now end,
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
        local gearDB = { schemaVersion = G.SCHEMA_VERSION, characters = {}, localCharacters = {} }
        api.DysgearMemoryAPI = { schemaVersion = 1, GetDatabase = function() return gearDB end }
        local db, startupErr, professionDB = G.InitializeSavedDatabases(api)
        assert(db, startupErr)
        api.GuildGearMemoryDB, api.DysgearMemoryDB = professionDB, gearDB
        client.api, client.db = api, db
        assert(client.db.characters == api.DysgearMemoryDB.characters)
        assert(api.GuildGearMemoryDB.characters == nil)
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

T.test("GC_GEAR stability deltas detect missed updates and repair only on explicit request", function()
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
    local stale = bob.db.characters[alice.identity.key]
    T.assertTrue(stale.refreshNeeded)
    T.assertFalse(stale.complete)
    T.assertEqual(stale.gear.slots[1], "item:3001")
    T.assertEqual(bus:count("SNAPSHOT_REQUEST"), 1)
    assert(bob.G.RequestCompleteSnapshot(bob.sync, alice.identity))
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
