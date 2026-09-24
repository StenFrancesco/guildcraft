local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/CharacterIdentity.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    T.loadAddonFile("GuildGearMemory/SyncProtocol.lua", GGM)
    T.loadAddonFile("GuildGearMemory/SyncTransport.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GuildSync.lua", GGM)
    return GGM
end

local function identity(name, realm, guid)
    return { key = name .. "-" .. realm, name = name, realm = realm, guid = guid }
end

local function snapshot(GGM, base, capturedAt)
    local result = { complete = true, capturedAt = capturedAt or 1700002000, slots = {} }
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        local itemID = base + index
        result.slots[slot.key] = {
            inventorySlotID = index,
            itemID = itemID,
            itemLink = "|Hitem:" .. itemID .. "|h[" .. slot.key .. "]|h",
        }
    end
    return result
end

local function clientApi(who, results)
    local timers, sends, now = {}, {}, 200
    local api = {
        C_ChatInfo = {}, C_Timer = {},
        UnitFullName = function() return who.name, who.realm end,
        GetRealmName = function() return who.realm end,
        UnitGUID = function() return who.guid end,
        GetTime = function() return now end,
    }
    api.C_ChatInfo.RegisterAddonMessagePrefix = function() return 0 end
    api.C_ChatInfo.SendAddonMessage = function(prefix, message, channel, target)
        table.insert(sends, { prefix = prefix, message = message, channel = channel, target = target })
        return results and results[#sends] or 0
    end
    api.C_Timer.NewTimer = function(delay, callback)
        local timer = { delay = delay, fired = false, cancelled = false }
        function timer:Fire()
            if not self.fired and not self.cancelled then self.fired = true; callback() end
        end
        function timer:Cancel() self.cancelled = true end
        table.insert(timers, timer)
        return timer
    end
    local function drain()
        local index = 1
        while index <= #timers do timers[index]:Fire(); index = index + 1 end
    end
    return api, sends, drain, function(value) now = value end, timers
end

local function fireNextTimer(...)
    local nextTimer
    for timerSetIndex = 1, select("#", ...) do
        for _, timer in ipairs(select(timerSetIndex, ...)) do
            if not timer.fired and not timer.cancelled and (not nextTimer or timer.delay < nextTimer.delay) then
                nextTimer = timer
            end
        end
    end
    if not nextTimer then return false end
    nextTimer:Fire()
    return true
end

local function deliver(GGM, sync, sends, sender)
    local state, err
    for _, send in ipairs(sends) do
        state, err = GGM.HandleGuildSyncAddonMessage(sync, send.prefix, send.message, send.channel, sender)
    end
    return state, err
end

T.test("incremental updates require a complete compatible baseline", function()
    local GGM = loadModules()
    local alice = identity("Alice", "Silvermoon", "A" )
    local bob = identity("Bob", "Silvermoon", "B")
    local db = assert(GGM.InitializeDatabase(nil))
    local sync = assert(GGM.CreateGuildSync(clientApi(bob), db))
    local changed = { inventorySlotID = 1, itemID = 9901, itemLink = "|Hitem:9901|h[Remote]|h" }
    local payload = assert(GGM.EncodeSyncSlotUpdate(alice, 5, "HEAD", changed, 1700002300))
    local state, err = GGM.HandleGuildSyncPayload(sync, alice.key, payload)
    T.assertNil(state); T.assertEqual(err, "record-missing")
    assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 6000), 4))
    state, err = GGM.HandleGuildSyncPayload(sync, alice.key, payload)
    T.assertEqual(state, "slot-applied"); T.assertNil(err)
    T.assertEqual(db.characters[alice.key].gear.slots.HEAD.itemID, 9901)
    T.assertEqual(db.characters[alice.key].confirmedSequence, 5)
end)

