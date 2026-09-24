local _, GGM = ...

local SEND_RESULT_NAMES = {
    [0] = "Success", [1] = "InvalidPrefix", [2] = "InvalidMessage", [3] = "AddonMessageThrottle",
    [4] = "InvalidChatType", [5] = "NotInGroup", [6] = "TargetRequired", [7] = "InvalidChannel",
    [8] = "ChannelThrottle", [9] = "GeneralError", [10] = "NotInGuild", [11] = "AddOnMessageLockdown",
    [12] = "TargetOffline",
}

local REGISTER_RESULT_NAMES = { [0] = "Success", [1] = "DuplicatePrefix", [2] = "InvalidPrefix", [3] = "MaxPrefixes" }

local function resultName(names, result)
    return names[result] or tostring(result)
end

local function nextMessageID(transport)
    transport.nextMessageID = (transport.nextMessageID % 999999) + 1
    return string.format("%06d", transport.nextMessageID)
end

local function buildFrames(payload, messageID)
    if type(payload) ~= "string" or payload == "" then return nil, "sync-payload-invalid" end
    if #payload > GGM.SYNC_MAX_LOGICAL_BYTES then return nil, "sync-payload-too-large" end
    local total = math.ceil(#payload / GGM.SYNC_FRAME_CHUNK_BYTES)
    if total < 1 or total > GGM.SYNC_MAX_FRAME_COUNT then return nil, "sync-frame-count-invalid" end
    local frames = {}
    for index = 1, total do
        local chunk = payload:sub(((index - 1) * GGM.SYNC_FRAME_CHUNK_BYTES) + 1, index * GGM.SYNC_FRAME_CHUNK_BYTES)
        local frame = string.format("F1|%s|%02d|%02d|%s", messageID, index, total, chunk)
        if #frame > GGM.SYNC_MAX_ADDON_MESSAGE_BYTES then return nil, "sync-frame-too-large" end
        frames[index] = frame
    end
    return frames, nil
end

local function sendFrame(transport, frame)
    local callOk, result = pcall(function()
        return select(-1, transport.api.C_ChatInfo.SendAddonMessage(GGM.SYNC_PREFIX, frame, GGM.SYNC_CHAT_TYPE))
    end)
    if not callOk then return false, "send-addon-message-threw" end
    if result ~= 0 then return false, "send-addon-message-failed:" .. resultName(SEND_RESULT_NAMES, result) end
    return true, nil
end

local function abortOutbound(transport, err)
    transport.outboundFrames = {}
    transport.sendTimer = nil
    transport.lastSendError = err
end

local pumpOutbound
pumpOutbound = function(transport)
    if #transport.outboundFrames == 0 then transport.sendTimer = nil; return true, nil end
    local sent, sendErr = sendFrame(transport, table.remove(transport.outboundFrames, 1))
    if not sent then abortOutbound(transport, sendErr); return false, sendErr end
    transport.lastSendError = nil
    if #transport.outboundFrames == 0 then transport.sendTimer = nil; return true, nil end
    local timerOk, timerOrError = pcall(transport.api.C_Timer.NewTimer, GGM.SYNC_SEND_INTERVAL_SECONDS, function()
        transport.sendTimer = nil
        local _, asyncErr = pumpOutbound(transport)
        if asyncErr then transport.lastSendError = asyncErr end
    end)
    if not timerOk or timerOrError == nil then
        local err = "sync-send-timer-create-failed"
        abortOutbound(transport, err)
        return false, err
    end
    transport.sendTimer = timerOrError
    return true, nil
end

local function activeAssemblyCount(transport)
    local count = 0
    for _, byMessageID in pairs(transport.inboundAssemblies) do for _ in pairs(byMessageID) do count = count + 1 end end
    return count
end

local function cleanupAssemblies(transport, now)
    for sender, byMessageID in pairs(transport.inboundAssemblies) do
        for messageID, assembly in pairs(byMessageID) do
            if now - assembly.updatedAt > GGM.SYNC_REASSEMBLY_TTL_SECONDS then byMessageID[messageID] = nil end
        end
        if next(byMessageID) == nil then transport.inboundAssemblies[sender] = nil end
    end
end

local function parseFrame(text)
    if type(text) ~= "string" then return nil, "sync-frame-invalid" end
    if #text > GGM.SYNC_MAX_ADDON_MESSAGE_BYTES then return nil, "sync-frame-too-large" end
    local messageID, indexText, totalText, chunkStart = text:match("^F1|(%d%d%d%d%d%d)|(%d%d)|(%d%d)|()")
    if not messageID then return nil, "sync-frame-invalid" end
    local index, total = tonumber(indexText), tonumber(totalText)
    if not index or not total or total < 1 or total > GGM.SYNC_MAX_FRAME_COUNT or index < 1 or index > total then return nil, "sync-frame-index-invalid" end
    local chunk = text:sub(chunkStart)
    if #chunk > GGM.SYNC_FRAME_CHUNK_BYTES then return nil, "sync-frame-chunk-too-large" end
    return { messageID = messageID, index = index, total = total, chunk = chunk }, nil
end

function GGM.CreateSyncTransport(api, onLogicalPayload)
    if type(api) ~= "table" or type(api.C_ChatInfo) ~= "table" or type(api.C_ChatInfo.RegisterAddonMessagePrefix) ~= "function" or type(api.C_ChatInfo.SendAddonMessage) ~= "function" then return nil, "chat-info-api-unavailable" end
    if type(api.C_Timer) ~= "table" or type(api.C_Timer.NewTimer) ~= "function" then return nil, "sync-timer-api-unavailable" end
    if type(api.GetTime) ~= "function" then return nil, "sync-time-api-unavailable" end
    if type(onLogicalPayload) ~= "function" then return nil, "sync-logical-handler-invalid" end
    return { api = api, onLogicalPayload = onLogicalPayload, nextMessageID = 0, outboundFrames = {}, sendTimer = nil, inboundAssemblies = {}, lastSendError = nil, lastReceiveError = nil }, nil
end

function GGM.RegisterSyncPrefix(transport)
    local callOk, result = pcall(function() return select(-1, transport.api.C_ChatInfo.RegisterAddonMessagePrefix(GGM.SYNC_PREFIX)) end)
    if not callOk then return false, "prefix-register-threw" end
    if result ~= 0 then return false, "prefix-register-failed:" .. resultName(REGISTER_RESULT_NAMES, result) end
    return true, nil
end

function GGM.SendSyncPayload(transport, payload)
    local frames, frameErr = buildFrames(payload, nextMessageID(transport))
    if not frames then return false, frameErr end
    if #transport.outboundFrames + #frames > GGM.SYNC_MAX_OUTBOUND_FRAMES then return false, "sync-outbound-queue-full" end
    local shouldPump = #transport.outboundFrames == 0 and transport.sendTimer == nil
    for _, frame in ipairs(frames) do table.insert(transport.outboundFrames, frame) end
    if shouldPump then return pumpOutbound(transport) end
    return true, nil
end

function GGM.HandleSyncTransportMessage(transport, prefix, text, channel, sender)
    if prefix ~= GGM.SYNC_PREFIX or channel ~= GGM.SYNC_CHAT_TYPE then return "ignored", nil end
    if type(sender) ~= "string" or sender == "" or #sender > GGM.SYNC_MAX_IDENTITY_KEY_BYTES then local err = "sync-sender-invalid"; transport.lastReceiveError = err; return nil, err end
    local frame, frameErr = parseFrame(text)
    if not frame then transport.lastReceiveError = frameErr; return nil, frameErr end
    local timeOk, now = pcall(transport.api.GetTime)
    if not timeOk or type(now) ~= "number" then local err = "sync-time-unavailable"; transport.lastReceiveError = err; return nil, err end
    cleanupAssemblies(transport, now)
    local byMessageID = transport.inboundAssemblies[sender]
    local assembly = byMessageID and byMessageID[frame.messageID] or nil
    if not assembly then
        if activeAssemblyCount(transport) >= GGM.SYNC_MAX_INBOUND_ASSEMBLIES then local err = "sync-inbound-assembly-limit"; transport.lastReceiveError = err; return nil, err end
        if not byMessageID then byMessageID = {}; transport.inboundAssemblies[sender] = byMessageID end
        assembly = { total = frame.total, chunks = {}, received = 0, bytes = 0, updatedAt = now }
        byMessageID[frame.messageID] = assembly
    elseif frame.index == 1 then
        -- Per-sender frames are serialized. Every first frame starts a fresh
        -- logical message, including after a sender reload reused its ID.
        assembly = { total = frame.total, chunks = {}, received = 0, bytes = 0, updatedAt = now }
        byMessageID[frame.messageID] = assembly
    elseif assembly.total ~= frame.total then
        byMessageID[frame.messageID] = nil
        local err = "sync-frame-total-mismatch"; transport.lastReceiveError = err; return nil, err
    end
    local previous = assembly.chunks[frame.index]
    if previous ~= nil then
        if previous == frame.chunk then return "partial", nil end
        byMessageID[frame.messageID] = nil
        local err = "sync-frame-conflict"; transport.lastReceiveError = err; return nil, err
    end
    assembly.chunks[frame.index] = frame.chunk
    assembly.received = assembly.received + 1
    assembly.bytes = assembly.bytes + #frame.chunk
    assembly.updatedAt = now
    if assembly.bytes > GGM.SYNC_MAX_LOGICAL_BYTES then byMessageID[frame.messageID] = nil; local err = "sync-payload-too-large"; transport.lastReceiveError = err; return nil, err end
    if assembly.received < assembly.total then return "partial", nil end
    local chunks = {}
    for index = 1, assembly.total do if assembly.chunks[index] == nil then return "partial", nil end; chunks[index] = assembly.chunks[index] end
    local payload = table.concat(chunks)
    byMessageID[frame.messageID] = nil
    if next(byMessageID) == nil then transport.inboundAssemblies[sender] = nil end
    if #payload > GGM.SYNC_MAX_LOGICAL_BYTES then local err = "sync-payload-too-large"; transport.lastReceiveError = err; return nil, err end
    local handlerOk, state, handlerErr = pcall(transport.onLogicalPayload, sender, payload)
    if not handlerOk then local err = "sync-logical-handler-threw"; transport.lastReceiveError = err; return nil, err end
    transport.lastReceiveError = handlerErr
    return state, handlerErr
end
