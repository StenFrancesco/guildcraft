local T = require("tests.testlib")

local guild = require("tests.profession_sync_fixture")

local function automatic(client)
    T.loadAddonFile("The Guild Book/AutomaticSync.lua", client.G)
    T.loadAddonFile("The Guild Book/ProfessionAutomaticSync.lua", client.G)
    client.api.IsResting = function() return true end
    client.api.C_Map = { GetBestMapForUnit = function() return 84 end }
end

T.test("tailor can manually receive engineering from the only other online guild member", function()
    local bus = guild()
    local tailor, engineer = bus:client("Tailor"), bus:client("Engineer")
    local function save(client, professionID, professionName, recipeID)
        assert(client.G.SaveProfessionSnapshot(client.db, client.identity, {
            complete = true, professionID = professionID, professionName = professionName,
            recipes = { { recipeID = recipeID, name = professionName .. " recipe" } },
            source = client.G.PROFESSION_SOURCE_PLAYER, status = "cached", capturedAt = 1700000000,
        }, { guildMembershipVerified = true }))
    end
    save(tailor, 197, "Tailoring", 1001)
    save(engineer, 202, "Engineering", 1002)
    tailor:ready(); engineer:ready()
    T.assertTrue(tailor.G.RequestProfessionSync(tailor.sync, 202, "selection"))
    local ok, err = tailor.G.RequestProfessionSync(tailor.sync, 202, "manual")
    T.assertFalse(ok)
    T.assertEqual(err, "profession-sync-busy")
    bus:advance(60)
    local received = assert(tailor.G.GetProfessionSyncRecord(tailor.db, engineer.identity.guid, 202))
    T.assertEqual(received.recipes[1].recipeID, 1002)
    T.assertTrue(tailor.G.RequestProfessionSync(tailor.sync, 202, "manual"))
    bus:advance(60)
    T.assertEqual(tailor.G.GetProfessionSyncStatus(tailor.sync, 202), "Matched 1 peer cache")
    T.assertNotNil(tailor.G.GetProfessionSyncRecord(tailor.db, tailor.identity.guid, 197))
end)

T.test("simultaneous profession comparisons elect one initiator and still exchange recipes", function()
    for _, reasons in ipairs({ { "selection", "selection" }, { "selection", "manual" },
        { "manual", "selection" }, { "manual", "manual" }, { "login", "manual" },
        { "manual", "login" }, { "login", "selection" }, { "selection", "login" } }) do
        for _, firstName in ipairs({ "Alice", "Zelda" }) do
            local bus = guild()
            local a, b = bus:client(firstName), bus:client("Bob")
            a:save(a.identity, { 3, 8 })
            a:ready(); b:ready()
            T.assertTrue(a.G.RequestProfessionSync(a.sync, 164, reasons[1]))
            T.assertTrue(b.G.RequestProfessionSync(b.sync, 164, reasons[2]))
            bus:advance(120)
            local received = b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164)
            T.assertNotNil(received, reasons[1] .. "/" .. reasons[2] .. " collision lost the comparison")
            T.assertEqual(#received.recipes, 2)
            T.assertEqual(bus:count("Q"), 2, "collision handling must not create retries")
            T.assertEqual(bus:count("C"), 1, "only one initiator should win")
            local frames = #bus.frames
            bus:advance(1800)
            T.assertEqual(#bus.frames, frames)
        end
    end
end)

T.test("manual profession comparison can reach a peer comparing a different profession", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }); a:ready(); b:ready()
    T.assertTrue(a.G.RequestProfessionSync(a.sync, 202, "selection"))
    T.assertTrue(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    bus:advance(120)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("collision arbitration never preempts selected initiators or responders", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    b:save(b.identity, { 3, 8 }); a:ready(); b:ready(); c:ready()
    local original, resume = a.api.ChatThrottleLib.SendAddonMessage, nil
    a.api.ChatThrottleLib.SendAddonMessage = function(...)
        local args = { ... }
        if args[4]:find("P4|M|", 1, true) then
            resume = function() original(unpack(args)) end
            return
        end
        return original(...)
    end
    T.assertTrue(a.G.RequestProfessionSync(a.sync, 164, "selection"))
    bus:advance(28)
    T.assertNotNil(resume)
    local initiator, responder = a.sync.active, b.sync.active
    T.assertNotNil(initiator.selected)
    T.assertEqual(responder.selected, b.sync.selfKey)
    T.assertTrue(c.G.RequestProfessionSync(c.sync, 202, "manual"))
    bus:advance(1)
    T.assertEqual(a.sync.active, initiator)
    T.assertEqual(b.sync.active, responder)
    T.assertTrue(not initiator.finished)
    T.assertTrue(not responder.finished)
    a.api.ChatThrottleLib.SendAddonMessage = original
    resume()
    bus:advance(120)
    T.assertNotNil(a.G.GetProfessionSyncRecord(a.db, b.identity.guid, 164))
end)

T.test("yielded manual sync reserves its response slot ahead of queued comparisons", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }); a:ready(); b:ready()
    T.assertTrue(a.G.RequestProfessionSync(a.sync, 164, "manual"))
    T.assertTrue(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    b.sync.pending[202] = { reason = "save", preferredPeer = a.sync.selfKey, ready = true }
    bus:advance(30)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertTrue(bus:count("C") >= 1)
end)

T.test("yielded profession sync queues its claim behind a throttled abandoned query", function()
    for _, reason in ipairs({ "selection", "manual" }) do
        local bus = guild()
        local a, b = bus:client("Alice"), bus:client("Bob")
        a:save(a.identity, { 3, 8 }); a:ready(); b:ready()
        local original, delayed = b.api.ChatThrottleLib.SendAddonMessage, false
        b.api.ChatThrottleLib.SendAddonMessage = function(...)
            local args = { ... }
            if not delayed then
                delayed = true
                b.api.C_Timer.NewTimer(2, function() original(unpack(args)) end)
                return
            end
            return original(...)
        end
        T.assertTrue(a.G.RequestProfessionSync(a.sync, 164, reason))
        T.assertTrue(b.G.RequestProfessionSync(b.sync, 164, reason))
        bus:advance(30)
        T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
        T.assertEqual(bus:count("C"), 1)
        T.assertEqual(bus:count("Q"), 2)
    end
end)

T.test("unanswered profession query records a diagnostic distinct from startup failure", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready(); a.drop = true
    T.assertTrue(b.G.RequestProfessionSync(b.sync, 164, "selection"))
    bus:advance(30)
    T.assertEqual(b.sync.lastError, "profession-sync-no-responder")
end)

local function receiveLegacyAnnouncement(sender, receiver, reason)
    local digest = assert(sender.G.GetProfessionSyncDigest(sender.db, 164, sender.sync.members))
    local payload = "P4|A|*|123-1|0|164," .. digest .. "," .. reason
    return receiver.sync.transport.onPayload(payload, sender.identity.key, "GUILD")
end

T.test("directed profession sync completes without an election wait or duplicate selection", function()
    local bus = guild()
    local requester, provider = bus:client("Alice"), bus:client("Zulu")
    for index = 1, 998 do bus:member("Member" .. index) end
    provider:save(provider.identity, { 3, 8, 9 })
    requester:ready(); provider:ready()
    assert(requester.G.RequestProfessionSync(requester.sync, 164, "manual", provider.identity.key:lower()))
    bus:advance(1.9)
    T.assertNotNil(requester.G.GetProfessionSyncRecord(requester.db, provider.identity.guid, 164),
        "a directed responder must not wait for its roster slot or election deadline")
    T.assertNil(requester.sync.manualOperation)
    T.assertEqual(bus:count("S"), 1)
    local frames = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frames, "old deadline callbacks must not restart a finished exchange")
end)

