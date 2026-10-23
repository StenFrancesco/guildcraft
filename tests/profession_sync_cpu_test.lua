local T = require("tests.testlib")
local guild = require("tests.profession_sync_fixture")

local function largeRecipeIDs(count)
    local ids = {}
    for index = 1, count do ids[index] = index end
    return ids
end

local function installCPUWork(G)
    T.loadAddonFile("The Guild Book/CPUWork.lua", G)
    G.CPUManualDriver = true
    local runFrame, frames = G.RunCPUFrame, 0
    G.RunCPUFrame = function()
        frames = frames + 1
        return runFrame()
    end
    local function pump(limit)
        limit = limit or 10000
        for _ = 1, limit do
            if G.GetCPUJobCount() == 0 then return frames end
            G.RunCPUFrame()
        end
        error("CPU job did not finish")
    end
    return pump, function() return frames end
end

T.test("cold comparison and save callers share one real CPU preparation job", function()
    local bus = guild()
    local requester, provider = bus:client("Alice"), bus:client("Bob")
    local pump, frames = installCPUWork(requester.G)
    requester:save(requester.identity, largeRecipeIDs(600))
    requester:ready(); provider:ready()

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "selection"))
    T.assertEqual(bus:count("Q", requester.identity.key), 0,
        "cold manifest preparation must yield before the query is submitted")
    T.assertTrue(requester.G.PublishProfessionSyncSave(requester.sync, 164, "before-save"))
    T.assertEqual(requester.G.GetCPUJobCount(), 1, "same-profession callers should share a prep job")

    local before = frames()
    pump()
    T.assertTrue(frames() - before > 1, "the 600-recipe read should span multiple CPU frames")
    T.assertEqual(bus:count("Q", requester.identity.key), 1)
    T.assertEqual(bus:count("A", requester.identity.key), 1,
        "the coalesced save callback must publish after the shared prep completes")

    bus:advance(60)
    T.assertNotNil(provider.G.GetProfessionSyncRecord(provider.db, requester.identity.guid, 164))
end)

T.test("stale CPU revision cannot publish a prepared profession query", function()
    local bus = guild()
    local requester, provider = bus:client("Alice"), bus:client("Bob")
    local pump = installCPUWork(requester.G)
    requester:save(requester.identity, largeRecipeIDs(600))
    requester:ready(); provider:ready()

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "selection"))
    requester.G.InvalidateCPURevision(requester.db)
    pump()
    T.assertEqual(bus:count("Q", requester.identity.key), 0)
    T.assertEqual(requester.G.GetCPUJobCount(), 0)
end)

T.test("expired manual preparation ends at its fixed operation deadline", function()
    local bus = guild()
    local requester, peer = bus:client("Alice"), bus:client("Bob")
    local pump = installCPUWork(requester.G)
    requester:save(requester.identity, largeRecipeIDs(600))
    requester:ready(); peer:ready()

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "manual"))
    local deadline = requester.sync.manualOperation.deadline
    bus:advance(deadline - bus.now + 1)
    pump()
    T.assertEqual(bus:count("Q", requester.identity.key), 0)
    T.assertNil(requester.sync.manualOperation)
    T.assertEqual(requester.G.GetProfessionSyncStatus(requester.sync, 164), "Catch-up needed")
end)

T.test("guild sync cancellation discards its queued profession preparation", function()
    local bus = guild()
    local requester = bus:client("Alice")
    local pump = installCPUWork(requester.G)
    requester:save(requester.identity, largeRecipeIDs(600))
    requester:ready()

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "selection"))
    T.assertEqual(requester.G.GetCPUJobCount(), 1)
    requester.G.CancelProfessionSync(requester.sync)
    pump()
    T.assertEqual(requester.G.GetCPUJobCount(), 0)
    T.assertEqual(bus:count("Q", requester.identity.key), 0)
end)

T.test("incoming query prepares a cold responder manifest before claiming", function()
    local bus = guild()
    local requester, responder = bus:client("Alice"), bus:client("Bob")
    local pump = installCPUWork(responder.G)
    responder:save(responder.identity, largeRecipeIDs(600))
    requester:ready(); responder:ready()

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "selection"))
    bus:advance(0)
    T.assertEqual(bus:count("C", responder.identity.key), 0,
        "the responder must finish cold digest preparation before claiming")
    T.assertEqual(responder.G.GetCPUJobCount(), 1)
    pump()
    bus:advance(2)
    T.assertEqual(bus:count("C", responder.identity.key), 1)
end)

T.test("save hints schedule asynchronous comparison without a cold digest read", function()
    local bus = guild()
    local sender, receiver = bus:client("Alice"), bus:client("Bob")
    local pump = installCPUWork(receiver.G)
    sender:save(sender.identity, largeRecipeIDs(600))
    receiver:save(receiver.identity, largeRecipeIDs(600))
    sender:ready(); receiver:ready()
    local digest = assert(sender.G.GetProfessionSyncDigest(sender.db, 164, sender.sync.members))
    local original, didRead = receiver.G.GetProfessionSyncDigest, false
    receiver.G.GetProfessionSyncDigest = function(...)
        didRead = true
        return original(...)
    end
    local payload = "P5|A|*|123-1|0|164," .. digest .. ",save"

    T.assertEqual(receiver.sync.transport.onPayload(payload, sender.identity.key, "GUILD"), "announced")
    T.assertFalse(didRead, "a cold save hint must not calculate the local digest in its event callback")
    bus:advance(5)
    T.assertFalse(didRead, "comparison startup should use asynchronous preparation")
    T.assertEqual(receiver.G.GetCPUJobCount(), 1)
    pump()
end)

