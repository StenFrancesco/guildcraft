local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("The Guild Book/Constants.lua", GGM)
    T.loadAddonFile("The Guild Book gear/Constants.lua", GGM)
    T.loadAddonFile("The Guild Book gear/GearData.lua", GGM)
    T.loadAddonFile("The Guild Book gear/CharacterIdentity.lua", GGM)
    T.loadAddonFile("The Guild Book gear/GearSnapshot.lua", GGM)
    T.loadAddonFile("The Guild Book/Storage.lua", GGM)
    T.loadAddonFile("The Guild Book gear/Storage.lua", GGM)
    T.loadAddonFile("The Guild Book gear/StableGearTracker.lua", GGM)
    T.loadAddonFile("The Guild Book gear/SyncProtocol.lua", GGM)
    T.loadAddonFile("The Guild Book gear/SyncTransport.lua", GGM)
    T.loadAddonFile("The Guild Book gear/GuildSync.lua", GGM)
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
            inventorySlotID = slot.inventorySlotID,
            itemID = itemID,
            itemLink = "|Hitem:" .. itemID .. "|h[" .. slot.key .. "]|h",
        }
    end
    return result
end

local function clientApi(who, results)
    local timers, timeoutTimers, sends, now = {}, {}, {}, 200
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
    api.C_Timer.After = function(delay, callback)
        local timer = { delay = delay, fired = false, cancelled = false }
        function timer:Fire()
            if not self.fired and not self.cancelled then self.fired = true; callback() end
        end
        function timer:Cancel() self.cancelled = true end
        table.insert(timeoutTimers, timer)
    end
    local function drain()
        local index = 1
        while index <= #timers do timers[index]:Fire(); index = index + 1 end
    end
    T.mockChatThrottle(api)
    return api, sends, drain, function(value) now = value end, timers, timeoutTimers
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

T.test("settle timer failure remains visible after claim transmission completes", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7200), 3))
    local api, sends, _, _, timers = clientApi(carol)
    local newTimer = api.C_Timer.NewTimer
    api.C_Timer.NewTimer = function(delay, callback)
        if delay == GGM.SYNC_SNAPSHOT_RESPONSE_OFFER_SETTLE_SECONDS then return nil end
        return newTimer(delay, callback)
    end
    local sync = assert(GGM.CreateGuildSync(api, db))
    assert(GGM.HandleGuildSyncPayload(sync, bob.key, assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001"))))
    timers[1]:Fire()
    T.assertEqual(#sends, 1)
    T.assertEqual(sync.pendingSnapshotResponseCount, 0)
    T.assertEqual(sync.transport.lastSendError, "sync-response-timer-create-failed")
end)

T.test("incremental updates require a complete compatible baseline", function()
    local GGM = loadModules()
    local alice = identity("Alice", "Silvermoon", "A" )
    local bob = identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil))
    local api, sends = clientApi(bob)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local changed = { inventorySlotID = 1, itemID = 9901, itemLink = "|Hitem:9901|h[Remote]|h" }
    local payload = assert(GGM.EncodeSyncSlotUpdate(alice, 5, "HEAD", changed, 1700002300))
    local state, err = GGM.HandleGuildSyncPayload(sync, alice.key, payload)
    T.assertEqual(state, "snapshot-requested"); T.assertNil(err)
    assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 6000), 4))
    state, err = GGM.HandleGuildSyncPayload(sync, alice.key, payload)
    T.assertEqual(state, "slot-applied"); T.assertNil(err)
    T.assertEqual(GGM.ParseItemString(db.characters[alice.key].gear.slots[1]), 9901)
    T.assertEqual(db.characters[alice.key].confirmedSequence, 5)

    assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 9900), 4))
    local preservedSlots = {}
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        preservedSlots[trackedSlot.key] = {
            itemString = db.characters[alice.key].gear.slots[trackedSlot.inventorySlotID],
            unavailable = db.characters[alice.key].gear.unavailableSlots[trackedSlot.inventorySlotID],
        }
    end
    local gapPayload = assert(GGM.EncodeSyncSlotUpdate(alice, 6, "HEAD",
        { inventorySlotID = 1, itemID = 9903, itemLink = "|Hitem:9903|h[Gap]|h" }, 1700002302))
    state, err = GGM.HandleGuildSyncPayload(sync, alice.key, gapPayload)
    T.assertEqual(state, "snapshot-request-pending")
    T.assertNil(err)
    local stale = assert(GGM.GetCharacterRecord(db, alice.key))
    T.assertFalse(stale.complete)
    T.assertTrue(stale.refreshNeeded)
    T.assertEqual(GGM.ParseItemString(stale.gear.slots[1]), 9901)

    local laterPayload = assert(GGM.EncodeSyncSlotUpdate(alice, 8, "HEAD",
        { inventorySlotID = 1, itemID = 9908, itemLink = "|Hitem:9908|h[Later]|h" }, 1700002304))
    state, err = GGM.HandleGuildSyncPayload(sync, alice.key, laterPayload)
    T.assertEqual(state, "sequence-floor-advanced")
    T.assertNil(err)
    stale = assert(GGM.GetCharacterRecord(db, alice.key))
    T.assertEqual(stale.requiredBaselineSequence, 8)
    T.assertEqual(stale.confirmedSequence, 4)
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        T.assertEqual(stale.gear.slots[trackedSlot.inventorySlotID], preservedSlots[trackedSlot.key].itemString)
        T.assertEqual(stale.gear.unavailableSlots[trackedSlot.inventorySlotID], preservedSlots[trackedSlot.key].unavailable)
    end
    T.assertEqual(#sends, 1)

    for _, belowFloor in ipairs({ 6, 7 }) do
        local repairedEarly, earlyErr = GGM.SaveReceivedCompleteCharacterRecord(db, alice, snapshot(GGM, 8000 + belowFloor), belowFloor)
        T.assertFalse(repairedEarly)
        T.assertEqual(earlyErr, "confirmed-sequence-before-required-baseline")
        T.assertTrue(assert(GGM.GetCharacterRecord(db, alice.key)).refreshNeeded)
        T.assertEqual(#sends, 1)
    end
    assert(GGM.SaveReceivedCompleteCharacterRecord(db, alice, snapshot(GGM, 8008), 8))
    local repaired = assert(GGM.GetCompleteCharacterRecord(db, alice.key))
    T.assertTrue(repaired.complete)
    T.assertNil(repaired.refreshNeeded)
    T.assertEqual(#sends, 1)
end)

T.test("incremental sender identity mismatch fails closed", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 6000), 1))
    local sync = assert(GGM.CreateGuildSync(clientApi(bob), db))
    local payload = assert(GGM.EncodeSyncSlotUpdate(alice, 2, "HEAD", { inventorySlotID = 1, itemID = 9902, itemLink = "|Hitem:9902|h[Spoof]|h" }, 1700002400))
    local state, err = GGM.HandleGuildSyncPayload(sync, "Mallory-Silvermoon", payload)
    T.assertNil(state); T.assertEqual(err, "sync-sender-identity-mismatch")
    T.assertEqual(GGM.ParseItemString(db.characters[alice.key].gear.slots[1]), 6001)
