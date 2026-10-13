local _, GGM = ...

local PREFIX = "GC_PROF"
local CHAT_TYPE = "GUILD"
local MAX_MESSAGE_BYTES = 240
local MAX_LOGICAL_BYTES = 65536
local MAX_CHUNK_BYTES = 222 -- 240 minus the 18-byte F1 header.
local MAX_FRAME_COUNT = 320
local MAX_OUTBOUND_FRAMES = 640
local MAX_INBOUND_ASSEMBLIES = 4
local REASSEMBLY_TTL_SECONDS = 300
local SEND_INTERVAL_SECONDS = 0.5
local MAX_SENDER_BYTES = 80

local SEND_RESULT_NAMES = {
    [0] = "Success", [1] = "InvalidPrefix", [2] = "InvalidMessage", [3] = "AddonMessageThrottle",
    [4] = "InvalidChatType", [5] = "NotInGroup", [6] = "TargetRequired", [7] = "InvalidChannel",
    [8] = "ChannelThrottle", [9] = "GeneralError", [10] = "NotInGuild", [11] = "AddOnMessageLockdown",
    [12] = "TargetOffline",
}

local REGISTER_RESULT_NAMES = {
    [0] = "Success", [1] = "DuplicatePrefix", [2] = "InvalidPrefix", [3] = "MaxPrefixes",
}

local SEND_ENUMS = { "SendAddonMessageResult", "AddonMessageResult", "SendAddOnMessageResult" }
local REGISTER_ENUMS = { "AddonMessagePrefixResult", "RegisterAddonMessagePrefixResult" }

