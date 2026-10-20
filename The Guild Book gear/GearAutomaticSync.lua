local _, GGM = ...

local MAX_TARGETS, MAX_IN_FLIGHT = 16, 4
local function resetAutomaticGuild(sync)
    sync.automaticGuild, sync.automaticRoster = nil, nil
    sync.automaticRemaining, sync.automaticCursor = nil, nil
end

local function public(api, value)
    if type(api.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(api.issecretvalue, value)
    return ok and secret == false
end

local function roster(sync)
    local api = sync.api
    local ok, result = pcall(function()
        local inGuild, combat = api.IsInGuild(), api.InCombatLockdown()
        if not public(api, inGuild) or not public(api, combat) or inGuild ~= true or combat ~= false then return end
        local count, selfGUID = api.GetNumGuildMembers(true), api.UnitGUID("player")
        if not public(api, count) or not public(api, selfGUID) or type(count) ~= "number"
            or count < 1 or count > 1000 or count ~= math.floor(count) then return end
        local name, _, _, realm = api.GetGuildInfo("player")
        if not public(api, name) or not public(api, realm) or type(name) ~= "string" or name == "" then return end
        realm = realm or api.GetRealmName()
        if not public(api, realm) or type(realm) ~= "string" or realm == "" then return end
        local rows, found, guids = {}, false, {}
        for index = 1, count do
            local row = { api.GetGuildRosterInfo(index) }
            if not public(api, row[1]) or not public(api, row[17]) or type(row[1]) ~= "string"
                or type(row[17]) ~= "string" or row[17] == "" then return end
            local character, characterRealm = row[1]:match("^([^-]+)%-(.+)$")
            if not character then character, characterRealm = row[1], api.GetRealmName() end
            if not public(api, characterRealm) or type(characterRealm) ~= "string" then return end
            local identity = { name = character, realm = characterRealm, key = character .. "-" .. characterRealm, guid = row[17] }
            if not GGM.ValidateSyncIdentity(identity) or rows[identity.key] or guids[row[17]] then return end
            rows[identity.key], guids[row[17]] = identity, true
            if row[17] == selfGUID then found = true end
        end
        if not found then return end
        return { members = rows, selfGUID = selfGUID, guild = name .. ":" .. realm }
    end)
    return ok and result or nil
end

local function interrupt(sync)
    local attempt = sync.automaticAttempt
    if not attempt then return end
    attempt.cancelled = true
    for _, job in ipairs(attempt.jobs) do
        if job.timer and type(job.timer.Cancel) == "function" then pcall(job.timer.Cancel, job.timer) end
        local pending = job.id and sync.pendingSnapshotRequests[job.id]
        if pending and pending.onFinished == job.callback then
            sync.pendingSnapshotRequests[job.id] = nil
            sync.pendingSnapshotRequestTargets[pending.targetKey] = nil
            sync.pendingSnapshotRequestCount = sync.pendingSnapshotRequestCount - 1
            if pending.sendToken then GGM.CancelSyncPayload(sync.transport, pending.sendToken) end
        end
    end
    sync.automaticAttempt = nil
    if attempt.done then attempt.done(true) end
end

local function run(sync, done)
    local current = roster(sync)
    if not current then done(true); return end
    if sync.automaticGuild and sync.automaticGuild ~= current.guild then
        GGM.StopAutomaticSync(sync.automaticController)
        return
    end
    sync.automaticGuild, sync.automaticRoster = current.guild, current.members
    if not sync.automaticRemaining then
        sync.automaticRemaining = {}
        for key, identity in pairs(current.members) do
            if identity.guid ~= current.selfGUID then sync.automaticRemaining[key] = identity end
        end
    end
    local candidates = {}
    for key in pairs(sync.automaticRemaining) do
        if current.members[key] and current.members[key].guid ~= current.selfGUID then
            sync.automaticRemaining[key] = current.members[key]
            candidates[#candidates + 1] = key
        else sync.automaticRemaining[key] = nil end
    end
    table.sort(candidates)
    if sync.automaticCursor then
        local rotated = {}
        for _, key in ipairs(candidates) do if key > sync.automaticCursor then rotated[#rotated + 1] = key end end
        for _, key in ipairs(candidates) do if key <= sync.automaticCursor then rotated[#rotated + 1] = key end end
        candidates = rotated
    end
    local attempt = { jobs = {}, nextIndex = 1, active = 0, attempted = 0, done = done }
    sync.automaticAttempt = attempt
    local pump
    pump = function()
        if attempt.cancelled or sync.automaticAttempt ~= attempt then return end
        local verified = roster(sync)
        if not verified or verified.guild ~= sync.automaticGuild then
            interrupt(sync); done(true); return
        end
        while attempt.active < MAX_IN_FLIGHT and attempt.attempted < MAX_TARGETS do
            local key = candidates[attempt.nextIndex]
            if not key then break end
            attempt.nextIndex, attempt.attempted = attempt.nextIndex + 1, attempt.attempted + 1
            sync.automaticCursor = key
            local job = { key = key }
            attempt.jobs[#attempt.jobs + 1] = job
            attempt.active = attempt.active + 1
            job.callback = function(success)
                if job.finished or attempt.cancelled or sync.automaticAttempt ~= attempt then return end
                job.finished = true; attempt.active = attempt.active - 1
                if job.timer and type(job.timer.Cancel) == "function" then pcall(job.timer.Cancel, job.timer) end
                if success then sync.automaticRemaining[key] = nil end
                -- Yield: completion may arrive within a transport callback.
                local ok, handle = pcall(sync.api.C_Timer.NewTimer, 0, pump)
                if not ok or not handle then interrupt(sync); done(true) end
            end
            local target = verified.members[key]
            local sent, _, requestID
            if target then sent, _, requestID = GGM.RequestCompleteSnapshot(sync, target, job.callback) end
            job.id = requestID
            if not sent then job.callback(false)
            else
                local ok, handle = pcall(sync.api.C_Timer.NewTimer, GGM.SYNC_SNAPSHOT_REQUEST_TTL_SECONDS + 0.1, function()
                    if not attempt.cancelled then GGM.ExpireGuildSnapshotRequests(sync); job.callback(false) end
                end)
                if ok and handle then job.timer = handle else interrupt(sync); done(true); return end
            end
        end
        if attempt.active == 0 then
            sync.automaticAttempt = nil
            done(next(sync.automaticRemaining) ~= nil)
        end
    end
    pump()
end

function GGM.LoginGearSync(sync)
    if not sync or type(GGM.CreateAutomaticSyncController) ~= "function" then return false end
    if not sync.automaticController then
        if type(sync.api.C_GuildInfo) == "table" and type(sync.api.C_GuildInfo.GuildRoster) == "function" then
            pcall(sync.api.C_GuildInfo.GuildRoster)
        end
        sync.automaticController = GGM.CreateAutomaticSyncController(sync.api,
            function(done) run(sync, done) end, function() interrupt(sync) end)
        sync.validateAutomaticResponse = function(message)
            local current = roster(sync)
            return current and (not sync.automaticGuild or current.guild == sync.automaticGuild)
                and current.members[message.requester.key] ~= nil and current.members[message.target.key] ~= nil
        end
        sync.validateAutomaticIncoming = function(sender, message)
            local current = roster(sync)
            local target = current and current.members[message.target.key]
            return current and current.guild == sync.automaticGuild and current.members[sender] ~= nil
                and target and (not message.target.guid or message.target.guid == target.guid)
        end
    end
    return GGM.StartAutomaticSync(sync.automaticController)
end

function GGM.WakeGearSync(sync)
    if not sync or not sync.automaticController then return end
    local guildOK, inGuild = pcall(sync.api.IsInGuild)
    if guildOK and public(sync.api, inGuild) and inGuild == false then
        GGM.StopAutomaticSync(sync.automaticController)
        resetAutomaticGuild(sync)
        return
    end
    local current = roster(sync)
    if current and sync.automaticGuild and current.guild ~= sync.automaticGuild then
        GGM.StopAutomaticSync(sync.automaticController)
        resetAutomaticGuild(sync)
        GGM.WakeAutomaticSync(sync.automaticController)
        return
    end
    if not current then
        if sync.automaticAttempt then interrupt(sync) end
        return
    end
    GGM.WakeAutomaticSync(sync.automaticController)
end
