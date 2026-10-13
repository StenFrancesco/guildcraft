local T = require("tests.testlib")

local function guild()
    local bus = { now = 0, timers = {}, clients = {}, members = {}, frames = {} }
    function bus:advance(seconds)
        local limit, ticks = self.now + seconds, 0
        while true do
            table.sort(self.timers, function(a, b) return a.at < b.at or (a.at == b.at and a.order < b.order) end)
            local timer = self.timers[1]
            if not timer or timer.at > limit then break end
            table.remove(self.timers, 1)
            self.now = timer.at
            if not timer.cancelled then timer.fn() end
            ticks = ticks + 1
            assert(ticks < 20000, "unbounded message/timer loop")
        end
        self.now = limit
    end
    function bus:member(name)
        local identity = { key = name .. "-Realm", name = name, realm = "Realm", guid = "Player-1-" .. string.format("%X", #self.members + 1) }
        self.members[#self.members + 1] = identity
        return identity
    end
    function bus:client(name)
        local client = { identity = self:member(name), G = {}, refreshes = 0 }
        for _, file in ipairs({ "Constants", "ProfessionSnapshot", "ProfessionIndex", "Storage", "CharacterIdentity", "ProfessionSyncData", "ProfessionTransport", "ProfessionSync" }) do
            local path = "GuildGearMemory/" .. file .. ".lua"
            local handle = io.open(path, "r")
            if handle then handle:close(); T.loadAddonFile(path, client.G) end
        end
        T.assertEqual(type(client.G.CreateProfessionSync), "function")
        client.db = client.G.InitializeDatabase(nil)
        client.api = {
            GetTime = function() return self.now end, time = function() return 1700000000 + math.floor(self.now) end,
            IsInGuild = function() return not client.left end, GetGuildInfo = function() return "Guild", nil, nil, "Realm" end,
            UnitGUID = function() return client.identity.guid end,
            UnitFullName = function() return name, "Realm" end, GetRealmName = function() return "Realm" end,
            InCombatLockdown = function() return false end, issecretvalue = function() return false end,
            GetNumGuildMembers = function() return #self.members end,
            GetGuildRosterInfo = function(index)
                local row = self.members[index]
                return row.key, nil, nil, nil, nil, nil, nil, nil, true, nil, nil, nil, nil, nil, nil, nil, row.guid
            end,
            C_Timer = { NewTimer = function(delay, fn)
                local timer = { at = self.now + delay, fn = fn, order = (#self.timers + 1) * 100 + #self.frames }
                function timer:Cancel() self.cancelled = true end
                self.timers[#self.timers + 1] = timer
                return timer
            end },
            C_ChatInfo = {
                RegisterAddonMessagePrefix = function(prefix) client.prefix = prefix; return 0 end,
                SendAddonMessage = function(prefix, text, channel)
                    self.frames[#self.frames + 1] = { sender = client.identity.key, text = text, prefix = prefix, channel = channel, at = self.now }
                    if client.throttled then return 3 end
                    -- Blizzard delivers addon messages as later events, never
                    -- reentrantly inside the sender's SendAddonMessage call.
                    self.timers[#self.timers + 1] = { at = self.now, order = #self.frames, fn = function()
                        for _, peer in ipairs(self.clients) do
                            if not peer.drop then peer.G.HandleProfessionSyncAddonMessage(peer.sync, prefix, text, channel, client.identity.key) end
                        end
                    end }
                    return 0
                end,
            },
        }
        client.G.RefreshVisibleProfessionCatalog = function() client.refreshes = client.refreshes + 1 end
        client.sync = assert(client.G.CreateProfessionSync(client.api, client.db))
        assert(client.G.RegisterProfessionSync(client.sync))
        self.clients[#self.clients + 1] = client
        function client:save(identity, ids, capturedAt)
            local recipes = {}
            for _, id in ipairs(ids) do recipes[#recipes + 1] = { recipeID = id, name = "Recipe " .. id } end
            table.sort(recipes, function(a, b) return a.recipeID < b.recipeID end)
            assert(self.G.SaveProfessionSnapshot(self.db, identity, {
                complete = true, professionID = 164, professionName = "Blacksmithing", recipes = recipes,
                source = self.G.PROFESSION_SOURCE_GUILD_LINK, status = "cached", capturedAt = capturedAt or 1700000000,
            }, { guildMembershipVerified = true }))
        end
        function client:ready() assert(self.G.RefreshProfessionSyncRoster(self.sync)) end
        return client
    end
    function bus:count(kind)
        local n = 0
        for _, frame in ipairs(self.frames) do if frame.text:find("P1|" .. kind .. "|", 1, true) then n = n + 1 end end
        return n
    end
    return bus
end

T.test("profession login announces once only after roster readiness and never polls", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    T.assertEqual(#bus.frames, 0)
    T.assertFalse(a.G.LoginProfessionSync(a.sync))
    a:ready(); b:ready()
    T.assertTrue(a.G.LoginProfessionSync(a.sync))
    bus:advance(20)
    T.assertEqual(bus:count("A"), 1)
    a.G.LoginProfessionSync(a.sync); a:ready(); bus:advance(600)
    T.assertEqual(bus:count("A"), 1)
    T.assertEqual(a.prefix, "GC_PROF")
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
    local count = #bus.frames
    bus:advance(600)
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
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Cache hashes match")
end)

T.test("changed save converges online observers without duplicate downloads", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    a:ready(); b:ready(); c:ready()
    local before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8 })
    T.assertTrue(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    bus:advance(60)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertNotNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    T.assertEqual(bus:count("D"), 1)
    local count = #bus.frames
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8 }, 1700000100)
    a.G.PublishProfessionSyncSave(a.sync, 164, before)
    bus:advance(600)
    T.assertEqual(#bus.frames, count)
end)

T.test("profession sync refuses older conflicting or locally owned replacements", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local offline = bus:member("Offline")
    a:save(offline, { 3 }, 1700000000); b:save(offline, { 8 }, 1700000000)
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(30)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, offline.guid, 164).recipes[1].recipeID, 8)
    T.assertEqual(a.G.GetProfessionSyncRecord(a.db, offline.guid, 164).recipes[1].recipeID, 3)
    T.assertEqual(bus:count("D"), 0)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Conflict: fresh observation needed")
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
    local result = b.G.HandleProfessionSyncAddonMessage(b.sync, "GC_PROF", "garbage", "GUILD", "Stranger-Realm")
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
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(70)
    T.assertTrue(bus:count("D") <= 4)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Catch-up needed")
    bus:advance(300)
    b.G.RequestProfessionSync(b.sync, 164, "manual")
    b.left = true; T.assertFalse(b.G.RefreshProfessionSyncRoster(b.sync))
    local count = #bus.frames
    bus:advance(600)
    for index = count + 1, #bus.frames do T.assertFalse(bus.frames[index].sender == b.identity.key) end
end)

T.test("login hash exchange automatically repairs missing cached profession data", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }); a:ready(); b:ready()
    assert(b.G.LoginProfessionSync(b.sync))
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
    T.assertEqual(bus:count("D"), 0)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Conflict: fresh observation needed")
end)

T.test("dropped profession response preserves prior membership and expires without retries", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }, 1700000001); b:save(a.identity, { 3 }, 1700000000)
    a:ready(); b:ready()
    local send = a.api.C_ChatInfo.SendAddonMessage
    a.api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel)
        if frame:find("P1|D|", 1, true) then b.drop = true end
        local result = send(prefix, frame, channel)
        return result
    end
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(400)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164).recipes, 1)
    T.assertEqual(b.G.GetProfessionSyncStatus(b.sync, 164), "Catch-up needed")
    T.assertEqual(bus:count("D"), 1)