T.test("a saved three-recipe update automatically reaches the other user within four seconds", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local ids = {}
    for index = 1, 300 do ids[index] = index end
    a:save(a.identity, ids); b:save(a.identity, ids)
    a:ready(); b:ready()
    local before = assert(a.G.GetProfessionSyncDigest(a.db, 164))
    for index = 301, 303 do ids[index] = index end
    a:save(a.identity, ids, 1700000001)
    assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    bus:advance(4)
    local received = assert(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertEqual(#received.recipes, 303)
    T.assertEqual(received.capturedAt, 1700000001)
    T.assertEqual(bus:count("D"), 2)
end)

T.test("discovery includes the last responder in a thousand-member roster within two seconds", function()
    local bus = guild()
    local requester = bus:client("ARequester")
    for index = 1, 998 do bus:member("Member" .. index) end
    local provider = bus:client("ZResponder")
    provider:save(provider.identity, { 3 })
    requester:ready(); provider:ready()
    assert(requester.G.RequestProfessionSync(requester.sync, 164, "selection"))
    bus:advance(1.99)
    T.assertEqual(bus:count("D"), 0, "untargeted discovery must collect claims for its full window")
    bus:advance(0.02)
    T.assertNotNil(requester.G.GetProfessionSyncRecord(requester.db, provider.identity.guid, 164),
        "the last roster slot must fit within the shortened discovery window")
    T.assertEqual(bus:count("C"), 1)
    T.assertEqual(bus:count("S"), 1)
end)

T.test("discovery still suppresses redundant claims and selects one responder", function()
    local bus = guild()
    local requester, a, b = bus:client("Requester"), bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); b:save(a.identity, { 3 })
    requester:ready(); a:ready(); b:ready()
    assert(requester.G.RequestProfessionSync(requester.sync, 164, "selection"))
    bus:advance(2.1)
    T.assertEqual(bus:count("C"), 1)
    T.assertEqual(bus:count("S"), 1)
    T.assertEqual(bus:count("D"), 1)
end)

T.test("a late legacy discovery claim starts immediately after the short window", function()
    local bus = guild()
    local requester, provider = bus:client("Alice"), bus:client("Zulu")
    provider:save(provider.identity, { 3 })
    requester:ready(); provider:ready()
    local newTimer = provider.api.C_Timer.NewTimer
    provider.api.C_Timer.NewTimer = function(delay, fn)
        if delay > 0 and delay < 2 then delay = 25 end
        return newTimer(delay, fn)
    end
    assert(requester.G.RequestProfessionSync(requester.sync, 164, "selection"))
    bus:advance(24.9)
    T.assertEqual(bus:count("D"), 0)
    bus:advance(0.2)
    T.assertNotNil(requester.G.GetProfessionSyncRecord(requester.db, provider.identity.guid, 164),
        "an old responder's late claim must remain usable without another election wait")
end)

T.test("directed fast selection rejects another peer's claim", function()
    local bus = guild()
    local requester, target, other = bus:client("Requester"), bus:client("Target"), bus:client("Other")
    requester:ready(); target:ready(); other:ready()
    target.drop = true
    assert(requester.G.RequestProfessionSync(requester.sync, 164, "manual", target.identity.key:lower()))
    bus:advance(0)
    local session = requester.sync.active
    local digest = assert(other.G.GetProfessionSyncDigest(other.db, 164))
    local payload = "P4|C|" .. requester.sync.selfKey .. "|" .. session.id .. "|164|" .. requester.sync.selfKey .. ";" .. digest
    T.assertEqual(requester.sync.transport.onPayload(payload, other.identity.key, "GUILD"), "ignored")
    T.assertNil(session.selected)
    T.assertEqual(bus:count("S"), 0)
end)

T.test("directed sync accepts an old responder's delayed claim without a second wait", function()
    local bus = guild()
    local requester, provider = bus:client("Alice"), bus:client("Zulu")
    provider:save(provider.identity, { 3 })
    requester:ready(); provider:ready()
    local newTimer, delayed = provider.api.C_Timer.NewTimer, false
    provider.api.C_Timer.NewTimer = function(delay, fn)
        if delay == 0 and not delayed then delay, delayed = 25, true end
        return newTimer(delay, fn)
    end
    assert(requester.G.RequestProfessionSync(requester.sync, 164, "manual", provider.sync.selfKey))
    bus:advance(24.9)
    T.assertEqual(bus:count("D"), 0)
    bus:advance(0.2)
    T.assertNotNil(requester.G.GetProfessionSyncRecord(requester.db, provider.identity.guid, 164))
    T.assertEqual(bus:count("S"), 1)
end)

T.test("unanswered discovery stops at its compatibility deadline and ignores late claims", function()
    local bus = guild()
    local requester, provider = bus:client("Alice"), bus:client("Zulu")
    requester:ready(); provider:ready()
    provider.drop = true
    assert(requester.G.RequestProfessionSync(requester.sync, 164, "selection"))
    local session = requester.sync.active
    bus:advance(26.9)
    T.assertNotNil(requester.sync.active)
    bus:advance(0.2)
    T.assertNil(requester.sync.active)
    T.assertEqual(requester.G.GetProfessionSyncStatus(requester.sync, 164), "Sync unavailable")
    local digest = assert(provider.G.GetProfessionSyncDigest(provider.db, 164))
    local payload = "P4|C|" .. requester.sync.selfKey .. "|" .. session.id .. "|164|" .. requester.sync.selfKey .. ";" .. digest
    T.assertEqual(requester.sync.transport.onPayload(payload, provider.identity.key, "GUILD"), "ignored")
    local frames = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frames)
end)