T.test("incremental sender identity mismatch fails closed", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(GGM.InitializeDatabase(nil))
    assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 6000), 1))
    local sync = assert(GGM.CreateGuildSync(clientApi(bob), db))
    local payload = assert(GGM.EncodeSyncSlotUpdate(alice, 2, "HEAD", { inventorySlotID = 1, itemID = 9902, itemLink = "|Hitem:9902|h[Spoof]|h" }, 1700002400))
    local state, err = GGM.HandleGuildSyncPayload(sync, "Mallory-Silvermoon", payload)
    T.assertNil(state); T.assertEqual(err, "sync-sender-identity-mismatch")
    T.assertEqual(db.characters[alice.key].gear.slots.HEAD.itemID, 6001)
end)

T.test("explicit request receives a complete offline cached record", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local bobDb = assert(GGM.InitializeDatabase(nil)); local bobApi, bobSends, drainBob = clientApi(bob)
    local bobSync = assert(GGM.CreateGuildSync(bobApi, bobDb))
    local carolDb = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(carolDb, alice, snapshot(GGM, 7000), 6))
    local carolApi, carolSends, drainCarol = clientApi(carol); local carolSync = assert(GGM.CreateGuildSync(carolApi, carolDb))
    assert(GGM.RequestCompleteSnapshot(bobSync, alice)); drainBob()
    local state, err = deliver(GGM, carolSync, bobSends, bob.key)
    T.assertEqual(state, "snapshot-response-queued"); T.assertNil(err)
    drainCarol(); state, err = deliver(GGM, bobSync, carolSends, carol.key)
    T.assertEqual(state, "snapshot-saved"); T.assertNil(err)
    T.assertEqual(bobDb.characters[alice.key].confirmedSequence, 6)
end)

T.test("a snapshot request produces at most one cached response", function()
    local GGM = loadModules()
    local alice, bob, carol, dave = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C"), identity("Dave", "Silvermoon", "D")
    local requestApi, requestSends, drain = clientApi(bob); local requester = assert(GGM.CreateGuildSync(requestApi, assert(GGM.InitializeDatabase(nil))))
    assert(GGM.RequestCompleteSnapshot(requester, alice)); drain()
    local carolDb = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(carolDb, alice, snapshot(GGM, 7100), 3))
    local carolApi, carolSends, _, _, carolTimers = clientApi(carol); local carolSync = assert(GGM.CreateGuildSync(carolApi, carolDb))
    local daveDb = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(daveDb, alice, snapshot(GGM, 7100), 3))
    local daveApi, daveSends, _, _, daveTimers = clientApi(dave); local daveSync = assert(GGM.CreateGuildSync(daveApi, daveDb))
    deliver(GGM, carolSync, requestSends, bob.key); deliver(GGM, daveSync, requestSends, bob.key)
    local deliveredCarol, deliveredDave = 0, 0
    while fireNextTimer(carolTimers, daveTimers) do
        while deliveredCarol < #carolSends do
            deliveredCarol = deliveredCarol + 1
            GGM.HandleGuildSyncAddonMessage(daveSync, carolSends[deliveredCarol].prefix, carolSends[deliveredCarol].message, carolSends[deliveredCarol].channel, carol.key)
        end
        while deliveredDave < #daveSends do
            deliveredDave = deliveredDave + 1
            GGM.HandleGuildSyncAddonMessage(carolSync, daveSends[deliveredDave].prefix, daveSends[deliveredDave].message, daveSends[deliveredDave].channel, dave.key)
        end
    end
    local expectedWinnerSends = carolTimers[1].delay < daveTimers[1].delay and carolSends or daveSends
    local expectedLoserSends = carolTimers[1].delay < daveTimers[1].delay and daveSends or carolSends
    T.assertTrue(#expectedWinnerSends > 0)
    T.assertEqual(#expectedLoserSends, 0)
end)

T.test("equal sequence claims elect the lexicographically first responder", function()
    local GGM = loadModules()
    local alice, bob, dave, eve = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Dave", "Silvermoon", "D"), identity("Eve", "Silvermoon", "E")
    local daveDb = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(daveDb, alice, snapshot(GGM, 7100), 3))
    local daveApi, daveSends, _, _, daveTimers = clientApi(dave); local daveSync = assert(GGM.CreateGuildSync(daveApi, daveDb))
    local eveDb = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(eveDb, alice, snapshot(GGM, 7100), 3))
    local eveApi, eveSends, _, _, eveTimers = clientApi(eve); local eveSync = assert(GGM.CreateGuildSync(eveApi, eveDb))
    local request = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001"))

    T.assertEqual(GGM.HandleGuildSyncPayload(daveSync, bob.key, request), "snapshot-response-queued")
    T.assertEqual(GGM.HandleGuildSyncPayload(eveSync, bob.key, request), "snapshot-response-queued")
    T.assertEqual(daveTimers[1].delay, eveTimers[1].delay)

    daveTimers[1]:Fire()
    eveTimers[1]:Fire()
    for _, send in ipairs(daveSends) do
        GGM.HandleGuildSyncAddonMessage(eveSync, send.prefix, send.message, send.channel, dave.key)
    end
    for _, send in ipairs(eveSends) do
        GGM.HandleGuildSyncAddonMessage(daveSync, send.prefix, send.message, send.channel, eve.key)
    end

    T.assertEqual(daveSync.pendingSnapshotResponseCount, 1)
    T.assertEqual(eveSync.pendingSnapshotResponseCount, 0)
    daveTimers[2]:Fire()
    T.assertEqual(#daveSends, 2)
    T.assertEqual(#eveSends, 1)
end)

T.test("snapshot response cancellation is scoped to requester", function()
    local GGM = loadModules()
    local alice, bob, eve, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Eve", "Silvermoon", "E"), identity("Carol", "Silvermoon", "C")
    local db = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7200), 3))
    local api, sends, _, _, timers = clientApi(carol); local sync = assert(GGM.CreateGuildSync(api, db))
    local bobRequest = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001"))
    local eveRequest = assert(GGM.EncodeSyncSnapshotRequest(eve, alice, "000001"))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, bob.key, bobRequest), "snapshot-response-queued")
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, eve.key, eveRequest), "snapshot-response-queued")
    local bobResponse = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, bob, snapshot(GGM, 7200), 3, "000001"))
    GGM.HandleGuildSyncPayload(sync, bob.key, bobResponse)
    local active = 0
    for _, timer in ipairs(timers) do if not timer.cancelled then active = active + 1 end end
    T.assertEqual(active, 1)
    T.assertEqual(sync.pendingSnapshotResponseCount, 1)
    T.assertEqual(#sends, 0)
end)

