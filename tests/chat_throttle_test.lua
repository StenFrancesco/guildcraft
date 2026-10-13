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
            c.sent[#c.sent + 1] = { prefix = prefix, channel = channel, target = target }
            return results and results[#c.sent] or 0
        end,
    }
    api.C_Timer = { NewTimer = function(delay, fn)
        local timer = { delay = delay, callback = fn }
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
    loadLibrary("GuildGearMemory")
    c.library = api.ChatThrottleLib
    loadLibrary("DysgearMemory")
    T.assertEqual(api.ChatThrottleLib, c.library)
    T.assertEqual(#c.frames, 1)
    function c:update(seconds)
        self.now = self.now + seconds
        self.library.OnUpdate(self.library.Frame, seconds)
    end
    return api, c
end

local function gear(api)
    local G = {}
    T.loadAddonFile("DysgearMemory/Constants.lua", G)
    T.loadAddonFile("DysgearMemory/SyncTransport.lua", G)
    return G, assert(G.CreateSyncTransport(api, function() end))
end

T.test("bundled CTL shares one queue for independent gear and profession addons", function()
    local api, c = client()
    local G, transport = gear(api)
    local P = {}
    T.loadAddonFile("GuildGearMemory/ProfessionTransport.lua", P)
    local profession = assert(P.CreateProfessionTransport(api, function() end))
    local completed = 0
    G.SendSyncPayload(transport, "gear", function(sent) T.assertTrue(sent); completed = completed + 1 end)
    P.SendProfessionPayload(profession, "recipes", "Alice-Realm", function(sent) T.assertTrue(sent); completed = completed + 1 end)
    T.assertEqual(#c.sent, 0)
    T.assertEqual(completed, 0)
    c:update(6)
    T.assertEqual(#c.sent, 2)
    T.assertEqual(completed, 2)
    T.assertEqual(c.sent[1].prefix, "GC_GEAR")
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
    T.loadAddonFile("DysgearMemory/SyncTransport.lua", G)
    T.loadAddonFile("GuildGearMemory/ProfessionTransport.lua", P)
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
    T.loadAddonFile("GuildGearMemory/ProfessionTransport.lua", G)
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