T.test("profession login waits for roster readiness and idle readiness creates no traffic", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    T.assertEqual(#bus.frames, 0)
    T.assertFalse(a.G.LoginProfessionSync(a.sync))
    a:ready(); b:ready()
    bus:advance(3600)
    T.assertEqual(#bus.frames, 0)
    T.assertEqual(a.prefix, "GC_PROF4")
end)

T.test("profession comparison transfers one complete cached snapshot from one responder", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    a:save(a.identity, { 3, 8 }); c:save(a.identity, { 3, 8 })
    a:ready(); b:ready(); c:ready()
    T.assertTrue(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    bus:advance(60)
    local received = assert(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertEqual(#received.recipes, 2)
    T.assertEqual(received.capturedAt, 1700000000)
    T.assertEqual(bus:count("D"), 1)
    T.assertTrue(b.refreshes > 0)
    bus:advance(600)
    local count = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, count)
end)

T.test("equal profession hashes send no recipe data and manual sync obeys cooldown", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); b:save(a.identity, { 3 })
    a:ready(); b:ready()
    T.assertTrue(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    T.assertFalse(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    bus:advance(30)
    T.assertEqual(bus:count("D"), 0)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Matched 1 peer cache")
end)

T.test("manual sync reaches a newer Bob after a matching Alice without voluntary publishing", function()
    local bus = guild()
    local alice, requester, bob = bus:client("Alice"), bus:client("Requester"), bus:client("Bob")
    local offline = bus:member("OfflineCrafter")
    alice:save(offline, { 3, 8 }, 1700000001)
    requester:save(offline, { 3, 8 }, 1700000001)
    bob:save(offline, { 3, 8, 9 }, 1700000002)
    alice:ready(); requester:ready(); bob:ready()
    T.assertEqual(bus:count("A"), 0, "the test peers should not announce before the manual request")

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(1200)

    local received = assert(requester.G.GetProfessionSyncRecord(requester.db, offline.guid, 164))
    T.assertEqual(received.capturedAt, 1700000002)
    T.assertEqual(#received.recipes, 3)
    T.assertEqual(received.recipes[1].recipeID, 3)
    T.assertEqual(received.recipes[2].recipeID, 8)
    T.assertEqual(received.recipes[3].recipeID, 9)
    T.assertTrue(bus:count("D", bob.identity.key) > 0, "Bob should provide the newer cached record")
    local frames = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frames, "manual traffic should stop after its finite peer list")
end)

T.test("manual request compares a newer peer directly after an older peer", function()
    local bus = guild()
    local alice, requester, bob = bus:client("Alice"), bus:client("Requester"), bus:client("Bob")
    local offline = bus:member("OfflineCrafter")
    alice:save(offline, { 3 }, 1700000000)
    requester:save(offline, { 3, 8 }, 1700000001)
    bob:save(offline, { 3, 8, 9 }, 1700000002)
    alice:ready(); requester:ready(); bob:ready()
    T.assertEqual(bus:count("A"), 0)

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(1200)

    local received = assert(requester.G.GetProfessionSyncRecord(requester.db, offline.guid, 164))
    T.assertEqual(received.capturedAt, 1700000002)
    T.assertEqual(#received.recipes, 3)
    local bobToRequester = 0
    for _, frame in ipairs(bus.frames) do
        if frame.sender == bob.identity.key and frame.text:find("P4|D|requester%-realm|", 1, false) then
            bobToRequester = bobToRequester + 1
        end
    end
    T.assertTrue(bobToRequester > 0, "the requester must ask Bob directly instead of depending on relayed announcements")
end)

T.test("a page cursor from Alice cannot hide Bob's newer earlier record", function()
    local bus = guild()
    local alice, requester, bob = bus:client("Alice"), bus:client("Requester"), bus:client("Bob")
    local identities = {}
    for index = 1, 131 do
        local identity = bus:member("Offline" .. index)
        identities[#identities + 1] = identity
        alice:save(identity, { index }, 1700000000)
        requester:save(identity, { index }, 1700000000)
    end
    table.sort(identities, function(left, right) return left.guid < right.guid end)
    local early, late = identities[1], identities[#identities]
    alice:save(late, { 999 }, 1700000001)
    bob:save(early, { 888 }, 1700000002)
    alice:ready(); requester:ready(); bob:ready()
    T.assertTrue(alice.G.GetProfessionSyncDigest(alice.db, 164, alice.sync.members)
        ~= requester.G.GetProfessionSyncDigest(requester.db, 164, requester.sync.members), "Alice's late record should make her digest differ")
    local startCursor = identities[2].guid
    requester.sync.cursor[164] = { [alice.identity.key:lower()] = startCursor }

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(1200)

    local cursors = {}
    for _, frame in ipairs(bus.frames) do
        if frame.sender == requester.identity.key then
            local cursor, peer = frame.text:match("P4|Q|%*|[^|]+|164|[^;]+;manual;([^;]*);([^|]*)")
            if peer and peer ~= "" and cursors[peer] == nil then cursors[peer] = cursor end
        end
    end
    T.assertEqual(cursors[alice.identity.key:lower()], startCursor, "same-peer page progress should be retained")
    T.assertEqual(cursors[bob.identity.key:lower()], "", "Bob's comparison must restart at the beginning of his manifest")
    local received = assert(requester.G.GetProfessionSyncRecord(requester.db, early.guid, 164))
    T.assertEqual(received.capturedAt, 1700000002)
    T.assertEqual(received.recipes[#received.recipes].recipeID, 888)
    T.assertTrue(bus:count("D", bob.identity.key) > 0, "Bob must be compared from the start of his own manifest")
end)

T.test("manual peer comparisons stop at four candidates and create no idle traffic", function()
    local bus = guild()
    local requester = bus:client("Requester")
    local offline = bus:member("OfflineCrafter")
    local peers = {}
    for index = 1, 6 do peers[index] = bus:client("Peer" .. index) end
    for _, client in ipairs({ requester, peers[1], peers[2], peers[3], peers[4], peers[5], peers[6] }) do
        client:save(offline, { 3, 8 }, 1700000001)
        client:ready()
    end
    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(1800)

    local preferred = {}
    for _, frame in ipairs(bus.frames) do
        if frame.sender == requester.identity.key then
            local peer = frame.text:match("P4|Q|%*|[^|]+|164|[^;]+;manual;[^;]*;([^|]+)")
            if peer and peer ~= "" then preferred[peer] = true end
        end
    end
    local compared = 0
    for _ in pairs(preferred) do compared = compared + 1 end
    T.assertEqual(compared, 4)
    for _, client in ipairs(peers) do T.assertEqual(bus:count("Q", client.identity.key), 0) end
    T.assertEqual(requester.G.GetProfessionSyncStatus(requester.sync, 164), "Catch-up needed")
    local frameCount = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frameCount, "elapsed time alone must not restart peer comparisons")
end)

T.test("directed profession queries do not occupy bystander session slots", function()
    local bus = guild()
    local requester = bus:client("Requester")
    local peers = {}
    for _, name in ipairs({ "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot" }) do
        peers[#peers + 1] = bus:client(name)
    end
    for index = 1, 4 do peers[index].drop = true end
    for _, client in ipairs({ requester, unpack(peers) }) do client:ready() end

    assert(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(245)

    local bystander = peers[5]
    local unfinished = 0
    for _, session in pairs(bystander.sync.sessions) do
        if not session.finished then unfinished = unfinished + 1 end
    end
    T.assertEqual(unfinished, 0, "preferred queries for other peers must not leave observer sessions behind")
    T.assertTrue(bystander.G.RequestProfessionSync(bystander.sync, 164, "manual"),
        "one other user's four-peer operation must not prevent this peer from starting its own request")
end)

T.test("directed query observers still defer pending meaningful-save comparisons", function()
    local bus = guild()
    local requester, alice, bob = bus:client("Requester"), bus:client("Alice"), bus:client("Bob")
    requester:ready(); alice:ready(); bob:ready()
    local pending = { reason = "save", preferredPeer = alice.identity.key:lower(), ready = true }
    requester.sync.pending[164] = pending
    local digest = assert(requester.G.GetProfessionSyncDigest(requester.db, 164, requester.sync.members))
    local query = "P4|Q|*|900000001-1|164|" .. digest .. ";manual;;" .. bob.identity.key:lower()

    T.assertEqual(requester.sync.transport.onPayload(query, alice.identity.key, "GUILD"), "observing")

    T.assertFalse(pending.ready, "an observed directed query must continue to back off save-created work")
    T.assertNil(requester.sync.sessions[alice.identity.key:lower() .. ":900000001-1"],
        "the bystander should not retain an unrelated transaction session")
end)

T.test("an active preferred responder updates presence and defers saves without retaining a query", function()
    local bus = guild()
    local requester, target, alice = bus:client("Requester"), bus:client("Target"), bus:client("Alice")
    requester:ready(); target:ready(); alice:ready()
    target.sync.active = { otherExchange = true }
    local pending = { reason = "save", preferredPeer = alice.identity.key:lower(), ready = true }
    target.sync.pending[164] = pending
    local digest = assert(target.G.GetProfessionSyncDigest(target.db, 164, target.sync.members))
    local query = "P4|Q|*|900000004-1|164|" .. digest .. ";manual;;" .. target.identity.key:lower()

    T.assertEqual(target.sync.transport.onPayload(query, requester.identity.key, "GUILD"), "response-queued")
    T.assertFalse(pending.ready)
    T.assertNil(target.sync.sessions[requester.identity.key:lower() .. ":900000004-1"],
        "a responder already in another exchange must not keep an unclaimable session")
    bus:advance(3)
    T.assertEqual(bus:count("C", target.identity.key), 0, "a busy target must not claim the request")
    T.assertTrue(target.sync.presenceEvidence[requester.identity.key:lower()] ~= nil,
        "the ignored work must still refresh sender presence evidence")
end)

T.test("a manual operation between peers cannot allocate a targeted response session", function()
    local bus = guild()
    local alice, target, bob = bus:client("Alpha"), bus:client("Target"), bus:client("Zulu")
    alice:ready(); target:ready(); bob:ready()
    assert(target.G.RequestProfessionSync(target.sync, 164, "manual"))
    bus:advance(27)
    T.assertNotNil(target.sync.manualOperation)
    T.assertNil(target.sync.active, "the target should be in its cooldown between peer comparisons")
    T.assertNil(target.sync.manualOperation.currentSession)

    local pending = { reason = "save", preferredPeer = alice.identity.key:lower(), ready = true }
    target.sync.pending[164] = pending
    local digest = assert(target.G.GetProfessionSyncDigest(target.db, 164, target.sync.members))
    local query = "P4|Q|*|900000005-1|164|" .. digest .. ";manual;;" .. target.identity.key:lower()
    local responsesBefore = bus:count("C", target.identity.key)

    T.assertEqual(target.sync.transport.onPayload(query, bob.identity.key, "GUILD"), "response-queued")
    T.assertFalse(pending.ready, "meaningful-save work must remain deferred during a manual operation")
    T.assertNil(target.sync.sessions[bob.identity.key:lower() .. ":900000005-1"],
        "the target cannot respond while its own manual operation is between peers")
    bus:advance(3)
    T.assertEqual(bus:count("C", target.identity.key), responsesBefore,
        "a manual-operation cooldown target must not claim another request")
end)

T.test("a busy continuation leaves catch-up needed instead of claiming a partial match", function()
    local bus = guild()
    local alice, requester, bob = bus:client("Alice"), bus:client("Requester"), bus:client("Bob")
    alice:ready(); requester:ready(); bob:ready()

    assert(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(27)
    T.assertEqual(requester.sync.manualOperation.matches, 1)

    -- Exercise the bounded-session admission failure on the next candidate.
    for index = 1, 4 do requester.sync.sessions["busy:" .. index] = { finished = false } end
    bus:advance(100)

    T.assertEqual(requester.G.GetProfessionSyncStatus(requester.sync, 164), "Catch-up needed",
        "a failed attempt to start the next selected peer is incomplete evidence")
end)

T.test("separate manual requests rotate the four-peer window to a newer fifth peer", function()
    local bus = guild()
    local requester = bus:client("Requester")
    local peers = {}
    for _, name in ipairs({ "Alpha", "Bravo", "Charlie", "Delta", "Echo", "ZedBob" }) do
        peers[#peers + 1] = bus:client(name)
    end
    local offline = bus:member("OfflineCrafter")
    for _, client in ipairs({ requester, unpack(peers) }) do
        client:save(offline, { 3, 8 }, 1700000001)
        client:ready()
    end
    peers[6]:save(offline, { 3, 8, 9 }, 1700000002)
    T.assertEqual(bus:count("A"), 0, "the peers must not announce the newer snapshot voluntarily")

    assert(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(245)
    local beforeRotation = assert(requester.G.GetProfessionSyncRecord(requester.db, offline.guid, 164))
    T.assertEqual(beforeRotation.capturedAt, 1700000001)
    T.assertEqual(#beforeRotation.recipes, 2)
    T.assertTrue(requester.G.GetProfessionSyncStatus(requester.sync, 164):find("Catch%-up") ~= nil)

    assert(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(240)

    local received = assert(requester.G.GetProfessionSyncRecord(requester.db, offline.guid, 164))
    T.assertEqual(received.capturedAt, 1700000002)
    T.assertEqual(#received.recipes, 3)
    T.assertTrue(bus:count("D", peers[6].identity.key) > 0, "the rotated window must query the fifth eligible peer")
    local frameCount = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frameCount, "rotation advances only on a later manual request")
end)

T.test("login sync exchanges cached data once without opening the addon", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }); b:save(b.identity, { 9 })
    a:ready(); b:ready(); automatic(a); automatic(b)
    T.assertTrue(a.G.LoginProfessionSync(a.sync))
    T.assertTrue(a.G.LoginProfessionSync(a.sync), "repeated login scheduling is idempotent")
    bus:advance(240)
    T.assertNotNil(a.G.GetProfessionSyncRecord(a.db, b.identity.guid, 164))
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertEqual(bus:count("Q", a.identity.key), 6, "one discovery per supported profession")
    local frames = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frames, "idle time must not restart login sync")
end)

T.test("login discovery collects replies for 27 seconds", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 })
    a:ready(); b:ready()
    T.assertTrue(a.G.RequestProfessionSync(a.sync, 164, "login"))
    bus:advance(26.9)
    T.assertTrue(bus:count("C") > 0)
    T.assertEqual(bus:count("D"), 0)
    T.assertEqual(bus:count("S"), 0)
    bus:advance(2)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("unselected login responder reservations expire after discovery", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    T.assertTrue(a.G.RequestProfessionSync(a.sync, 164, "login"))
    bus:advance(0)
    local reservation = b.sync.active
    T.assertNotNil(reservation, "the responder reserves its slot while collecting login claims")
    T.assertEqual(reservation.reason, "login")

    -- The initiator no longer receives the responder's claim, so it cannot
    -- select this peer or send S to release it explicitly.
    a.drop = true
    bus:advance(29)
    T.assertNil(b.sync.active, "an unselected login reservation must not block peers for the 300-second TTL")
    T.assertNil(b.sync.sessions[reservation.initiator .. ":" .. reservation.id])
end)

T.test("manual button still exchanges records within two seconds", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 })
    a:ready(); b:ready()
    T.assertTrue(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    bus:advance(2)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("simultaneous login syncs exchange data and leave no recurring traffic", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); b:save(b.identity, { 8 })
    a:ready(); b:ready(); automatic(a); automatic(b)
    T.assertTrue(a.G.LoginProfessionSync(a.sync))
    T.assertTrue(b.G.LoginProfessionSync(b.sync))
    bus:advance(600)
    T.assertNotNil(a.G.GetProfessionSyncRecord(a.db, b.identity.guid, 164))
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    local frames = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frames)
end)

T.test("login comparison yielded to a different profession resumes once", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 })
    a:ready(); b:ready()
    T.assertTrue(a.G.RequestProfessionSync(a.sync, 165, "login"))
    T.assertTrue(b.G.RequestProfessionSync(b.sync, 164, "login"))
    bus:advance(180)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164),
        "yielding to another profession must not drop the login comparison")
    T.assertEqual(bus:count("Q", b.identity.key), 2)
    local frames = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frames, "a yielded job must not create recurring retries")
end)

T.test("login discovery without peers finishes its finite pass", function()
    local bus = guild()
    local a = bus:client("Alice")
    a:ready(); automatic(a)
    T.assertTrue(a.G.LoginProfessionSync(a.sync))
    bus:advance(240)
    T.assertNil(a.sync.active)
    T.assertNil(next(a.sync.pending))
    T.assertEqual(bus:count("Q"), 0, "no eligible peer requires no discovery")
    T.assertFalse(a.sync.automaticController.pending)
    local frames = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frames)
end)

T.test("cancelling login sync clears the remaining automatic work", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready(); automatic(a); automatic(b)
    T.assertTrue(a.G.LoginProfessionSync(a.sync))
    bus:advance(2)
    a.G.StopAutomaticSync(a.sync.automaticController)
    a.G.CancelProfessionSync(a.sync)
    local frames = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, frames)
    T.assertNil(a.sync.active)
    T.assertNil(next(a.sync.pending))
end)

T.test("legacy background announcements are hints and their queries are ignored", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    local digest = assert(a.G.GetProfessionSyncDigest(a.db, 164, a.sync.members))
    for _, reason in ipairs({ "background" }) do
        local announcement = "P4|A|*|123-1|0|164," .. digest .. "," .. reason
        T.assertEqual(b.sync.transport.onPayload(announcement, a.identity.key, "GUILD"), "announced")
        local query = "P4|Q|*|123-2|164|" .. digest .. ";" .. reason .. ";;"
        T.assertEqual(b.sync.transport.onPayload(query, a.identity.key, "GUILD"), "ignored")
    end
    bus:advance(3600)
    T.assertEqual(#bus.frames, 0, "legacy periodic traffic must not trigger local responses")
    T.assertEqual(b.sync.peers[a.identity.key:lower()][164], digest)
end)

T.test("manual session timeout cancels queued frames and ignores a late CTL completion", function()
    local bus = guild()
    local peer, requester = bus:client("Alice"), bus:client("Bob")
    peer:ready(); requester:ready()
    local submissions, held = 0, nil
    requester.api.ChatThrottleLib.SendAddonMessage = function(_, _, _, _, _, _, _, callback, arg)
        submissions = submissions + 1
        held = { callback = callback, arg = arg }
    end

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    T.assertEqual(submissions, 1)
    bus:advance(301)
    T.assertEqual(requester.G.GetProfessionSyncStatus(requester.sync, 164), "Catch-up needed")
    T.assertNil(requester.sync.manualOperation)
    assert(held)
    held.callback(held.arg, true, 0)
    bus:advance(1200)

    T.assertEqual(submissions, 1, "late CTL completion must not submit remaining operation frames")
    T.assertEqual(#bus.frames, 0)
    T.assertEqual(requester.G.GetProfessionSyncStatus(requester.sync, 164), "Catch-up needed")
end)

T.test("changed save converges observers through separate selected whispers without repeating current records", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    a:ready(); b:ready(); c:ready()
    local before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8 })
    T.assertTrue(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    bus:advance(180)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertNotNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    T.assertEqual(bus:count("D"), 2)
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8 })
    a.G.PublishProfessionSyncSave(a.sync, 164, before)
    bus:advance(600)
    T.assertEqual(bus:count("D"), 2)
end)

T.test("profession sync merges equal-time differences without discarding either cache", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000000); b:save(offline, { 8 }, 1700000000)
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(30)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, offline.guid, 164).recipes, 2)
    T.assertEqual(a.G.GetProfessionSyncRecord(a.db, offline.guid, 164).recipes[1].recipeID, 3)
    T.assertEqual(bus:count("D"), 2)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Compared with 1 peer")