T.test("a stale response does not cancel a fresher responder timer", function()
    local GGM = loadModules()
    local alice, bob, carol, dave = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C"), identity("Dave", "Silvermoon", "D")
    local carolDb = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(carolDb, alice, snapshot(GGM, 7500), 10))
    local carolApi, carolSends, _, _, carolTimers = clientApi(carol); local carolSync = assert(GGM.CreateGuildSync(carolApi, carolDb))
    local daveDb = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(daveDb, alice, snapshot(GGM, 7400), 8))
    local daveApi, daveSends, daveDrain = clientApi(dave); local daveSync = assert(GGM.CreateGuildSync(daveApi, daveDb))
    local request = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001"))
    T.assertEqual(GGM.HandleGuildSyncPayload(carolSync, bob.key, request), "snapshot-response-queued")
    T.assertEqual(GGM.HandleGuildSyncPayload(daveSync, bob.key, request), "snapshot-response-queued")
    daveDrain()
    for _, send in ipairs(daveSends) do
        GGM.HandleGuildSyncAddonMessage(carolSync, send.prefix, send.message, send.channel, dave.key)
    end
    T.assertEqual(carolSync.pendingSnapshotResponseCount, 1)
    T.assertFalse(carolTimers[1].cancelled)
    carolTimers[1]:Fire()
    T.assertEqual(carolSync.pendingSnapshotResponseCount, 0)
    T.assertTrue(#carolSends > 0)
end)