end)

T.test("explicit request receives a complete offline cached record", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local bobDb = assert(T.initializeDatabase(GGM, nil)); local bobApi, bobSends, drainBob = clientApi(bob)
    local bobSync = assert(GGM.CreateGuildSync(bobApi, bobDb))
    local carolDb = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(carolDb, alice, snapshot(GGM, 7000), 6))
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
    local requestApi, requestSends, drain = clientApi(bob); local requester = assert(GGM.CreateGuildSync(requestApi, assert(T.initializeDatabase(GGM, nil))))
    assert(GGM.RequestCompleteSnapshot(requester, alice)); drain()
    local carolDb = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(carolDb, alice, snapshot(GGM, 7100), 3))
    local carolApi, carolSends, _, _, carolTimers = clientApi(carol); local carolSync = assert(GGM.CreateGuildSync(carolApi, carolDb))
    local daveDb = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(daveDb, alice, snapshot(GGM, 7100), 3))
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
    -- Equal-sequence claims elect the lexicographically first responder even
    -- when its deterministic response delay is later. The earlier client may
    -- already have sent one bounded claim before it observes the better claim.
    T.assertTrue(#carolSends > 1)
    T.assertEqual(#daveSends, 1)
end)

T.test("equal sequence claims elect the lexicographically first responder", function()
    local GGM = loadModules()
    local alice, bob, dave, eve = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Dave", "Silvermoon", "D"), identity("Eve", "Silvermoon", "E")
    local daveDb = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(daveDb, alice, snapshot(GGM, 7100), 3))
    local daveApi, daveSends, _, _, daveTimers = clientApi(dave); local daveSync = assert(GGM.CreateGuildSync(daveApi, daveDb))
    local eveDb = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(eveDb, alice, snapshot(GGM, 7100), 3))
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
    daveTimers[3]:Fire()
    T.assertEqual(#daveSends, 2)
    T.assertEqual(#eveSends, 1)
end)

T.test("snapshot response cancellation is scoped to requester", function()
    local GGM = loadModules()
    local alice, bob, eve, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Eve", "Silvermoon", "E"), identity("Carol", "Silvermoon", "C")
    local db = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7200), 3))
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
    local carolDb = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(carolDb, alice, snapshot(GGM, 7500), 10))
    local carolApi, carolSends, _, _, carolTimers = clientApi(carol); local carolSync = assert(GGM.CreateGuildSync(carolApi, carolDb))
    local daveDb = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(daveDb, alice, snapshot(GGM, 7400), 8))
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
    T.assertEqual(carolSync.pendingSnapshotResponseCount, 1)
    local timerIndex = 2
    while timerIndex <= #carolTimers do carolTimers[timerIndex]:Fire(); timerIndex = timerIndex + 1 end
    T.assertEqual(carolSync.pendingSnapshotResponseCount, 0)
    T.assertTrue(#carolSends > 0)
end)

