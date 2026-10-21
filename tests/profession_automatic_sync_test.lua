local T = require("tests.testlib")
local guild = require("tests.profession_sync_fixture")

local function automatic(client)
    T.loadAddonFile("The Guild Book/AutomaticSync.lua", client.G)
    T.loadAddonFile("The Guild Book/ProfessionAutomaticSync.lua", client.G)
    client.api.IsResting = function() return true end
    client.api.C_Map = { GetBestMapForUnit = function() return client.map or 84 end }
end

T.test("automatic recipe login checks another peer after a matching cache", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    local crafter = bus:member("Offline")
    c:save(crafter, { 3, 9 })
    for _, client in ipairs({ a, b, c }) do client:ready(); automatic(client) end
    a.api.random = function() return 300 end
    assert(a.G.LoginProfessionSync(a.sync)); assert(a.G.LoginProfessionSync(a.sync))
    bus:advance(299); T.assertEqual(#bus.frames, 0)
    bus:advance(1100)
    local record = assert(a.G.GetProfessionSyncRecord(a.db, crafter.guid, 164))
    T.assertEqual(#record.recipes, 2)
    local frames = #bus.frames; bus:advance(10000); T.assertEqual(#bus.frames, frames)
    T.assertFalse(a.sync.automaticController.pending)
end)

T.test("automatic recipes finish a hundred changed records across bounded attempts", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local identities = {}
    for index = 1, 100 do
        identities[index] = bus:member("Offline" .. index)
        a:save(identities[index], { index })
    end
    a:ready(); b:ready(); automatic(b)
    assert(b.G.LoginProfessionSync(b.sync)); bus:advance(6000)
    for _, identity in ipairs(identities) do T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, identity.guid, 164)) end
    T.assertFalse(b.sync.automaticController.pending)
    local frames = #bus.frames; bus:advance(10000); T.assertEqual(#bus.frames, frames)
end)

T.test("automatic recipes reach a fifth peer beyond matching caches", function()
    local bus = guild()
    local requester = bus:client("Requester")
    local peers = {}
    for index = 1, 5 do peers[index] = bus:client("Peer" .. index) end
    local offline = bus:member("Offline")
    peers[5]:save(offline, { 9 })
    requester:ready(); automatic(requester)
    for _, peer in ipairs(peers) do peer:ready() end
    assert(requester.G.LoginProfessionSync(requester.sync)); bus:advance(6000)
    T.assertNotNil(requester.G.GetProfessionSyncRecord(requester.db, offline.guid, 164))
    T.assertTrue(requester.sync.automaticController.recoveries <= 3)
end)

T.test("a recipe request queued while sending is served after the transport drains", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready(); b:ready()
    local original, held = a.api.ChatThrottleLib.SendAddonMessage, nil
    a.api.ChatThrottleLib.SendAddonMessage = function(lib, priority, prefix, text, channel, target, queue, callback, arg)
        held = function() original(lib, priority, prefix, text, channel, target, queue, callback, arg) end
    end
    assert(a.G.SendProfessionPayload(a.sync.transport, "unrelated"))
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(1)
    T.assertEqual(a.sync.deferredResponseCount, 1)
    a.api.ChatThrottleLib.SendAddonMessage = original; held(); bus:advance(80)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertEqual(a.sync.deferredResponseCount, 0)
end)