T.test("pending delayed snapshot responses are capped", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7300), 3))
    local api, sends, _, _, timers = clientApi(carol); local sync = assert(GGM.CreateGuildSync(api, db))
    for requestIndex = 1, GGM.SYNC_MAX_PENDING_SNAPSHOT_RESPONSES do
        local requestID = string.format("%06d", requestIndex)
        local requester = identity("Bob" .. requestIndex, "Silvermoon", "B" .. requestIndex)
        local request = assert(GGM.EncodeSyncSnapshotRequest(requester, alice, requestID))
        T.assertEqual(GGM.HandleGuildSyncPayload(sync, requester.key, request), "snapshot-response-queued")
    end
    local rejectedRequester = identity("Bob17", "Silvermoon", "B17")
    local rejectedRequest = assert(GGM.EncodeSyncSnapshotRequest(rejectedRequester, alice, "000017"))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, rejectedRequester.key, rejectedRequest), "ignored")
    T.assertEqual(sync.pendingSnapshotResponseCount, GGM.SYNC_MAX_PENDING_SNAPSHOT_RESPONSES)
    T.assertEqual(#timers, GGM.SYNC_MAX_PENDING_SNAPSHOT_RESPONSES)
    T.assertEqual(#sends, 0)
    timers[1]:Fire()
    T.assertEqual(sync.pendingSnapshotResponseCount, GGM.SYNC_MAX_PENDING_SNAPSHOT_RESPONSES - 1)
end)

T.test("repeated snapshot requests for one requester and target coalesce", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7350), 3))
    local api, sends, drain, setTime = clientApi(carol); local sync = assert(GGM.CreateGuildSync(api, db))
    local request1 = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001"))
    local request2 = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000002"))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, bob.key, request1), "snapshot-response-queued")
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, bob.key, request2), "ignored")
    T.assertEqual(sync.pendingSnapshotResponseCount, 1)
    drain()
    T.assertEqual(sync.snapshotResponseCooldownEntryCount, 1)
    setTime(200 + GGM.SYNC_SNAPSHOT_RESPONSE_COOLDOWN_SECONDS)
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, bob.key, request2), "snapshot-response-queued")
    drain()
    T.assertEqual(sync.snapshotResponseCooldownEntryCount, 1)
end)

T.test("failed delayed snapshot response timer creation does not leak pending state", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7400), 3))
    local api = clientApi(carol); api.C_Timer.NewTimer = function() return nil end
    local sync = assert(GGM.CreateGuildSync(api, db))
    local request = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001"))
    local state, err = GGM.HandleGuildSyncPayload(sync, bob.key, request)
    T.assertNil(state); T.assertEqual(err, "sync-response-timer-create-failed")
    T.assertEqual(sync.pendingSnapshotResponseCount, 0)
    T.assertNil(next(sync.pendingSnapshotResponses))
end)

T.test("responder cooldown is bounded per requester and target", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7150), 3))
    local api, sends, drain, setTime = clientApi(carol); local sync = assert(GGM.CreateGuildSync(api, db))
    local request = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001"))
    local state, err = GGM.HandleGuildSyncPayload(sync, bob.key, request)
    T.assertEqual(state, "snapshot-response-queued"); T.assertNil(err); drain(); local count = #sends
    setTime(200 + GGM.SYNC_SNAPSHOT_RESPONSE_COOLDOWN_SECONDS - 0.01)
    state, err = GGM.HandleGuildSyncPayload(sync, bob.key, request)
    T.assertEqual(state, "ignored"); T.assertNil(err); T.assertEqual(#sends, count)
    setTime(200 + GGM.SYNC_SNAPSHOT_RESPONSE_COOLDOWN_SECONDS)
    state, err = GGM.HandleGuildSyncPayload(sync, bob.key, request)
    T.assertEqual(state, "snapshot-response-queued"); T.assertNil(err); drain(); T.assertTrue(#sends > count)
end)

T.test("unavailable or malformed request produces no response", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(GGM.InitializeDatabase(nil)); local api, sends = clientApi(carol); local sync = assert(GGM.CreateGuildSync(api, db))
    local request = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001")); local state, err = GGM.HandleGuildSyncPayload(sync, bob.key, request)
    T.assertEqual(state, "ignored"); T.assertNil(err); T.assertEqual(#sends, 0)
    db.characters[alice.key] = { complete = true, identity = alice, gear = { complete = true, capturedAt = 1, slots = {} }, confirmedSequence = 0 }
    state, err = GGM.HandleGuildSyncPayload(sync, bob.key, request)
    T.assertNil(state); T.assertEqual(err, "snapshot-slot-missing:HEAD"); T.assertEqual(#sends, 0)
end)

T.test("lower sequence response cannot replace newer record", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 8000), 9))
    local sync = assert(GGM.CreateGuildSync(clientApi(bob), db)); local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, identity("Carol", "Silvermoon", "Carol"), snapshot(GGM, 9000, 1700003000), 8, "000001"))
    local state, err = GGM.HandleGuildSyncPayload(sync, "Carol-Silvermoon", payload)
    T.assertEqual(state, "ignored"); T.assertNil(err); T.assertEqual(db.characters[alice.key].gear.slots.HEAD.itemID, 8001)