T.test("a better claim cancels a snapshot still queued behind outbound frames", function()
    local GGM = loadModules()
    local alice, bob, carol, dave = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C"), identity("Dave", "Silvermoon", "D")
    local db = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7500), 3))
    local api, sends, _, _, timers = clientApi(carol); local sync = assert(GGM.CreateGuildSync(api, db))
    local request = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001"))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, bob.key, request), "snapshot-response-queued")

    timers[1]:Fire() -- advertises the claim while this client is idle
    assert(GGM.SendSyncPayload(sync.transport, string.rep("x", 700)))
    timers[2]:Fire() -- queues the complete snapshot behind the newer traffic
    local fullPayload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(GGM, 7500), 3, "000001"))
    local fullFrameCount = math.ceil(#fullPayload / GGM.SYNC_FRAME_CHUNK_BYTES)
    T.assertEqual(sync.pendingSnapshotResponseCount, 1)
    T.assertEqual(#sync.transport.outboundFrames, 4 + fullFrameCount)

    local betterClaim = assert(GGM.EncodeSyncSnapshotResponseClaim(alice, bob, dave, 4, "000001", 1700002000))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, dave.key, betterClaim), "snapshot-response-claim-accepted")
    T.assertEqual(sync.pendingSnapshotResponseCount, 0)
    T.assertEqual(#sync.transport.outboundFrames, 4)
    T.assertEqual(#sends, 1)
    local timerIndex = 1
    while timerIndex <= #timers do timers[timerIndex]:Fire(); timerIndex = timerIndex + 1 end
    T.assertEqual(#sync.transport.outboundFrames, 0)
    T.assertEqual(#sends, 5) -- one claim and four blocker frames; no snapshot frames
end)

T.test("gear-ready snapshot requests retry after a silent response timeout", function()
    local GGM = loadModules()
    local owner, requester = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local api, sends, _, setNow, timers, timeoutTimers = clientApi(requester)
    local sync = assert(GGM.CreateGuildSync(api, assert(T.initializeDatabase(GGM, nil))))
    local ready = assert(GGM.EncodeSyncGearReady(owner, 3, 1700003000, 1700002500))

    local state = GGM.HandleGuildSyncPayload(sync, owner.key, ready)

    T.assertEqual(state, "snapshot-requested")
    local requestID = sync.pendingSnapshotRequestTargets[owner.key]
    local pending = sync.pendingSnapshotRequests[requestID]
    T.assertNotNil(pending.gearReadyTimeoutTimer)
    T.assertTrue(fireNextTimer(timers)) -- send the initial request
    T.assertEqual(#sends, 1)

    setNow(pending.expiresAt)
    timeoutTimers[1]:Fire()

    T.assertEqual(sync.pendingSnapshotRequestCount, 0)
    local retryState = sync.gearReadyRetryStates[owner.key]
    T.assertNotNil(retryState)
    T.assertNotNil(retryState.timer)
    T.assertTrue(retryState.timer.delay >= GGM.SYNC_SNAPSHOT_REPAIR_BACKOFF_SECONDS)

    setNow(pending.expiresAt + retryState.timer.delay)
    retryState.timer:Fire()

    T.assertEqual(sync.pendingSnapshotRequestCount, 1)
    local retryID = sync.pendingSnapshotRequestTargets[owner.key]
    T.assertTrue(retryID ~= requestID)
    T.assertNotNil(sync.pendingSnapshotRequests[retryID].gearReadyTimeoutTimer)
    T.assertTrue(fireNextTimer(timers)) -- send the retry
    T.assertEqual(#sends, 2)
end)

T.test("repeated snapshot requests for one requester and target coalesce", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7350), 3))
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
    local db = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7400), 3))
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
    local db = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 7150), 3))
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
    local db = assert(T.initializeDatabase(GGM, nil)); local api, sends = clientApi(carol); local sync = assert(GGM.CreateGuildSync(api, db))
    local request = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001")); local state, err = GGM.HandleGuildSyncPayload(sync, bob.key, request)
    T.assertEqual(state, "ignored"); T.assertNil(err); T.assertEqual(#sends, 0)
    db.characters[alice.key] = { complete = true, identity = alice, gear = { complete = true, capturedAt = 1, slots = {} }, confirmedSequence = 0 }
    state, err = GGM.HandleGuildSyncPayload(sync, bob.key, request)
    T.assertNil(state); T.assertEqual(err, "snapshot-unavailable-slots-invalid"); T.assertEqual(#sends, 0)
end)

T.test("lower sequence response cannot replace newer record", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 8000), 9))
    local sync = assert(GGM.CreateGuildSync(clientApi(bob), db)); local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, identity("Carol", "Silvermoon", "Carol"), snapshot(GGM, 9000, 1700003000), 8, "000001"))
    local state, err = GGM.HandleGuildSyncPayload(sync, "Carol-Silvermoon", payload)
    T.assertEqual(state, "ignored"); T.assertNil(err); T.assertEqual(GGM.ParseItemString(db.characters[alice.key].gear.slots[1]), 8001)
end)

T.test("unsolicited snapshot response is rejected", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 8000), 9))
    local sync = assert(GGM.CreateGuildSync(clientApi(bob), db))
    local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, identity("Carol", "Silvermoon", "C"), snapshot(GGM, 9000), 10, "999999"))
    local state, err = GGM.HandleGuildSyncPayload(sync, "Carol-Silvermoon", payload)
    T.assertEqual(state, "ignored"); T.assertNil(err)
    T.assertEqual(db.characters[alice.key].confirmedSequence, 9)
    T.assertEqual(GGM.ParseItemString(db.characters[alice.key].gear.slots[1]), 8001)
end)

T.test("snapshot response matching an explicit request is accepted", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    alice.raceID, alice.sex, alice.displayID = 5, 2, 12345
    local db = assert(T.initializeDatabase(GGM, nil)); local api, sends, drain = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    assert(GGM.RequestCompleteSnapshot(sync, alice)); drain()
    local requestPayload = assert(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$"))
    local request = assert(GGM.DecodeSyncMessage(requestPayload))
    local claim = assert(GGM.EncodeSyncSnapshotResponseClaim(alice, bob, carol, 10, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, carol.key, claim), "snapshot-response-claim-recorded")
    local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(GGM, 9000), 10, request.requestID))
    local state, err = GGM.HandleGuildSyncPayload(sync, carol.key, payload)
    T.assertEqual(state, "snapshot-saved"); T.assertNil(err)
    T.assertEqual(db.characters[alice.key].confirmedSequence, 10)
    local saved = assert(GGM.GetCompleteCharacterRecord(db, alice.key))
    T.assertEqual(saved.identity.raceID, 5)
    T.assertEqual(saved.identity.sex, 2)
    T.assertEqual(saved.identity.displayID, 12345)
end)

T.test("received local snapshot refreshes the active gear tracker baseline", function()
    local GGM = loadModules()
    local alice, carol = identity("Alice", "Silvermoon", "A"), identity("Carol", "Silvermoon", "C")
    local db = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 8000), 4))
    local api, sends, _, _, timers = clientApi(alice)
    local slotIDs, itemIDs, itemLinks = {}, {}, {}
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        slotIDs[slot.inventoryName] = slot.inventorySlotID
        itemIDs[slot.inventorySlotID] = index == 1 and 8001 or 9000 + index
        itemLinks[slot.inventorySlotID] = "|Hitem:" .. tostring(itemIDs[slot.inventorySlotID]) .. "|h[" .. slot.key .. "]|h"
    end
    api.GetInventorySlotInfo = function(name) return slotIDs[name] end
    api.GetInventoryItemID = function(_, slotID) return itemIDs[slotID] end
    api.GetInventoryItemLink = function(_, slotID) return itemLinks[slotID] end
    api.GetServerTime = function() return 1700003000 end
    local initialRuntimeSnapshot = assert(GGM.BuildRuntimeGearSnapshot(api, db.characters[alice.key].gear))
    local tracker = assert(GGM.CreateStableGearTracker(api, alice.key, initialRuntimeSnapshot, 30))
    local sync = assert(GGM.CreateGuildSync(api, db))
    sync.localGearTracker = tracker
    assert(GGM.RequestCompleteSnapshot(sync, alice))
    local request = assert(GGM.DecodeSyncMessage(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$")))
    sync.pendingSnapshotRequests[request.requestID].selectedResponderKey = carol.key
    local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, alice, carol, snapshot(GGM, 9000, 1700002500), 5, request.requestID))

    local state, err = GGM.HandleGuildSyncPayload(sync, carol.key, payload)

    T.assertEqual(state, "snapshot-saved"); T.assertNil(err)
    T.assertEqual(tracker.confirmedSlots.HEAD.itemID, 9001)
    T.assertNotNil(tracker.pendingBySlot.HEAD)
    T.assertEqual(GGM.HandlePlayerEquipmentChanged(tracker, 1), "pending")
    T.assertEqual(#timers, 2) -- transport cooldown and local stability timer
    T.assertEqual(tracker.pendingBySlot.HEAD.timer.delay, 30)
end)