end)

T.test("unsolicited or wrong-recipient profession payloads do not modify caches", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    local payload = "P1|D|bob-realm|1-1|164|alice-realm;" .. a.identity.guid .. ";0123456789abcdef;1700000000;player;Blacksmithing;3:Recipe 3:"
    a.G.SendProfessionPayload(a.sync.transport, payload)
    bus:advance(10)
    T.assertNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    a.G.SendProfessionPayload(a.sync.transport, "P1|Q|stranger-realm|1-2|164|0123456789abcdef;manual")
    bus:advance(10)
    T.assertEqual(bus:count("C"), 0)
end)

T.test("real profession event startup does not require the gear companion", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 }); a:ready()
    local G, api, onEvent = b.G, b.api, nil
    api._G = api; setmetatable(api, { __index = _G })
    api.CreateFrame = function() return { RegisterEvent = function() end, SetScript = function(_, _, fn) onEvent = fn end } end
    api.C_GuildInfo = { GuildRoster = function() return true end }
    api.GuildGearMemoryDB = b.db
    G.RegisterSnapshotTestSlashCommand = function() end
    G.InitializeSavedDatabases = function() return b.db, nil, b.db end
    G.CreateProfessionLinkSaveController = function() return {} end
    G.RegisterProfessionLinkSaveController = function() return true end
    G.RecordLocalPlayerOwnership = function() return G.MarkLocalCharacterGUID(b.db, b.identity.guid) end
    local chunk = assert(loadfile("GuildGearMemory/Main.lua")); setfenv(chunk, api); chunk("GuildGearMemory", G)
    onEvent(nil, "ADDON_LOADED", "GuildGearMemory")
    b.sync = G.professionSync
    T.assertNotNil(b.sync)
    T.assertEqual(#bus.frames, 0)
    onEvent(nil, "PLAYER_LOGIN")
    onEvent(nil, "PLAYER_ENTERING_WORLD")
    onEvent(nil, "GUILD_ROSTER_UPDATE")
    bus:advance(80)
    T.assertNotNil(G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    onEvent(nil, "GUILD_ROSTER_UPDATE"); onEvent(nil, "PLAYER_ENTERING_WORLD"); bus:advance(600)
    T.assertEqual(bus:count("A"), 1)
end)

T.test("one login comparison catches up more than one profession within its finite budget", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3 })
    assert(a.G.SaveProfessionSnapshot(a.db, a.identity, {
        complete = true, professionID = 171, professionName = "Alchemy", capturedAt = 1700000000,
        source = "player", status = "cached", recipes = { { recipeID = 9, name = "Potion" } },
    }, { guildMembershipVerified = true }))
    a:ready(); b:ready()
    assert(b.G.LoginProfessionSync(b.sync)); bus:advance(150)
    T.assertNotNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
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
    b.sync.cursor[164] = identities[128].guid
    a.sync.cursor[164] = identities[32].guid
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(80)
    T.assertEqual(bus:count("D"), 1)
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(80)
    T.assertEqual(bus:count("D"), 1)
    T.assertEqual(b.G.GetProfessionSyncRecord(b.db, last.guid, 164).recipes[1].recipeID, 500)