end)

T.test("profession sync transfers newer offline crafter records and preserves source time", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3, 8 }, 1700000001); b:save(offline, { 3 }, 1700000000)
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(40)
    local row = assert(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164))
    T.assertEqual(#row.recipes, 2)
    T.assertEqual(row.capturedAt, 1700000001)
end)

T.test("profession sync rejects strangers combat and throttling without retries", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready(); b:ready()
    local result = b.G.HandleProfessionSyncAddonMessage(b.sync, "GC_PROF4", "garbage", "GUILD", "Stranger-Realm")
    T.assertEqual(result, "ignored")
    b.api.InCombatLockdown = function() return true end
    T.assertFalse(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    b.api.InCombatLockdown = function() return false end
    b.throttled = true
    b.G.RequestProfessionSync(b.sync, 164, "manual")
    bus:advance(600)
    T.assertEqual(#bus.frames, 1)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Sync unavailable")
end)

T.test("profession sync is bounded and guild departure cancels pending traffic", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    for index = 1, 9 do a:save(bus:member("Offline" .. index), { index }) end
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(1)
    T.assertTrue(bus:count("D") <= 4)
    T.assertNotNil(b.sync.manualOperation)
    b.left = true; T.assertFalse(b.G.RefreshProfessionSyncRoster(b.sync))
    local count = #bus.frames
    bus:advance(600)
    for index = count + 1, #bus.frames do T.assertFalse(bus.frames[index].sender == b.identity.key) end
end)

T.test("manual hash comparison repairs missing cached profession data", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }); a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    bus:advance(80)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertEqual(bus:count("D"), 1)
end)

T.test("profession sync preserves the active player's record even before an ownership marker exists", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(b.identity, { 3, 8 }, 1700000001); b:save(b.identity, { 3 }, 1700000000)
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(60)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, b.identity.guid, 164).recipes, 1)
    T.assertEqual(bus:count("D"), 2)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Conflict: fresh observation needed")
end)

T.test("dropped profession response preserves prior membership and expires without retries", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }, 1700000001); b:save(a.identity, { 3 }, 1700000000)
    a:ready(); b:ready()
    local send = a.api.C_ChatInfo.SendAddonMessage
    a.api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel, target)
        if frame:find("P4|D|", 1, true) then b.drop = true end
        local result = send(prefix, frame, channel, target)
        return result
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(400)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164).recipes, 1)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Catch-up needed")
    T.assertEqual(bus:count("D"), 2)
end)

T.test("unsolicited or wrong-recipient profession payloads do not modify caches", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    local payload = "P4|D|bob-realm|1-1|164|alice-realm;" .. a.identity.guid .. ";0123456789abcdef;1700000000;player;Blacksmithing;3:Recipe 3:"
    a.G.SendProfessionPayload(a.sync.transport, payload)
    bus:advance(10)
    T.assertNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    a.G.SendProfessionPayload(a.sync.transport, "P4|Q|stranger-realm|1-2|164|0123456789abcdef;manual")
    bus:advance(10)
    T.assertEqual(bus:count("C"), 0)
end)

T.test("real profession event startup does not require the gear companion", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready()
    automatic(b)
    local G, api, onEvent = b.G, b.api, nil
    api._G = api; setmetatable(api, { __index = _G })
    api.CreateFrame = function() return { RegisterEvent = function() end, SetScript = function(_, _, fn) onEvent = fn end } end
    api.C_GuildInfo = { GuildRoster = function() return true end }
    api.TheGuildBookDB = b.db
    G.RegisterSnapshotTestSlashCommand = function() end
    G.InitializeSavedDatabases = function() return b.db, nil, b.db end
    G.CreateProfessionLinkSaveController = function() return {} end
    G.TryAutoSaveProfession = function() return "ignored" end
    G.RegisterProfessionLinkSaveController = function() return true end
    G.RecordLocalPlayerOwnership = function() return G.MarkLocalCharacterGUID(b.db, b.identity.guid) end
    local chunk = assert(loadfile("The Guild Book/Main.lua")); setfenv(chunk, api); chunk("The Guild Book", G)
    onEvent(nil, "ADDON_LOADED", "The Guild Book")
    b.sync = G.professionSync
    T.assertNotNil(b.sync)
    T.assertEqual(#bus.frames, 0)
    onEvent(nil, "PLAYER_LOGIN")
    onEvent(nil, "PLAYER_ENTERING_WORLD")
    onEvent(nil, "GUILD_ROSTER_UPDATE")
    T.assertTrue(G.professionLoginSyncIssued)
    bus:advance(240)
    T.assertNotNil(G.GetProfessionSyncRecord(b.db, a.identity.guid, 164),
        "login must sync after roster readiness without opening the addon")
    assert(G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(80)
    T.assertNotNil(G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    onEvent(nil, "GUILD_ROSTER_UPDATE"); onEvent(nil, "PLAYER_ENTERING_WORLD")
    local count = #bus.frames
    bus:advance(3600)
    T.assertEqual(#bus.frames, count)
end)

T.test("manual comparisons cover selected professions independently", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 })
    assert(a.G.SaveProfessionSnapshot(a.db, a.identity, {
        complete = true, professionID = 171, professionName = "Alchemy", capturedAt = 1700000000,
        source = "player", status = "cached", recipes = { { recipeID = 9, name = "Potion" } },
    }, { guildMembershipVerified = true }))
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(100)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 171))
    assert(b.G.RequestProfessionSync(b.sync, 171, "manual")); bus:advance(100)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 171))
    T.assertEqual(bus:count("D"), 2)