T.test("received slot delta leaves saved model identity untouched without requesting a baseline", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    alice.raceID, alice.sex, alice.displayID = 3, 3, 54321
    local db = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 8000), 4))
    local api, sends = clientApi(bob)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local update = assert(GGM.EncodeSyncSlotUpdate(identity("Alice", "Silvermoon", "A"), 5, "HEAD", {
        inventorySlotID = 1, itemID = 9999, itemLink = "|Hitem:9999|h[Changed]|h",
    }, 1700003000))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, alice.key, update), "slot-applied")
    local saved = assert(GGM.GetCompleteCharacterRecord(db, alice.key))
    T.assertEqual(saved.identity.raceID, 3)
    T.assertEqual(saved.identity.sex, 3)
    T.assertEqual(saved.identity.displayID, 54321)
    T.assertEqual(GGM.ParseItemString(saved.gear.slots[1]), 9999)
    T.assertEqual(#sends, 0)
end)

T.test("stale snapshot response remains pending for a later better response", function()
    local GGM = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local db = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 8000), 9))
    local api, sends, drain = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    assert(GGM.RequestCompleteSnapshot(sync, alice)); drain()
    local request = assert(GGM.DecodeSyncMessage(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$")))
    local claim = assert(GGM.EncodeSyncSnapshotResponseClaim(alice, bob, carol, 10, request.requestID, 1700002000))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, carol.key, claim), "snapshot-response-claim-recorded")
    local stale = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(GGM, 9000, 1700001000), 8, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, carol.key, stale), "ignored")
    T.assertEqual(sync.pendingSnapshotRequestCount, 1)
    local better = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(GGM, 9100, 1700003000), 10, request.requestID))
    T.assertEqual(GGM.HandleGuildSyncPayload(sync, carol.key, better), "snapshot-saved")
    T.assertEqual(sync.pendingSnapshotRequestCount, 0)
    T.assertEqual(db.characters[alice.key].confirmedSequence, 10)
end)

T.test("snapshot requests for the same target are deduplicated and cooled down", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil)); local api, sends, _, setTime = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
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
    local db = assert(T.initializeDatabase(GGM, nil)); local api, sends, drain = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    assert(GGM.RequestCompleteSnapshot(sync, alice)); drain()
    local request = assert(GGM.DecodeSyncMessage(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$")))
    local payload = assert(GGM.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(GGM, 9000), 10, request.requestID))
    local state, err = GGM.HandleGuildSyncPayload(sync, mallory.key, payload)
    T.assertEqual(state, "ignored"); T.assertNil(err); T.assertEqual(sync.pendingSnapshotRequestCount, 1)
end)

T.test("snapshot response requires the responder selected by the claim", function()
    local GGM = loadModules()
    local alice, bob, carol, dave = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C"), identity("Dave", "Silvermoon", "D")
    local db = assert(T.initializeDatabase(GGM, nil)); local api, sends, drain = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
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
    local db = assert(T.initializeDatabase(GGM, nil)); local api, sends, _, setTime = clientApi(bob); local sync = assert(GGM.CreateGuildSync(api, db))
    for requestIndex = 1, GGM.SYNC_MAX_PENDING_SNAPSHOT_REQUESTS do
        T.assertTrue(GGM.RequestCompleteSnapshot(sync, identity("Alice" .. requestIndex, "Silvermoon", "A" .. requestIndex)))
    end
    local ok, err = GGM.RequestCompleteSnapshot(sync, identity("Alice17", "Silvermoon", "A17"))
    T.assertFalse(ok); T.assertEqual(err, "sync-pending-request-limit")
    setTime(200 + GGM.SYNC_SNAPSHOT_REQUEST_TTL_SECONDS)
    T.assertTrue(GGM.RequestCompleteSnapshot(sync, alice))
    T.assertEqual(sync.pendingSnapshotRequestCount, 1)
    T.assertTrue(#sends > 0)
end)

T.test("confirmed publication uses the persisted sequence and slot", function()
    local GGM = loadModules()
    local alice = identity("Alice", "Silvermoon", "A"); local db = assert(T.initializeDatabase(GGM, nil)); assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 10000), 4))
    local changed = { inventorySlotID = 1, itemID = 10999, itemLink = "|Hitem:10999|h[Published]|h" }
    assert(GGM.ApplyReceivedCharacterSlot(db, alice.key, "HEAD", changed, 1700003300, 5))
    local api, sends, drain = clientApi(alice); local sync = assert(GGM.CreateGuildSync(api, db))
    local ok, err = GGM.PublishConfirmedSlot(sync, alice.key, "HEAD", changed, 1700003300, 5)
    T.assertTrue(ok); T.assertNil(err); drain(); T.assertTrue(#sends > 0)
end)