end)

T.test("unsolicited snapshot response is rejected", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 8000), 9))
    local sync = assert(GGM.CreateGuildSync(clientApi(bob), db))
    local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, identity("Carol", "Silvermoon", "C"), snapshot(GGM, 9000), 10, "999999"))
    local state, err = GGM.HandleGuildSyncPayload(sync, "Carol-Silvermoon", payload)
    T.assertEqual(state, "ignored"); T.assertNil(err)
    T.assertEqual(db.characters[alice.key].confirmedSequence, 9)
    T.assertEqual(db.characters[alice.key].gear.slots.HEAD.itemID, 8001)
end)

T.test("snapshot response matching an explicit request is accepted", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(GGM.InitializeDatabase(nil)); local api, sends, drain = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    assert(GGM.RequestCompleteSnapshot(sync, alice)); drain()
    local requestPayload = assert(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$"))
    local request = assert(GGM.DecodeSyncMessage(requestPayload))
    local claim = assert(GGM.EncodeSyncSnapshotResponseClaim(alice, bob, carol, 10, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, carol.key, claim), "snapshot-response-claim-recorded")
    local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(GGM, 9000), 10, request.requestID))
    local state, err = GGM.HandleGuildSyncPayload(sync, carol.key, payload)
    T.assertEqual(state, "snapshot-saved"); T.assertNil(err)
    T.assertEqual(db.characters[alice.key].confirmedSequence, 10)
end)

T.test("stale snapshot response remains pending for a later better response", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 8000), 9))
    local api, sends, drain = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    assert(GGM.RequestCompleteSnapshot(sync, alice)); drain()
    local request = assert(GGM.DecodeSyncMessage(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$")))
    local claim = assert(GGM.EncodeSyncSnapshotResponseClaim(alice, bob, carol, 10, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, carol.key, claim), "snapshot-response-claim-recorded")
    local stale = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(GGM, 9000), 8, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, carol.key, stale), "ignored")
    T.assertEqual(sync.pendingSnapshotRequestCount, 1)
    local better = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(GGM, 9100), 10, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, carol.key, better), "snapshot-saved")
    T.assertEqual(sync.pendingSnapshotRequestCount, 0)
    T.assertEqual(db.characters[alice.key].confirmedSequence, 10)
end)

T.test("snapshot requests for the same target are deduplicated and cooled down", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(GGM.InitializeDatabase(nil)); local api, sends, _, setTime = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    T.assertTrue(GGM.RequestCompleteSnapshot(sync, alice))
    local ok, err = GGM.RequestCompleteSnapshot(sync, alice)
    T.assertFalse(ok); T.assertEqual(err, "sync-snapshot-request-pending")
    local request = assert(GGM.DecodeSyncMessage(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$")))
    local responder = identity("Carol", "Silvermoon", "C")
    local claim = assert(GGM.EncodeSyncSnapshotResponseClaim(alice, bob, responder, 10, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, responder.key, claim), "snapshot-response-claim-recorded")
    local response = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, responder, snapshot(GGM, 9000), 10, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, responder.key, response), "snapshot-saved")
    ok, err = GGM.RequestCompleteSnapshot(sync, alice)
    T.assertFalse(ok); T.assertEqual(err, "sync-snapshot-request-cooldown")
    setTime(200 + GGM.SYNC_SNAPSHOT_REQUEST_COOLDOWN_SECONDS)
    T.assertTrue(GGM.RequestCompleteSnapshot(sync, alice))
end)

