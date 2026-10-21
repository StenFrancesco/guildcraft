local T = require("tests.testlib")

local function client(results)
    local c = { now = 0, sent = {}, timers = {}, frames = {} }
    local api = setmetatable({}, { __index = _G })
    api._G = api
    api.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, GeneralError = 9 } }
    api.GetTime = function() return c.now end
    api.GetFramerate = function() return 60 end
    api.hooksecurefunc = function() end
    api.securecallfunction = function(fn, ...) return fn(...) end
    api.geterrorhandler = function() return function() end end
    -- WoW's xpcall accepts arguments; stock Lua 5.1 does not.
    api.xpcall = function(fn, handler, ...)
        local args, count = {...}, select("#", ...)
        return xpcall(function() return fn(unpack(args, 1, count)) end, handler)
    end
    api.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end end }, { __index = table })
    api.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return 0 end,
        SendAddonMessage = function(prefix, text, channel, target)
            c.sent[#c.sent + 1] = { prefix = prefix, text = text, channel = channel, target = target, at = c.now }
            return results and results[#c.sent] or 0
        end,
    }
    api.C_Timer = { NewTimer = function(delay, fn)
        local timer = { delay = delay, callback = fn, due = c.now + delay }
        function timer:Cancel() self.cancelled = true end
        c.timers[#c.timers + 1] = timer
        return timer
    end }
    api.CreateFrame = function()
        local frame = { scripts = {} }
        function frame:Hide() self.shown = false end
        function frame:Show() self.shown = true end
        function frame:SetScript(event, fn) self.scripts[event] = fn end
        function frame:RegisterEvent() end
        c.frames[#c.frames + 1] = frame
        return frame
    end
    local function loadLibrary(folder)
        local chunk = assert(loadfile(folder .. "/Libs/ChatThrottleLib/ChatThrottleLib.lua"))
        setfenv(chunk, api)
        chunk()
    end
    loadLibrary("The Guild Book")
    c.library = api.ChatThrottleLib
    loadLibrary("The Guild Book gear")
    T.assertEqual(api.ChatThrottleLib, c.library)
    T.assertEqual(#c.frames, 1)
    function c:update(seconds)
        self.now = self.now + seconds
        self.library.OnUpdate(self.library.Frame, seconds)
    end
    function c:advance(seconds)
        local untilTime = self.now + seconds
        while self.now < untilTime do
            local step = math.min(0.01, untilTime - self.now)
            local ready = {}
            for _, timer in ipairs(self.timers) do
                if not timer.cancelled and not timer.fired and timer.due <= self.now + step then
                    timer.fired = true
                    ready[#ready + 1] = timer
                end
            end
            self:update(step)
            -- Snapshot ready work so a newly scheduled zero timer yields.
            for _, timer in ipairs(ready) do
                if not timer.cancelled then timer.callback() end
            end
        end
    end
    return api, c
end

T.test("bundled CTL permits same-prefix bursts within its shared byte budget", function()
    local api, c = client()
    c:update(6)
    local completed = 0
    for index = 1, 30 do
        api.ChatThrottleLib:SendAddonMessage("BULK", "GC_PROF5", tostring(index), "GUILD", nil, "GC_PROF5",
            function(_, sent, result)
                T.assertTrue(sent)
                T.assertEqual(result, 0)
                completed = completed + 1
            end)
    end
    -- The fake API accepts every send. CTL has no proactive per-prefix clock.
    T.assertEqual(#c.sent, 30)
    T.assertEqual(completed, 30)
    for index, call in ipairs(c.sent) do
        T.assertEqual(call.at, 6)
        T.assertEqual(call.text, tostring(index))
    end
end)

T.test("bundled CTL bounds combined prefix traffic by its shared byte budget", function()
    local api, c = client()
    c:update(6)
    local text = string.rep("x", 240)
    for index = 1, 30 do
        local prefix = index % 2 == 0 and "GC_GEAR7" or "GC_PROF5"
        api.ChatThrottleLib:SendAddonMessage("BULK", prefix, text, "GUILD", nil, prefix)
    end
    local size = #text + c.library.MSG_OVERHEAD
    T.assertEqual(#c.sent, math.floor(c.library.BURST / size))
    c:update(1)
    T.assertEqual(#c.sent, math.floor((c.library.BURST + c.library.MAX_CPS) / size))
    local seen = {}
    for _, call in ipairs(c.sent) do seen[call.prefix] = true end
    T.assertTrue(seen.GC_GEAR7)
    T.assertTrue(seen.GC_PROF5)
end)

local function gear(api)
    local G = {}
    T.loadAddonFile("The Guild Book gear/Constants.lua", G)
    T.loadAddonFile("The Guild Book gear/SyncTransport.lua", G)
    return G, assert(G.CreateSyncTransport(api, function() end))
end

T.test("bundled CTL shares one queue for independent gear and profession addons", function()
    local api, c = client()
    local G, transport = gear(api)
    local P = {}
    T.loadAddonFile("The Guild Book/ProfessionTransport.lua", P)
    local profession = assert(P.CreateProfessionTransport(api, function() end))
    local completed = 0
    G.SendSyncPayload(transport, "gear", function(sent) T.assertTrue(sent); completed = completed + 1 end)
    P.SendProfessionPayload(profession, "recipes", "Alice-Realm", function(sent) T.assertTrue(sent); completed = completed + 1 end)
    T.assertEqual(#c.sent, 0)
    T.assertEqual(completed, 0)
    c:update(6)
    T.assertEqual(#c.sent, 2)
    T.assertEqual(completed, 2)
    T.assertEqual(c.sent[1].prefix, "GC_GEAR7")
    T.assertEqual(c.sent[2].channel, "WHISPER")
    T.assertEqual(c.sent[2].target, "Alice-Realm")
end)

T.test("bundled CTL defers Blizzard throttle until a later submission", function()
    local api, c = client({3, 0})
    local G, transport = gear(api)
    local completed = 0
    G.SendSyncPayload(transport, "gear", function(sent) T.assertTrue(sent); completed = completed + 1 end)
    c:update(6)
    T.assertEqual(#c.sent, 1)
    T.assertEqual(completed, 0)
    c:update(0.1)
    T.assertEqual(#c.sent, 1)
    c:update(0.4)
    T.assertEqual(#c.sent, 2)
    T.assertEqual(completed, 1)
end)

T.test("bundled CTL blocked prefix does not prevent another prefix from completing", function()
    local api, c = client({3, 0, 0})
    local G, transport = gear(api)
    local P = {}
    T.loadAddonFile("The Guild Book/ProfessionTransport.lua", P)
    local profession = assert(P.CreateProfessionTransport(api, function() end))
    local gearDone, professionDone = 0, 0
    G.SendSyncPayload(transport, "gear", function(sent) T.assertTrue(sent); gearDone = gearDone + 1 end)
    P.SendProfessionPayload(profession, "recipes", "Alice-Realm",
        function(sent) T.assertTrue(sent); professionDone = professionDone + 1 end)
    c:update(6)
    T.assertEqual(gearDone, 0)
    T.assertEqual(professionDone, 1)
    T.assertEqual(#c.sent, 2)
    c:update(0.4)
    T.assertEqual(gearDone, 1)
    T.assertEqual(professionDone, 1)
    T.assertEqual(c.sent[3].text, c.sent[1].text)
end)

T.test("bundled CTL persistent prefix throttle retains the frame without a completion deadline", function()
    local results = {}
    for index = 1, 25 do results[index] = 3 end
    local api, c = client(results)
    local G, transport = gear(api)
    local completed = 0
    G.SendSyncPayload(transport, string.rep("g", 500), function() completed = completed + 1 end)
    c:update(6)
    for index = 1, 20 do c:update(0.4) end
    T.assertEqual(#c.sent, 21)
    T.assertEqual(completed, 0)
    T.assertNotNil(transport.inFlight)
    T.assertEqual(#c.timers, 0)
    for _, call in ipairs(c.sent) do T.assertEqual(call.text, c.sent[1].text) end
end)

T.test("bundled CTL channel throttle fails both transports closed without retry", function()
    local api, c = client({8, 8})
    local G, transport = gear(api)
    local P = {}
    T.loadAddonFile("The Guild Book/ProfessionTransport.lua", P)
    local profession = assert(P.CreateProfessionTransport(api, function() end))
    local completed = 0
    G.SendSyncPayload(transport, string.rep("g", 500), function(sent, err)
        T.assertFalse(sent)
        T.assertEqual(err, "send-addon-message-failed:ChannelThrottle")
        completed = completed + 1
    end)
    P.SendProfessionPayload(profession, string.rep("p", 500), "Alice-Realm", function(sent, err)
        T.assertFalse(sent)
        T.assertEqual(err, "profession-send-addon-message-failed:ChannelThrottle")
        completed = completed + 1
    end)
    c:update(6)
    T.assertEqual(completed, 2)
    T.assertEqual(#transport.outboundFrames, 0)
    T.assertEqual(#profession.outboundFrames, 0)
    c:update(1)
    T.assertEqual(#c.sent, 2)
    T.assertEqual(#c.timers, 0)
end)

T.test("real CTL completion starts each transports pacing after a prefix throttle", function()
    for _, domain in ipairs({"gear", "profession"}) do
        local api, c = client({3, 0})
        local G, transport, interval
        if domain == "gear" then
            G, transport = gear(api)
            interval = G.SYNC_SEND_INTERVAL_SECONDS
            G.SendSyncPayload(transport, string.rep("g", 500))
        else
            G = {}
            T.loadAddonFile("The Guild Book/ProfessionTransport.lua", G)
            transport = assert(G.CreateProfessionTransport(api, function() end))
            interval = 0
            G.SendProfessionPayload(transport, string.rep("p", 500), "Alice-Realm")
        end
        c:update(6)
        T.assertEqual(#c.timers, 0)
        c:update(0.4)
        T.assertEqual(#c.sent, 2)
        T.assertEqual(#c.timers, 1)
        T.assertEqual(c.timers[1].delay, interval)
        T.assertNil(transport.inFlight)
        T.assertNotNil(transport.sendTimer)
        if interval > 0 then c:update(interval - 0.01) end
        T.assertEqual(#c.sent, 2)
        if interval > 0 then c.now = c.now + 0.01 end
        c.timers[1].callback()
        if interval == 0 then
            -- Returning to CTL need not immediately despool its shared queue.
            T.assertEqual(#c.sent, 2)
            T.assertNotNil(transport.inFlight)
            c:update(0.1)
        end
        T.assertEqual(#c.sent, 3)
        T.assertTrue(c.sent[3].at - c.sent[2].at >= interval - 0.000001)
        T.assertEqual(c.sent[3].text:sub(1, 9), c.sent[2].text:sub(1, 9))
        T.assertTrue(c.sent[3].text ~= c.sent[2].text)
    end
end)

T.test("multi-frame professions finish faster while sharing real CTL with paced gear", function()
    local api, c = client()
    c:update(6)
    local G, transport = gear(api)
    local P = {}
    T.loadAddonFile("The Guild Book/ProfessionTransport.lua", P)
    local profession = assert(P.CreateProfessionTransport(api, function() end))
    local gearPayload, professionPayload = string.rep("g", 700), string.rep("p", 222 * 40)
    local gearDone, professionDone, finishedAt = 0, 0, nil
    G.SendSyncPayload(transport, gearPayload, function(sent)
        T.assertTrue(sent)
        gearDone = gearDone + 1
    end)
    P.SendProfessionPayload(profession, professionPayload, "Alice-Realm", function(sent)
        T.assertTrue(sent)
        professionDone = professionDone + 1
        finishedAt = c.now
    end)
    T.assertEqual(#c.sent, 2)
    c:advance(30)
    T.assertEqual(gearDone, 1)
    T.assertEqual(professionDone, 1)
    -- Forty frames used to require at least 19.5 seconds of fixed waits.
    T.assertTrue(finishedAt - 6 < 19.5)
    local chunks, lastGearAt, bytes = {GC_GEAR7 = {}, GC_PROF5 = {}}, nil, 0
    for _, call in ipairs(c.sent) do
        local index, chunk = call.text:match("^F1|%d+|(%d+)|%d+|(.*)$")
        local frames = chunks[call.prefix]
        T.assertEqual(tonumber(index), #frames + 1)
        frames[#frames + 1] = chunk
        bytes = bytes + #call.text + c.library.MSG_OVERHEAD
        T.assertTrue(bytes <= c.library.BURST + c.library.MAX_CPS * (call.at - 6) + 0.000001)
        if call.prefix == "GC_GEAR7" then
            if lastGearAt then T.assertTrue(call.at - lastGearAt >= G.SYNC_SEND_INTERVAL_SECONDS - 0.000001) end
            lastGearAt = call.at
        else
            T.assertEqual(call.channel, "WHISPER")
            T.assertEqual(call.target, "Alice-Realm")
        end
    end
    T.assertEqual(table.concat(chunks.GC_GEAR7), gearPayload)
    T.assertEqual(table.concat(chunks.GC_PROF5), professionPayload)
    T.assertEqual(#transport.outboundFrames, 0)
    T.assertEqual(#profession.outboundFrames, 0)
end)

T.test("bundled CTL terminal failure aborts remaining gear frames", function()
    local api, c = client({12})
    local G, transport = gear(api)
    local completed = 0
    G.SendSyncPayload(transport, string.rep("g", 500), function(sent)
        T.assertFalse(sent)
        completed = completed + 1
    end)
    c:update(6)
    T.assertEqual(#c.sent, 1)
    T.assertEqual(completed, 1)
    T.assertEqual(#transport.outboundFrames, 0)
    c:update(1)
    T.assertEqual(#c.sent, 1)
end)

T.test("transports fail closed when ChatThrottleLib is missing", function()
    local api = client()
    api.ChatThrottleLib = nil
    local G, P = {}, {}
    T.loadAddonFile("The Guild Book gear/SyncTransport.lua", G)
    T.loadAddonFile("The Guild Book/ProfessionTransport.lua", P)
    local transport, err = G.CreateSyncTransport(api, function() end)
    T.assertNil(transport)
    T.assertEqual(err, "sync-chat-throttle-lib-unavailable")
    transport, err = P.CreateProfessionTransport(api, function() end)
    T.assertNil(transport)
    T.assertEqual(err, "profession-chat-throttle-lib-unavailable")
end)

T.test("gear cancellation leaves only the frame already submitted to CTL", function()
    local api, c = client()
    local G, transport = gear(api)
    local completed = 0
    local ok, err, group = G.SendSyncPayload(transport, string.rep("x", 500), function() completed = completed + 1 end)
    T.assertTrue(ok)
    T.assertTrue(G.CancelSyncPayload(transport, group))
    c:update(6)
    T.assertEqual(#c.sent, 1)
    T.assertEqual(completed, 0)
    c.timers[1].callback()
    T.assertEqual(#transport.outboundFrames, 0)
    c:update(1)
    T.assertEqual(#c.sent, 1)
end)

T.test("profession cancellation ignores the real CTL send without starting more frames", function()
    local api, c = client()
    local G = {}
    T.loadAddonFile("The Guild Book/ProfessionTransport.lua", G)
    local transport = assert(G.CreateProfessionTransport(api, function() end))
    local completed = 0
    G.SendProfessionPayload(transport, string.rep("x", 500), "Alice-Realm", function(sent)
        T.assertFalse(sent)
        completed = completed + 1
    end)
    G.CancelProfessionTransport(transport)
    T.assertEqual(completed, 1)
    c:update(6)
    T.assertEqual(#c.sent, 1)
    T.assertEqual(completed, 1)
    T.assertEqual(#c.timers, 0)
    T.assertEqual(#transport.outboundFrames, 0)
end)
