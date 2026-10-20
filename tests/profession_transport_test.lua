local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("The Guild Book/ProfessionTransport.lua", GGM)
    return GGM
end

local function makeApi(options)
    options = options or {}
    local c = {
        now = 10,
        timers = {},
        sent = {},
        registered = {},
        sendResults = options.sendResults or {},
        registerResult = options.registerResult,
        enum = options.enum,
    }

    local api = {
        C_ChatInfo = {},
        C_Timer = {},
        Enum = c.enum,
        GetTime = function() return c.now end,
    }

    api.C_ChatInfo.RegisterAddonMessagePrefix = function(prefix)
        table.insert(c.registered, prefix)
        if c.registerResult == nil then return 0 end
        return c.registerResult
    end

    api.C_ChatInfo.SendAddonMessage = function(prefix, frame, channel, target)
        table.insert(c.sent, {
            prefix = prefix,
            frame = frame,
            channel = channel,
            target = target,
            at = c.now,
        })
        return c.sendResults[#c.sent] or 0
    end

    api.C_Timer.NewTimer = function(delay, callback)
        local timer = { delay = delay, callback = callback, cancelled = false, fired = false }
        function timer:Cancel() self.cancelled = true end
        function timer:FireEvenIfCancelled()
            if self.fired then return end
            self.fired = true
            c.now = c.now + self.delay
            self.callback()
        end
        function timer:Fire()
            if self.cancelled then return end
            self:FireEvenIfCancelled()
        end
        table.insert(c.timers, timer)
        return timer
    end

    T.mockChatThrottle(api)
    return api, c
end

T.test("profession completion waits for throttle callback and ignores cancelled work", function()
    local G = loadModules()
    local api, c = makeApi()
    local callback
    api.ChatThrottleLib.SendAddonMessage = function(_, priority, prefix, frame, channel, target, queue, fn, arg)
        T.assertEqual(priority, "BULK")
        T.assertEqual(channel, "WHISPER")
        T.assertEqual(target, "Alice-Silvermoon")
        callback = function() fn(arg, true, 0) end
    end
    local finished = {}
    local transport = assert(G.CreateProfessionTransport(api, function() end))
    T.assertTrue(G.SendProfessionPayload(transport, string.rep("x", 500), "Alice-Silvermoon", function(sent)
        finished[#finished + 1] = sent
    end))
    T.assertEqual(#c.sent, 0)
    T.assertEqual(#c.timers, 0)
    T.assertEqual(#finished, 0)
    G.CancelProfessionTransport(transport)
    T.assertEqual(#finished, 1)
    T.assertFalse(finished[1])
    callback()
    T.assertEqual(#c.timers, 0)
    T.assertEqual(#finished, 1)
end)

local function makeFrame(messageID, index, total, chunk)
    return string.format("F1|%06d|%03d|%03d|%s", messageID, index, total, chunk)
end

local function receive(GGM, transport, frame, sender, prefix, channel)
    return GGM.ReceiveProfessionFrame(transport, prefix or "GC_PROF4", frame, channel or "GUILD", sender or "Alice-Silvermoon")
end

T.test("profession fragment identity includes the delivery channel", function()
    local G = loadModules()
    local received = {}
    local transport = assert(G.CreateProfessionTransport(makeApi(), function(payload, sender, channel)
        received[#received + 1] = { payload = payload, channel = channel }
        return "complete"
    end))
    receive(G, transport, makeFrame(1, 1, 2, "guild"))
    receive(G, transport, makeFrame(1, 2, 2, "whisper"), nil, nil, "WHISPER")
    T.assertEqual(#received, 0)
    receive(G, transport, makeFrame(1, 1, 2, "private"), nil, nil, "WHISPER")
    T.assertEqual(received[1].payload, "privatewhisper")
    T.assertEqual(received[1].channel, "WHISPER")
end)

T.test("profession transport registers GC_PROF4 and reports API registration failures", function()
    local GGM = loadModules()
    local api, c = makeApi()
    local transport = assert(GGM.CreateProfessionTransport(api, function() end))

    local ok, err = GGM.RegisterProfessionTransport(transport)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(c.registered[1], "GC_PROF4")

    c.registerResult = 1
    local failed, failedErr = GGM.RegisterProfessionTransport(transport)
    T.assertFalse(failed)
    T.assertEqual(failedErr, "profession-prefix-register-failed:DuplicatePrefix")
end)

T.test("profession transport yields bounded ordered WHISPER frames without a fixed delay", function()
    local GGM = loadModules()
    local api, c = makeApi()
    local transport = assert(GGM.CreateProfessionTransport(api, function() end))
    local payload = string.rep("recipe:", 100)

    local ok, err = GGM.SendProfessionPayload(transport, payload, "Bob-Silvermoon")
    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(#c.sent, 1)
    T.assertTrue(#c.timers > 0)

    for _, timer in ipairs(c.timers) do
        T.assertEqual(timer.delay, 0)
        timer:Fire()
    end

    T.assertTrue(#c.sent > 1)
    for index, call in ipairs(c.sent) do
        T.assertEqual(call.prefix, "GC_PROF4")
        T.assertEqual(call.channel, "WHISPER")
        T.assertEqual(call.target, "Bob-Silvermoon")
        T.assertTrue(#call.frame <= 240)
        T.assertEqual(call.at, 10)
        T.assertEqual(tonumber(call.frame:match("^F1|%d+|(%d+)|")), index)
    end
end)

T.test("profession transport accepts a 64 KiB payload but bounds the queue and rejects larger payloads", function()
    local GGM = loadModules()
    local api = makeApi()
    local transport = assert(GGM.CreateProfessionTransport(api, function() end))
    local maxPayload = string.rep("x", 65536)

    local ok, err = GGM.SendProfessionPayload(transport, maxPayload)
    T.assertTrue(ok)
    T.assertNil(err)
    T.assertTrue(#transport.outboundFrames <= 640)

    local tooLarge, tooLargeErr = GGM.SendProfessionPayload(transport, maxPayload .. "x")
    T.assertFalse(tooLarge)
    T.assertEqual(tooLargeErr, "profession-payload-too-large")

    local queueFull, queueErr = GGM.SendProfessionPayload(transport, maxPayload)
    T.assertTrue(queueFull)
    T.assertNil(queueErr)
    local overflow, overflowErr = GGM.SendProfessionPayload(transport, maxPayload)
    T.assertFalse(overflow)
    T.assertEqual(overflowErr, "profession-outbound-queue-full")
end)

T.test("profession transport reassembles all chunks atomically and returns the handler result", function()
    local GGM = loadModules()
    local api = makeApi()
    local payload = string.rep("profession-data|", 25)
    local receivedPayload, receivedSender
    local transport = assert(GGM.CreateProfessionTransport(api, function(value, sender)
        receivedPayload, receivedSender = value, sender
        return "handled", "accepted"
    end))

    local partial, partialErr = receive(GGM, transport, makeFrame(7, 2, 2, payload:sub(201)), "Crafter-Silvermoon")
    T.assertEqual(partial, "partial")
    T.assertNil(partialErr)
    T.assertNil(receivedPayload)

    local state, err = receive(GGM, transport, makeFrame(7, 1, 2, payload:sub(1, 200)), "Crafter-Silvermoon")
    T.assertEqual(state, "handled")
    T.assertEqual(err, "accepted")
    T.assertEqual(receivedPayload, payload)
    T.assertEqual(receivedSender, "Crafter-Silvermoon")
    T.assertEqual(next(transport.inboundAssemblies), nil)
end)

T.test("profession transport ignores identical duplicate chunks and rejects conflicting duplicates", function()
    local GGM = loadModules()
    local api = makeApi()
    local handled = 0
    local transport = assert(GGM.CreateProfessionTransport(api, function() handled = handled + 1 end))

    local first = makeFrame(8, 1, 2, "first")
    T.assertEqual(receive(GGM, transport, first), "partial")
    T.assertEqual(receive(GGM, transport, first), "partial")
    T.assertEqual(transport.inboundAssemblies["Alice-Silvermoon"]["GUILD:000008"].received, 1)

    local state, err = receive(GGM, transport, makeFrame(8, 1, 2, "other"))
    T.assertNil(state)
    T.assertEqual(err, "profession-frame-conflict")
    T.assertNil(transport.inboundAssemblies["Alice-Silvermoon"])
    T.assertEqual(handled, 0)
end)

T.test("profession transport ignores other prefixes and channels and rejects malformed frames", function()
    local GGM = loadModules()
    local api = makeApi()
    local handled = 0
    local transport = assert(GGM.CreateProfessionTransport(api, function() handled = handled + 1 end))

    local wrongPrefix, prefixErr = receive(GGM, transport, "nonsense", "Alice-Silvermoon", "OTHER", "GUILD")
    local wrongChannel, channelErr = receive(GGM, transport, "nonsense", "Alice-Silvermoon", "GC_PROF", "PARTY")
    T.assertEqual(wrongPrefix, "ignored")
    T.assertNil(prefixErr)
    T.assertEqual(wrongChannel, "ignored")
    T.assertNil(channelErr)

    local state, err = receive(GGM, transport, "bad-frame")
    T.assertNil(state)
    T.assertEqual(err, "profession-frame-invalid")
    local oversized, oversizedErr = receive(GGM, transport, string.rep("x", 241))
    T.assertNil(oversized)
    T.assertEqual(oversizedErr, "profession-frame-too-large")
    T.assertEqual(handled, 0)
end)

T.test("profession transport expires incomplete assemblies after five minutes", function()
    local GGM = loadModules()
    local api, c = makeApi()
    local transport = assert(GGM.CreateProfessionTransport(api, function() error("partial message must not dispatch") end))

    T.assertEqual(receive(GGM, transport, makeFrame(9, 1, 2, "old")), "partial")
    c.now = c.now + 301
    T.assertEqual(receive(GGM, transport, makeFrame(10, 1, 2, "new")), "partial")
    T.assertNil(transport.inboundAssemblies["Alice-Silvermoon"]["GUILD:000009"])
    T.assertNotNil(transport.inboundAssemblies["Alice-Silvermoon"]["GUILD:000010"])
end)

T.test("profession transport caps simultaneous reassemblies at four", function()
    local GGM = loadModules()
    local api = makeApi()
    local transport = assert(GGM.CreateProfessionTransport(api, function() end))

    for index = 1, 4 do
        local state, err = receive(GGM, transport, makeFrame(index, 1, 2, "x"), "Sender" .. index .. "-Silvermoon")
        T.assertEqual(state, "partial")
        T.assertNil(err)
    end
    local state, err = receive(GGM, transport, makeFrame(5, 1, 2, "x"), "Overflow-Silvermoon")
    T.assertNil(state)
    T.assertEqual(err, "profession-inbound-assembly-limit")
    T.assertNil(transport.inboundAssemblies["Overflow-Silvermoon"])
end)

T.test("profession transport cancellation clears work and makes stale timers generation-safe", function()
    local GGM = loadModules()
    local api, c = makeApi()
    local transport = assert(GGM.CreateProfessionTransport(api, function() end))
    local ok = GGM.SendProfessionPayload(transport, string.rep("z", 700))
    T.assertTrue(ok)
    local staleTimer = c.timers[1]
    T.assertEqual(receive(GGM, transport, makeFrame(11, 1, 2, "partial")), "partial")

    GGM.CancelProfessionTransport(transport)
    T.assertEqual(#transport.outboundFrames, 0)
    T.assertEqual(next(transport.inboundAssemblies), nil)
    local sentAtCancel = #c.sent
    staleTimer:FireEvenIfCancelled()
    T.assertEqual(#c.sent, sentAtCancel)

    local reused, reusedErr = GGM.SendProfessionPayload(transport, "after-cancel")
    T.assertTrue(reused)
    T.assertNil(reusedErr)
    T.assertEqual(#c.sent, sentAtCancel + 1)
end)

T.test("profession transport reuse after cancellation has no leftover fixed delay", function()
    local GGM = loadModules()
    local api, c = makeApi()
    local transport = assert(GGM.CreateProfessionTransport(api, function() end))

    T.assertTrue(GGM.SendProfessionPayload(transport, "before-cancel"))
    GGM.CancelProfessionTransport(transport)
    local sentAtCancel = #c.sent
    local ok, err = GGM.SendProfessionPayload(transport, "after-cancel")

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(#c.sent, sentAtCancel + 1)
    T.assertEqual(#c.timers, 0)
end)

T.test("profession transport does not schedule overlapping timers from completion callbacks", function()
    local GGM = loadModules()
    local api, c = makeApi()
    local transport = assert(GGM.CreateProfessionTransport(api, function() end))
    local followupQueued = false

    local ok = GGM.SendProfessionPayload(transport, "first", nil, function(sent)
        T.assertTrue(sent)
        followupQueued = GGM.SendProfessionPayload(transport, string.rep("f", 700))
    end)

    T.assertTrue(ok)
    T.assertTrue(followupQueued)
    T.assertEqual(#c.timers, 1)
    T.assertEqual(#c.sent, 1)
    T.assertEqual(c.timers[1].delay, 0)
end)

T.test("profession completion can cancel and reuse without losing the new continuation", function()
    local G = loadModules()
    local api, c = makeApi()
    local transport = assert(G.CreateProfessionTransport(api, function() end))
    local completed, reused = 0, false
    T.assertTrue(G.SendProfessionPayload(transport, "first", nil, function(sent)
        T.assertTrue(sent)
        G.CancelProfessionTransport(transport)
        reused = G.SendProfessionPayload(transport, string.rep("r", 500), nil, function(success)
            T.assertTrue(success)
            completed = completed + 1
        end)
    end))
    T.assertTrue(reused)
    T.assertEqual(#c.sent, 2)
    T.assertEqual(#c.timers, 1)
    T.assertEqual(transport.sendTimer, c.timers[1])
    for _, timer in ipairs(c.timers) do timer:Fire() end
    T.assertEqual(completed, 1)
    T.assertEqual(#c.sent, 4)
    T.assertNil(transport.sendTimer)
    T.assertNil(transport.inFlight)
end)

T.test("duplicate successful CTL callbacks do not consume the next profession frame", function()
    local G = loadModules()
    local api, c = makeApi()
    local pending, completed = {}, 0
    api.ChatThrottleLib.SendAddonMessage = function(_, priority, prefix, frame, channel, target, queue, fn, arg)
        pending[#pending + 1] = function() fn(arg, true, 0) end
    end
    local transport = assert(G.CreateProfessionTransport(api, function() end))
    T.assertTrue(G.SendProfessionPayload(transport, string.rep("x", 300), nil, function(sent)
        T.assertTrue(sent)
        completed = completed + 1
    end))
    pending[1]()
    T.assertEqual(#c.timers, 1)
    c.timers[1]:Fire()
    T.assertEqual(#pending, 2)
    local secondFrame = transport.inFlight
    pending[1]()
    T.assertEqual(transport.inFlight, secondFrame)
    T.assertEqual(completed, 0)
    pending[2]()
    pending[2]()
    T.assertEqual(completed, 1)
    T.assertEqual(#transport.outboundFrames, 0)
    T.assertNil(transport.sendTimer)
end)

T.test("profession transport aborts queued frames and reports API send failures without retry", function()
    local GGM = loadModules()
    local api, c = makeApi({ sendResults = { 0, 3 } })
    local failures, completionCalls = {}, 0
    local transport = assert(GGM.CreateProfessionTransport(api, function() end, function(err)
        table.insert(failures, err)
    end))
    local ok, err = GGM.SendProfessionPayload(transport, string.rep("q", 700), nil, function(sent, finishErr)
        completionCalls = completionCalls + 1
        T.assertFalse(sent)
        T.assertEqual(finishErr, "profession-send-addon-message-failed:AddonMessageThrottle")
    end)
    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(#c.sent, 1)

    c.timers[1]:Fire()

    T.assertEqual(#c.sent, 2)
    T.assertEqual(#transport.outboundFrames, 0)
    T.assertNil(transport.sendTimer)
    T.assertEqual(#failures, 1)
    T.assertEqual(failures[1], "profession-send-addon-message-failed:AddonMessageThrottle")
    T.assertEqual(completionCalls, 1)
end)

T.test("profession transport accepts boolean and enum API success values", function()
    local GGM = loadModules()
    local api = makeApi({ enum = {
        AddonMessagePrefixResult = { Success = "REGISTERED" },
        SendAddonMessageResult = { Success = "SENT" },
    } })
    api.C_ChatInfo.RegisterAddonMessagePrefix = function() return "REGISTERED" end
    api.C_ChatInfo.SendAddonMessage = function() return "SENT" end
    local transport = assert(GGM.CreateProfessionTransport(api, function() end))

    local registered, registerErr = GGM.RegisterProfessionTransport(transport)
    local sent, sendErr = GGM.SendProfessionPayload(transport, "small")
    T.assertTrue(registered)
    T.assertNil(registerErr)
    T.assertTrue(sent)
    T.assertNil(sendErr)
end)

T.test("profession transport fails the active group if continuation timer creation fails", function()
    local GGM = loadModules()
    local api, c = makeApi()
    api.C_Timer.NewTimer = function() return nil end
    local failures = {}
    local transport = assert(GGM.CreateProfessionTransport(api, function() end, function(err)
        table.insert(failures, err)
    end))
    local ok, err = GGM.SendProfessionPayload(transport, string.rep("t", 700))

    T.assertFalse(ok)
    T.assertEqual(err, "profession-send-timer-create-failed")
    T.assertEqual(#c.sent, 1)
    T.assertEqual(#transport.outboundFrames, 0)
    T.assertEqual(#failures, 1)
    T.assertEqual(failures[1], err)
end)

T.test("profession transport aborts a whisper when the target goes offline between frames", function()
    local GGM = loadModules()
    local api, c = makeApi()
    local online = true
    local presenceChecks, failures, completionCalls = 0, {}, 0
    local transport = assert(GGM.CreateProfessionTransport(api, function() end, function(err)
        failures[#failures + 1] = err
    end))
    transport.canSendTarget = function(target)
        presenceChecks = presenceChecks + 1
        T.assertEqual(target, "Bob-Silvermoon")
        return online
    end

    local ok, err = GGM.SendProfessionPayload(transport, string.rep("offline-aware", 50), "Bob-Silvermoon", function(sent, finishErr)
        completionCalls = completionCalls + 1
        T.assertFalse(sent)
        T.assertEqual(finishErr, "profession-target-unavailable")
    end)
    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(#c.sent, 1)
    T.assertEqual(presenceChecks, 1)
    T.assertEqual(#c.timers, 1)

    online = false
    c.timers[1]:Fire()

    T.assertEqual(#c.sent, 1)
    T.assertEqual(presenceChecks, 2)
    T.assertEqual(#transport.outboundFrames, 0)
    T.assertNil(transport.sendTimer)
    T.assertEqual(#c.timers, 1)
    T.assertEqual(transport.lastSendError, "profession-target-unavailable")
    T.assertEqual(#failures, 1)
    T.assertEqual(failures[1], "profession-target-unavailable")
    T.assertEqual(completionCalls, 1)

    online = true
    c.timers[1]:FireEvenIfCancelled()
    T.assertEqual(#c.sent, 1)
    T.assertEqual(#failures, 1)
    T.assertEqual(completionCalls, 1)
end)

T.test("profession transport fails closed for unknown or throwing target presence", function()
    local callbacks = {
        function() return nil end,
        function() error("presence API unavailable") end,
    }

    for _, canSendTarget in ipairs(callbacks) do
        local GGM = loadModules()
        local api, c = makeApi()
        local failures, completionCalls, presenceChecks = {}, 0, 0
        local transport = assert(GGM.CreateProfessionTransport(api, function() end, function(err)
            failures[#failures + 1] = err
        end))
        transport.canSendTarget = function(target)
            presenceChecks = presenceChecks + 1
            T.assertEqual(target, "Bob-Silvermoon")
            return canSendTarget()
        end

        local ok, err = GGM.SendProfessionPayload(transport, "private update", "Bob-Silvermoon", function(sent, finishErr)
            completionCalls = completionCalls + 1
            T.assertFalse(sent)
            T.assertEqual(finishErr, "profession-target-unavailable")
        end)

        T.assertFalse(ok)
        T.assertEqual(err, "profession-target-unavailable")
        T.assertEqual(presenceChecks, 1)
        T.assertEqual(#c.sent, 0)
        T.assertEqual(#c.timers, 0)
        T.assertEqual(#transport.outboundFrames, 0)
        T.assertEqual(#failures, 1)
        T.assertEqual(failures[1], "profession-target-unavailable")
        T.assertEqual(completionCalls, 1)
    end
end)

T.test("profession transport leaves guild sends independent of target presence", function()
    local GGM = loadModules()
    local api, c = makeApi()
    local presenceChecks = 0
    local transport = assert(GGM.CreateProfessionTransport(api, function() end))
    transport.canSendTarget = function()
        presenceChecks = presenceChecks + 1
        return false
    end

    local ok, err = GGM.SendProfessionPayload(transport, string.rep("guild update", 50))
    T.assertTrue(ok)
    T.assertNil(err)
    for _, timer in ipairs(c.timers) do timer:Fire() end

    T.assertTrue(#c.sent > 1)
    T.assertEqual(presenceChecks, 0)
    for _, call in ipairs(c.sent) do
        T.assertEqual(call.prefix, "GC_PROF4")
        T.assertEqual(call.channel, "GUILD")
        T.assertNil(call.target)
    end
end)

T.test("profession transport does not send after target-presence callback cancels the group", function()
    local GGM = loadModules()
    local api, c = makeApi()
    local failures, completions = {}, 0
    local transport = assert(GGM.CreateProfessionTransport(api, function() end, function(err)
        failures[#failures + 1] = err
    end))
    transport.canSendTarget = function()
        GGM.CancelProfessionTransport(transport)
        return true
    end

    local ok, err = GGM.SendProfessionPayload(transport, "cancel during presence check", "Bob-Silvermoon", function(sent, finishErr)
        completions = completions + 1
        T.assertFalse(sent)
        T.assertEqual(finishErr, "profession-send-cancelled")
    end)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(#c.sent, 0)
    T.assertEqual(#transport.outboundFrames, 0)
    T.assertNil(transport.sendTimer)
    T.assertEqual(#failures, 0)
    T.assertEqual(completions, 1)
end)

return T