end)

T.test("large profession manifests compare shared GUID windows without duplicate transfers", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local identities = {}
    for index = 1, 130 do
        local identity = bus:member("Offline" .. index)
        identities[#identities + 1] = identity
        a:save(identity, { index }, 1700000001)
        b:save(identity, { index }, 1700000001)
    end
    table.sort(identities, function(x, y) return x.guid < y.guid end)
    local last = identities[130]
    a:save(last, { 500 }, 1700000002)
    a:ready(); b:ready()
    b.sync.cursor[164] = { [a.identity.key:lower()] = identities[128].guid }
    a.sync.cursor[164] = { [b.identity.key:lower()] = identities[32].guid }
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(80)
    T.assertEqual(bus:count("D"), 2)
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(80)
    T.assertEqual(bus:count("D"), 2)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, last.guid, 164).recipes[#b.G.GetProfessionSyncRecord(b.db, last.guid, 164).recipes].recipeID, 500)
end)

T.test("manual sync resumes each peer after the first 128 character entries", function()
    local bus = guild()
    local alice, bob, requester = bus:client("Alice"), bus:client("Bob"), bus:client("Requester")
    local identities, baseRecipeID = {}, {}
    for index = 1, 150 do
        local identity = bus:member("Offline" .. index)
        identities[#identities + 1] = identity
        baseRecipeID[identity.guid] = index
        alice:save(identity, { index }, 1700000001)
        bob:save(identity, { index }, 1700000001)
        requester:save(identity, { index }, 1700000001)
    end
    table.sort(identities, function(left, right) return left.guid < right.guid end)
    local aliceLate, bobLate = identities[149], identities[150]
    alice:save(aliceLate, { 999 }, 1700000002)
    bob:save(bobLate, { 1000 }, 1700000002)
    alice:ready(); bob:ready(); requester:ready()

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(900)
    T.assertEqual(requester.G.GetProfessionSyncRecord(requester.db, aliceLate.guid, 164).recipes[1].recipeID, baseRecipeID[aliceLate.guid],
        "the first 128-entry window should not include Alice's late change")
    T.assertEqual(requester.G.GetProfessionSyncRecord(requester.db, bobLate.guid, 164).recipes[1].recipeID, baseRecipeID[bobLate.guid],
        "the first 128-entry window should not include Bob's late change")

    T.assertEqual(#requester.G.GetProfessionSyncRecord(requester.db, aliceLate.guid, 164).recipes, 2,
        "Alice's per-peer cursor should reach her entry beyond the first window")
    T.assertEqual(#requester.G.GetProfessionSyncRecord(requester.db, bobLate.guid, 164).recipes, 2,
        "Bob's per-peer cursor should reach his entry beyond the first window")
    local queried = {}
    for _, frame in ipairs(bus.frames) do
        if frame.sender == requester.identity.key then
            local peer = frame.text:match("P4|Q|%*|[^|]+|164|[^;]+;manual;[^;]*;([^|]*)")
            if peer and peer ~= "" then queried[peer] = (queried[peer] or 0) + 1 end
        end
    end
    T.assertTrue((queried[alice.identity.key:lower()] or 0) >= 2, "Alice should be selected in both manual syncs")
    T.assertTrue((queried[bob.identity.key:lower()] or 0) >= 2, "Bob should be selected in both manual syncs")
end)

T.test("profession sync refuses secret input and unavailable secret checks", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    b.api.issecretvalue = nil
    T.assertFalse(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    b.api.issecretvalue = function(value) return value == "GC_PROF4" end
    assert(a.G.RequestProfessionSync(a.sync, 164, "manual")); bus:advance(60)
    T.assertEqual(bus:count("C"), 0)
end)

T.test("maximum complete profession membership fits bounded frames and is stored atomically", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local recipes = {}
    for index = 1, 4096 do recipes[index] = index end
    a:save(a.identity, recipes); a:ready(); b:ready()
    local receive = b.G.ReceiveProfessionFrame
    local dataID, partialFrames, savedEarly = nil, 0, false
    b.G.ReceiveProfessionFrame = function(transport, prefix, text, channel, sender)
        local id, index, total = text:match("^F1|(%d+)|(%d+)|(%d+)|")
        if text:find("|P4|D|", 1, true) then dataID = id end
        local state, err = receive(transport, prefix, text, channel, sender)
        if id == dataID and tonumber(index) < tonumber(total) then
            partialFrames = partialFrames + 1
            if b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164) then savedEarly = true end
        end
        return state, err
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(45)
    T.assertTrue(partialFrames > 0)
    T.assertFalse(savedEarly)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164).recipes, 4096)
    for _, frame in ipairs(bus.frames) do T.assertTrue(#frame.text <= 240) end
end)

T.test("manual comparisons retain the four-record limit across professions", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    for index = 1, 5 do
        local identity = bus:member("Offline" .. index)
        a:save(identity, { index })
        assert(a.G.SaveProfessionSnapshot(a.db, identity, {
            complete = true, professionID = 171, professionName = "Alchemy", capturedAt = 1700000000,
            source = "guild-profession-link", status = "cached", recipes = { { recipeID = index + 10, name = "Potion" } },
        }, { guildMembershipVerified = true }))
    end
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(1000)
    assert(b.G.RequestProfessionSync(b.sync, 171, "manual")); bus:advance(1000)
    T.assertEqual(bus:count("D"), 10)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Compared with 1 peer")
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 171), "Compared with 1 peer")
    bus:advance(3600); T.assertEqual(bus:count("D"), 10)
end)

T.test("same-realm addon senders without a realm suffix resolve through the verified roster", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready(); b:ready()
    local handle = b.G.HandleProfessionSyncAddonMessage
    b.G.HandleProfessionSyncAddonMessage = function(sync, prefix, frame, channel, sender)
        return handle(sync, prefix, frame, channel, sender:match("^([^-]+)"))
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(60)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("changed announcement compares its source even when another peer has the old matching hash", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }); b:save(offline, { 3 }); c:save(offline, { 3 })
    a:ready(); b:ready(); c:ready()
    local before = c.G.GetProfessionSyncDigest(c.db, 164)
    c:save(offline, { 3, 8 }, 1700000001)
    assert(c.G.PublishProfessionSyncSave(c.sync, 164, before)); bus:advance(180)
    T.assertEqual(#a.G.GetProfessionSyncRecord(a.db, offline.guid, 164).recipes, 2)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, offline.guid, 164).recipes, 2)
    T.assertEqual(bus:count("D"), 4)
end)

T.test("changed saves coalesce while newer reobservations of reverted contents retain their timestamp", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    local before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3 }); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    bus:advance(35)
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8 }, 1700000035); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8, 9 }, 1700000036); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    bus:advance(65)
    T.assertEqual(bus:count("A", a.identity.key), 2)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164).recipes, 3)
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3 }, 1700000100); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8, 9 }, 1700000101); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    bus:advance(200)
    T.assertTrue(bus:count("A", a.identity.key) >= 3)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164).capturedAt, 1700000101)
end)

T.test("guild invalidation cancels a paced changed-save announcement", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    local before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3 }); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    bus:advance(35)
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8 }, 1700000035)
    assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    a.sync.rosterReady = false
    a.G.CancelProfessionSync(a.sync)
    bus:advance(400)
    T.assertEqual(bus:count("A", a.identity.key), 1)
    T.assertNil(next(a.sync.pendingSaves))
end)

T.test("simultaneous independent announcements retain each source within a bounded queue", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    a:ready(); b:ready(); c:ready()
    local before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3 }); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    before = b.G.GetProfessionSyncDigest(b.db, 164)
    b:save(b.identity, { 8 }); assert(b.G.PublishProfessionSyncSave(b.sync, 164, before))
    bus:advance(250)
    T.assertNotNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    T.assertNotNil(c.G.GetProfessionSyncRecord(c.db, b.identity.guid, 164))
    local frames = #bus.frames; bus:advance(600); T.assertEqual(#bus.frames, frames)
end)

T.test("combat at a paced save deadline surfaces catch-up and creates no retries", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    local before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3 }); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    bus:advance(35)
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8 }, 1700000035)
    assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    a.api.InCombatLockdown = function() return true end
    bus:advance(30)
    T.assertEqual(a.G.GetProfessionSyncStatus(a.sync, 164), "Catch-up needed")
    a.api.InCombatLockdown = function() return false end
    bus:advance(400)
    T.assertEqual(bus:count("A", a.identity.key), 1)
end)

T.test("received recipe labels prefer local metadata and retain unfamiliar peer labels", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }); b:save(b.identity, { 3 })
    a.db.professionRecipeIndex[164][3].name = "Foreign known"
    a.db.professionRecipeIndex[164][8].name = "Foreign unfamiliar"
    b.db.professionRecipeIndex[164][3].name = "Local known"
    a:ready(); b:ready()
    local logicalData
    local sendPayload = a.G.SendProfessionPayload
    a.G.SendProfessionPayload = function(transport, payload, target, onFinished)
        if payload:match("^P4|D|") then logicalData = payload end
        return sendPayload(transport, payload, target, onFinished)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(90)
    local record = assert(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertEqual(record.recipes[1].name, "Local known")
    T.assertEqual(record.recipes[2].name, "Foreign unfamiliar")
    T.assertNotNil(logicalData)
    T.assertNil(logicalData:find("Foreign known", 1, true), "known recipient labels should be omitted")
    T.assertNotNil(logicalData:find("Foreign unfamiliar", 1, true), "unknown labels should remain available")
end)

