local _, GGM = ...
local P = GGM.BankSyncProtocol

local MAX_PEERS, PEER_TTL, MAX_PENDING, MAX_PEERS_PER_WINDOW = 64, 300, 8, 4
local CAPTURE_DEBOUNCE, RESPONSE_TIMEOUT = 1, 30

local function integer(value, minimum, maximum)
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function normalized(value)
    if type(value) ~= "string" then return nil end
    return (value:gsub("%s", "")):lower()
end

local function senderMatches(encoded, actual)
    local left, right = normalized(encoded), normalized(actual)
    if not left or not right then return false end
    if left == right then return true end
    -- Some clients report only the character name for local-realm senders.
    local encodedName = left:match("^([^%-]+)")
    return encodedName ~= nil and encodedName == right and not right:find("-", 1, true)
end

local function timerCancel(timer)
    if type(timer) == "table" and type(timer.Cancel) == "function" then pcall(timer.Cancel, timer) end
end

local function apiCall(fn, ...)
    if type(fn) ~= "function" then return false, "api-unavailable" end
    local ok, first, second = pcall(fn, ...)
    if not ok then return false, "api-failed" end
    return true, first, second
end

local function context(sync)
    if not sync.available or not sync.bankAPI then return nil, sync.error or "bank-sync-unavailable" end
    local ok, value, err = apiCall(sync.bankAPI.GetGuildBankSyncContext)
    if not ok or type(value) ~= "table" then return nil, err or value or "guild-session-unavailable" end
    if type(value.guildKey) ~= "string" or value.guildKey == ""
        or type(value.sessionToken) ~= "string" or value.sessionToken == ""
        or type(value.viewableTabIDs) ~= "table" then return nil, "guild-session-context-invalid" end
    return value
end