T.test("busy recipe requests are deduplicated bounded and expire", function()
    local bus = guild()
    local target = bus:client("Target")
    local peers = {}
    for index = 1, 20 do peers[index] = bus:client("Peer" .. index) end
    target:ready(); target.sync.active = { busy = true }
    for index, peer in ipairs(peers) do
        peer:ready()
        local digest = assert(peer.G.GetProfessionSyncDigest(peer.db, 164))
        local payload = "P5|Q|*|123-" .. index .. "|164|" .. digest .. ";manual;;target-realm"
        target.sync.transport.onPayload(payload, peer.identity.key, "GUILD")
        target.sync.transport.onPayload(payload, peer.identity.key, "GUILD")
    end
    T.assertEqual(target.sync.deferredResponseCount, 16)
    bus:advance(30); T.assertEqual(target.sync.deferredResponseCount, 0)
    target.sync.active = nil; target.sync.transport.onIdle(); bus:advance(100)
    T.assertEqual(#bus.frames, 0)
end)

T.test("new recipe protocol rejects destructive legacy messages", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    local digest = assert(a.G.GetProfessionSyncDigest(a.db, 164))
    T.assertEqual(b.sync.transport.onPayload("P3|Q|*|123-1|164|" .. digest .. ";manual;;", a.identity.key, "GUILD"), "ignored")
    T.assertEqual(b.G.HandleProfessionSyncAddonMessage(b.sync, "GC_PROF3", "anything", "GUILD", a.identity.key), "ignored")
    T.assertEqual(#bus.frames, 0)
end)

T.test("manual profession synchronization bypasses the automatic login delay", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready(); b:ready(); automatic(b)
    b.api.random = function() return 300 end
    assert(b.G.LoginProfessionSync(b.sync))
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(5)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("recipe automatic work restarts with fresh professions on the verified guild switch wake", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready(); automatic(b)
    assert(b.G.LoginProfessionSync(b.sync)); bus:advance(300)
    local oldGuild = b.sync.automaticGuild
    T.assertNotNil(oldGuild)
    b.sync.guild = "OtherGuild:Realm"; b.G.WakeProfessionSync(b.sync)
    T.assertFalse(b.sync.automaticController.stopped)
    bus:advance(300)
    T.assertEqual(b.sync.automaticGuild, "OtherGuild:Realm")
    T.assertNotNil(b.sync.automaticRemaining)
    T.assertTrue(b.sync.automaticController.recoveries <= 3)
end)

T.test("recipe automatic work waits for guild membership and roster readiness", function()
    local bus = guild()
    local b = bus:client("Bob")
    b:ready(); automatic(b)
    assert(b.G.LoginProfessionSync(b.sync)); bus:advance(300)
    b.api.IsInGuild = function() return false end
    b.G.WakeProfessionSync(b.sync)
    T.assertTrue(b.sync.automaticController.stopped)
    b.api.IsInGuild = function() return true end
    b.sync.rosterReady = false
    b.G.WakeProfessionSync(b.sync)
    T.assertTrue(b.sync.automaticController.stopped)
    b.sync.rosterReady = true
    b.G.WakeProfessionSync(b.sync)
    T.assertFalse(b.sync.automaticController.stopped)
end)

T.test("real recipe login event schedules synchronization without the character browser", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready(); b:ready(); automatic(b)
    local api, G, handler = b.api, b.G, nil
    api._G = api; setmetatable(api, { __index = _G })
    api.CreateFrame = function() return { RegisterEvent = function() end,
        SetScript = function(_, _, fn) handler = fn end } end
    G.db, G.professionSync, G.professionRosterMembershipCurrent = b.db, b.sync, true
    G.RegisterSnapshotTestSlashCommand = function() end
    G.RecordLocalPlayerOwnership = function() return true end
    local chunk = assert(loadfile("The Guild Book/Main.lua")); setfenv(chunk, api); chunk("The Guild Book", G)
    G.professionRosterMembershipCurrent = true
    handler(nil, "PLAYER_LOGIN"); bus:advance(100)
    T.assertNotNil(G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
end)

T.test("recipe login interrupted by unavailable roster resumes in a stationary city", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready(); b:ready(); automatic(b)
    b.sync.rosterReady = false
    assert(b.G.LoginProfessionSync(b.sync)); bus:advance(1199)
    T.assertEqual(#bus.frames, 0)
    b:ready(); bus:advance(100)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertFalse(b.sync.automaticController.pending)
end)

T.test("simultaneous recipe login jobs recover through bounded city retries", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); b:save(b.identity, { 8 })
    for _, client in ipairs({ a, b }) do client:ready(); automatic(client); assert(client.G.LoginProfessionSync(client.sync)) end
    bus:advance(6000)
    T.assertNotNil(a.G.GetProfessionSyncRecord(a.db, b.identity.guid, 164))
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    local count = #bus.frames; bus:advance(10000); T.assertEqual(#bus.frames, count)
    T.assertTrue(a.sync.automaticController.recoveries <= 3)
    T.assertTrue(b.sync.automaticController.recoveries <= 3)
end)

T.test("six simultaneous recipe logins preserve and share every participant's recipes", function()
    local bus, clients = guild(), {}
    for index = 1, 6 do
        local client = bus:client("Member" .. index)
        client:save(client.identity, { index }); clients[index] = client
    end
    for _, client in ipairs(clients) do client:ready(); automatic(client); assert(client.G.LoginProfessionSync(client.sync)) end
    bus:advance(20000)
    for _, client in ipairs(clients) do
        for _, member in ipairs(clients) do
            T.assertNotNil(client.G.GetProfessionSyncRecord(client.db, member.identity.guid, 164))
        end
    end
    local count = #bus.frames; bus:advance(10000); T.assertEqual(#bus.frames, count)
end)