T.test("a transmitted label upgrades a local Recipe ID fallback", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); b:save(b.identity, { 8 })
    a.db.professionRecipeIndex[164][3].name = "Actual recipe label"
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(90)
    T.assertEqual(b.db.professionRecipeIndex[164][3].name, "Actual recipe label")
end)

T.test("a deferred observer tries each independent queued source within cooldown bounds", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    a:save(a.identity, { 3 }); a:ready(); b:ready(); c:ready()
    c.sync.pending[164] = { reason = "save", preferredPeer = "bob-realm",
        following = { reason = "save", preferredPeer = "alice-realm", ready = true } }
    b.drop = true
    local digest = a.G.GetProfessionSyncDigest(a.db, 164)
    assert(a.G.SendProfessionPayload(a.sync.transport,
        "P4|Q|*|1-9|164|" .. digest .. ";save;;bob-realm"))
    bus:advance(59)
    T.assertNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    bus:advance(331)
    T.assertNotNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    T.assertEqual(bus:count("Q"), 3)
    local frames = #bus.frames; bus:advance(600); T.assertEqual(#bus.frames, frames)
end)

T.test("a departed queued source does not strand the next valid announcement", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    a:save(a.identity, { 3 }); a:ready(); b:ready(); c:ready()
    c.sync.pending[164] = { reason = "save", preferredPeer = "departed-realm", ready = true,
        following = { reason = "save", preferredPeer = "alice-realm", ready = true } }
    b.drop = true
    local digest = a.G.GetProfessionSyncDigest(a.db, 164)
    assert(a.G.SendProfessionPayload(a.sync.transport,
        "P4|Q|*|1-9|164|" .. digest .. ";save;;bob-realm"))
    bus:advance(390)
    T.assertNotNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    T.assertEqual(bus:count("Q"), 2)
end)

T.test("profession details and timestamp-only manifests are delivered only to the selected peer", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    a:save(a.identity, { 3 }); a:ready(); b:ready(); c:ready()
    -- Use one discovery exchange: a manual operation intentionally compares
    -- the next peer after cooldown and now reaches it before 65 seconds.
    assert(b.G.RequestProfessionSync(b.sync, 164, "selection")); bus:advance(3)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    T.assertEqual(bus:count("K"), 1)
    for _, frame in ipairs(bus.frames) do
        local kind = frame.text:match("P4|(%a)|")
        if kind == "M" or kind == "R" or kind == "D" or kind == "K" then
            T.assertEqual(frame.channel, "WHISPER"); T.assertNotNil(frame.target)
        end
        if kind == "M" then
            T.assertNil(frame.text:match("Player[^;]+,%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x,"))
        end
    end
end)

T.test("newer timestamp replaces identical recipe contents and is preserved on relay", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000001); b:save(offline, { 3 }, 1700000000)
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(65)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164).capturedAt, 1700000001)
    T.assertEqual(a.G.GetProfessionSyncDigest(a.db, 164), b.G.GetProfessionSyncDigest(b.db, 164))
    T.assertEqual(bus:count("D"), 0, "matching recipe hashes should not resend recipe records")
    T.assertEqual(bus:count("T"), 1, "matching recipe hashes should exchange freshness metadata")
end)

T.test("freshness updates carry validated source and profession metadata", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000001); b:save(offline, { 3 }, 1700000000)
    a.db.professions[offline.key].snapshots[164].source = a.G.PROFESSION_SOURCE_PLAYER
    a.db.professions[offline.key].snapshots[164].professionName = "Blacksmithing Updated"
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(90)
    local updated = assert(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164))
    T.assertEqual(updated.capturedAt, 1700000001)
    T.assertEqual(updated.source, b.G.PROFESSION_SOURCE_PLAYER)
    T.assertEqual(updated.professionName, "Blacksmithing Updated")
    T.assertEqual(bus:count("D"), 0)
end)

T.test("false-positive metadata hints preserve exact recipe membership with an explicit ID fallback", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 11 }); b:save(b.identity, { 3 })
    a.db.professionRecipeIndex[164][3].name = "Foreign known"
    a.db.professionRecipeIndex[164][11].name = "Foreign unfamiliar"
    b.db.professionRecipeIndex[164][3].name = "Local known"
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(90)
    local record = assert(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertEqual(#record.recipes, 2)
    T.assertEqual(record.recipes[1].recipeID, 3)
    T.assertEqual(record.recipes[2].recipeID, 11)
    T.assertEqual(record.recipes[1].name, "Local known")
    T.assertEqual(record.recipes[2].name, "Recipe 11")
    T.assertEqual(record.hash, b.G.HashProfessionRecipes(164, record.recipes))
end)

T.test("malformed bounded metadata hints are rejected before a complete record is requested", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }); b:save(b.identity, { 3 })
    a:ready(); b:ready()
    local receive = a.sync.transport.onPayload
    local corrupted = 0
    a.sync.transport.onPayload = function(payload, sender, channel)
        if payload:match("^P4|R|") then
            payload, corrupted = payload:gsub("(;record;)(%d+);([^;]+);(%d+);([^;]+)$", function(prefix, _, _, iconBits, iconFilter)
                return prefix .. "999999;z;" .. iconBits .. ";" .. iconFilter
            end)
        end
        return receive(payload, sender, channel)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(90)
    T.assertEqual(corrupted, 1, "the malformed metadata filter must be injected")
    T.assertEqual(bus:count("D", a.identity.key), 0)
    T.assertNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("empty newer remote snapshots preserve learned recipe membership", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, {}, 1700000001); b:save(offline, { 3, 8 }, 1700000000)
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(90)
    local record = assert(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164))
    T.assertEqual(#record.recipes, 2)
    T.assertEqual(record.capturedAt, 1700000001)
end)

T.test("older and equal-time recipe differences merge on both participants", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    local offline, equalTime = bus:member("Offline"), bus:member("EqualTime")
    alice:save(offline, { 3, 8 }, 1700000001)
    bob:save(offline, { 8, 9 }, 1700000000)
    alice:save(equalTime, { 3 }, 1700000001)
    bob:save(equalTime, { 8 }, 1700000001)
    alice:ready(); bob:ready()

    T.assertTrue(bob.G.RequestProfessionSync(bob.sync, 164, "manual", alice.identity.key:lower()))
    bus:advance(90)

    local aliceRecord = assert(alice.G.GetProfessionSyncRecord(alice.db, offline.guid, 164))
    local bobRecord = assert(bob.G.GetProfessionSyncRecord(bob.db, offline.guid, 164))
    T.assertEqual(#aliceRecord.recipes, 3)
    T.assertEqual(#bobRecord.recipes, 3)
    T.assertEqual(aliceRecord.recipes[3].recipeID, 9)
    T.assertEqual(bobRecord.recipes[3].recipeID, 9)
    T.assertEqual(aliceRecord.capturedAt, 1700000001)
    T.assertEqual(bobRecord.capturedAt, 1700000001)
    T.assertEqual(#assert(alice.G.GetProfessionSyncRecord(alice.db, equalTime.guid, 164)).recipes, 2)
    T.assertEqual(#assert(bob.G.GetProfessionSyncRecord(bob.db, equalTime.guid, 164)).recipes, 2)
end)

T.test("one manual operation continues through bounded four-record batches", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    local identities = {}
    for index = 1, 10 do
        identities[index] = bus:member("Offline" .. index)
        alice:save(identities[index], { index })
    end
    alice:ready(); bob:ready()

    T.assertTrue(bob.G.RequestProfessionSync(bob.sync, 164, "manual", alice.identity.key:lower()))
    bus:advance(900)

    for _, identity in ipairs(identities) do
        T.assertNotNil(bob.G.GetProfessionSyncRecord(bob.db, identity.guid, 164),
            "the bounded operation should continue until every changed record is compared")
    end
    local perSession = {}
    for _, frame in ipairs(bus.frames) do
        local id = frame.text:match("P4|D|[^|]+|([^|]+)|")
        if id then perSession[id] = (perSession[id] or 0) + 1 end
    end
    T.assertEqual(bus:count("D"), 10)
    for _, count in pairs(perSession) do T.assertTrue(count <= 4, "each comparison must stay within four records") end
end)

T.test("manual operation publishes a bounded completion result to its callback", function()
    local bus = guild()
    local alice, bob = bus:client("Alice"), bus:client("Bob")
    alice:ready(); bob:ready()
    local callbackCount, callbackResult = 0, nil

    T.assertTrue(bob.G.RequestProfessionSync(bob.sync, 164, "manual", alice.identity.key:lower(), function(result)
        callbackCount = callbackCount + 1
        callbackResult = result
    end))
    bus:advance(90)

    local result = assert(bob.sync.lastOperationResult)
    T.assertEqual(callbackCount, 1)
    T.assertEqual(callbackResult, result)
    T.assertEqual(result.professionID, 164)
    T.assertFalse(result.unfinished)
    T.assertEqual(type(result.remainingPeers), "table")
    T.assertEqual(type(result.cursors), "table")
end)

T.test("equal-time recipe differences merge while another record transfers", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local conflict, changed = bus:member("Conflict"), bus:member("Changed")
    a:save(conflict, { 3 }, 1700000000); b:save(conflict, { 8 }, 1700000000)
    a:save(changed, { 9 }, 1700000001)
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(90)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, conflict.guid, 164).recipes, 2)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, changed.guid, 164).recipes[1].recipeID, 9)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Compared with 1 peer")
end)