local function sortedTabIDs(rows)
    local ids = {}
    for id in pairs(rows or {}) do if integer(id, 1, 8) then ids[#ids + 1] = id end end
    table.sort(ids)
    return ids
end

local function cancelTimer(sync, key)
    timerCancel(sync[key])
    sync[key] = nil
end

local drive, buildPeerQueue

local function schedule(sync, key, delay, callback)
    cancelTimer(sync, key)
    local timerAPI = sync.api.C_Timer
    if type(timerAPI) ~= "table" or type(timerAPI.NewTimer) ~= "function" then return false end
    local generation = sync.generation
    local ok, timer = pcall(timerAPI.NewTimer, delay, function()
        if sync.generation ~= generation then return end
        sync[key] = nil
        callback()
    end)
    if not ok or not timer then return false end
    sync[key] = timer
    return true
end

local function currentIdentity(sync)
    local ok, identity = apiCall(GGM.BuildPlayerIdentity, sync.api)
    if not ok or type(identity) ~= "table" or type(identity.key) ~= "string" or identity.key == "" then
        return nil, identity or "player-identity-unavailable"
    end
    return identity
end

local function setStatus(sync, value)
    sync.status = value
end

local function clearWork(sync, clearManual)
    cancelTimer(sync, "captureTimer")
    cancelTimer(sync, "responseTimer")
    sync.pending = {}
    sync.selectedPeer = nil
    sync.current = nil
    sync.peerQueue = {}
    sync.peerIndex = 1
    sync.peersInWindow = 0
    if clearManual then
        sync.manualPending = false
        sync.manualActive = false
    end
end

local function expirePeers(sync)
    local ok, now = apiCall(sync.api.GetTime)
    if not ok or type(now) ~= "number" then return false end
    local selectedExpired = false
    for key, peer in pairs(sync.peers) do
        if now - peer.lastSeen > PEER_TTL then
            sync.peers[key] = nil
            sync.peerCount = math.max(0, sync.peerCount - 1)
            if sync.selectedPeer == key then
                selectedExpired = true
                clearWork(sync, false)
            end
        end
    end
    return selectedExpired
end

local function peerExpiryDelay(sync)
    local ok, now = apiCall(sync.api.GetTime)
    if not ok or type(now) ~= "number" then return nil end
    local earliest
    for _, peer in pairs(sync.peers) do
        local left = PEER_TTL - (now - peer.lastSeen)
        if not earliest or left < earliest then earliest = left end
    end
    return earliest
end

local function schedulePeerExpiry(sync)
    local delay = peerExpiryDelay(sync)
    if not delay then return end
    if delay < 0 then delay = 0 end
    schedule(sync, "peerExpiryTimer", delay + 0.01, function()
        local selectedExpired = expirePeers(sync)
        if selectedExpired and sync.sessionActive then
            buildPeerQueue(sync)
            if #sync.peerQueue > 0 then drive(sync) else
                sync.manualPending = false
                sync.manualActive = false
                setStatus(sync, "Waiting for guild caches")
            end
        end
        schedulePeerExpiry(sync)
    end)
end

local function sendMessage(sync, kind, values, target, channel, done)
    if not sync.transport or not sync.sessionActive then return false, "bank-sync-session-unavailable" end
    local ok, err = GGM.SendBankSyncMessage(sync.transport, kind, values, target, channel, done)
    if not ok then sync.error = err end
    return ok, err
end

local function publishManifest(sync)
    local ctx, ctxErr = context(sync)
    if not ctx or not sync.sessionActive then return false, ctxErr or "guild-session-unavailable" end
    if ctx.guildKey ~= sync.guildKey or ctx.sessionToken ~= sync.sessionToken then
        GGM.CancelBankSync(sync, "guild-session-changed")
        return false, "guild-session-changed"
    end
    local identity, identityErr = currentIdentity(sync)
    if not identity then setStatus(sync, "Bank sync unavailable"); return false, identityErr end
    local tabs = {}
    for _, tabID in ipairs(sortedTabIDs(ctx.viewableTabIDs)) do
        local snapshotOK, snapshot, snapshotErr = apiCall(sync.bankAPI.GetGuildBankSyncSnapshot, tabID, ctx.sessionToken)
        if snapshotOK and type(snapshot) == "table" and snapshot.status == "cached" and snapshot.id == tabID then
            tabs[tabID] = { capturedAt = snapshot.capturedAt, digest = P.Digest(tabID, snapshot) }
        else
            tabs[tabID] = { noComplete = true }
        end
    end
    local pages, err = P.BuildManifest(identity.key, ctx.guildKey, ctx.sessionToken, tabs)
    if not pages then sync.error = err; return false, err end
    for _, raw in ipairs(pages) do
        local message = P.Decode(raw, "GUILD")
        if not message then return false, "bank-sync-manifest-encode-failed" end
        local sent, sendErr = sendMessage(sync, "M", message.fields, nil, "GUILD")
        if not sent then return false, sendErr end
    end
    return true
end

local function manifestSignature(manifest)
    local pieces = { manifest.sessionToken }
    for _, id in ipairs(sortedTabIDs(manifest.tabs)) do
        local row = manifest.tabs[id]
        pieces[#pieces + 1] = table.concat({ id, row.capturedAt or "-", row.digest or "-" }, ":")
    end
    return table.concat(pieces, "|")
end

buildPeerQueue = function(sync)
    expirePeers(sync)
    local keys = {}
    for key, peer in pairs(sync.peers) do
        if peer.guildKey == sync.guildKey and peer.sessionToken and peer.senderKey ~= sync.senderKey
            and sync.processed[key] ~= peer.signature then keys[#keys + 1] = key end
    end
    table.sort(keys)
    sync.peerQueue = keys
    sync.peerIndex = 1
    sync.peersInWindow = 0
end

local function nextCandidate(sync, peer)
    local ctx, ctxErr = context(sync)
    if not ctx then return nil, ctxErr end
    local peerManifest = sync.peers[peer]
    if not peerManifest then return nil end
    for _, tabID in ipairs(sortedTabIDs(peerManifest.tabs)) do
        local remote = peerManifest.tabs[tabID]
        if not remote.noComplete and remote.digest and ctx.viewableTabIDs[tabID] then
            local snapshotOK, localSnapshot = apiCall(sync.bankAPI.GetGuildBankSyncSnapshot, tabID, ctx.sessionToken)
            if not snapshotOK or type(localSnapshot) ~= "table" or localSnapshot.status ~= "cached"
                or type(localSnapshot.capturedAt) ~= "number" or localSnapshot.capturedAt < remote.capturedAt then
                return tabID
            end
        end
    end
    return nil
end

local function finishPeer(sync)
    if sync.selectedPeer then
        local peer = sync.peers[sync.selectedPeer]
        if peer then sync.processed[sync.selectedPeer] = peer.signature end
    end
    sync.selectedPeer = nil
    sync.current = nil
    cancelTimer(sync, "responseTimer")
    sync.peersInWindow = sync.peersInWindow + 1
    if sync.manualPending then
        sync.manualPending = false
        sync.manualActive = true
        buildPeerQueue(sync)
        drive(sync)
        return
    end
    sync.peerIndex = sync.peerIndex + 1
    if sync.peersInWindow >= MAX_PEERS_PER_WINDOW then
        buildPeerQueue(sync)
        if #sync.peerQueue == 0 then
            sync.manualActive = false
            setStatus(sync, "Compared available guild snapshots")
            return
        end
    end
    drive(sync)
end

local function advanceAfterRequest(sync)
    local peerKey = sync.selectedPeer
    if not peerKey then return end
    sync.current = nil
    sync.pending = {}
    cancelTimer(sync, "responseTimer")
    local tabID = nextCandidate(sync, peerKey)
    if tabID then
        local peer = sync.peers[peerKey]
        local ctx = context(sync)
        if not peer or not ctx then finishPeer(sync); return end
        sync.requestSequence = sync.requestSequence % 999999999 + 1
        local requestID = tostring(sync.requestSequence)
        local entry = { peer = peerKey, senderKey = peer.senderKey, peerToken = peer.sessionToken,
            guildKey = sync.guildKey, localToken = sync.sessionToken, tabID = tabID,
            requestID = requestID, generation = sync.generation }
        sync.pending[requestID] = entry
        sync.current = entry
        setStatus(sync, "Requesting guild tab " .. tabID)
        local timeoutScheduled = schedule(sync, "responseTimer", RESPONSE_TIMEOUT, function()
            if sync.current == entry then
                sync.pending[requestID] = nil
                sync.error = "bank-sync-no-response"
                advanceAfterRequest(sync)
            end
        end)
        if not timeoutScheduled then
            sync.pending[requestID] = nil
            sync.current = nil
            sync.error = "bank-sync-timeout-unavailable"
            setStatus(sync, "Guild sync timer unavailable")
            finishPeer(sync)
            return
        end
        local sent, err = sendMessage(sync, "Q", { sync.senderKey, sync.guildKey, sync.sessionToken,
            peer.sessionToken, requestID, tostring(tabID) }, peer.senderKey, "WHISPER", function(success)
                if sync.generation ~= entry.generation or sync.current ~= entry then return end
                if not success then
                    sync.pending[requestID] = nil
                    advanceAfterRequest(sync)
                end
            end)
        if not sent and sync.current == entry then
            sync.pending[requestID] = nil
            advanceAfterRequest(sync)
        end
        return
    end
    finishPeer(sync)
end

drive = function(sync)
    if not sync.sessionActive or sync.current then return end
    if sync.manualPending then
        sync.manualPending = false
        sync.manualActive = true
        buildPeerQueue(sync)
    elseif #sync.peerQueue == 0 or sync.peerIndex > #sync.peerQueue then
        local completedManual = sync.manualActive
        sync.manualActive = false
        setStatus(sync, completedManual and "Compared available guild snapshots" or "Waiting for guild caches")
        return
    end
    while sync.peerIndex <= #sync.peerQueue do
        local peerKey = sync.peerQueue[sync.peerIndex]
        local peer = sync.peers[peerKey]
        if peer and sync.processed[peerKey] ~= peer.signature then
            sync.selectedPeer = peerKey
            advanceAfterRequest(sync)
            return
        end
        sync.peerIndex = sync.peerIndex + 1
    end
    sync.peerQueue = {}
    sync.manualPending = false
    sync.manualActive = false
    setStatus(sync, "Compared available guild snapshots")
end

local function handleManifest(sync, message, sender)
    local fields = message.fields
    if not senderMatches(fields[1], sender) then return false, "bank-sync-manifest-sender-mismatch" end
    local ctx = context(sync)
    if not ctx or fields[2] ~= ctx.guildKey or fields[3] == sync.sessionToken then return false, "bank-sync-manifest-session-invalid" end
    local complete, err = P.AcceptManifestPage(sync.assembler, message, fields[1])
    if not complete then return complete == "partial", err end
    if complete == "partial" then return true end
    if not complete then return false, err end
    if complete.guildKey ~= sync.guildKey or complete.sessionToken == "" then return false, "bank-sync-manifest-session-invalid" end
    local peerKey = normalized(complete.sender)
    if not peerKey or peerKey == normalized(sync.senderKey) then return false, "bank-sync-manifest-sender-invalid" end
    local nowOK, now = apiCall(sync.api.GetTime)
    if not nowOK or type(now) ~= "number" then return false, "bank-sync-time-unavailable" end
    local current = sync.peers[peerKey]
    if not current and sync.peerCount >= MAX_PEERS then
        local oldestKey, oldestAt
        for key, peer in pairs(sync.peers) do if not oldestAt or peer.lastSeen < oldestAt then oldestKey, oldestAt = key, peer.lastSeen end end
        if oldestKey then sync.peers[oldestKey] = nil; sync.peerCount = sync.peerCount - 1 end
    end
    local signature = manifestSignature(complete)
    sync.peers[peerKey] = { senderKey = complete.sender, guildKey = complete.guildKey,
        sessionToken = complete.sessionToken, tabs = complete.tabs, lastSeen = now, signature = signature }
    if not current then sync.peerCount = sync.peerCount + 1 end
    sync.assembler.sets = sync.assembler.sets or {}
    schedulePeerExpiry(sync)
    if sync.selectedPeer == peerKey and sync.current and sync.current.peerToken ~= complete.sessionToken then
        clearWork(sync, false)
    end
    buildPeerQueue(sync)
    if sync.current then return true end
    drive(sync)
    return true
end

local function validateSnapshotResponse(sync, sender, fields)
    if not sync.sessionActive or not sync.current then return false end
    local entry = sync.current
    if entry.generation ~= sync.generation or sync.pending[entry.requestID] ~= entry
        or fields[5] ~= entry.requestID or tonumber(fields[6]) ~= entry.tabID
        or normalized(entry.peer) ~= normalized(sync.selectedPeer) or not senderMatches(fields[1], sender)
        or normalized(fields[1]) ~= normalized(entry.senderKey) or fields[2] ~= entry.guildKey
        or fields[3] ~= entry.localToken or fields[4] ~= entry.peerToken then return false end
    local ctx = context(sync)
    if not ctx or ctx.guildKey ~= entry.guildKey or ctx.sessionToken ~= entry.localToken or not ctx.viewableTabIDs[entry.tabID] then return false end
    local peer = sync.peers[entry.peer]
    local nowOK, now = apiCall(sync.api.GetTime)
    if not peer or not nowOK or now - peer.lastSeen > PEER_TTL or peer.sessionToken ~= entry.peerToken then return false end
    local row = peer.tabs[entry.tabID]
    local snap = fields[7]
    return row ~= nil and not row.noComplete and snap.id == entry.tabID and snap.capturedAt == row.capturedAt
        and P.Digest(entry.tabID, snap) == row.digest
end

local function handleMessage(sync, message, sender, channel)
    if not sync.sessionActive then return false, "guild-session-unavailable" end
    if message.type == "M" then return handleManifest(sync, message, sender) end
    local fields = message.fields
    if message.type == "E" then
        if not senderMatches(fields[1], sender) or fields[2] ~= sync.guildKey then return false, "bank-sync-session-invalid" end
        local key = normalized(fields[1]); local peer = sync.peers[key]
        if peer and peer.sessionToken == fields[3] then
            sync.peers[key] = nil; sync.peerCount = math.max(0, sync.peerCount - 1); sync.processed[key] = nil
            if sync.selectedPeer == key then
                clearWork(sync, false)
                buildPeerQueue(sync)
                if #sync.peerQueue > 0 then drive(sync) else
                    sync.manualPending = false
                    sync.manualActive = false
                    setStatus(sync, "Waiting for guild caches")
                end
            end
        end
        return true
    end
    if message.type == "Q" then
        local ctx = context(sync)
        local key = normalized(fields[1]); local peer = sync.peers[key]
        if channel ~= "WHISPER" or not senderMatches(fields[1], sender) or fields[2] ~= sync.guildKey
            or fields[4] ~= sync.sessionToken or not peer or peer.sessionToken ~= fields[3]
            or not peer.tabs[tonumber(fields[6])] or not ctx or not ctx.viewableTabIDs[tonumber(fields[6])] then
            return false, "bank-sync-request-unbound"
        end
        local snapshotOK, snapshot, err = apiCall(sync.bankAPI.GetGuildBankSyncSnapshot, tonumber(fields[6]), ctx.sessionToken)
        if not snapshotOK or type(snapshot) ~= "table" or snapshot.id ~= tonumber(fields[6]) then return false, err or snapshot or "guild-tab-snapshot-unavailable" end
        local sent, sendErr = GGM.SendBankSyncSnapshot(sync.transport, sender,
            { fields[1], fields[2], fields[3], fields[4], fields[5], fields[6] }, snapshot,
            function(success) if not success then sync.error = "bank-sync-snapshot-send-failed" end end)
        return sent, sendErr
    end
    if message.type == "S" then
        if not validateSnapshotResponse(sync, sender, fields) then return false, "bank-sync-response-unbound" end
        local entry = sync.current
        local ok, merged, err = apiCall(sync.bankAPI.MergeGuildBankSyncSnapshot, entry.guildKey, entry.localToken, entry.tabID, fields[7])
        sync.pending[entry.requestID] = nil
        cancelTimer(sync, "responseTimer")
        if ok and merged then setStatus(sync, "Guild tab updated") else setStatus(sync, "Guild tab already current") end
        if not ok or err then sync.error = err or "bank-sync-merge-failed" end
        advanceAfterRequest(sync)
        return true, err
    end
    return false, "bank-sync-message-unsupported"
end

function GGM.CreateBankSync(api)
    api = api or _G
    local bankAPI = type(api) == "table" and api.DysbankMemoryAPI or nil
    local supported = type(bankAPI) == "table" and bankAPI.schemaVersion == 1
        and type(bankAPI.GetGuildBankSyncContext) == "function"
        and type(bankAPI.GetGuildBankSyncSnapshot) == "function"
        and type(bankAPI.MergeGuildBankSyncSnapshot) == "function"
    local sync = { api = api, bankAPI = supported and bankAPI or nil, available = supported,
        status = supported and "Waiting for guild bank access" or "Bank sync unavailable",
        peers = {}, peerCount = 0, processed = {}, pending = {}, peerQueue = {}, peerIndex = 1,
        manualPending = false, manualActive = false, requestSequence = 0, generation = 0,
        sessionActive = false, assembler = P and P.NewManifestAssembler(function() return api.GetTime() end) }
    if not supported then sync.error = "bank-companion-unavailable"; return sync, sync.error end
    local transport, err = GGM.CreateBankSyncTransport(api, function(message, sender, channel)
        return handleMessage(sync, message, sender, channel)
    end)
    if not transport then sync.available = false; sync.error = err; sync.status = "Bank sync unavailable"; return sync, err end
    sync.transport = transport
    return sync, nil
end

function GGM.RegisterBankSync(sync)
    if type(sync) ~= "table" or not sync.available or not sync.transport then return false, sync and sync.error or "bank-sync-unavailable" end
    if sync.registrationAttempted then return sync.registered == true, sync.registerError end
    sync.registrationAttempted = true
    local registered, err = GGM.RegisterBankSyncTransport(sync.transport)
    sync.registered, sync.registerError = registered == true, err
    if not sync.registered then sync.available = false; sync.error = err; sync.status = "Bank sync unavailable" end
    return sync.registered, err
end

function GGM.CancelBankSync(sync, reason)
    if type(sync) ~= "table" then return false end
    local oldToken, oldGuild, oldSender = sync.sessionToken, sync.guildKey, sync.senderKey
    local wasActive = sync.sessionActive
    sync.generation = sync.generation + 1
    clearWork(sync, true)
    cancelTimer(sync, "peerExpiryTimer")
    sync.peers, sync.peerCount, sync.processed, sync.assembler = {}, 0, {}, P.NewManifestAssembler(function() return sync.api.GetTime() end)
    sync.sessionActive = false
    sync.sessionToken, sync.guildKey, sync.senderKey = nil, nil, nil
    if sync.transport then
        GGM.CancelBankSyncTransport(sync.transport, reason or "bank-sync-cancelled")
        if wasActive and oldToken and oldGuild and oldSender and reason ~= "guild-session-changed" then
            GGM.SetBankSyncTransportIdentity(sync.transport, oldSender, oldToken)
            GGM.SendBankSyncMessage(sync.transport, "E", { oldSender, oldGuild, oldToken }, nil, "GUILD")
        end
    end
    setStatus(sync, sync.available and "Waiting for guild bank access" or "Bank sync unavailable")
    return true
end

local function startSession(sync)
    local ctx, err = context(sync)
    if not ctx then setStatus(sync, "Bank sync unavailable"); sync.error = err; return false, err end
    local identity, identityErr = currentIdentity(sync)
    if not identity then sync.error = identityErr; return false, identityErr end
    if sync.sessionActive and sync.sessionToken == ctx.sessionToken and sync.guildKey == ctx.guildKey then return true end
    if sync.sessionActive then GGM.CancelBankSync(sync, "guild-session-changed") end
    sync.generation = sync.generation + 1
    sync.sessionActive, sync.guildKey, sync.sessionToken, sync.senderKey = true, ctx.guildKey, ctx.sessionToken, identity.key
    sync.peers, sync.peerCount, sync.processed, sync.pending = {}, 0, {}, {}
    sync.assembler = P.NewManifestAssembler(function() return sync.api.GetTime() end)
    local ok, identityErr = GGM.SetBankSyncTransportIdentity(sync.transport, identity.key, ctx.sessionToken)
    if not ok then GGM.CancelBankSync(sync, identityErr); return false, identityErr end
    setStatus(sync, "Checking available guild snapshots")
    publishManifest(sync)
    return true
end

function GGM.HandleBankSyncAddonMessage(sync, prefix, message, distribution, sender)
    if type(sync) ~= "table" or not sync.available or not sync.transport then return false, sync and sync.error or "bank-sync-unavailable" end
    if prefix ~= P.PREFIX then return false end
    local function validate(senderName, fields)
        return validateSnapshotResponse(sync, senderName, fields)
    end
    local state, err = GGM.ReceiveBankSyncFrame(sync.transport, prefix, message, distribution, sender, validate)
    return state, err
end

function GGM.HandleBankSyncEvent(sync, event)
    if type(sync) ~= "table" then return false end
    if event == "GUILDBANKFRAME_CLOSED" then return GGM.CancelBankSync(sync, "guild-bank-closed") end
    if event == "PLAYER_GUILD_UPDATE" and sync.sessionActive then
        local ctx = context(sync)
        if not ctx or ctx.guildKey ~= sync.guildKey or ctx.sessionToken ~= sync.sessionToken then
            return GGM.CancelBankSync(sync, "guild-session-changed")
        end
        return false
    end
    if event == "GUILD_ROSTER_UPDATE" then
        if expirePeers(sync) and sync.sessionActive then
            buildPeerQueue(sync)
            if #sync.peerQueue > 0 then drive(sync) else
                sync.manualPending = false
                sync.manualActive = false
                setStatus(sync, "Waiting for guild caches")
            end
        end
        return true
    end
    return false
end

function GGM.OnBankMemoryChanged(sync, reason, tabID)
    if type(sync) ~= "table" then return false end
    if reason == "guild-session-close" then return GGM.CancelBankSync(sync, "guild-bank-closed") end
    if reason == "guild-session-open" then return startSession(sync) end
    if not sync.sessionActive then return false end
    if reason == "guild-metadata" then return publishManifest(sync) end
    if reason == "guild-capture" then
        sync.lastCapturedTab = tabID
        return schedule(sync, "captureTimer", CAPTURE_DEBOUNCE, function() publishManifest(sync) end)
    end
    if reason == "remote-merge" then
        -- The saved snapshot retains its original capture timestamp and digest.
        return publishManifest(sync)
    end
    return false
end

function GGM.RequestBankSyncFromButton(sync)
    if type(sync) ~= "table" or not sync.available then return false, sync and sync.error or "bank-sync-unavailable" end
    if not sync.sessionActive then return false, "Open an accessible guild bank tab first" end
    if sync.manualPending or sync.manualActive then return true, nil end
    sync.processed = {}
    sync.manualPending = sync.current ~= nil
    sync.manualActive = sync.current == nil
    publishManifest(sync)
    if not sync.current then
        buildPeerQueue(sync)
        drive(sync)
    else
        setStatus(sync, "Guild sync queued")
    end
    return true, nil
end

function GGM.GetBankSyncStatus(sync)
    if type(sync) ~= "table" then return "Bank sync unavailable" end
    return sync.status or (sync.available and "Waiting for guild bank access" or "Bank sync unavailable")
end

