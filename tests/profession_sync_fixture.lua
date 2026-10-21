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
        local identity = { key = name .. "-Realm", name = name, realm = "Realm", guid = "Player-1-" .. string.format("%X", #self.members + 1), online = false }
        self.members[#self.members + 1] = identity
        return identity
    end
    function bus:client(name)
        local client = { identity = self:member(name), G = {}, refreshes = 0 }
        client.identity.online = true
        client.visibleCatalog = {}
        for _, file in ipairs({ "Constants", "ProfessionSnapshot", "ProfessionIndex", "Storage", "CharacterIdentity", "ProfessionSyncData", "ProfessionTransport", "ProfessionSync" }) do
            local path = "The Guild Book/" .. file .. ".lua"
            local handle = io.open(path, "r")
            if handle then handle:close(); T.loadAddonFile(path, client.G) end
        end
        T.assertEqual(type(client.G.CreateProfessionSync), "function")
        client.db = client.G.InitializeDatabase(nil)
        client.api = {
            GetTime = function() return self.now end, time = function() return 999 end,
            GetServerTime = function() return 1700000000 + math.floor(self.now) end,
            random = function(low) return low end,
            IsInGuild = function() return not client.left end, GetGuildInfo = function() return "Guild", nil, nil, "Realm" end,
            UnitGUID = function() return client.identity.guid end,
            UnitFullName = function() return name, "Realm" end, GetRealmName = function() return "Realm" end,
            InCombatLockdown = function() return false end, issecretvalue = function() return false end,
            GetNumGuildMembers = function() return #self.members end,
            GetGuildRosterInfo = function(index)
                local row = self.members[index]
                return row.key, nil, nil, nil, nil, nil, nil, nil, row.online, nil, nil, nil, nil, nil, nil, nil, row.guid
            end,
            C_Timer = { NewTimer = function(delay, fn)
                local timer = { at = self.now + delay, fn = fn, order = (#self.timers + 1) * 100 + #self.frames }
                function timer:Cancel() self.cancelled = true end
                self.timers[#self.timers + 1] = timer
                return timer
            end },
            C_ChatInfo = {
                RegisterAddonMessagePrefix = function(prefix) client.prefix = prefix; return 0 end,
                SendAddonMessage = function(prefix, text, channel, target)
                    self.frames[#self.frames + 1] = { sender = client.identity.key, text = text, prefix = prefix, channel = channel, target = target, at = self.now }
                    if client.throttled then return 3 end
                    -- Blizzard delivers addon messages as later events, never
                    -- reentrantly inside the sender's SendAddonMessage call.
                    self.timers[#self.timers + 1] = { at = self.now, order = #self.frames, fn = function()
                        for _, peer in ipairs(self.clients) do
                            if not peer.drop and (channel == "GUILD" or target == peer.identity.key) then
                                peer.G.HandleProfessionSyncAddonMessage(peer.sync, prefix, text, channel, client.identity.key)
                            end
                        end
                    end }
                    return 0
                end,
            },
        }
        T.mockChatThrottle(client.api)
        client.G.RefreshVisibleProfessionCatalog = function()
            client.refreshes = client.refreshes + 1
            client.visibleCatalog = client.G.GetProfessionSyncManifest(client.db, 164) or {}
        end
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
    function bus:count(kind, sender)
        local n = 0
        for _, frame in ipairs(self.frames) do
            if (not sender or frame.sender == sender) and (frame.text:find("P5|" .. kind .. "|", 1, true) or (kind == "D" and frame.text:match("^F1|%d+|001|%d+|Z1|"))) then n = n + 1 end
        end
        return n
    end
    return bus
end


return guild