T.test("a second-peer timeout preserves a conflict found by the first peer", function()
    local bus = guild()
    local alice, requester, bob = bus:client("Alice"), bus:client("Requester"), bus:client("Bob")
    local conflict = requester.identity
    alice:save(conflict, { 3 }, 1700000000)
    requester:save(conflict, { 8 }, 1700000000)
    bob:save(conflict, { 8 }, 1700000000)
    alice:ready(); requester:ready(); bob:ready()

    assert(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(55)
    T.assertTrue(requester.sync.manualOperation.conflict, "the first comparison should have recorded its conflict")

    local original = requester.api.ChatThrottleLib.SendAddonMessage
    local held
    requester.api.ChatThrottleLib.SendAddonMessage = function(lib, priority, prefix, text, channel, target, queue, callback, arg)
        if text:find("P4|Q|", 1, true) then
            held = { callback = callback, arg = arg }
            return
        end
        return original(lib, priority, prefix, text, channel, target, queue, callback, arg)
    end
    bus:advance(10)
    T.assertNotNil(held, "the next preferred-peer query should be held before its callback")
    bus:advance(301)

    T.assertEqual(requester.G.GetProfessionSyncStatus(requester.sync, 164), "Conflict: fresh observation needed",
        "a later session timeout must not erase an earlier conflict")
    held.callback(held.arg, true, 0)
    bus:advance(1200)
    T.assertEqual(requester.G.GetProfessionSyncStatus(requester.sync, 164), "Conflict: fresh observation needed")
end)

T.test("cancellation during a planned transfer preserves its conflict and committed record", function()
    local bus = guild()
    local alice, requester = bus:client("Alice"), bus:client("Bob")
    local conflict, changedOne, changedTwo = requester.identity, bus:member("ChangedOne"), bus:member("ChangedTwo")
    alice:save(conflict, { 3 }, 1700000000)
    requester:save(conflict, { 8 }, 1700000000)
    alice:save(changedOne, { 9 }, 1700000002)
    requester:save(changedOne, { 8 }, 1700000001)
    alice:save(changedTwo, { 10 }, 1700000002)
    requester:save(changedTwo, { 8 }, 1700000001)
    alice:ready(); requester:ready()
    local receive, cancelled, plannedConflict, retainedGUID = requester.sync.transport.onPayload, false, false, nil
    requester.sync.transport.onPayload = function(payload, sender, channel)
        local result, err = receive(payload, sender, channel)
        if not cancelled and payload:find("P4|D|", 1, true) then
            local session = requester.sync.manualOperation and requester.sync.manualOperation.currentSession
            for _, identity in ipairs({ changedOne, changedTwo }) do
                local record = requester.G.GetProfessionSyncRecord(requester.db, identity.guid, 164)
                if record and record.capturedAt == 1700000002 then retainedGUID = identity.guid end
            end
            if retainedGUID then
                plannedConflict = session and session.conflict == true
                cancelled = true
                requester.G.CancelProfessionSync(requester.sync)
            end
        end
        return result, err
    end

    assert(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    bus:advance(90)

    T.assertTrue(cancelled, "the test must cancel after one newer record has been committed")
    T.assertTrue(plannedConflict, "the active session must already know about the equal-time conflict")
    T.assertNotNil(requester.G.GetProfessionSyncRecord(requester.db, retainedGUID, 164),
        "cancellation must retain already committed cached data")
    T.assertEqual(requester.G.GetProfessionSyncStatus(requester.sync, 164), "Conflict: fresh observation needed",
        "a conflict held on the unfinished session must survive cancellation")
end)

T.test("unknown roster presence fails closed until a valid recent protocol message arrives", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a.identity.online = "unknown"
    a:ready(); b:ready()
    T.assertFalse(b.sync.transport.canSendTarget("alice-realm"))
    T.assertEqual(receiveLegacyAnnouncement(a, b, "login"), "announced")
    T.assertTrue(b.sync.transport.canSendTarget("alice-realm"))
end)

T.test("a same-time roster refresh supersedes a valid message received earlier in that frame", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    T.assertEqual(receiveLegacyAnnouncement(a, b, "background"), "announced")
    T.assertTrue(b.sync.transport.canSendTarget("alice-realm"))
    a.identity.online = false
    assert(b.G.RefreshProfessionSyncRoster(b.sync))
    T.assertFalse(b.sync.transport.canSendTarget("alice-realm"))
end)

T.test("a valid message older than the latest roster observation does not override offline presence", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    T.assertEqual(receiveLegacyAnnouncement(a, b, "login"), "announced")
    a.identity.online = false
    bus:advance(1); assert(b.G.RefreshProfessionSyncRoster(b.sync))
    T.assertFalse(b.sync.transport.canSendTarget("alice-realm"))
end)

T.test("a valid D response establishes presence before its acknowledgement is queued", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready(); b:ready()
    local receive, observedOffline = b.sync.transport.onPayload, false
    b.sync.transport.onPayload = function(payload, sender, channel)
        if not observedOffline and payload:match("^P4|D|") then
            observedOffline = true
            b.sync.presenceRevision = b.sync.presenceRevision + 1
            b.sync.senders[sender].presence = { online = false, observedAt = bus.now,
                revision = b.sync.presenceRevision }
            b.sync.presenceEvidence[sender] = nil
        end
        return receive(payload, sender, channel)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(45)
    T.assertTrue(observedOffline)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertTrue(bus:count("K", b.identity.key) > 0)
end)

T.test("a valid T response establishes presence before its acknowledgement is queued", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000001); b:save(offline, { 3 }, 1700000000)
    a:ready(); b:ready()
    local receive, observedOffline = b.sync.transport.onPayload, false
    b.sync.transport.onPayload = function(payload, sender, channel)
        if not observedOffline and payload:match("^P4|T|") then
            observedOffline = true
            b.sync.presenceRevision = b.sync.presenceRevision + 1
            b.sync.senders[sender].presence = { online = false, observedAt = bus.now,
                revision = b.sync.presenceRevision }
            b.sync.presenceEvidence[sender] = nil
        end
        return receive(payload, sender, channel)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(45)
    T.assertTrue(observedOffline)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164).capturedAt, 1700000001)
    T.assertTrue(bus:count("K", b.identity.key) > 0)
end)

T.test("roster refresh fails closed when GetTime is secret invalid or throwing", function()
    local bus = guild()
    local b = bus:client("Bob")
    b:ready()
    local invalidClocks = {
        function() error("clock unavailable") end,
        function() return nil end,
        function() return math.huge end,
        function() return 0 / 0 end,
    }
    for _, getTime in ipairs(invalidClocks) do
        b.api.GetTime = getTime
        local callOk, refreshed = pcall(b.G.RefreshProfessionSyncRoster, b.sync)
        T.assertTrue(callOk, "invalid clock values must not escape the roster handler")
        T.assertFalse(refreshed)
    end
    b.api.GetTime = function() return 25 end
    b.api.issecretvalue = function(value) return value == 25 end
    local callOk, refreshed = pcall(b.G.RefreshProfessionSyncRoster, b.sync)
    T.assertTrue(callOk)
    T.assertFalse(refreshed, "secret roster observation time must fail closed")
end)

T.test("an active multi-frame transfer stops when its selected peer goes offline", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local recipes = {}
    for index = 1, 4096 do recipes[index] = index end
    a:save(a.identity, recipes); a:ready(); b:ready()
    local receive = b.G.ReceiveProfessionFrame
    local framesAtTransition
    b.G.ReceiveProfessionFrame = function(transport, prefix, text, channel, sender)
        local state, err = receive(transport, prefix, text, channel, sender)
        if not framesAtTransition and text:find("|P4|D|", 1, true) then
            framesAtTransition = #bus.frames
            b.identity.online = false
            assert(a.G.RefreshProfessionSyncRoster(a.sync))
        end
        return state, err
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(45)
    T.assertNotNil(framesAtTransition)
    bus:advance(100)
    T.assertEqual(#bus.frames, framesAtTransition)
    T.assertNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("receive bursts coalesce into one final catalog refresh with all committed data", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(a.identity, { 3 }); a:save(offline, { 8 })
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    for _ = 1, 120 do
        if b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164)
            and b.G.GetProfessionSyncRecord(b.db, offline.guid, 164) then break end
        bus:advance(0.5)
    end
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164))
    T.assertEqual(b.refreshes, 1, "the completed burst should coalesce into one final refresh")
    b.G.CancelProfessionSync(b.sync)
    T.assertEqual(b.refreshes, 1, "cancellation should not duplicate a completed refresh")
    T.assertEqual(#b.visibleCatalog, 2, "the final visible catalog should contain both committed records")
    bus:advance(10)
    T.assertEqual(b.refreshes, 1, "stale refresh callbacks must not run twice")
end)

T.test("cancellation flushes committed catalog changes and invalidates the refresh timer", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(a.identity, { 3 }); a:save(offline, { 8 })
    a:ready(); b:ready()
    local receive, cancelled = b.sync.transport.onPayload, false
    b.sync.transport.onPayload = function(payload, sender, channel)
        local result = receive(payload, sender, channel)
        if not cancelled and payload:match("^P4|D|") then
            cancelled = true
            b.G.CancelProfessionSync(b.sync)
        end
        return result
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(45)
    T.assertTrue(cancelled)
    T.assertEqual(b.refreshes, 1)
    bus:advance(10)
    T.assertEqual(b.refreshes, 1)
end)