T.test("online presence refresh preserves membership identity during preparation", function()
    local bus = guild()
    local requester, peer = bus:client("Alice"), bus:client("Bob")
    local pump = installCPUWork(requester.G)
    requester:save(requester.identity, largeRecipeIDs(600))
    requester:ready(); peer:ready()

    T.assertTrue(requester.G.RequestProfessionSync(requester.sync, 164, "selection"))
    local members = requester.sync.members
    peer.identity.online = false
    T.assertTrue(requester.G.RefreshProfessionSyncRoster(requester.sync))
    T.assertEqual(requester.sync.members, members,
        "presence-only changes should preserve the membership snapshot used by the job")
    pump()
    T.assertEqual(bus:count("Q", requester.identity.key), 1)
end)

T.test("invalidated completed preparation is rebuilt before a save announcement", function()
    local bus = guild()
    local client = bus:client("Alice")
    local pump = installCPUWork(client.G)
    local ids = largeRecipeIDs(600)
    client:save(client.identity, ids)
    client:ready()

    T.assertTrue(client.G.PublishProfessionSyncSave(client.sync, 164, "before-save"))
    pump()
    T.assertEqual(bus:count("A", client.identity.key), 1)
    local before = assert(client.G.GetProfessionSyncDigest(client.db, 164, client.sync.members))
    ids[#ids + 1] = 601
    client:save(client.identity, ids, 1700000001)

    T.assertTrue(client.G.PublishProfessionSyncSave(client.sync, 164, before))
    bus:advance(60)
    T.assertEqual(client.G.GetCPUJobCount(), 1,
        "a database revision change must invalidate the completed prep cache")
    pump()
    T.assertEqual(bus:count("A", client.identity.key), 2)
end)

local function installFrameDriver(client)
    local frames = {}
    client.api.CreateFrame = function()
        local frame = {}
        local function tick()
            frame.pending = nil
            if frame.update then frame.update() end
            if frame.update and not frame.pending then frame.pending = client.api.C_Timer.NewTimer(1/60, tick) end
        end
        function frame:SetScript(event, fn)
            if event ~= "OnUpdate" then return end
            self.update = fn
            if fn and not self.pending then self.pending = client.api.C_Timer.NewTimer(1/60, tick)
            elseif not fn and self.pending then self.pending:Cancel(); self.pending = nil end
        end
        frames[#frames + 1] = frame
        return frame
    end
    T.loadAddonFile("The Guild Book/CPUWork.lua",client.G)
    return frames
end
T.test("real frame-driven compressed transfers converge and stop CPU updates",function()
    local bus = guild()
    local owner, receiver = bus:client("Alice"), bus:client("Bob")
    owner:save(owner.identity,largeRecipeIDs(1000))
    owner:ready();receiver:ready()
    local first,second = installFrameDriver(owner),installFrameDriver(receiver)
    T.assertTrue(receiver.G.RequestProfessionSync(receiver.sync,164,"manual"))
    bus:advance(180)
    local actual=assert(receiver.G.GetProfessionSyncRecord(receiver.db,owner.identity.guid,164))
    T.assertEqual(#actual.recipes,1000)
    T.assertEqual(owner.G.GetProfessionSyncDigest(owner.db,164),receiver.G.GetProfessionSyncDigest(receiver.db,164))
    T.assertEqual(owner.G.GetCPUJobCount(),0);T.assertEqual(receiver.G.GetCPUJobCount(),0)
    for _,frames in ipairs({first,second}) do for _,frame in ipairs(frames) do T.assertNil(frame.update);T.assertNil(frame.pending) end end
    T.assertTrue(bus:count("D")>0);T.assertTrue(bus:count("K")>0)
    T.assertNil(receiver.sync.manualOperation)
end)

T.test("shared preparation subscribers remain bounded during repeated save events",function()
    local bus=guild()
    local client=bus:client("Alice")
    local pump=installCPUWork(client.G)
    client:save(client.identity,largeRecipeIDs(600));client:ready()
    for i=1,100 do client.G.PublishProfessionSyncSave(client.sync,164,"before") end
    T.assertEqual(client.G.GetCPUJobCount(),1)
    T.assertTrue(#client.sync.preparationTokens[164].subscribers<=16)
    pump();T.assertEqual(client.G.GetCPUJobCount(),0)
end)

T.test("frame-driven renamed records retain full recovery validation and can converge",function()
    local bus=guild()
    local owner,receiver=bus:client("Alice"),bus:client("Bob")
    owner:save(owner.identity,{1,2},1700000010)
    receiver:save(owner.identity,{1},1700000000)
    local oldKey=owner.identity.key
    owner.identity.name,owner.identity.key="Renamed","Renamed-Realm"
    owner:ready();receiver:ready()
    installFrameDriver(owner);installFrameDriver(receiver)
    T.assertTrue(receiver.G.RequestProfessionSync(receiver.sync,164,"manual"))
    bus:advance(180)
    local record=assert(receiver.G.GetProfessionSyncRecord(receiver.db,owner.identity.guid,164))
    T.assertEqual(#record.recipes,2)
    T.assertNotNil(receiver.db.professions[owner.identity.key])
    T.assertNil(receiver.db.professions[oldKey])
    T.assertEqual(owner.G.GetCPUJobCount(),0);T.assertEqual(receiver.G.GetCPUJobCount(),0)
end)

return true
