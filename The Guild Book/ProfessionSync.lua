local _, GGM = ...

local PREFIX = "GC_PROF3"
local PROFESSIONS = { 164, 165, 171, 197, 202, 333 }
local SUPPORTED = {}
for _, professionID in ipairs(PROFESSIONS) do SUPPORTED[professionID] = true end
local MAX_RECORDS, MAX_PAGES, PAGE_SIZE = 4, 4, 32
local COOLDOWN, TTL, MAX_MANUAL_PEERS = 60, 300, 4
-- Leave one session TTL and cooldown for each of the four allowed peers.
local MANUAL_OPERATION_SECONDS = MAX_MANUAL_PEERS * (TTL + COOLDOWN)
local CLAIM_START_SECONDS, CLAIM_SPREAD_SECONDS = 0.1, 1
local ELECTION_SECONDS, RESPONSE_DEADLINE_SECONDS = 2, 27
local PRESENCE_EVIDENCE_SECONDS, CATALOG_REFRESH_DELAY = 60, 5
local MAX_KNOWN_RECIPE_IDS, BLOOM_BITS_PER_ID = 2048, 8
local BLOOM_MAX_BITS, BLOOM_PROBES = MAX_KNOWN_RECIPE_IDS * BLOOM_BITS_PER_ID, 5
local BLOOM_MULTIPLIERS, BLOOM_OFFSETS = { 17, 31, 47, 61, 73 }, { 1, 3, 5, 7, 9 }
local continueManualOperation, finishManualOperation, cancelManualOperation
local function integer(value, low, high) return GGM.IsProfessionSyncInteger(value, low, high) end
local function split(text, separator)
    local result, start = {}, 1
    while true do
        local found = text:find(separator, start, true)
        if not found then result[#result + 1] = text:sub(start); return result end
        result[#result + 1] = text:sub(start, found - 1)
        start = found + #separator
    end
end
local function encode(text) return (text:gsub("[^%w %-]", function(byte) return string.format("%%%02X", byte:byte()) end)) end
local function decode(text, maximum)
    if type(text) ~= "string" or #text > maximum * 3 or text:find("%%[^%x]")
        or text:find("%%.$") or text:sub(-1) == "%" then return nil end
    if text:gsub("%%(%x%x)", ""):find("%%") then return nil end
    local decoded = text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    if #decoded > maximum or decoded:find("[%z\1-\31\127]") then return nil end
    return decoded
end
local function hash(value) return type(value) == "string" and #value == 16 and value:match("^%x+$") ~= nil end
local function key(value) return type(value) == "string" and value:gsub("%s", ""):lower() or nil end
local function now(sync) return sync.api.GetTime() end
local function finiteTime(value)
    return type(value) == "number" and value >= 0 and value == value and value ~= math.huge and value ~= -math.huge
end
local function jitter(sync, low, high)
    local random = sync.api.random or math.random
    local ok, value = pcall(random, low, high)
    return ok and integer(value, low, high) and value or low
end
local function readable(sync, value)
    if type(sync.api.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(sync.api.issecretvalue, value)
    return ok and secret == false
end
local function notify(sync, professionID, message)
    sync.status[professionID] = message
    if type(GGM.RefreshVisibleProfessionSyncStatus) == "function" then GGM.RefreshVisibleProfessionSyncStatus() end
end
local function manualOperationHasConflict(operation)
    return operation and (operation.conflict or (operation.currentSession and operation.currentSession.conflict)) or false
end
local function safe(sync)
    if not sync.registered or not sync.rosterReady then return false end
    if type(sync.api.InCombatLockdown) ~= "function" then return false end
    local ok, combat = pcall(sync.api.InCombatLockdown)
    return ok and readable(sync, combat) and combat == false
end
local function timer(sync, delay, fn)
    local generation = sync.generation
    local ok, value = pcall(sync.api.C_Timer.NewTimer, delay, function()
        if sync.generation == generation then fn() end
    end)
    if not ok or not value then return false end
    return true, value
end

local function visibleCatalogRefresh(sync)
    if not sync.catalogDirty then return end
    sync.catalogDirty = false
    if type(GGM.RefreshVisibleProfessionCatalog) == "function" then
        pcall(GGM.RefreshVisibleProfessionCatalog)
    end
end

local function flushCatalogRefresh(sync)
    sync.catalogRefreshToken = (sync.catalogRefreshToken or 0) + 1
    local pending = sync.catalogRefreshTimer
    sync.catalogRefreshTimer, sync.catalogRefreshScheduled = nil, false
    if type(pending) == "table" and type(pending.Cancel) == "function" then pcall(pending.Cancel, pending) end
    visibleCatalogRefresh(sync)
end

local function scheduleCatalogRefresh(sync)
    sync.catalogDirty = true
    if sync.catalogRefreshScheduled then return end
    sync.catalogRefreshScheduled = true
    sync.catalogRefreshToken = (sync.catalogRefreshToken or 0) + 1
    local token = sync.catalogRefreshToken
    local ok, pending = pcall(sync.api.C_Timer.NewTimer, CATALOG_REFRESH_DELAY, function()
        if sync.catalogRefreshToken ~= token then return end
        sync.catalogRefreshTimer, sync.catalogRefreshScheduled = nil, false
        visibleCatalogRefresh(sync)
    end)
    if not ok or not pending then
        sync.catalogRefreshScheduled = false
        visibleCatalogRefresh(sync)
        return
    end
    sync.catalogRefreshTimer = pending
end

local function canSendTarget(sync, target)
    local sender = key(target)
    local identity = sender and sync.senders and sync.senders[sender]
    local presence = identity and identity.presence
    if not presence then return false end
    if presence.online == true then return true end
    local evidence = sync.presenceEvidence and sync.presenceEvidence[sender]
    if not evidence or evidence.revision <= presence.revision then return false end
    local ok, at = pcall(sync.api.GetTime)
    if not ok or not readable(sync, at) or not finiteTime(at) then return false end
    return at >= evidence.at and at - evidence.at <= PRESENCE_EVIDENCE_SECONDS
end

local function recordValidPresence(sync, sender)
    if not sync.senders[sender] then return end
    local ok, at = pcall(sync.api.GetTime)
    if not ok or not readable(sync, at) or not finiteTime(at) then return end
    sync.presenceRevision = (sync.presenceRevision or 0) + 1
    sync.presenceEvidence[sender] = { at = at, revision = sync.presenceRevision }
    for peer, evidence in pairs(sync.presenceEvidence) do
        if not sync.senders[peer] or at < evidence.at or at - evidence.at > PRESENCE_EVIDENCE_SECONDS then
            sync.presenceEvidence[peer] = nil
        end
    end
end

local function acceptPeerMessage(sync, sender)
    recordValidPresence(sync, sender)
end

local function bloomIndexes(recipeID, bits)
    local indexes = {}
    for index = 1, BLOOM_PROBES do
        indexes[index] = ((recipeID * BLOOM_MULTIPLIERS[index] + BLOOM_OFFSETS[index]) % bits) + 1
    end
    return indexes
end

local function buildBloom(ids)
    local count = #ids
    if count == 0 then return "0", "-" end
    local bits = count * BLOOM_BITS_PER_ID
    local bytes = {}
    for _, recipeID in ipairs(ids) do
        for _, bitIndex in ipairs(bloomIndexes(recipeID, bits)) do
            local byteIndex = math.floor((bitIndex - 1) / 8) + 1
            local mask = 2 ^ ((bitIndex - 1) % 8)
            local byte = bytes[byteIndex] or 0
            if math.floor(byte / mask) % 2 == 0 then bytes[byteIndex] = byte + mask end
        end
    end
    local encoded = {}
    for index = 1, bits / 8 do encoded[index] = string.format("%02x", bytes[index] or 0) end
    return tostring(bits), table.concat(encoded)
end

local function knownMetadataFilters(sync, professionID)
    local index = sync.db.professionRecipeIndex[professionID] or {}
    if type(index) ~= "table" then return "0", "-", "0", "-" end
    local names, icons, count, scanned = {}, {}, 0, 0
    for recipeID, entry in pairs(index) do
        if count >= MAX_KNOWN_RECIPE_IDS or scanned >= MAX_KNOWN_RECIPE_IDS * 4 then break end
        scanned = scanned + 1
        if integer(recipeID, 1, 2147483647) and type(entry) == "table" then
            local hasName = type(entry.name) == "string" and entry.name ~= "" and entry.name ~= "Recipe " .. recipeID
            local hasIcon = integer(entry.outputIcon, 1, 2147483647)
            if hasName or hasIcon then
                count = count + 1
                if hasName then names[#names + 1] = recipeID end
                if hasIcon then icons[#icons + 1] = recipeID end
            end
        end
    end
    local nameBits, nameFilter = buildBloom(names)
    local iconBits, iconFilter = buildBloom(icons)
    return nameBits, nameFilter, iconBits, iconFilter
end

local function parseBloom(bitsText, encoded)
    if bitsText == "0" then return encoded == "-" and { bits = 0, bytes = {} } or nil end
    if type(bitsText) ~= "string" or not bitsText:match("^%d+$") then return nil end
    local bits = tonumber(bitsText)
    if not integer(bits, BLOOM_BITS_PER_ID, BLOOM_MAX_BITS) or bits % 8 ~= 0
        or type(encoded) ~= "string" or #encoded ~= bits / 4 or #encoded > BLOOM_MAX_BITS / 4
        or not encoded:match("^%x+$") then return nil end
    local bytes = {}
    for index = 1, #encoded, 2 do bytes[#bytes + 1] = tonumber(encoded:sub(index, index + 1), 16) end
    return { bits = bits, bytes = bytes }
end

local function bloomContains(filter, recipeID)
    if not filter or filter.bits == 0 then return false end
    for _, bitIndex in ipairs(bloomIndexes(recipeID, filter.bits)) do
        local byte = filter.bytes[math.floor((bitIndex - 1) / 8) + 1] or 0
        local mask = 2 ^ ((bitIndex - 1) % 8)
        if math.floor(byte / mask) % 2 == 0 then return false end
    end
    return true
end

function GGM.CancelProfessionSync(sync)
    if not sync then return end
    local operation = sync.manualOperation
    local conflictProfession = manualOperationHasConflict(operation) and operation.professionID or nil
    sync.generation = sync.generation + 1
    flushCatalogRefresh(sync)
    if sync.manualOperation then sync.manualOperation.cancelled = true end
    sync.manualOperation = nil
    sync.sessions, sync.pending, sync.pendingSaves, sync.active = {}, {}, {}, nil
    if sync.transport then GGM.CancelProfessionTransport(sync.transport) end
    for professionID in pairs(sync.status) do
        notify(sync, professionID, professionID == conflictProfession and "Conflict: fresh observation needed" or "Sync unavailable")
    end
end

local function failed(sync, err)
    sync.lastError = err
    GGM.CancelProfessionSync(sync)
end
local function send(sync, kind, recipient, id, professionID, body, onFinished)
    if not safe(sync) then failed(sync, "profession-sync-unavailable"); return false end
    local payload = table.concat({ "P3", kind, recipient or "*", id, tostring(professionID), body or "" }, "|")
    local private = kind == "M" or kind == "R" or kind == "D" or kind == "T" or kind == "K"
    local identity = private and sync.senders[recipient]
    if private and not identity then return false end
    local ok, err = GGM.SendProfessionPayload(sync.transport, payload, identity and identity.key or nil, onFinished)
    if not ok then failed(sync, err) end
    return ok
end
local function nextID(sync)
    sync.sequence = sync.sequence + 1
    return tostring(math.floor(now(sync) * 1000) % 1000000000) .. "-" .. sync.sequence
end
local function sessionKey(sender, id) return sender .. ":" .. id end
local function findSession(sync, initiator, id) return sync.sessions[sessionKey(initiator, id)] end
local drainPending
local function createSession(sync, initiator, id, professionID, digest, reason, startGUID, preferredPeer)
    local count = 0
    for _, session in pairs(sync.sessions) do if not session.finished then count = count + 1 end end
    if count >= 4 then return nil end
    local session = {
        initiator = initiator, id = id, professionID = professionID, digest = digest, reason = reason,
        manifests = {}, manifestPages = {}, claims = {}, dataSeen = {}, requested = {}, startedAt = now(sync),
        startGUID = startGUID or "", preferredPeer = preferredPeer, manifestTruncated = {},
    }
    sync.sessions[sessionKey(initiator, id)] = session
    if not timer(sync, TTL, function()
        if not session.finished then
            session.finished = true
            if sync.active == session then sync.active = nil end
            if session.operation then
                cancelManualOperation(sync, session.operation, "Catch-up needed")
            else
                if sync.selfKey == session.initiator or sync.selfKey == session.selected then notify(sync, professionID, "Catch-up needed") end
                timer(sync, 0.5, function() drainPending(sync) end)
            end
        end
        sync.sessions[sessionKey(initiator, id)] = nil
    end) then failed(sync, "profession-sync-timer-unavailable"); return nil end
    return session
end

function GGM.RefreshProfessionSyncRoster(sync)
    local api = sync.api
    local timeOk, observedAt = pcall(api.GetTime)
    if not timeOk or not readable(sync, observedAt) or not finiteTime(observedAt) then
        sync.rosterReady = false
        GGM.CancelProfessionSync(sync)
        return false, "profession-sync-roster-unavailable"
    end
    local presenceRevision = (sync.presenceRevision or 0) + 1
    local ok, inGuild = pcall(api.IsInGuild)
    if not ok or not readable(sync, inGuild) or inGuild ~= true then
        sync.rosterReady = false
        GGM.CancelProfessionSync(sync)
        return false, "profession-sync-not-in-guild"
    end
    local rowsOk, rows = pcall(function()
        local count = api.GetNumGuildMembers(true)
        if not readable(sync, count) or not integer(count, 1, 1000) then return nil end
        local byGUID, bySender = {}, {}
        for index = 1, count do
            local row = { api.GetGuildRosterInfo(index) }
            if not readable(sync, row[1]) or not readable(sync, row[17])
                or type(row[1]) ~= "string" or #row[1] > 256 or not GGM.IsProfessionGUID(row[17]) then return nil end
            local name, realm = row[1]:match("^([^-]+)%-(.+)$")
            if not name then name, realm = row[1], api.GetRealmName() end
            if not readable(sync, realm) or type(realm) ~= "string" or realm == "" then return nil end
            local online
            if readable(sync, row[9]) and type(row[9]) == "boolean" then online = row[9] end
            local identity = { key = name .. "-" .. realm, name = name, realm = realm, guid = row[17],
                presence = { online = online, observedAt = observedAt, revision = presenceRevision } }
            local sender = key(identity.key)
            if byGUID[identity.guid] or bySender[sender] then return nil end
            byGUID[identity.guid], bySender[sender] = identity, identity
        end
        local selfGUID = api.UnitGUID("player")
        if not readable(sync, selfGUID) then return nil end
        local identity = byGUID[selfGUID]
        local guildName, _, _, guildRealm = api.GetGuildInfo("player")
        if not identity or not readable(sync, guildName) or not readable(sync, guildRealm) or type(guildName) ~= "string" then return nil end
        return { byGUID = byGUID, bySender = bySender, selfKey = key(identity.key), selfGUID = selfGUID,
            presenceRevision = presenceRevision,
            guild = guildName .. ":" .. (guildRealm or api.GetRealmName()) }
    end)
    if not rowsOk or not rows then
        sync.rosterReady = false
        GGM.CancelProfessionSync(sync)
        return false, "profession-sync-roster-unavailable"
    end
    if sync.guild and sync.guild ~= rows.guild then
        GGM.CancelProfessionSync(sync)
        sync.peers, sync.heard, sync.cursor, sync.manualCursor, sync.presenceEvidence = {}, {}, {}, {}, {}
    end
    sync.members, sync.senders, sync.selfKey, sync.selfGUID, sync.guild = rows.byGUID, rows.bySender, rows.selfKey, rows.selfGUID, rows.guild
    sync.presenceRevision = rows.presenceRevision
    for sender, evidence in pairs(sync.presenceEvidence or {}) do
        if not sync.senders[sender] or observedAt < evidence.at or observedAt - evidence.at > PRESENCE_EVIDENCE_SECONDS then
            sync.presenceEvidence[sender] = nil
        end
    end
    sync.rosterReady = true
    if sync.active then
        local peer
        if sync.active.initiator == sync.selfKey then peer = sync.active.selected
        elseif sync.active.selected == sync.selfKey then peer = sync.active.initiator end
        if (not rows.bySender[sync.active.initiator]
            or (sync.active.selected and not rows.bySender[sync.active.selected])
            or (peer and not canSendTarget(sync, peer))) then GGM.CancelProfessionSync(sync) end
    end
    return true, nil
end

local function manifest(sync, professionID)
    local rows, err = GGM.GetProfessionSyncManifest(sync.db, professionID)
    if not rows then return nil, err end
    local filtered = {}
    for _, row in ipairs(rows) do if sync.members[row.guid] then filtered[#filtered + 1] = row end end
    return filtered, nil
end
local function completeManifest(sync, session, sender, rows, truncated)
    session.manifests[sender] = rows
    session.manifestTruncated[sender] = truncated
    if truncated then session.truncated = true end
end
local planTransfers, maybeFinish, requestNext
local function sendManifest(sync, session)
    local rows, err = manifest(sync, session.professionID)
    if not rows then failed(sync, err); return false end
    local limited = {}
    local eligible = {}
    for _, row in ipairs(rows) do if row.guid > session.startGUID then eligible[#eligible + 1] = row end end
    for index = 1, math.min(PAGE_SIZE * MAX_PAGES, #eligible) do limited[#limited + 1] = eligible[index] end
    -- Both peers use the initiator's GUID range. Absence beyond a truncated
    -- window is unknown, never evidence that a record is missing.
    local pages = math.max(1, math.ceil(#limited / PAGE_SIZE))
    completeManifest(sync, session, sync.selfKey, limited, #limited < #eligible)
    for page = 1, pages do
        local parts = { page .. "," .. pages .. "," .. (#limited < #eligible and "1" or "0") }
        for index = (page - 1) * PAGE_SIZE + 1, math.min(page * PAGE_SIZE, #limited) do
            local row = limited[index]
            parts[#parts + 1] = table.concat({ row.guid, tostring(row.capturedAt), row.hash }, ",")
        end
        local peer = sync.selfKey == session.initiator and session.selected or session.initiator
        if not send(sync, "M", peer, session.id, session.professionID,
            session.initiator .. ";" .. table.concat(parts, ";")) then return false end
    end
    planTransfers(sync, session)
    return true
end

drainPending = function(sync)
    if sync.active or sync.manualOperation then return end
    local selected
    for professionID, pending in pairs(sync.pending) do
        if pending.ready and (not selected or professionID < selected) then selected = professionID end
    end
    if not selected then return end
    local pending = sync.pending[selected]
    local remaining = (sync.cooldowns[selected] or -COOLDOWN) + COOLDOWN - now(sync)
    if remaining > 0 then
        pending.ready = false
        timer(sync, remaining, function()
            if sync.pending[selected] ~= pending then return end
            pending.ready = true
            drainPending(sync)
        end)
        return
    end
    sync.pending[selected] = pending.following
    if pending.following then pending.following.ready = true end
    local peer = pending.preferredPeer and sync.peers[pending.preferredPeer]
    if peer and peer[selected] == GGM.GetProfessionSyncDigest(sync.db, selected, sync.members) then
        timer(sync, 0.5, function() drainPending(sync) end)
        return
    end
    local accepted = GGM.RequestProfessionSync(sync, selected, pending.reason, pending.preferredPeer)
    if not accepted then
        notify(sync, selected, "Catch-up needed")
        -- The failed job is removed. Continue only the finite remaining queue,
        -- never retry an unavailable peer or generate a new comparison.
        if next(sync.pending) then timer(sync, 0.5, function() drainPending(sync) end) end
    end
end

local function scheduleComparison(sync, professionID, reason, preferredPeer)
    if preferredPeer and not canSendTarget(sync, preferredPeer) then
        notify(sync, professionID, "Catch-up needed")
        return
    end
    if sync.pending[professionID] then
        local item, count = sync.pending[professionID], 1
        while true do
            if item.preferredPeer == preferredPeer then
                if reason == "login" then item.reason = "login" end
                return
            end
            if not item.following then break end
            item, count = item.following, count + 1
        end
        -- Retain independent announcements without turning a burst into an
        -- unbounded cache sweep. Overflow remains explicitly catch-up needed.
        if count >= 4 then notify(sync, professionID, "Catch-up needed"); return end
        item.following = { reason = reason, preferredPeer = preferredPeer, ready = true }
        return
    end
    local pending = { reason = reason, preferredPeer = preferredPeer }
    sync.pending[professionID] = pending
    local order = 0
    for sender in pairs(sync.senders) do if sender < sync.selfKey then order = order + 1 end end
    local delay = math.max(1 + order * 0.1 + jitter(sync, 0, 2),
        (sync.cooldowns[professionID] or -COOLDOWN) + COOLDOWN - now(sync))
    timer(sync, delay, function()
        if sync.pending[professionID] ~= pending then return end
        pending.ready = true
        drainPending(sync)
    end)
end

local function peerLabel(sync, peer)
    local identity = peer and sync.senders[peer]
    return identity and identity.name or peer or "peer"
end

local function statusForPeer(sync, session, message)
    local peer = sync.selfKey == session.initiator and session.selected or session.initiator
    if message == "Cache hashes match" then return "Matches " .. peerLabel(sync, peer) .. " cache" end
    if message == "Compared cached data" then return "Compared with " .. peerLabel(sync, peer) end
    return message
end

local function finish(sync, session, message)
    if session.finished then return end
    session.finished = true
    if sync.active == session then sync.active = nil end
    if sync.selfKey == session.initiator and session.nextCursor ~= nil then
        sync.cursor[session.professionID] = sync.cursor[session.professionID] or {}
        sync.cursor[session.professionID][session.selected] = session.nextCursor
    end
    local operation = session.operation
    if operation and sync.manualOperation == operation and sync.selfKey == session.initiator then
        if operation.currentSession == session then operation.currentSession = nil end
        if message == "Cache hashes match" then
            operation.matches = operation.matches + 1
            operation.completed = operation.completed + 1
        elseif message == "Compared cached data" then
            operation.completed = operation.completed + 1
        elseif message == "Conflict: fresh observation needed" then
            operation.conflict = true
        else
            operation.uncertain = true
        end
        if session.truncated or message == "Catch-up needed" then operation.uncertain = true end
    end
    if sync.selfKey == session.initiator or sync.selfKey == session.selected then
        flushCatalogRefresh(sync)
        if not operation then notify(sync, session.professionID, statusForPeer(sync, session, message)) end
    end
    if sync.selfKey == session.initiator or sync.selfKey == session.selected then
        local peer = sync.selfKey == session.initiator and session.selected or session.initiator
        if peer and message ~= "Conflict: fresh observation needed" and message ~= "Sync unavailable" then
            local digest = GGM.GetProfessionSyncDigest(sync.db, session.professionID, sync.members)
            if message == "Cache hashes match" or message == "Compared cached data" then
                sync.peers[peer] = sync.peers[peer] or {}; sync.peers[peer][session.professionID] = digest
            end
        end
    end
    if operation and sync.manualOperation == operation and sync.selfKey == session.initiator then
        notify(sync, session.professionID, "Comparing cached data")
        timer(sync, 0.5, function() continueManualOperation(sync, operation) end)
    else
        timer(sync, 0.5, function() drainPending(sync) end)
    end
end
maybeFinish = function(sync, session)
    if session.finished or not session.plan then return end
    for _, item in ipairs(session.plan) do if not session.dataSeen[item.guid] then return end end
    local message = session.conflict and "Conflict: fresh observation needed"
        or session.truncated and "Catch-up needed" or "Compared cached data"
    if sync.selfKey == session.initiator then
        send(sync, "F", "*", session.id, session.professionID, message)
    end
    finish(sync, session, message)
end
planTransfers = function(sync, session)
    if session.plan or not session.selected or not session.manifests[session.initiator] or not session.manifests[session.selected] then return end
    local left, right, guids = {}, {}, {}
    local boundary
    for _, sender in ipairs({ session.initiator, session.selected }) do
        local rows = session.manifests[sender]
        if session.manifestTruncated[sender] and #rows > 0 then
            local last = rows[#rows].guid
            if not boundary or last < boundary then boundary = last end
        end
    end
    for _, row in ipairs(session.manifests[session.initiator]) do
        if not boundary or row.guid <= boundary then left[row.guid] = row; guids[row.guid] = true end
    end
    for _, row in ipairs(session.manifests[session.selected]) do
        if not boundary or row.guid <= boundary then right[row.guid] = row; guids[row.guid] = true end
    end
    local sorted = {}
    for guid in pairs(guids) do sorted[#sorted + 1] = guid end
    table.sort(sorted)
    local plan = {}
    for _, guid in ipairs(sorted) do
        local a, b = left[guid], right[guid]
        local provider, row, action
        if not a then provider, row, action = session.selected, b, "record"
        elseif not b then provider, row, action = session.initiator, a, "record"
        elseif a.hash == b.hash and a.capturedAt ~= b.capturedAt then
            if a.capturedAt > b.capturedAt then provider, row = session.initiator, a
            else provider, row = session.selected, b end
            action = "fresh"
        elseif a.hash ~= b.hash and a.capturedAt == b.capturedAt then
            session.conflict = true
        elseif a.hash ~= b.hash then
            if a.capturedAt > b.capturedAt then provider, row = session.initiator, a
            else provider, row = session.selected, b end
            action = "record"
        end
        if row then
            if #plan < MAX_RECORDS then
                plan[#plan + 1] = { guid = guid, capturedAt = row.capturedAt,
                    hash = row.hash, action = action, provider = provider,
                    recipient = provider == session.initiator and session.selected or session.initiator }
            else session.truncated = true; session.budgetLimited = true end
        end
    end
    session.plan = plan
    if #plan == 0 and not session.truncated and session.digest ~= session.claims[session.selected] then
        session.conflict = true
    end
    session.nextCursor = session.budgetLimited and session.startGUID or boundary or ""
    requestNext(sync, session)
    maybeFinish(sync, session)
end

requestNext = function(sync, session)
    if session.finished then return end
    -- At most one outstanding record in each direction. Four large records
    -- must never be queued together or exceed this exchange's lifetime.
    for _, item in ipairs(session.plan) do
        if item.recipient == sync.selfKey and session.requested[item.guid] and not session.dataSeen[item.guid] then return end
    end
    for _, item in ipairs(session.plan) do
        if item.recipient == sync.selfKey and not session.dataSeen[item.guid] then
            local reason
            if item.guid == sync.selfGUID or GGM.IsLocalCharacterGUID(sync.db, item.guid) then
                reason = "skip"; session.conflict = true
            elseif item.action == "fresh" then
                local localRecord, localErr = GGM.GetProfessionSyncRecord(sync.db, item.guid, session.professionID)
                if not localRecord then
                    if localErr ~= "profession-sync-record-missing" then failed(sync, localErr); return end
                    reason = "defer"; session.truncated = true; session.nextCursor = session.startGUID
                elseif localRecord.hash ~= item.hash then
                    reason = "skip"; session.conflict = true
                elseif localRecord.capturedAt >= item.capturedAt then
                    reason = "defer"; session.truncated = true; session.nextCursor = session.startGUID
                end
            elseif now(sync) - session.startedAt > TTL - 170 then
                reason = "defer"; session.truncated = true; session.nextCursor = session.startGUID
            end
            if reason then
                session.dataSeen[item.guid] = true
                if not send(sync, "K", item.provider, session.id, session.professionID,
                    session.initiator .. ";" .. item.guid .. ";" .. item.capturedAt .. ";" .. reason) then return end
            else
                session.requested[item.guid] = true
                local action, nameBits, nameFilter, iconBits, iconFilter = item.action, "0", "-", "0", "-"
                if action == "record" then
                    nameBits, nameFilter, iconBits, iconFilter = knownMetadataFilters(sync, session.professionID)
                end
                send(sync, "R", item.provider, session.id, session.professionID,
                    table.concat({ session.initiator, item.guid, item.capturedAt, item.hash, action,
                        nameBits, nameFilter, iconBits, iconFilter }, ";"))
                return
            end
        end
    end
end

local function recordBody(record, knownNames, knownIcons)
    local rows, remaining = {}, 58000
    for _, recipe in ipairs(record.recipes) do remaining = remaining - #tostring(recipe.recipeID) - 3 end
    for _, recipe in ipairs(record.recipes) do
        local label = bloomContains(knownNames, recipe.recipeID) and "" or encode(recipe.name)
        local icon = recipe.outputIcon and not bloomContains(knownIcons, recipe.recipeID) and tostring(recipe.outputIcon) or ""
        if #label + #icon > remaining then label, icon = "", "" end
        remaining = remaining - #label - #icon
        rows[#rows + 1] = tostring(recipe.recipeID) .. ":" .. label .. ":" .. icon
    end
    return table.concat({ record.guid, record.hash, tostring(record.capturedAt), record.source,
        encode(record.professionName), table.concat(rows, ",") }, ";")
end
local function parseRecord(sync, session, body)
    local fields = split(body, ";")
    if #fields ~= 6 or not sync.members[fields[1]] or not hash(fields[2]) then return nil end
    local capturedAt = tonumber(fields[3])
    local clockOk, clock = pcall(sync.api.GetServerTime)
    if not integer(capturedAt, 1, 4294967295) or not clockOk or not readable(sync, clock)
        or not integer(clock, 1, 4294967295) or capturedAt > clock + 300 then return nil end
    local professionName = decode(fields[5], GGM.PROFESSION_MAX_NAME_BYTES)
    if not professionName or professionName == "" then return nil end
    local recipes = {}
    if fields[6] ~= "" then
        for _, token in ipairs(split(fields[6], ",")) do
            local bits = split(token, ":")
            if #bits ~= 3 or #recipes >= GGM.PROFESSION_MAX_RECIPES then return nil end
            local recipeID, icon = tonumber(bits[1]), bits[3] ~= "" and tonumber(bits[3]) or nil
            if not integer(recipeID, 1, 2147483647) or (bits[3] ~= "" and not integer(icon, 1, 2147483647)) then return nil end
            local label = decode(bits[2], GGM.PROFESSION_MAX_NAME_BYTES)
            if not label then return nil end
            local localRecipe = (sync.db.professionRecipeIndex[session.professionID] or {})[recipeID]
            local localName = localRecipe and localRecipe.name
            if localName == "Recipe " .. recipeID then localName = nil end
            recipes[#recipes + 1] = { recipeID = recipeID,
                name = localName or (label ~= "" and label or "Recipe " .. recipeID),
                outputIcon = localRecipe and localRecipe.outputIcon or icon }
        end
    end
    local record = { guid = fields[1], hash = fields[2], capturedAt = capturedAt, source = fields[4], professionID = session.professionID,
        professionName = professionName, complete = true, status = "cached", recipes = recipes }
    if not GGM.ValidateProfessionCapture(record) or GGM.HashProfessionRecipes(session.professionID, recipes) ~= record.hash then return nil end
    return record
end

local COMPARISON_PRIORITY = { save = 1, selection = 2, manual = 3 }
local function yieldUnselectedComparison(sync, sender, reason)
    local session = sync.active
    if not session or session.finished or session.initiator ~= sync.selfKey or session.selected then return end
    local incoming, current = COMPARISON_PRIORITY[reason], COMPARISON_PRIORITY[session.reason]
    if not incoming or not current or incoming < current
        or (incoming == current and sender > sync.selfKey) then return end
    -- Simultaneous queries otherwise leave both initiators busy and unable to
    -- claim either comparison. Manual work wins, then the canonical sender key.
    -- Only yield before peer selection, when no record transfers have started.
    if session.operation and sync.manualOperation == session.operation then
        session.operation.uncertain = true
        finishManualOperation(sync, session.operation, "Catch-up needed")
    else
        session.finished = true
        sync.sessions[sessionKey(session.initiator, session.id)] = nil
        sync.active = nil
        notify(sync, session.professionID, "Catch-up needed")
    end
    return true
end

local function selectResponder(sync, session)
    if session.finished or sync.active ~= session or session.selected then return false end
    if not session.preferredPeer and not session.electionReady then return false end
    local chosen
    for candidate in pairs(session.claims) do
        if not chosen or candidate < chosen then chosen = candidate end
    end
    if not chosen then return false end
    sync.lastError = nil
    session.selected = chosen
    if session.claims[chosen] == session.digest
        and GGM.GetProfessionSyncDigest(sync.db, session.professionID, sync.members) == session.digest then
        send(sync, "F", "*", session.id, session.professionID, "Cache hashes match")
        finish(sync, session, "Cache hashes match")
    elseif send(sync, "S", chosen, session.id, session.professionID, "") then
        sendManifest(sync, session)
    end
    return true
end

local function logical(sync, payload, rawSender, channel)
    if not safe(sync) then return "ignored" end
    local sender = key(rawSender)
    if not sync.senders[sender] or sender == sync.selfKey then return "ignored" end
    local fields = split(payload, "|")
    if #fields ~= 6 or fields[1] ~= "P3" or #fields[4] > 32 or not fields[4]:match("^%d+%-%d+$") then return "ignored" end
    local kind, recipient, id, professionID, body = fields[2], fields[3], fields[4], tonumber(fields[5]), fields[6]
    local private = kind == "M" or kind == "R" or kind == "D" or kind == "T" or kind == "K"
    if private and (channel ~= "WHISPER" or recipient ~= sync.selfKey)
        or not private and channel ~= "GUILD" then return "ignored" end
    if recipient ~= "*" and not sync.senders[recipient] then return "ignored" end
    if kind == "A" then
        if recipient ~= "*" or professionID ~= 0 then return "ignored" end
        local seen, entries = {}, split(body, ";")
        if #entries > #PROFESSIONS then return "ignored" end
        for _, entry in ipairs(entries) do
            local bits = split(entry, ",")
            local pid = tonumber(bits[1])
            if #bits ~= 3 or not SUPPORTED[pid] or not hash(bits[2])
                or (bits[3] ~= "login" and bits[3] ~= "save" and bits[3] ~= "background") or seen[pid] then return "ignored" end
            seen[pid] = true
        end
        acceptPeerMessage(sync, sender)
        for _, entry in ipairs(entries) do
            local bits = split(entry, ",")
            local pid = tonumber(bits[1])
            sync.peers[sender] = sync.peers[sender] or {}; sync.peers[sender][pid] = bits[2]
            sync.heard[pid] = { digest = bits[2], at = now(sync) }
            local digest = GGM.GetProfessionSyncDigest(sync.db, pid, sync.members)
            if bits[3] == "save" and digest and digest ~= bits[2] then
                scheduleComparison(sync, pid, "save", sender)
            end
        end
        return "announced"
    end
    if not SUPPORTED[professionID] then return "ignored" end
    if kind == "Q" then
        local bits = split(body, ";")
        if recipient ~= "*" or #bits ~= 4 or not hash(bits[1]) or (bits[3] ~= "" and not GGM.IsProfessionGUID(bits[3]))
            or (bits[4] ~= "" and (not sync.senders[bits[4]] or bits[4] == sender))
            or (bits[2] ~= "manual" and bits[2] ~= "selection" and bits[2] ~= "save") then return "ignored" end
        if findSession(sync, sender, id) then return "ignored" end
        local cooldownKey = sender .. ":" .. professionID
        if (sync.peerCooldowns[cooldownKey] or -COOLDOWN) + COOLDOWN > now(sync) then return "ignored" end
        local preferredPeer = bits[4] ~= "" and bits[4] or nil
        local yielded
        if not preferredPeer or preferredPeer == sync.selfKey then
            yielded = yieldUnselectedComparison(sync, sender, bits[2])
        end
        local cannotRespond = (preferredPeer and preferredPeer ~= sync.selfKey) or sync.active or sync.manualOperation
        acceptPeerMessage(sync, sender)
        sync.peerCooldowns[cooldownKey] = now(sync)
        -- Bystanders cannot consume whisper data. Defer their own comparison
        -- rather than deleting it or starting all downloads simultaneously.
        local pending = sync.pending[professionID]
        if pending then
            pending.ready = false
            timer(sync, COOLDOWN + jitter(sync, 1, 5), function()
                if sync.pending[professionID] == pending then pending.ready = true; drainPending(sync) end
            end)
        end
        sync.cooldowns[professionID] = now(sync)
        if cannotRespond then return "observing" end
        local rows = manifest(sync, professionID)
        local digest = GGM.GetProfessionSyncDigest(sync.db, professionID, sync.members)
        if not rows or not digest then return "observing" end
        local session = createSession(sync, sender, id, professionID, bits[1], bits[2], bits[3], preferredPeer)
        if not session then return "observing" end
        -- Reserve the comparison we yielded to, including its response window.
        -- Pending work must not occupy the slot before selection arrives.
        if yielded then sync.active = session end
        local order, rosterCount = 0, 0
        for candidate in pairs(sync.senders) do
            rosterCount = rosterCount + 1
            if candidate < sync.selfKey then order = order + 1 end
        end
        -- Directed requests already name the sole responder. Discovery slots
        -- fit every supported roster size inside the two-second window.
        local claimDelay = preferredPeer and 0
            or CLAIM_START_SECONDS + CLAIM_SPREAD_SECONDS * order / rosterCount
        timer(sync, claimDelay, function()
            if session.finished or session.selected or (sync.active and sync.active ~= session) then return end
            -- Preserve yielded-query admission while CTL drains its backlog.
            if #sync.transport.outboundFrames > 0 and not yielded then return end
            if next(session.claims) then return end
            session.claims[sync.selfKey] = digest
            send(sync, "C", sender, id, professionID, sender .. ";" .. digest)
        end)
        return "comparing"
    end
    local bits = split(body, ";")
    local initiator
    -- M carries its provider, all other transaction data names the initiator.
    if kind == "S" or kind == "F" then initiator = sender
    else initiator = bits[1] end
    local session = findSession(sync, initiator, id)
    if not session or session.finished or session.professionID ~= professionID or now(sync) - session.startedAt > TTL then return "ignored" end
    if kind == "C" then
        if recipient ~= session.initiator or #bits ~= 2 or not hash(bits[2]) or session.selected
            or (session.preferredPeer and session.preferredPeer ~= sender) then return "ignored" end
        acceptPeerMessage(sync, sender)
        session.claims[sender] = bits[2]
        selectResponder(sync, session)
        return "claimed"
    elseif kind == "S" then
        if sender ~= session.initiator or not session.claims[recipient] or body ~= "" or session.selected then return "ignored" end
        acceptPeerMessage(sync, sender)
        session.selected = recipient
        if recipient == sync.selfKey then
            if sync.active and sync.active ~= session then return "ignored" end
            sync.active = session
            notify(sync, professionID, "Comparing cached data")
            sendManifest(sync, session)
        end
        return "selected"
    elseif kind == "M" then
        if not session.selected or (sender ~= session.initiator and sender ~= session.selected)
            or (sync.selfKey ~= session.initiator and sync.selfKey ~= session.selected) then return "ignored" end
        local header = split(bits[2] or "", ",")
        local page, pages = tonumber(header[1]), tonumber(header[2])
        if #header ~= 3 or not integer(page, 1, MAX_PAGES) or not integer(pages, page, MAX_PAGES)
            or (header[3] ~= "0" and header[3] ~= "1") or #bits > PAGE_SIZE + 2 then return "ignored" end
        local state = session.manifestPages[sender]
        if not state then state = { pages = pages, truncated = header[3], rows = {} }; session.manifestPages[sender] = state end
        if state.pages ~= pages or state.truncated ~= header[3] or state.rows[page] then return "ignored" end
        local parsed, lastGUID = {}, nil
        for index = 3, #bits do
            local row = split(bits[index], ",")
            local time = tonumber(row[2])
            local clockOk, clock = pcall(sync.api.GetServerTime)
            if #row ~= 3 or not sync.members[row[1]] or not hash(row[3]) or not integer(time, 1, 4294967295)
                or not clockOk or not readable(sync, clock) or not integer(clock, 1, 4294967295) or time > clock + 300
                or row[1] <= session.startGUID
                or (lastGUID and lastGUID >= row[1]) then return "ignored" end
            parsed[#parsed + 1] = { guid = row[1], capturedAt = time, hash = row[3]:lower() }; lastGUID = row[1]
        end
        acceptPeerMessage(sync, sender)
        state.rows[page] = parsed
        local rows = {}
        for index = 1, pages do
            if not state.rows[index] then return "manifest-partial" end
            for _, row in ipairs(state.rows[index]) do
                if #rows > 0 and rows[#rows].guid >= row.guid then return "ignored" end
                rows[#rows + 1] = row
            end
        end
        completeManifest(sync, session, sender, rows, header[3] == "1")
        planTransfers(sync, session)
        return "manifest"
    elseif kind == "R" then
        if #bits ~= 9 or not session.plan or not GGM.IsProfessionGUID(bits[2])
            or not integer(tonumber(bits[3]), 1, 4294967295) or not hash(bits[4])
            or (bits[5] ~= "record" and bits[5] ~= "fresh") then return "ignored" end
        local nameBloom, iconBloom = parseBloom(bits[6], bits[7]), parseBloom(bits[8], bits[9])
        if not nameBloom or not iconBloom or (bits[5] == "fresh"
            and (bits[6] ~= "0" or bits[7] ~= "-" or bits[8] ~= "0" or bits[9] ~= "-")) then return "ignored" end
        for _, item in ipairs(session.plan) do
            if item.guid == bits[2] and item.capturedAt == tonumber(bits[3]) and item.hash == bits[4]:lower()
                and item.action == bits[5] and item.provider == recipient and item.recipient == sender then
                if session.requested[item.guid] then return "ignored" end
                session.requested[item.guid] = true
                if recipient == sync.selfKey then
                    local record = GGM.GetProfessionSyncRecord(sync.db, item.guid, professionID)
                    if not record or record.capturedAt ~= item.capturedAt or record.hash ~= item.hash then
                        finish(sync, session, "Catch-up needed"); return "stale"
                    end
                    acceptPeerMessage(sync, sender)
                    if item.action == "fresh" then
                        send(sync, "T", sender, id, professionID, table.concat({ session.initiator, record.guid,
                            record.hash, record.capturedAt, record.source, encode(record.professionName) }, ";"))
                    else
                        send(sync, "D", sender, id, professionID,
                            session.initiator .. ";" .. recordBody(record, nameBloom, iconBloom))
                    end
                else
                    acceptPeerMessage(sync, sender)
                end
                return "requested"
            end
        end
    elseif kind == "D" then
        if not session.plan or #bits ~= 7 then return "ignored" end
        local record = parseRecord(sync, session, body:sub(#bits[1] + 2))
        if not record then return "ignored" end
        for _, item in ipairs(session.plan) do
            if item.guid == record.guid and item.action == "record" and item.capturedAt == record.capturedAt and item.hash == record.hash
                and item.provider == sender and item.recipient == recipient and session.requested[item.guid] and not session.dataSeen[item.guid] then
                acceptPeerMessage(sync, sender)
                local localRecord, localErr = GGM.GetProfessionSyncRecord(sync.db, record.guid, professionID)
                if not localRecord and localErr ~= "profession-sync-record-missing" then return "ignored" end
                local acknowledgement = "stored"
                if record.guid == sync.selfGUID or GGM.IsLocalCharacterGUID(sync.db, record.guid) then
                    session.conflict = true; acknowledgement = "skip"
                elseif not localRecord or localRecord.capturedAt < record.capturedAt then
                    local saved, err = GGM.SaveProfessionSnapshot(sync.db, sync.members[record.guid], record, { guildMembershipVerified = true })
                    if not saved then failed(sync, err); return "ignored" end
                    scheduleCatalogRefresh(sync)
                elseif localRecord and localRecord.hash ~= record.hash and localRecord.capturedAt == record.capturedAt then
                    session.conflict = true; acknowledgement = "skip"
                elseif localRecord and localRecord.capturedAt > record.capturedAt then
                    session.truncated = true; session.nextCursor = session.startGUID; acknowledgement = "defer"
                end
                session.dataSeen[item.guid] = true
                if not send(sync, "K", sender, id, professionID,
                    session.initiator .. ";" .. item.guid .. ";" .. item.capturedAt .. ";" .. acknowledgement) then return "ignored" end
                notify(sync, professionID, "Syncing cached data")
                requestNext(sync, session)
                maybeFinish(sync, session)
                return "stored"
            end
        end
    elseif kind == "T" then
        local capturedAt = tonumber(bits[4])
        local source = bits[5]
        local professionName = decode(bits[6], GGM.PROFESSION_MAX_NAME_BYTES)
        local clockOk, clock = pcall(sync.api.GetServerTime)
        if #bits ~= 6 or not GGM.IsProfessionGUID(bits[2]) or not hash(bits[3])
            or not integer(capturedAt, 1, 4294967295) or not clockOk or not readable(sync, clock)
            or not integer(clock, 1, 4294967295) or capturedAt > clock + 300
            or (source ~= GGM.PROFESSION_SOURCE_GUILD_LINK and source ~= GGM.PROFESSION_SOURCE_PLAYER)
            or not professionName or professionName == "" then return "ignored" end
        for _, item in ipairs(session.plan or {}) do
            if item.guid == bits[2] and item.hash == bits[3]:lower() and item.capturedAt == capturedAt
                and item.action == "fresh" and item.provider == sender and item.recipient == recipient
                and recipient == sync.selfKey and session.requested[item.guid] and not session.dataSeen[item.guid] then
                acceptPeerMessage(sync, sender)
                local localRecord, localErr = GGM.GetProfessionSyncRecord(sync.db, item.guid, professionID)
                local acknowledgement = "stored"
                if item.guid == sync.selfGUID or GGM.IsLocalCharacterGUID(sync.db, item.guid) then
                    session.conflict = true
                    acknowledgement = "skip"
                elseif not localRecord then
                    if localErr ~= "profession-sync-record-missing" then return "ignored" end
                    session.truncated = true; session.nextCursor = session.startGUID
                    acknowledgement = "defer"
                elseif localRecord.hash ~= item.hash then
                    session.conflict = true
                    acknowledgement = "skip"
                elseif localRecord.capturedAt >= capturedAt then
                    session.truncated = true; session.nextCursor = session.startGUID
                    acknowledgement = "defer"
                else
                    local updated = {
                        guid = localRecord.guid, professionID = professionID, professionName = professionName,
                        capturedAt = capturedAt, source = source, status = "cached", complete = true,
                        recipes = localRecord.recipes,
                    }
                    if not GGM.ValidateProfessionCapture(updated)
                        or GGM.HashProfessionRecipes(professionID, updated.recipes) ~= item.hash then return "ignored" end
                    local saved, err = GGM.SaveProfessionSnapshot(sync.db, sync.members[item.guid], updated,
                        { guildMembershipVerified = true })
                    if not saved then failed(sync, err); return "ignored" end
                    scheduleCatalogRefresh(sync)
                end
                session.dataSeen[item.guid] = true
                if not send(sync, "K", sender, id, professionID,
                    session.initiator .. ";" .. item.guid .. ";" .. item.capturedAt .. ";" .. acknowledgement) then return "ignored" end
                notify(sync, professionID, "Syncing cached data")
                requestNext(sync, session)
                maybeFinish(sync, session)
                return "stored"
            end
        end
    elseif kind == "K" then
        if #bits ~= 4 or not session.plan or (bits[4] ~= "stored" and bits[4] ~= "skip" and bits[4] ~= "defer") then return "ignored" end
        for _, item in ipairs(session.plan) do
            if item.guid == bits[2] and item.capturedAt == tonumber(bits[3]) and item.provider == sync.selfKey
                and item.recipient == sender and not session.dataSeen[item.guid]
                and (session.requested[item.guid] or bits[4] == "skip" or bits[4] == "defer") then
                acceptPeerMessage(sync, sender)
                session.dataSeen[item.guid] = true
                if bits[4] == "skip" then session.conflict = true end
                if bits[4] == "defer" then session.truncated = true; session.nextCursor = session.startGUID end
                requestNext(sync, session)
                maybeFinish(sync, session)
                return "acknowledged"
            end
        end
    elseif kind == "F" then
        if recipient ~= "*" or (body ~= "Cache hashes match" and body ~= "Compared cached data"
            and body ~= "Catch-up needed" and body ~= "Conflict: fresh observation needed") then return "ignored" end
        if session.plan then
            for _, item in ipairs(session.plan) do if not session.dataSeen[item.guid] then return "incomplete" end end
        elseif not next(session.claims) then return "ignored" end
        acceptPeerMessage(sync, sender)
        finish(sync, session, session.conflict and "Conflict: fresh observation needed" or session.truncated and "Catch-up needed" or body)
        return "finished"
    end
    return "ignored"
end

function GGM.CreateProfessionSync(api, db)
    if type(api) ~= "table" or type(db) ~= "table" then return nil, "profession-sync-unavailable" end
    local sync = { api = api, db = db, generation = 0, sequence = 0, sessions = {}, pending = {}, status = {},
        cooldowns = {}, peerCooldowns = {}, pendingSaves = {}, lastAnnouncedDigests = {}, saveCooldowns = {},
        selectedOnce = {}, cursor = {}, manualCursor = {}, peers = {}, heard = {}, presenceEvidence = {}, presenceRevision = 0,
        registered = false, rosterReady = false }
    local transport, err = GGM.CreateProfessionTransport(api, function(payload, sender, channel) return logical(sync, payload, sender, channel) end,
        function(failure) failed(sync, failure) end)
    if not transport then return nil, err end
    sync.transport = transport
    transport.canSendTarget = function(target) return canSendTarget(sync, target) end
    return sync, nil
end

function GGM.RegisterProfessionSync(sync)
    local ok, err = GGM.RegisterProfessionTransport(sync.transport)
    sync.registered = ok == true
    sync.lastError = err
    return ok, err
end

function GGM.HandleProfessionSyncAddonMessage(sync, prefix, frame, channel, rawSender)
    if not sync or not readable(sync, prefix) or not readable(sync, frame) or not readable(sync, channel)
        or not readable(sync, rawSender) or prefix ~= PREFIX or (channel ~= "GUILD" and channel ~= "WHISPER") or not safe(sync) then return "ignored" end
    if type(rawSender) ~= "string" then return "ignored" end
    if not rawSender:find("-", 1, true) then
        local ok, realm = pcall(sync.api.GetRealmName)
        if not ok or not readable(sync, realm) or type(realm) ~= "string" or realm == "" then return "ignored" end
        rawSender = rawSender .. "-" .. realm
    end
    local sender = key(rawSender)
    if not sender or not sync.senders[sender] or sender == sync.selfKey then return "ignored" end
    return GGM.ReceiveProfessionFrame(sync.transport, prefix, frame, channel, sender)
end

local function manualCandidates(sync, professionID, preferredPeer)
    local ordered, seen = {}, {}
    local function add(peer)
        if not peer or peer == sync.selfKey or seen[peer] or not sync.senders[peer] then return end
        seen[peer] = true
        ordered[#ordered + 1] = peer
    end
    local known = {}
    for peer, digests in pairs(sync.peers) do
        if type(digests) == "table" and next(digests) then known[#known + 1] = peer end
    end
    table.sort(known)
    for _, peer in ipairs(known) do add(peer) end
    local roster = {}
    for peer in pairs(sync.senders) do roster[#roster + 1] = peer end
    table.sort(roster)
    for _, peer in ipairs(roster) do add(peer) end

    local first = 1
    local previous = sync.manualCursor[professionID]
    if previous then
        for index, peer in ipairs(ordered) do
            if peer == previous then first = index % #ordered + 1; break end
        end
    end
    local candidates, included = {}, {}
    local function include(peer)
        if peer and not included[peer] and canSendTarget(sync, peer) and #candidates < MAX_MANUAL_PEERS then
            included[peer] = true
            candidates[#candidates + 1] = peer
        end
    end
    include(preferredPeer)
    for offset = 0, #ordered - 1 do
        include(ordered[(first + offset - 1) % #ordered + 1])
    end
    local overflow = false
    for _, peer in ipairs(ordered) do
        if canSendTarget(sync, peer) and not included[peer] then overflow = true; break end
    end
    return candidates, overflow
end

local function startProfessionComparison(sync, professionID, reason, preferredPeer, operation)
    if not SUPPORTED[professionID] or not safe(sync) then
        if sync then notify(sync, professionID or 0, "Sync unavailable") end
        return false, "profession-sync-unavailable"
    end
    if reason ~= "manual" and reason ~= "selection" and reason ~= "save" then return false, "profession-sync-reason-invalid" end
    if preferredPeer and (not sync.senders[preferredPeer] or preferredPeer == sync.selfKey
        or not canSendTarget(sync, preferredPeer)) then return false, "profession-sync-peer-unavailable" end
    if reason == "selection" and sync.selectedOnce[professionID] then return false, "profession-sync-already-compared" end
    if sync.active or (sync.manualOperation and sync.manualOperation ~= operation) then return false, "profession-sync-busy" end
    if (sync.cooldowns[professionID] or -COOLDOWN) + COOLDOWN > now(sync) then return false, "profession-sync-cooldown" end
    local digest, err = GGM.GetProfessionSyncDigest(sync.db, professionID, sync.members)
    if not digest then return false, err end
    local id = nextID(sync)
    local professionCursors = sync.cursor[professionID]
    local startGUID = preferredPeer and type(professionCursors) == "table" and professionCursors[preferredPeer]
    if type(startGUID) ~= "string" or not GGM.IsProfessionGUID(startGUID) then startGUID = "" end
    local session = createSession(sync, sync.selfKey, id, professionID, digest, reason, startGUID, preferredPeer)
    if not session then return false, "profession-sync-busy" end
    session.operation = operation
    if operation then operation.currentSession = session end
    if reason == "selection" then sync.selectedOnce[professionID] = true end
    sync.cooldowns[professionID], sync.active = now(sync), session
    notify(sync, professionID, "Comparing cached data")
    local sent = send(sync, "Q", "*", id, professionID, digest .. ";" .. reason .. ";" .. startGUID .. ";" .. (preferredPeer or ""), function(success)
        if not success or session.finished then return end
        if not preferredPeer then
            timer(sync, ELECTION_SECONDS, function()
                session.electionReady = true
                selectResponder(sync, session)
            end)
        end
        -- Old clients may still use roster slots extending to 26 seconds.
        -- This is only a no-response bound, never a wait after a usable claim.
        timer(sync, RESPONSE_DEADLINE_SECONDS, function()
            if session.finished or sync.active ~= session or session.selected then return end
            if not selectResponder(sync, session) then
                sync.lastError = "profession-sync-no-responder"
                finish(sync, session, "Sync unavailable")
            end
        end)
    end)
    return sent, sent and nil or sync.lastError
end

finishManualOperation = function(sync, operation, fallback)
    if not operation or operation.finished or sync.manualOperation ~= operation then return end
    operation.finished = true
    if operation.deadlineTimer and type(operation.deadlineTimer.Cancel) == "function" then
        pcall(operation.deadlineTimer.Cancel, operation.deadlineTimer)
    end
    sync.manualOperation = nil
    local session = operation.currentSession
    if session and not session.finished then
        session.finished = true
        sync.sessions[sessionKey(session.initiator, session.id)] = nil
        if sync.active == session then sync.active = nil end
    end
    operation.currentSession = nil
    local status
    if operation.conflict then
        status = "Conflict: fresh observation needed"
    elseif operation.uncertain or operation.moreCandidates then
        status = "Catch-up needed"
    elseif operation.completed > 0 and operation.matches == operation.completed then
        status = "Matched " .. operation.completed .. (operation.completed == 1 and " peer cache" or " peer caches")
    elseif operation.completed > 0 then
        status = "Compared with " .. operation.completed .. (operation.completed == 1 and " peer" or " peers")
    else
        status = fallback or "Sync unavailable"
    end
    notify(sync, operation.professionID, status)
    timer(sync, 0.5, function() drainPending(sync) end)
end

cancelManualOperation = function(sync, operation, status)
    if not operation or operation.finished or sync.manualOperation ~= operation then return end
    operation.finished, operation.cancelled, operation.uncertain = true, true, true
    local professionID = operation.professionID
    local finalStatus = manualOperationHasConflict(operation) and "Conflict: fresh observation needed" or status or "Catch-up needed"
    -- Invalidate callbacks and discard every dependent transport frame. CTL may
    -- still submit the one frame already handed to it, but cannot start another.
    GGM.CancelProfessionSync(sync)
    notify(sync, professionID, finalStatus)
end

local function continueManualOperationNow(sync, operation)
    if not operation or operation.finished or operation.cancelled or sync.manualOperation ~= operation then return false end
    if not safe(sync) then
        cancelManualOperation(sync, operation, "Sync unavailable")
        return false
    end
    local current = now(sync)
    if not finiteTime(current) or current >= operation.deadline then
        cancelManualOperation(sync, operation, "Catch-up needed")
        return false
    end
    if sync.active or #sync.transport.outboundFrames > 0 then
        timer(sync, math.min(0.5, operation.deadline - current), function() continueManualOperation(sync, operation) end)
        return true
    end
    local peer = operation.candidates[operation.nextIndex]
    if not peer then
        finishManualOperation(sync, operation, "Sync unavailable")
        return true
    end
    if not canSendTarget(sync, peer) then
        operation.uncertain = true
        operation.nextIndex = operation.nextIndex + 1
        timer(sync, 0.5, function() continueManualOperation(sync, operation) end)
        return true
    end
    local remaining = (sync.cooldowns[operation.professionID] or -COOLDOWN) + COOLDOWN - current
    if remaining > 0 then
        timer(sync, math.min(remaining, operation.deadline - current), function() continueManualOperation(sync, operation) end)
        return true
    end
    operation.nextIndex = operation.nextIndex + 1
    operation.attempted = operation.attempted + 1
    local ok, err = startProfessionComparison(sync, operation.professionID, "manual", peer, operation)
    if not ok and sync.manualOperation == operation then
        operation.uncertain = true
        timer(sync, math.min(0.5, operation.deadline - current), function() continueManualOperation(sync, operation) end)
    end
    return ok
end

continueManualOperation = function(sync, operation)
    return continueManualOperationNow(sync, operation)
end

function GGM.RequestProfessionSync(sync, professionID, reason, preferredPeer)
    reason = reason or "manual"
    if reason ~= "manual" then return startProfessionComparison(sync, professionID, reason, preferredPeer) end
    if not SUPPORTED[professionID] or not safe(sync) then
        if sync then notify(sync, professionID or 0, "Sync unavailable") end
        return false, "profession-sync-unavailable"
    end
    if preferredPeer and (not sync.senders[preferredPeer] or preferredPeer == sync.selfKey
        or not canSendTarget(sync, preferredPeer)) then return false, "profession-sync-peer-unavailable" end
    if sync.active or sync.manualOperation then return false, "profession-sync-busy" end
    if (sync.cooldowns[professionID] or -COOLDOWN) + COOLDOWN > now(sync) then return false, "profession-sync-cooldown" end
    local candidates, moreCandidates = manualCandidates(sync, professionID, preferredPeer)
    if #candidates == 0 then
        notify(sync, professionID, "Catch-up needed")
        return false, "profession-sync-peer-unavailable"
    end
    local operation = {
        professionID = professionID, candidates = candidates, moreCandidates = moreCandidates,
        nextIndex = 1, attempted = 0, completed = 0, matches = 0,
        startedAt = now(sync), deadline = now(sync) + MANUAL_OPERATION_SECONDS,
    }
    sync.manualOperation = operation
    local timerOk, deadlineTimer = timer(sync, MANUAL_OPERATION_SECONDS, function()
        if sync.manualOperation == operation and not operation.finished then
            cancelManualOperation(sync, operation, "Catch-up needed")
        end
    end)
    if not timerOk then
        failed(sync, "profession-sync-timer-unavailable")
        return false, sync.lastError
    end
    operation.deadlineTimer = deadlineTimer
    sync.manualCursor[professionID] = candidates[#candidates]
    return continueManualOperation(sync, operation)
end

function GGM.LoginProfessionSync()
    return false
end

local function announceSave(sync, professionID, digest)
    if not send(sync, "A", "*", nextID(sync), 0, professionID .. "," .. digest .. ",save") then return false end
    sync.saveCooldowns[professionID] = now(sync)
    sync.lastAnnouncedDigests[professionID] = digest
    return true
end

function GGM.PublishProfessionSyncSave(sync, professionID, beforeHash)
    if not safe(sync) then return false end
    local digest = GGM.GetProfessionSyncDigest(sync.db, professionID, sync.members)
    if not digest or digest == beforeHash then return false end
    if sync.pendingSaves[professionID] then return true end
    local remaining = (sync.saveCooldowns[professionID] or -COOLDOWN) + COOLDOWN - now(sync)
    if remaining > 0 then
        -- One save-created job holds the latest local state. The timer only
        -- paces that work; it never originates a poll, heartbeat, or retry.
        local pending = {}
        sync.pendingSaves[professionID] = pending
        if not timer(sync, remaining, function()
            if sync.pendingSaves[professionID] ~= pending then return end
            sync.pendingSaves[professionID] = nil
            if not safe(sync) then notify(sync, professionID, "Catch-up needed"); return end
            local latest = GGM.GetProfessionSyncDigest(sync.db, professionID, sync.members)
            if latest and latest ~= sync.lastAnnouncedDigests[professionID] then announceSave(sync, professionID, latest) end
        end) then
            sync.pendingSaves[professionID] = nil
            return false
        end
        notify(sync, professionID, "Update queued")
        return true
    end
    if digest == sync.lastAnnouncedDigests[professionID] then return false end
    return announceSave(sync, professionID, digest)
end

function GGM.GetProfessionSyncStatus(sync, professionID)
    return sync and sync.status[professionID] or "Sync unavailable"
end
