local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/SyncTransport.lua", GGM)
    return GGM
end

local function makeApi(sendResults)
    local timers = {}
    local sendCalls = {}
    local now = 100
    local registerResult = 0

    local api = {
        C_ChatInfo = {},
        C_Timer = {},
        GetTime = function()
            return now
        end,
    }

    api.C_ChatInfo.RegisterAddonMessagePrefix = function(prefix)
        T.assertEqual(prefix, "DysGuildGear")
        return registerResult
    end

    api.C_ChatInfo.SendAddonMessage = function(prefix, message, chatType, target)
        table.insert(sendCalls, {
            prefix = prefix,
            message = message,
            chatType = chatType,
            target = target,
        })
        local index = #sendCalls
        return sendResults and sendResults[index] or 0
    end

    api.C_Timer.NewTimer = function(delay, callback)
        local timer = { delay = delay, fired = false }
        function timer:Fire()
            if not self.fired then
                self.fired = true
                callback()
            end
        end
        table.insert(timers, timer)
        return timer
    end

    local function setRegisterResult(value)
        registerResult = value
    end

    local function drainTimers()
        local index = 1
        while index <= #timers do
            timers[index]:Fire()
            index = index + 1
        end
    end

    return api, timers, sendCalls, setRegisterResult, drainTimers
end

T.test("transport registers the addon prefix and treats non-success as failure", function()
    local GGM = loadModules()
    local api, _, _, setRegisterResult = makeApi()
    local transport = assert(GGM.CreateSyncTransport(api, function() end))

    local ok, err = GGM.RegisterSyncPrefix(transport)
    T.assertTrue(ok)
    T.assertNil(err)

    setRegisterResult(2)
    local failed, failedErr = GGM.RegisterSyncPrefix(transport)
    T.assertFalse(failed)
    T.assertEqual(failedErr, "prefix-register-failed:InvalidPrefix")
end)