T.test("snapshot response requires the selected responder as transport sender", function()
    local GGM = loadModules()
    local alice, bob, carol, mallory = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C"), identity("Mallory", "Silvermoon", "M")
    local db = assert(GGM.InitializeDatabase(nil)); local api, sends, drain = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    assert(GGM.RequestCompleteSnapshot(sync, alice)); drain()
    local request = assert(GGM.DecodeSyncMessage(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$")))
    local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(GGM, 9000), 10, request.requestID))
    local state, err = GGM.HandleGuildSyncPayload(sync, mallory.key, payload)
    T.assertEqual(state, "ignored"); T.assertNil(err); T.assertEqual(sync.pendingSnapshotRequestCount, 1)
end)

T.test("snapshot response requires the responder selected by the claim", function()
    local GGM = loadModules()
    local alice, bob, carol, dave = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C"), identity("Dave", "Silvermoon", "D")
    local db = assert(GGM.InitializeDatabase(nil)); local api, sends, drain = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    assert(GGM.RequestCompleteSnapshot(sync, alice)); drain()
    local request = assert(GGM.DecodeSyncMessage(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$")))
    local claim = assert(GGM.EncodeSyncSnapshotResponseClaim(alice, bob, carol, 10, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, carol.key, claim), "snapshot-response-claim-recorded")
    local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, dave, snapshot(GGM, 9000), 10, request.requestID))
    local state, err = GGM.HandleGuildSyncPayload(sync, dave.key, payload)
    T.assertEqual(state, "ignored"); T.assertNil(err); T.assertEqual(sync.pendingSnapshotRequestCount, 1)
end)

T.test("pending snapshot requests are bounded and expire", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(GGM.InitializeDatabase(nil)); local api, sends, _, setTime = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    for requestIndex = 1, GGM.SYNC_MAX_PENDING_SNAPSHOT_REQUESTS do
        T.assertTrue(GGM.RequestCompleteSnapshot(sync, identity("Alice" .. requestIndex, "Silvermoon", "A" .. requestIndex)))
    end
    local ok, err = GGM.RequestCompleteSnapshot(sync, identity("Alice17", "Silvermoon", "A17"))
    T.assertFalse(ok); T.assertEqual(err, "sync-pending-request-limit")
    setTime(200 + GGM.SYNC_SNAPSHOT_REQUEST_TTL_SECONDS)
    T.assertTrue(GGM.RequestCompleteSnapshot(sync, alice))
    T.assertEqual(sync.pendingSnapshotRequestCount, GGM.SYNC_MAX_PENDING_SNAPSHOT_REQUESTS)
    T.assertTrue(#sends > 0)
end)

T.test("confirmed publication uses the persisted sequence and slot", function()
    local GGM = loadModules()
    local alice = identity("Alice", "Silvermoon", "A"); local db = assert(GGM.InitializeDatabase(nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 10000), 4))
    local changed = { inventorySlotID = 1, itemID = 10999, itemLink = "|Hitem:10999|h[Published]|h" }
    assert(GGM.ApplyReceivedCharacterSlot(db, alice.key, "HEAD", changed, 1700003300, 5))
    local api, sends, drain = clientApi(alice); local sync = assert(GGM.CreateGuildSync(api, db))
    local ok, err = GGM.PublishConfirmedSlot(sync, alice.key, "HEAD", changed, 1700003300, 5)
    T.assertTrue(ok); T.assertNil(err); drain(); T.assertTrue(#sends > 0)
end)