local function enumTables(api, names)
    local tables = {}
    local enums = type(api.Enum) == "table" and api.Enum or nil
    if enums then
        for _, name in ipairs(names) do
            if type(enums[name]) == "table" then tables[#tables + 1] = enums[name] end
        end
    end
    return tables
end

local function isSuccess(api, result, names)
    if result == 0 or result == true then return true end
    for _, enum in ipairs(enumTables(api, names)) do
        if enum.Success ~= nil and result == enum.Success then return true end
    end
    return false
end

local function resultName(api, result, names, knownNames)
    for _, enum in ipairs(enumTables(api, names)) do
        for name, value in pairs(enum) do
            if value == result and name ~= "Success" then return tostring(name) end
        end
    end
    if knownNames[result] then return knownNames[result] end
    if type(result) == "string" then return result end
    return tostring(result)
end

local function reportFailure(transport, err)
    if type(transport.onFailure) == "function" then
        pcall(transport.onFailure, err)
    end
end

local function finishGroup(group, sent, err)
    if not group or group.finished then return end
    group.finished = true
    if type(group.onFinished) == "function" then
        pcall(group.onFinished, sent, err, group.target)
    end
end

local function cancelTimer(timer)
    if type(timer) ~= "table" or type(timer.Cancel) ~= "function" then return end
    pcall(timer.Cancel, timer)
end

local function abortOutbound(transport, err, activeGroup)
    local groups = {}
    if activeGroup then groups[activeGroup] = true end
    for _, queued in ipairs(transport.outboundFrames) do
        if type(queued) == "table" and queued.group then groups[queued.group] = true end
    end

    local timer = transport.sendTimer
    transport.outboundFrames = {}
    transport.sendTimer = nil
    transport.lastSendError = err
    cancelTimer(timer)
    for group in pairs(groups) do finishGroup(group, false, err) end
    reportFailure(transport, err)
end

local function buildFrames(transport, payload)
    if type(payload) ~= "string" or payload == "" then return nil, "profession-payload-invalid" end
    if #payload > MAX_LOGICAL_BYTES then return nil, "profession-payload-too-large" end

    local total = math.ceil(#payload / MAX_CHUNK_BYTES)
    if total < 1 or total > MAX_FRAME_COUNT then return nil, "profession-frame-count-invalid" end

    transport.nextMessageID = (transport.nextMessageID % 999999) + 1
    local messageID = string.format("%06d", transport.nextMessageID)
    local frames = {}
    for index = 1, total do
        local chunk = payload:sub(((index - 1) * MAX_CHUNK_BYTES) + 1, index * MAX_CHUNK_BYTES)
        local frame = string.format("F1|%s|%03d|%03d|%s", messageID, index, total, chunk)
        if #frame > MAX_MESSAGE_BYTES then return nil, "profession-frame-too-large" end
        frames[index] = frame
    end
    return frames, nil
end

local function sendFrame(transport, frame)
    local callOk, result = pcall(function()
        return select(-1, transport.api.C_ChatInfo.SendAddonMessage(PREFIX, frame, CHAT_TYPE))
    end)
    if not callOk then return false, "profession-send-addon-message-threw" end
    if not isSuccess(transport.api, result, SEND_ENUMS) then
        return false, "profession-send-addon-message-failed:" .. resultName(transport.api, result, SEND_ENUMS, SEND_RESULT_NAMES)
    end
    return true, nil
end

local pumpOutbound

local function schedulePump(transport, delay)
    local generation = transport.generation
    local timerOk, timerOrError = pcall(transport.api.C_Timer.NewTimer, delay, function()
        if generation ~= transport.generation then return end
        transport.sendTimer = nil
        local _, pumpErr = pumpOutbound(transport)
        if pumpErr then transport.lastSendError = pumpErr end
    end)
    if not timerOk or timerOrError == nil then
        return false, "profession-send-timer-create-failed"
    end
    transport.sendTimer = timerOrError
    return true, nil
end

pumpOutbound = function(transport)
    if transport.closed or transport.cancelling or transport.sendTimer ~= nil then return true, nil end

    while transport.outboundFrames[1] and transport.outboundFrames[1].group.cancelled do
        table.remove(transport.outboundFrames, 1)
    end
    local queued = transport.outboundFrames[1]
    if not queued then return true, nil end

    local timeOk, now = pcall(transport.api.GetTime)
    if not timeOk or type(now) ~= "number" then
        local err = "profession-time-unavailable"
        abortOutbound(transport, err, queued.group)
        return false, err
    end

    local delay = transport.nextSendAt and (transport.nextSendAt - now) or 0
    if delay > 0 then
        local scheduled, scheduleErr = schedulePump(transport, delay)
        if not scheduled then
            abortOutbound(transport, scheduleErr, queued.group)
            return false, scheduleErr
        end
        return true, nil
    end

    table.remove(transport.outboundFrames, 1)
    local sent, sendErr = sendFrame(transport, queued.frame)
    if not sent then
        abortOutbound(transport, sendErr, queued.group)
        return false, sendErr
    end

    transport.lastSendError = nil
    transport.nextSendAt = now + SEND_INTERVAL_SECONDS
    queued.group.remaining = queued.group.remaining - 1
    if queued.group.remaining == 0 then finishGroup(queued.group, true, nil) end

    if #transport.outboundFrames > 0 and transport.sendTimer == nil then
        local scheduled, scheduleErr = schedulePump(transport, SEND_INTERVAL_SECONDS)
        if not scheduled then
            abortOutbound(transport, scheduleErr, queued.group)
            return false, scheduleErr
        end
        return true, nil
    end
    return true, nil
end

local function activeAssemblyCount(transport)
    local count = 0
    for _, byMessageID in pairs(transport.inboundAssemblies) do
        for _ in pairs(byMessageID) do count = count + 1 end
    end
    return count
end

local function cleanupAssemblies(transport, now)
    for sender, byMessageID in pairs(transport.inboundAssemblies) do
        for messageID, assembly in pairs(byMessageID) do
            if now - assembly.updatedAt > REASSEMBLY_TTL_SECONDS then
                byMessageID[messageID] = nil
            end
        end
        if next(byMessageID) == nil then transport.inboundAssemblies[sender] = nil end
    end
end

local function parseFrame(text)
    if type(text) ~= "string" then return nil, "profession-frame-invalid" end
    if #text > MAX_MESSAGE_BYTES then return nil, "profession-frame-too-large" end
    local messageID, indexText, totalText, chunkStart = text:match("^F1|(%d%d%d%d%d%d)|(%d%d%d)|(%d%d%d)|()")
    if not messageID then return nil, "profession-frame-invalid" end

    local index, total = tonumber(indexText), tonumber(totalText)
    if messageID == "000000" or not index or not total or total < 1 or total > MAX_FRAME_COUNT or index < 1 or index > total then
        return nil, "profession-frame-index-invalid"
    end

    local chunk = text:sub(chunkStart)
    if #chunk == 0 then return nil, "profession-frame-invalid" end
    if #chunk > MAX_CHUNK_BYTES then return nil, "profession-frame-chunk-too-large" end
    return { messageID = messageID, index = index, total = total, chunk = chunk }, nil
end

function GGM.CreateProfessionTransport(api, onPayload, onFailure)
    if type(api) ~= "table" or type(api.C_ChatInfo) ~= "table"
        or type(api.C_ChatInfo.RegisterAddonMessagePrefix) ~= "function"
        or type(api.C_ChatInfo.SendAddonMessage) ~= "function" then
        return nil, "profession-chat-info-api-unavailable"
    end
    if type(api.C_Timer) ~= "table" or type(api.C_Timer.NewTimer) ~= "function" then
        return nil, "profession-timer-api-unavailable"
    end
    if type(api.GetTime) ~= "function" then return nil, "profession-time-api-unavailable" end
    if type(onPayload) ~= "function" then return nil, "profession-payload-handler-invalid" end
    if onFailure ~= nil and type(onFailure) ~= "function" then return nil, "profession-failure-handler-invalid" end

    return {
        api = api,
        onPayload = onPayload,
        onFailure = onFailure,
        nextMessageID = 0,
        nextSendAt = nil,
        outboundFrames = {},
        sendTimer = nil,
        inboundAssemblies = {},
        generation = 0,
        lastSendError = nil,
        lastReceiveError = nil,
        closed = false,
        cancelling = false,
    }, nil
end

function GGM.RegisterProfessionTransport(transport)
    if type(transport) ~= "table" or transport.closed then return false, "profession-transport-unavailable" end
    local callOk, result = pcall(function()
        return select(-1, transport.api.C_ChatInfo.RegisterAddonMessagePrefix(PREFIX))
    end)
    if not callOk then
        local err = "profession-prefix-register-threw"
        reportFailure(transport, err)
        return false, err
    end
    if not isSuccess(transport.api, result, REGISTER_ENUMS) then
        local err = "profession-prefix-register-failed:" .. resultName(transport.api, result, REGISTER_ENUMS, REGISTER_RESULT_NAMES)
        reportFailure(transport, err)
        return false, err
    end
    return true, nil
end

function GGM.SendProfessionPayload(transport, payload, target, onFinished)
    if type(transport) ~= "table" or transport.closed then return false, "profession-transport-unavailable" end
    if transport.cancelling then return false, "profession-transport-cancelling" end

    local frames, frameErr = buildFrames(transport, payload)
    if not frames then return false, frameErr end
    if #transport.outboundFrames + #frames > MAX_OUTBOUND_FRAMES then
        return false, "profession-outbound-queue-full"
    end

    local group = { remaining = #frames, cancelled = false, onFinished = onFinished, target = target }
    for _, frame in ipairs(frames) do
        table.insert(transport.outboundFrames, { frame = frame, group = group })
    end

    local sent, sendErr = pumpOutbound(transport)
    if not sent then return false, sendErr, group end
    return true, nil, group
end

function GGM.ReceiveProfessionFrame(transport, prefix, frameText, channel, sender)
    if prefix ~= PREFIX or channel ~= CHAT_TYPE then return "ignored", nil end
    if type(transport) ~= "table" or transport.closed then return nil, "profession-transport-unavailable" end
    if type(sender) ~= "string" or #sender == 0 or #sender > MAX_SENDER_BYTES or sender:find("[%z\1-\31\127]") then
        local err = "profession-sender-invalid"
        transport.lastReceiveError = err
        return nil, err
    end

    local frame, frameErr = parseFrame(frameText)
    if not frame then transport.lastReceiveError = frameErr; return nil, frameErr end

    local timeOk, now = pcall(transport.api.GetTime)
    if not timeOk or type(now) ~= "number" then
        local err = "profession-time-unavailable"
        transport.lastReceiveError = err
        return nil, err
    end
    cleanupAssemblies(transport, now)

    local byMessageID = transport.inboundAssemblies[sender]
    local assembly = byMessageID and byMessageID[frame.messageID] or nil
    if not assembly then
        if activeAssemblyCount(transport) >= MAX_INBOUND_ASSEMBLIES then
            local err = "profession-inbound-assembly-limit"
            transport.lastReceiveError = err
            return nil, err
        end
        if not byMessageID then byMessageID = {}; transport.inboundAssemblies[sender] = byMessageID end
        assembly = { total = frame.total, chunks = {}, received = 0, bytes = 0, updatedAt = now }
        byMessageID[frame.messageID] = assembly
    elseif frame.total ~= assembly.total then
        byMessageID[frame.messageID] = nil
        if next(byMessageID) == nil then transport.inboundAssemblies[sender] = nil end
        local err = "profession-frame-total-mismatch"
        transport.lastReceiveError = err
        return nil, err
    end

    local previous = assembly.chunks[frame.index]
    if previous ~= nil then
        if previous == frame.chunk then transport.lastReceiveError = nil; return "partial", nil end
        byMessageID[frame.messageID] = nil
        if next(byMessageID) == nil then transport.inboundAssemblies[sender] = nil end
        local err = "profession-frame-conflict"
        transport.lastReceiveError = err
        return nil, err
    end

    assembly.chunks[frame.index] = frame.chunk
    assembly.received = assembly.received + 1
    assembly.bytes = assembly.bytes + #frame.chunk
    assembly.updatedAt = now
    if assembly.bytes > MAX_LOGICAL_BYTES then
        byMessageID[frame.messageID] = nil
        if next(byMessageID) == nil then transport.inboundAssemblies[sender] = nil end
        local err = "profession-payload-too-large"
        transport.lastReceiveError = err
        return nil, err
    end
    if assembly.received < assembly.total then transport.lastReceiveError = nil; return "partial", nil end

    local chunks = {}
    for index = 1, assembly.total do
        if assembly.chunks[index] == nil then transport.lastReceiveError = nil; return "partial", nil end
        chunks[index] = assembly.chunks[index]
    end

    local payload = table.concat(chunks)
    byMessageID[frame.messageID] = nil
    if next(byMessageID) == nil then transport.inboundAssemblies[sender] = nil end
    if #payload > MAX_LOGICAL_BYTES then
        local err = "profession-payload-too-large"
        transport.lastReceiveError = err
        return nil, err
    end

    local handlerOk, state, handlerErr = pcall(transport.onPayload, payload, sender)
    if not handlerOk then
        local err = "profession-payload-handler-threw"
        transport.lastReceiveError = err
        return nil, err
    end
    transport.lastReceiveError = handlerErr
    return state, handlerErr
end

function GGM.CancelProfessionTransport(transport)
    if type(transport) ~= "table" or transport.closed or transport.cancelling then return false end
    transport.cancelling = true
    transport.generation = transport.generation + 1

    local timer = transport.sendTimer
    local groups = {}
    for _, queued in ipairs(transport.outboundFrames) do
        if queued.group then groups[queued.group] = true end
    end
    transport.outboundFrames = {}
    transport.sendTimer = nil
    transport.inboundAssemblies = {}
    cancelTimer(timer)

    for group in pairs(groups) do finishGroup(group, false, "profession-send-cancelled") end
    transport.lastSendError = nil
    transport.lastReceiveError = nil
    transport.cancelling = false
    return true
end