T.test("transport frames large logical payloads below the addon-message limit and sends only on GUILD", function()
    local GGM = loadModules()
    local api, _, sendCalls, _, drainTimers = makeApi()
    local transport = assert(GGM.CreateSyncTransport(api, function() end))
    local payload = string.rep("a", 700)

    local ok, err = GGM.SendSyncPayload(transport, payload)
    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(#sendCalls, 1)

    drainTimers()

    T.assertTrue(#sendCalls > 1)
    for _, call in ipairs(sendCalls) do
        T.assertEqual(call.prefix, GGM.SYNC_PREFIX)
        T.assertEqual(call.chatType, "GUILD")
        T.assertNil(call.target)
        T.assertTrue(#call.message <= GGM.SYNC_MAX_ADDON_MESSAGE_BYTES)
    end
end)

T.test("transport reassembles a framed logical payload before invoking the handler", function()
    local GGM = loadModules()
    local senderApi, _, sendCalls, _, drainTimers = makeApi()
    local senderTransport = assert(GGM.CreateSyncTransport(senderApi, function() end))
    local payload = string.rep("payload:|", 90)
    assert(GGM.SendSyncPayload(senderTransport, payload))
    drainTimers()

    local receivedPayload
    local receivedSender
    local receiverApi = makeApi()
    local receiverTransport = assert(GGM.CreateSyncTransport(receiverApi, function(sender, logicalPayload)
        receivedSender = sender
        receivedPayload = logicalPayload
        return "handled", nil
    end))

    for index = #sendCalls, 1, -1 do
        GGM.HandleSyncTransportMessage(receiverTransport, GGM.SYNC_PREFIX, sendCalls[index].message, "GUILD", "Alice-Silvermoon")
    end

    T.assertEqual(receivedSender, "Alice-Silvermoon")
    T.assertEqual(receivedPayload, payload)
end)

T.test("transport ignores unrelated prefix and channel without invoking the logical handler", function()
    local GGM = loadModules()
    local api = makeApi()
    local handled = 0
    local transport = assert(GGM.CreateSyncTransport(api, function()
        handled = handled + 1
    end))

    local state1, err1 = GGM.HandleSyncTransportMessage(transport, "OtherAddon", "anything", "GUILD", "Alice-Silvermoon")
    local state2, err2 = GGM.HandleSyncTransportMessage(transport, GGM.SYNC_PREFIX, "anything", "PARTY", "Alice-Silvermoon")

    T.assertEqual(state1, "ignored")
    T.assertNil(err1)
    T.assertEqual(state2, "ignored")
    T.assertNil(err2)
    T.assertEqual(handled, 0)
end)

T.test("transport aborts queued frames on throttling without retry or alternate channel", function()
    local GGM = loadModules()
    local api, timers, sendCalls = makeApi({ 0, 3 })
    local transport = assert(GGM.CreateSyncTransport(api, function() end))
    local payload = string.rep("b", 700)

    local ok, err = GGM.SendSyncPayload(transport, payload)
    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(#sendCalls, 1)

    timers[1]:Fire()

    T.assertEqual(#sendCalls, 2)
    T.assertEqual(transport.lastSendError, "send-addon-message-failed:AddonMessageThrottle")
    T.assertEqual(#transport.outboundFrames, 0)
    T.assertNil(transport.sendTimer)
    for _, call in ipairs(sendCalls) do
        T.assertEqual(call.chatType, "GUILD")
    end
end)

T.test("transport fails closed for not-in-guild and addon-message-lockdown results", function()
    local GGM = loadModules()
    local cases = {
        { result = 10, name = "NotInGuild" },
        { result = 11, name = "AddOnMessageLockdown" },
    }

    for _, case in ipairs(cases) do
        local api, timers, sendCalls = makeApi({ case.result })
        local transport = assert(GGM.CreateSyncTransport(api, function() end))
        local ok, err = GGM.SendSyncPayload(transport, string.rep("c", 700))

        T.assertFalse(ok)
        T.assertEqual(err, "send-addon-message-failed:" .. case.name)
        T.assertEqual(#sendCalls, 1)
        T.assertEqual(#timers, 0)
        T.assertEqual(#transport.outboundFrames, 0)
        T.assertEqual(sendCalls[1].chatType, "GUILD")
    end
end)

T.test("transport rejects malformed and oversized inbound frames without handler calls", function()
    local GGM = loadModules()
    local api = makeApi()
    local handled = 0
    local transport = assert(GGM.CreateSyncTransport(api, function()
        handled = handled + 1
    end))

    local _, malformedErr = GGM.HandleSyncTransportMessage(transport, GGM.SYNC_PREFIX, "bad-frame", "GUILD", "Alice-Silvermoon")
    T.assertEqual(malformedErr, "sync-frame-invalid")

    local _, oversizedErr = GGM.HandleSyncTransportMessage(transport, GGM.SYNC_PREFIX, string.rep("x", GGM.SYNC_MAX_ADDON_MESSAGE_BYTES + 1), "GUILD", "Alice-Silvermoon")
    T.assertEqual(oversizedErr, "sync-frame-too-large")
    T.assertEqual(handled, 0)
end)

T.test("transport caps incomplete reassemblies without retaining empty sender buckets", function()
    local GGM = loadModules()
    local api = makeApi()
    local transport = assert(GGM.CreateSyncTransport(api, function() end))

    for index = 1, GGM.SYNC_MAX_INBOUND_ASSEMBLIES do
        local sender = "Sender" .. tostring(index) .. "-Silvermoon"
        local state, err = GGM.HandleSyncTransportMessage(transport, GGM.SYNC_PREFIX, "F1|000001|01|02|x", "GUILD", sender)
        T.assertEqual(state, "partial")
        T.assertNil(err)
    end

    local overflowSender = "Overflow-Silvermoon"
    local state, err = GGM.HandleSyncTransportMessage(transport, GGM.SYNC_PREFIX, "F1|000001|01|02|x", "GUILD", overflowSender)

    T.assertNil(state)
    T.assertEqual(err, "sync-inbound-assembly-limit")
    T.assertNil(transport.inboundAssemblies[overflowSender])
end)