T.test("confirmed publication reconstructs protocol six slot data from compact storage", function()
    local GGM = loadModules()
    local alice = identity("Alice", "Silvermoon", "A")
    local db = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveCompleteCharacterRecord(db, alice, snapshot(GGM, 2000), 4))
    local api = clientApi(alice)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local captured
    local encode = GGM.EncodeSyncSlotUpdate
    GGM.EncodeSyncSlotUpdate = function(identityValue, sequence, slotKey, slotValue, confirmedAt)
        captured = GGM.CopyGearSlotValue(slotValue)
        return encode(identityValue, sequence, slotKey, slotValue, confirmedAt)
    end

    local record = assert(GGM.GetCompleteCharacterRecord(db, alice.key))
    local runtimeSlot = assert(GGM.BuildRuntimeGearSlot(api, record.gear, "HEAD"))
    local sent, err = GGM.PublishConfirmedSlot(sync, alice.key, "HEAD", runtimeSlot, record.gear.capturedAt, 4)
    T.assertTrue(sent)
    T.assertNil(err)
    T.assertEqual(captured.inventorySlotID, 1)
    T.assertEqual(captured.itemID, runtimeSlot.itemID)
    T.assertTrue(type(captured.itemLink) == "string" and captured.itemLink:match("^|Hitem:") ~= nil)
end)