end)

T.test("profession sync refuses secret input and unavailable secret checks", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:ready(); b:ready()
    b.api.issecretvalue = nil
    T.assertFalse(b.G.RequestProfessionSync(b.sync, 164, "manual"))
    b.api.issecretvalue = function(value) return value == "GC_PROF" end
    assert(a.G.RequestProfessionSync(a.sync, 164, "manual")); bus:advance(60)
    T.assertEqual(bus:count("C"), 0)
end)

T.test("maximum complete profession membership fits bounded frames and is stored atomically", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    local recipes = {}
    for index = 1, 4096 do recipes[index] = index end
    a:save(a.identity, recipes); a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(35)
    T.assertNil(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    bus:advance(230)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164).recipes, 4096)
    for _, frame in ipairs(bus.frames) do T.assertTrue(#frame.text <= 240) end
end)

T.test("login repair stops at eight records across professions without automatic retries", function()
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
    a:ready(); b:ready(); assert(a.G.LoginProfessionSync(a.sync)); bus:advance(400)
    T.assertEqual(bus:count("D"), 8)
    local frames = #bus.frames; bus:advance(600); T.assertEqual(#bus.frames, frames)
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
    assert(c.G.PublishProfessionSyncSave(c.sync, 164, before)); bus:advance(65)
    T.assertEqual(#a.G.GetProfessionSyncRecord(a.db, offline.guid, 164).recipes, 2)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, offline.guid, 164).recipes, 2)
    T.assertEqual(bus:count("D"), 1)
end)

T.test("changed saves during cooldown coalesce into one paced announcement and cancelled reverts stay silent", function()
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
    T.assertEqual(bus:count("A"), 2)
    T.assertEqual(#b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164).recipes, 3)
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3 }, 1700000100); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    before = a.G.GetProfessionSyncDigest(a.db, 164)
    a:save(a.identity, { 3, 8, 9 }, 1700000101); assert(a.G.PublishProfessionSyncSave(a.sync, 164, before))
    bus:advance(200)
    T.assertEqual(bus:count("A"), 2)
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
    T.assertEqual(bus:count("A"), 1)
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
    T.assertEqual(bus:count("A"), 1)
end)

T.test("received recipe labels prefer local metadata and retain unfamiliar peer labels", function()
    local bus = guild()
    local a, b = bus:client("Alice"), bus:client("Bob")
    a:save(a.identity, { 3, 8 }); b:save(b.identity, { 3 })
    a.db.professionRecipeIndex[164][3].name = "Foreign known"
    a.db.professionRecipeIndex[164][8].name = "Foreign unfamiliar"
    b.db.professionRecipeIndex[164][3].name = "Local known"
    a:ready(); b:ready()
    assert(b.G.RequestProfessionSync(b.sync, 164, "manual")); bus:advance(90)
    local record = assert(b.G.GetProfessionSyncRecord(b.db, a.identity.guid, 164))
    T.assertEqual(record.recipes[1].name, "Local known")
    T.assertEqual(record.recipes[2].name, "Foreign unfamiliar")
end)

T.test("an expired observed exchange releases the next independent queued source without retry", function()
    local bus = guild()
    local a, b, c = bus:client("Alice"), bus:client("Bob"), bus:client("Carol")
    a:save(a.identity, { 3 }); a:ready(); b:ready(); c:ready()
    c.sync.pending[164] = { reason = "save", preferredPeer = "bob-realm",
        following = { reason = "save", preferredPeer = "alice-realm", ready = true } }
    b.drop = true
    local digest = a.G.GetProfessionSyncDigest(a.db, 164)
    assert(a.G.SendProfessionPayload(a.sync.transport,
        "P1|Q|*|1-9|164|" .. digest .. ";save;;bob-realm"))
    bus:advance(290)
    T.assertNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    bus:advance(100)
    T.assertNotNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    T.assertEqual(bus:count("Q"), 2)
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
        "P1|Q|*|1-9|164|" .. digest .. ";save;;bob-realm"))
    bus:advance(390)
    T.assertNotNil(c.G.GetProfessionSyncRecord(c.db, a.identity.guid, 164))
    T.assertEqual(bus:count("Q"), 2)
end)

return { guild = guild }