T.test("timestamp-only freshness rejects a corrupt expected content hash", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000001); b:save(offline, { 3 }, 1700000000)
    a:ready(); b:ready()
    local receive = b.sync.transport.onPayload
    local changed = 0
    b.sync.transport.onPayload = function(payload, sender, channel)
        if payload:match("^P4|T|") then
            local prefix, expectedHash, timestamp, source, name = payload:match("^(.-P4|T|.-|.-|164|[^;]+;[^;]+;)(%x+);(%d+);([^;]+);([^;]+)$")
            if prefix then
                payload = prefix .. "0000000000000000;" .. timestamp .. ";" .. source .. ";" .. name
                changed = changed + 1
            end
        end
        return receive(payload, sender, channel)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(400)
    local record = assert(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164))
    T.assertEqual(changed, 1, "the expected hash mutation must reach a T message")
    T.assertEqual(record.capturedAt, 1700000000)
    T.assertEqual(bus:count("D"), 0)
end)

T.test("timestamp-only freshness rejects a future timestamp", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000001); b:save(offline, { 3 }, 1700000000)
    a:ready(); b:ready()
    local receive = b.sync.transport.onPayload
    local changed = 0
    b.sync.transport.onPayload = function(payload, sender, channel)
        if payload:match("^P4|T|") then
            payload, changed = payload:gsub("(%x+);(%d+);([^;]+);([^;]+)$", "%1;1700001000;%3;%4")
        end
        return receive(payload, sender, channel)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(400)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164).capturedAt, 1700000000)
    T.assertEqual(changed, 1, "the future timestamp mutation must reach a T message")
    T.assertEqual(bus:count("D"), 0)
end)

T.test("timestamp-only freshness cannot overwrite a newer local observation made during transfer", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000001); b:save(offline, { 3 }, 1700000000)
    a:ready(); b:ready()
    local send, changed = a.api.C_ChatInfo.SendAddonMessage, false
    a.api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel, target)
        if not changed and frame:find("P4|T|", 1, true) then
            changed = true; b:save(offline, { 8 }, 1700000002)
        end
        return send(prefix, frame, channel, target)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(55)
    local record = assert(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164))
    T.assertEqual(record.recipes[1].recipeID, 8)
    T.assertEqual(record.capturedAt, 1700000002)
    T.assertEqual(bus:count("D"), 0)
end)

T.test("timestamp-only freshness cannot recreate a missing local record", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000001); b:save(offline, { 3 }, 1700000000)
    a:ready(); b:ready()
    local send, removed = a.api.C_ChatInfo.SendAddonMessage, false
    a.api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel, target)
        if not removed and frame:find("P4|T|", 1, true) then
            removed = true
            b.db.professions[offline.key].snapshots[164] = nil
        end
        return send(prefix, frame, channel, target)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(55)
    T.assertNil(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164))
    T.assertEqual(bus:count("D"), 0)
end)

T.test("timestamp-only freshness uses a private channel", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000001); b:save(offline, { 3 }, 1700000000)
    a:ready(); b:ready()
    local send = a.api.C_ChatInfo.SendAddonMessage
    a.api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel, target)
        if frame:find("P4|T|", 1, true) then channel, target = "GUILD", nil end
        return send(prefix, frame, channel, target)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(400)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164).capturedAt, 1700000000)
    T.assertEqual(bus:count("D"), 0)
end)

T.test("timestamp-only freshness never replaces the local player's owned snapshot", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(b.identity, { 3 }, 1700000001); b:save(b.identity, { 3 }, 1700000000)
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(60)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, b.identity.guid, 164).capturedAt, 1700000000)
    T.assertEqual(bus:count("T"), 0)
end)

T.test("manual sync continues bounded pages then becomes idle", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local identities = {}
    for index = 1, 13 do identities[index] = bus:member("Offline" .. index); a:save(identities[index], { index }) end
    a:ready(); b:ready(); assert(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    bus:advance(1800)
    local received = 0
    for _, identity in ipairs(identities) do
        if b.G.GetProfessionSyncRecord(b.db, identity.guid, 164) then received = received + 1 end
    end
    T.assertEqual(received, 13)
    T.assertEqual(bus:count("D"), 13)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Compared with 1 peer")
    local transfers, announcements = bus:count("D"), bus:count("A")
    bus:advance(1800)
    T.assertEqual(bus:count("D"), transfers)
    T.assertEqual(bus:count("A"), announcements)
end)

T.test("dropped storage acknowledgement cannot report a completed transfer", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready(); b:ready()
    local send = b.api.C_ChatInfo.SendAddonMessage
    b.api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel, target)
        if frame:find("P4|K|", 1, true) then return 0 end
        return send(prefix, frame, channel, target)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(65)
    T.assertNotNil(a.sync.active)
    bus:advance(300)
    T.assertEqual(a.G.GetProfessionSyncStatus(a.sync, 164), "Catch-up needed")
end)

T.test("wrong-channel detail frames cannot modify a selected profession exchange", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready(); b:ready()
    local send = a.api.C_ChatInfo.SendAddonMessage
    a.api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel, target)
        if frame:find("P4|D|", 1, true) then channel, target = "GUILD", nil end
        return send(prefix, frame, channel, target)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(400)
    T.assertNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("twenty participants catch up through serialized whispers with no duplicate records", function()
    local bus = guild()
    local clients = {}
    for index = 1, 20 do clients[index] = bus:client(string.format("Member%02d", index)) end
    local offline = bus:member("Offline")
    for _, client in ipairs(clients) do client:ready() end
    local before = clients[1].G.GetProfessionSyncDigest(clients[1].db, 164, clients[1].sync.members)
    clients[1]:save(offline, { 3, 8 })
    assert(clients[1].G.PublishProfessionSyncSave(clients[1].sync, 164, before))
    bus:advance(3600)
    for _, client in ipairs(clients) do
        T.assertNotNil(client.G.GetProfessionSyncRecord(client.db, offline.guid, 164))
        T.assertTrue(#client.sync.transport.outboundFrames <= 640)
    end
    T.assertEqual(bus:count("D"), 19)
    local count = bus:count("D")
    bus:advance(1800)
    T.assertEqual(bus:count("D"), count)
    T.assertEqual(bus:count("A"), 1)
end)

T.test("an unselected observer is not labelled synchronized by another pair's exchange", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    a:save(a.identity, { 3 }); a:ready(); b:ready(); c:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(40)
    T.assertNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    T.assertFalse(c.G.GetProfessionSyncStatus(c.sync, 164) == "Compared cached data")
end)

T.test("whisper sync rejects old protocol clients and future timestamp manifests", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }, 1700009999); a:ready(); b:ready()
    T.assertEqual(b.G.HandleProfessionSyncAddonMessage(b.sync, "GC_PROF", "garbage", "GUILD", a.identity.key), "ignored")
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(400)
    T.assertNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("guild departure and rejoining do not create periodic announcements", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready(); bus:advance(20)
    a.left = true; T.assertFalse(a.G.RefreshProfessionSyncRoster(a.sync))
    bus:advance(1000); T.assertEqual(#bus.frames, 0)
    a.left = false; a:ready(); bus:advance(420)
    T.assertEqual(#bus.frames, 0)
end)

T.test("multiple maximum-size profession records catch up without overflowing the outbound queue", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local recipes, identities = {}, {}
    for index = 1, 4096 do recipes[index] = index end
    for index = 1, 4 do identities[index] = bus:member("Offline" .. index); a:save(identities[index], recipes) end
    a:ready(); b:ready(); assert(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    bus:advance(1600)
    for _, identity in ipairs(identities) do
        T.assertEqual(#assert(b.G.GetProfessionSyncRecord(b.db, identity.guid, 164)).recipes, 4096)
    end
    T.assertEqual(bus:count("D"), 4)
    T.assertNil(a.sync.transport.lastSendError)
end)

T.test("a newer local observation is retained until a separate manual repair", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000001); a:ready(); b:ready()
    local send, changed = a.api.C_ChatInfo.SendAddonMessage, false
    a.api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel, target)
        if not changed and frame:find("P4|D|", 1, true) then
            changed = true; b:save(offline, { 8 }, 1700000002)
        end
        return send(prefix, frame, channel, target)
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(200)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, offline.guid, 164).recipes, 2)
    T.assertEqual(a.G.GetProfessionSyncRecord(a.db, offline.guid, 164).capturedAt, 1700000001)
    assert(a.G.RequestProfessionSync(a.sync, 164, "manual")); bus:advance(200)
    T.assertEqual(a.G.GetProfessionSyncRecord(a.db, offline.guid, 164).capturedAt, 1700000002)
end)

T.test("a new installation stays idle until manual repair and then syncs one bounded page", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local identities = {}
    for index = 1, 100 do identities[index] = bus:member("Offline" .. index); a:save(identities[index], { index }) end
    a:ready(); b:ready(); bus:advance(7200)
    T.assertEqual(#bus.frames, 0)
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(1800)
    local received = 0
    for _, identity in ipairs(identities) do
        if b.G.GetProfessionSyncRecord(b.db, identity.guid, 164) then received = received + 1 end
    end
    T.assertEqual(received, 32)
    T.assertEqual(bus:count("D"), 32)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Catch-up needed")
    local transfers = bus:count("D"); bus:advance(3600); T.assertEqual(bus:count("D"), transfers)
end)

return { guild = guild }