local function oversizedStoredSnapshot(GGM)
    local result = snapshot(GGM, 3000)
    local itemString = "item:123" .. string.rep(":0", 156)
    T.assertTrue(#itemString <= GGM.GEAR_MAX_ITEM_STRING_BYTES)
    local itemID = assert(GGM.ParseItemString(itemString))
    result.slots.HEAD = {
        inventorySlotID = 1,
        itemID = itemID,
        itemLink = "|H" .. itemString .. "|h[Long]|h",
    }
    return result
end

T.test("oversized reconstructed incremental hyperlink fails before queueing", function()
    local GGM = loadModules()
    local alice = identity("Alice", "Silvermoon", "A")
    local db = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveCompleteCharacterRecord(db, alice, oversizedStoredSnapshot(GGM), 4))
    local api, sends = clientApi(alice)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local before = assert(GGM.GetCompleteCharacterRecord(db, alice.key))
    local runtimeSlot = assert(GGM.BuildRuntimeGearSlot(api, before.gear, "HEAD"))

    local sent, err = GGM.PublishConfirmedSlot(sync, alice.key, "HEAD", runtimeSlot, before.gear.capturedAt, 4)

    T.assertFalse(sent)
    T.assertEqual(err, "sync-item-link-too-long")
    T.assertEqual(#sends, 0)
    T.assertEqual(#sync.transport.outboundFrames, 0)
    local after = assert(GGM.GetCompleteCharacterRecord(db, alice.key))
    T.assertEqual(after.confirmedSequence, 4)
    T.assertEqual(after.gear.slots[1], before.gear.slots[1])
end)

T.test("oversized reconstructed snapshot fails before a claim or snapshot is queued", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveCompleteCharacterRecord(db, alice, oversizedStoredSnapshot(GGM), 4))
    local api, sends, _, _, timers = clientApi(alice)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local request = assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001"))

    local state, err = GGM.HandleGuildSyncPayload(sync, bob.key, request)

    T.assertNil(state)
    T.assertEqual(err, "sync-item-link-too-long")
    T.assertEqual(#sends, 0)
    T.assertEqual(#timers, 0)
    T.assertEqual(sync.pendingSnapshotResponseCount, 0)
    T.assertEqual(#sync.transport.outboundFrames, 0)
    local record = assert(GGM.GetCompleteCharacterRecord(db, alice.key))
    T.assertEqual(record.confirmedSequence, 4)
    T.assertTrue(record.gear.complete)
    T.assertNotNil(record.gear.slots[1])
end)

T.test("migrated incomplete records do not answer full snapshot requests", function()
    local GGM = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "Player-1234-AAAA"), identity("Bob", "Silvermoon", "Player-1234-BBBB")
    local db = assert(T.initializeDatabase(GGM, nil))
    local migratedSlots = {}
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        if slot.key ~= "SHIRT" and slot.key ~= "TABARD" and slot.key ~= "RANGED" then
            migratedSlots[slot.key] = { inventorySlotID = slot.inventorySlotID, itemID = 7000 + index, itemLink = "|Hitem:" .. tostring(7000 + index) .. "|h[Legacy]|h" }
        end
    end
    db.characters[alice.key] = {
        complete = false, completeness = "incomplete", identity = alice, confirmedSequence = 3,
        gear = { complete = false, capturedAt = 1700002000, slots = migratedSlots },
    }
    local api, _, _, _, timers = clientApi(alice)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local result, err = GGM.HandleGuildSyncPayload(sync, bob.key,
        assert(GGM.EncodeSyncSnapshotRequest(bob, alice, "000001")))
    T.assertNil(err)
    T.assertEqual(result, "ignored")
    T.assertEqual(#timers, 0)
end)

T.test("gear sender normalization accepts local short names and normalized realms without accepting a different realm", function()
    local G = loadModules()
    local alice, bob = identity("Alice", "Argent Dawn", "A"), identity("Bob", "Argent Dawn", "B")
    local db = assert(T.initializeDatabase(G, nil))
    assert(G.SaveCompleteCharacterRecord(db, alice, snapshot(G, 6000), 1))
    local sync = assert(G.CreateGuildSync(clientApi(bob), db))
    local payload = assert(G.EncodeSyncSlotUpdate(alice, 2, "HEAD", { inventorySlotID = 1, itemID = 9999, itemLink = "|Hitem:9999|h[Changed]|h" }, 1700002400))
    T.assertEqual(G.HandleGuildSyncPayload(sync, "Alice", payload), "slot-applied")
    T.assertEqual(G.HandleGuildSyncPayload(sync, "Alice-ArgentDawn", payload), "slot-applied")
    local state, err = G.HandleGuildSyncPayload(sync, "Alice-OtherRealm", payload)
    T.assertNil(state); T.assertEqual(err, "sync-sender-identity-mismatch")
end)

T.test("automatic gear repair coalesces requests and does not trust mismatched owner updates", function()
    local G = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local api, sends = clientApi(bob)
    local sync = assert(G.CreateGuildSync(api, assert(T.initializeDatabase(G, nil))))
    local payload = assert(G.EncodeSyncSlotUpdate(alice, 2, "HEAD", { inventorySlotID = 1, itemID = 9999, itemLink = "|Hitem:9999|h[Changed]|h" }, 1700002400))
    G.HandleGuildSyncPayload(sync, "Mallory-Silvermoon", payload)
    T.assertEqual(#sends, 0)
    T.assertEqual(G.HandleGuildSyncPayload(sync, alice.key, payload), "snapshot-requested")
    T.assertEqual(G.HandleGuildSyncPayload(sync, alice.key, payload), "snapshot-request-pending")
    T.assertEqual(sync.pendingSnapshotRequestCount, 1)
    T.assertEqual(#sends, 1)
    T.assertNil(sync.db.characters[alice.key])
end)

T.test("gear request status reports expiry without sending or retaining pending work", function()
    local G = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local api, sends, _, setTime = clientApi(bob)
    local sync = assert(G.CreateGuildSync(api, assert(T.initializeDatabase(G, nil))))
    assert(G.RequestCompleteSnapshot(sync, alice))
    local status, busy = G.GetGearSyncStatus(sync, alice.key)
    T.assertEqual(status, "Waiting for a gear snapshot..."); T.assertTrue(busy)
    setTime(200 + G.SYNC_SNAPSHOT_REQUEST_TTL_SECONDS)
    status, busy = G.GetGearSyncStatus(sync, alice.key)
    T.assertEqual(status, "No gear snapshot received. Try again."); T.assertFalse(busy)
    T.assertEqual(sync.pendingSnapshotRequestCount, 0)
    T.assertEqual(#sends, 1)
end)

T.test("asynchronous request send failure releases pending gear requests", function()
    local G = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local api = clientApi(bob)
    local complete
    api.ChatThrottleLib.SendAddonMessage = function(_, _, _, _, _, _, _, callback) complete = callback end
    local sync = assert(G.CreateGuildSync(api, assert(T.initializeDatabase(G, nil))))
    assert(G.RequestCompleteSnapshot(sync, alice))
    complete(nil, false, 10)
    T.assertEqual(sync.pendingSnapshotRequestCount, 0)
    local status, busy, err = G.GetGearSyncStatus(sync, alice.key)
    T.assertFalse(busy)
    T.assertEqual(err, "send-addon-message-failed:NotInGuild")
end)

T.test("missing-baseline repair refuses peer snapshots older than the triggering owner update", function()
    local G = loadModules()
    local alice, bob, carol = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B"), identity("Carol", "Silvermoon", "C")
    local api, sends = clientApi(bob)
    local sync = assert(G.CreateGuildSync(api, assert(T.initializeDatabase(G, nil))))
    local update = assert(G.EncodeSyncSlotUpdate(alice, 8, "HEAD", { inventorySlotID = 1, itemID = 9999, itemLink = "|Hitem:9999|h[Changed]|h" }, 1700002400))
    G.HandleGuildSyncPayload(sync, alice.key, update)
    local request = assert(G.DecodeSyncMessage(sends[1].message:match("^F1|%d+|%d+|%d+|(.*)$")))
    local claim = assert(G.EncodeSyncSnapshotResponseClaim(alice, bob, carol, 7, request.requestID))
    T.assertEqual(G.HandleGuildSyncPayload(sync, carol.key, claim), "ignored")
    local response = assert(G.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(G, 7000), 7, request.requestID))
    T.assertEqual(G.HandleGuildSyncPayload(sync, carol.key, response), "ignored")
    T.assertNil(sync.db.characters[alice.key])
    T.assertEqual(sync.pendingSnapshotRequestCount, 1)
    claim = assert(G.EncodeSyncSnapshotResponseClaim(alice, bob, carol, 8, request.requestID))
    G.HandleGuildSyncPayload(sync, carol.key, claim)
    response = assert(G.EncodeSyncSnapshotResponse(alice, bob, carol, snapshot(G, 8000), 8, request.requestID))
    T.assertEqual(G.HandleGuildSyncPayload(sync, carol.key, response), "snapshot-saved")
    T.assertEqual(G.GetGearSyncStatus(sync, alice.key), "Gear snapshot synchronized.")
end)

T.test("failed automatic gear repair does not send a request for every following slot", function()
    local G = loadModules()
    local alice, bob = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local api, sends, _, setTime = clientApi(bob, { 10, 10 })
    local sync = assert(G.CreateGuildSync(api, assert(T.initializeDatabase(G, nil))))
    local update = assert(G.EncodeSyncSlotUpdate(alice, 8, "HEAD", { inventorySlotID = 1, itemID = 9999, itemLink = "|Hitem:9999|h[Changed]|h" }, 1700002400))
    G.HandleGuildSyncPayload(sync, alice.key, update)
    G.HandleGuildSyncPayload(sync, alice.key, update)
    T.assertEqual(#sends, 1)
    setTime(200 + G.SYNC_SNAPSHOT_REQUEST_COOLDOWN_SECONDS)
    G.HandleGuildSyncPayload(sync, alice.key, update)
    T.assertEqual(#sends, 2)
end)

T.test("owner gear-ready metadata carries maximum time and minimum slot observation separately", function()
    local GGM = loadModules()
    local owner = identity("Alice", "Silvermoon", "A")
    local db = assert(T.initializeDatabase(GGM, nil))
    local observed = snapshot(GGM, 8200, 1700002000)
    observed.slotObservedAt = {}
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        observed.slotObservedAt[slot.inventorySlotID] = slot.inventorySlotID == 1 and 1700001000 or (slot.inventorySlotID == 2 and 1700002000 or 1700001800)
    end
    assert(GGM.SaveCompleteCharacterRecord(db, owner, observed, 4))
    local api, sends = clientApi(owner)
    local sync = assert(GGM.CreateGuildSync(api, db))
    sync.localGearTracker = { characterKey = owner.key }

    local queued, err = GGM.AnnounceLocalGearReady(sync)

    T.assertTrue(queued)
    T.assertNil(err)
    local frame = sends[1].message
    local payload = frame:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$")
    local message = assert(GGM.DecodeSyncMessage(payload))
    T.assertEqual(message.capturedAt, 1700002000)
    T.assertEqual(message.baselineObservedAt, 1700001000)
end)

T.test("gear-ready triggers one paced snapshot repair for a missing cache", function()
    local GGM = loadModules()
    local owner, requester = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil))
    local api, sends = clientApi(requester)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local ready = assert(GGM.EncodeSyncGearReady(owner, 5, 1700002000, 1700001500))

    local state = GGM.HandleGuildSyncPayload(sync, owner.key, ready)
    local duplicateState = GGM.HandleGuildSyncPayload(sync, owner.key, ready)

    T.assertEqual(state, "snapshot-requested")
    T.assertEqual(duplicateState, "snapshot-request-pending")
    T.assertEqual(#sends, 1)
    T.assertEqual(sync.pendingSnapshotRequestCount, 1)
end)

T.test("gear-ready refreshes one earlier unanswered request but duplicate hints coalesce", function()
    local GGM = loadModules()
    local owner, requester = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil))
    local api, sends, drain = clientApi(requester)
    local sync = assert(GGM.CreateGuildSync(api, db))
    assert(GGM.RequestCompleteSnapshot(sync, owner, 7, 1700008000))
    T.assertEqual(#sends, 1)
    local requestID = sync.pendingSnapshotRequestTargets[owner.key]
    local originalPending = sync.pendingSnapshotRequests[requestID]
    local ready = assert(GGM.EncodeSyncGearReady(owner, 0, 1700002000, 1700001500))

    local refreshed = GGM.HandleGuildSyncPayload(sync, owner.key, ready)
    local duplicate = GGM.HandleGuildSyncPayload(sync, owner.key, ready)
    drain()

    T.assertEqual(refreshed, "snapshot-request-refreshed")
    T.assertEqual(duplicate, "snapshot-request-pending")
    T.assertEqual(#sends, 2)
    local firstPayload = assert(sends[1].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$"))
    local secondPayload = assert(sends[2].message:match("^F1|%d%d%d%d%d%d|%d%d|%d%d|(.*)$"))
    T.assertEqual(assert(GGM.DecodeSyncMessage(firstPayload)).requestID, requestID)
    T.assertEqual(assert(GGM.DecodeSyncMessage(secondPayload)).requestID, requestID)
    T.assertEqual(sync.pendingSnapshotRequestCount, 1)
    T.assertEqual(sync.pendingSnapshotRequestTargets[owner.key], requestID)
    T.assertTrue(sync.pendingSnapshotRequests[requestID] == originalPending)
    T.assertEqual(originalPending.minimumSequence, 7)
    T.assertEqual(originalPending.minimumObservedAt, 1700008000)
end)

T.test("gear-ready does not duplicate a request that is still queued for transmission", function()
    local GGM = loadModules()
    local owner, requester = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local api, sends = clientApi(requester)
    local completion
    local throttleCalls = 0
    api.ChatThrottleLib.SendAddonMessage = function(_, _, prefix, frame, channel, target, _, callback, arg)
        throttleCalls = throttleCalls + 1
        completion = function()
            api.C_ChatInfo.SendAddonMessage(prefix, frame, channel, target)
            callback(arg, true, 0)
        end
    end
    local sync = assert(GGM.CreateGuildSync(api, assert(T.initializeDatabase(GGM, nil))))
    assert(GGM.RequestCompleteSnapshot(sync, owner, 3, 1700002500))
    local requestID = sync.pendingSnapshotRequestTargets[owner.key]
    local pending = sync.pendingSnapshotRequests[requestID]
    T.assertFalse(pending.requestSent)
    T.assertEqual(#sync.transport.outboundFrames, 1)
    local ready = assert(GGM.EncodeSyncGearReady(owner, 4, 1700003000, 1700002500))

    local state = GGM.HandleGuildSyncPayload(sync, owner.key, ready)

    T.assertEqual(state, "snapshot-request-pending")
    T.assertEqual(throttleCalls, 1)
    T.assertEqual(#sync.transport.outboundFrames, 1)
    T.assertEqual(sync.pendingSnapshotRequestTargets[owner.key], requestID)
    T.assertTrue(sync.pendingSnapshotRequests[requestID] == pending)
    completion()
    T.assertTrue(pending.requestSent)
    T.assertEqual(#sends, 1)
end)
T.test("failed gear-ready refresh preserves the original pending request callback", function()
    local GGM = loadModules()
    local owner, requester = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local api = clientApi(requester)
    local sync = assert(GGM.CreateGuildSync(api, assert(T.initializeDatabase(GGM, nil))))
    local callbackCalls = 0
    assert(GGM.RequestCompleteSnapshot(sync, owner, 3, 1700002500, function()
        callbackCalls = callbackCalls + 1
    end))
    local oldID = sync.pendingSnapshotRequestTargets[owner.key]
    local oldPending = sync.pendingSnapshotRequests[oldID]
    local originalSend = GGM.SendSyncPayload
    GGM.SendSyncPayload = function() return false, "sync-outbound-queue-full" end
    local ready = assert(GGM.EncodeSyncGearReady(owner, 0, 1700002000, 1700001500))

    local state = GGM.HandleGuildSyncPayload(sync, owner.key, ready)

    GGM.SendSyncPayload = originalSend
    T.assertEqual(state, "snapshot-request-pending")
    T.assertEqual(sync.pendingSnapshotRequestTargets[owner.key], oldID)
    T.assertTrue(sync.pendingSnapshotRequests[oldID] == oldPending)
    T.assertEqual(sync.pendingSnapshotRequestCount, 1)
    T.assertTrue(oldPending.gearReadyRefreshUsed)
    T.assertEqual(callbackCalls, 0)
end)

T.test("gear-ready expires an old request before retrying after timeout backoff", function()
    local GGM = loadModules()
    local owner, requester = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local api, sends, drain, setNow = clientApi(requester)
    local sync = assert(GGM.CreateGuildSync(api, assert(T.initializeDatabase(GGM, nil))))
    local callbackCalls = 0
    assert(GGM.RequestCompleteSnapshot(sync, owner, 3, 1700002500, function(ok)
        callbackCalls = callbackCalls + 1
        T.assertFalse(ok)
    end))
    drain()
    local expiredID = sync.pendingSnapshotRequestTargets[owner.key]
    local ready = assert(GGM.EncodeSyncGearReady(owner, 4, 1700003000, 1700002500))
    setNow(200 + GGM.SYNC_SNAPSHOT_REQUEST_TTL_SECONDS + 1)

    local expiredState = GGM.HandleGuildSyncPayload(sync, owner.key, ready)

    T.assertEqual(expiredState, "snapshot-request-cooldown")
    T.assertEqual(callbackCalls, 1)
    T.assertEqual(sync.pendingSnapshotRequestCount, 0)
    T.assertEqual(#sends, 1)
    local retryState = sync.gearReadyRetryStates[owner.key]
    T.assertNotNil(retryState)
    T.assertNotNil(retryState.timer)
    setNow(200 + GGM.SYNC_SNAPSHOT_REQUEST_TTL_SECONDS + 1 + retryState.timer.delay)
    retryState.timer:Fire()
    drain()

    T.assertEqual(#sends, 2)
    local retryID = sync.pendingSnapshotRequestTargets[owner.key]
    T.assertNotNil(retryID)
    T.assertTrue(retryID ~= expiredID)
end)

T.test("gear-ready sequence breaks an otherwise equal-time cache freshness tie", function()
    local GGM = loadModules()
    local owner, requester = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil))
    local sameTimeSnapshot = snapshot(GGM, 8460, 1700005000)
    sameTimeSnapshot.slotObservedAt = {}
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        sameTimeSnapshot.slotObservedAt[slot.inventorySlotID] = (slot.inventorySlotID == 1 and 1700005000 or 1700004500)
    end
    assert(GGM.SaveCompleteCharacterRecord(db, owner, sameTimeSnapshot, 4))
    local api, sends = clientApi(requester)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local ready = assert(GGM.EncodeSyncGearReady(owner, 5, 1700005000, 1700004500))

    local state = GGM.HandleGuildSyncPayload(sync, owner.key, ready)

    T.assertEqual(state, "snapshot-requested")
    T.assertEqual(#sends, 1)
end)

T.test("gear-ready ignores a matching snapshot and rejects self, mismatched sender, and conflicting GUIDs", function()
    local GGM = loadModules()
    local owner, requester = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local ready = assert(GGM.EncodeSyncGearReady(owner, 4, 1700002000, 1700001500))
    local matchingDB = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveCompleteCharacterRecord(matchingDB, owner, snapshot(GGM, 8400, 1700002000), 4))
    local matchingApi, matchingSends = clientApi(requester)
    local matchingSync = assert(GGM.CreateGuildSync(matchingApi, matchingDB))
    T.assertEqual(GGM.HandleGuildSyncPayload(matchingSync, owner.key, ready), "gear-ready-current")
    T.assertEqual(#matchingSends, 0)

    local selfDB = assert(T.initializeDatabase(GGM, nil))
    local selfApi = clientApi(owner)
    local selfSync = assert(GGM.CreateGuildSync(selfApi, selfDB))
    T.assertEqual(GGM.HandleGuildSyncPayload(selfSync, owner.key, ready), "ignored")
    local emptyDB = assert(T.initializeDatabase(GGM, nil))
    local api, sends, drain = clientApi(requester)
    local sync = assert(GGM.CreateGuildSync(api, emptyDB))
    T.assertEqual(sync.pendingSnapshotRequestCount, 0)
    local rejected, senderErr = GGM.HandleGuildSyncPayload(sync, "Mallory-Silvermoon", ready)
    T.assertNil(rejected)
    T.assertEqual(senderErr, "sync-sender-identity-mismatch")
    assert(GGM.SaveCompleteCharacterRecord(emptyDB, identity("Alice", "Silvermoon", "OTHER"), snapshot(GGM, 8500), 4))
    local conflict, conflictErr = GGM.HandleGuildSyncPayload(sync, owner.key, ready)
    T.assertNil(conflict)
    T.assertEqual(conflictErr, "identity-mismatch")
    T.assertEqual(#sends, 0)
end)

T.test("a lower sequence with a newer owner capture still requests cache repair", function()
    local GGM = loadModules()
    local owner, requester = identity("Alice", "Silvermoon", "A"), identity("Bob", "Silvermoon", "B")
    local db = assert(T.initializeDatabase(GGM, nil))
    assert(GGM.SaveCompleteCharacterRecord(db, owner, snapshot(GGM, 8450, 1700001000), 40))
    local api, sends, drain = clientApi(requester)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local ready = assert(GGM.EncodeSyncGearReady(owner, 0, 1700005000, 1700004500))

    local state = GGM.HandleGuildSyncPayload(sync, owner.key, ready)

    T.assertEqual(state, "snapshot-requested")
    T.assertEqual(#sends, 1)
end)

T.test("malformed gear-ready messages do not mutate saved gear", function()
    local GGM = loadModules()
    local db = assert(T.initializeDatabase(GGM, nil))
    local requester = identity("Bob", "Silvermoon", "B")
    local api = clientApi(requester)
    local sync = assert(GGM.CreateGuildSync(api, db))
    local before = next(db.characters)
    local malformed, malformedErr = GGM.HandleGuildSyncPayload(sync, "Alice-Silvermoon", "6R1:1")
    T.assertNil(malformed)
    T.assertNotNil(malformedErr)
    local unknown, unknownErr = GGM.HandleGuildSyncPayload(sync, "Alice-Silvermoon", "6X")
    T.assertNil(unknown)
    T.assertEqual(unknownErr, "sync-message-type-unknown")
    T.assertEqual(next(db.characters), before)
end)
